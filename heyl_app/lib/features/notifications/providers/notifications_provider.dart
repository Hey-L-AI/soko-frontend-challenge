import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/os_tray_channel.dart';
import '../../../core/services/experiment_service.dart';
import '../../../data/models/notification_item.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';

/// Which slice of `notification_events` the inbox screen is currently
/// rendering. `inbox` is unread + non-dismissed only; `history` is
/// everything the user has touched but hasn't been swept.
enum NotificationsInboxMode { inbox, history }

/// PROD-2524 T-E inbox state. Held by the screen-level notifier; the
/// bottom-nav badge reads its own slim `unreadCountProvider`.
class NotificationsInboxState {
  final List<NotificationItem> items;
  final NotificationsInboxMode mode;
  final bool isLoading;
  final bool hasLoadedOnce;
  final Object? error;

  /// The mode the current `items` were last loaded for. Null until the
  /// first refresh completes. While `loadedMode != mode`, `items` belong
  /// to a previous mode and the screen should treat itself as still
  /// loading instead of rendering the empty state (PROD-2803).
  final NotificationsInboxMode? loadedMode;

  const NotificationsInboxState({
    this.items = const [],
    this.mode = NotificationsInboxMode.inbox,
    this.isLoading = false,
    this.hasLoadedOnce = false,
    this.error,
    this.loadedMode,
  });

  NotificationsInboxState copyWith({
    List<NotificationItem>? items,
    NotificationsInboxMode? mode,
    bool? isLoading,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
    NotificationsInboxMode? loadedMode,
  }) {
    return NotificationsInboxState(
      items: items ?? this.items,
      mode: mode ?? this.mode,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
      loadedMode: loadedMode ?? this.loadedMode,
    );
  }

  /// Rows the screen should render for the current mode.
  ///
  /// `inbox`: only unread, non-dismissed. The server already filters
  /// this way (`include_read=false&include_dismissed=false`), but
  /// optimistic mutations also need to drop a freshly-read/dismissed
  /// row from the list without waiting for the next refresh.
  ///
  /// `history`: show everything the server returned, in order. Read
  /// and dismissed rows render with their existing demoted styling.
  List<NotificationItem> get visible => switch (mode) {
    NotificationsInboxMode.inbox =>
      items
          .where((it) => it.isUnread && !it.isDismissed)
          .toList(growable: false),
    NotificationsInboxMode.history => items,
  };

  /// Same content as `visible`, grouped by `bundleKey` for the inbox
  /// list. Rows without a `bundleKey` form singleton bundles so the
  /// screen renders a uniform list. Newest-first ordering preserved.
  List<NotificationBundle> get visibleBundles =>
      NotificationBundle.group(visible);
}

/// Inbox notifier. Fetches fresh on every `refresh()` call (delivery plan:
/// "no resume-poll dedupe needed"). Optimistic local mutations on
/// read/dismiss so the UI is responsive; the next `refresh()` reconciles.
class NotificationsInboxNotifier extends Notifier<NotificationsInboxState> {
  @override
  NotificationsInboxState build() {
    // Refresh on auth-flip so a fresh login sees the new account's inbox.
    ref.listen<bool>(authStateProvider.select((s) => s.isAuthenticated), (
      prev,
      next,
    ) {
      if (next && prev != true) {
        // ignore: unawaited_futures
        refresh();
      }
    });
    return const NotificationsInboxState();
  }

  Future<void> refresh({
    NotificationsInboxMode mode = NotificationsInboxMode.inbox,
  }) async {
    if (state.isLoading) return;
    state = state.copyWith(isLoading: true, mode: mode, clearError: true);
    final isHistory = mode == NotificationsInboxMode.history;
    try {
      final page = await ref
          .read(notificationsApiProvider)
          .list(includeRead: isHistory, includeDismissed: isHistory);
      state = state.copyWith(
        items: page.items,
        isLoading: false,
        hasLoadedOnce: true,
        loadedMode: mode,
      );
      // Resync the badge — it might have drifted from the inbox state
      // if a push arrived mid-refresh.
      // ignore: unawaited_futures
      ref.read(notificationsUnreadCountProvider.notifier).refresh();
    } catch (e, st) {
      debugPrint('[NotificationsInbox] refresh failed: $e\n$st');
      state = state.copyWith(
        isLoading: false,
        error: e,
        hasLoadedOnce: true,
        loadedMode: mode,
      );
    }
  }

  /// Optimistic mark-read. Server PATCH happens fire-and-forget; on
  /// failure the optimistic flip is reverted.
  Future<void> markRead(String id) async {
    final idx = state.items.indexWhere((it) => it.id == id);
    if (idx < 0) return;
    final original = state.items[idx];
    if (!original.isUnread) return;
    final now = DateTime.now().toUtc();
    final updated = [...state.items]..[idx] = original.copyWith(readAt: now);
    state = state.copyWith(items: updated);
    // ignore: unawaited_futures
    ref.read(notificationsUnreadCountProvider.notifier).decrement();
    try {
      await ref.read(notificationsApiProvider).markRead(id);
      // PROD-2781 follow-up — keep the OS tray in sync with the
      // inbox. Backend stamps tag/apns-collapse-id = notification_id,
      // so cancelling by tag = id clears that one delivered push.
      // ignore: unawaited_futures
      ref.read(osTrayChannelProvider).clearByTag(id);
    } catch (e) {
      debugPrint('[NotificationsInbox] markRead($id) failed: $e');
      // Revert.
      final reverted = [...state.items]..[idx] = original;
      state = state.copyWith(items: reverted);
      // ignore: unawaited_futures
      ref.read(notificationsUnreadCountProvider.notifier).refresh();
    }
  }

  /// Optimistic mark-bundle-read. Flips every unread member of the bundle
  /// in one server round-trip via
  /// `POST /api/v1/app/notifications/bundles/{bundle_key}/read` (PROD-2781
  /// B3). On failure, reverts every optimistically-flipped row.
  Future<void> markBundleRead(String bundleKey) async {
    final indices = <int>[];
    for (var i = 0; i < state.items.length; i++) {
      final it = state.items[i];
      if (it.bundleKey == bundleKey && it.isUnread) {
        indices.add(i);
      }
    }
    if (indices.isEmpty) return;
    final originals = <int, NotificationItem>{
      for (final i in indices) i: state.items[i],
    };
    final now = DateTime.now().toUtc();
    final updated = [...state.items];
    for (final i in indices) {
      updated[i] = originals[i]!.copyWith(readAt: now);
    }
    state = state.copyWith(items: updated);
    final badge = ref.read(notificationsUnreadCountProvider.notifier);
    for (var i = 0; i < indices.length; i++) {
      badge.decrement();
    }
    try {
      await ref.read(notificationsApiProvider).markBundleRead(bundleKey);
      // Clear each member's delivered push from the OS tray. Bundle
      // key isn't the system tag — each member ships with its own
      // notification_id-stamped tag — so we loop the freshly-read ids.
      final tray = ref.read(osTrayChannelProvider);
      for (final original in originals.values) {
        // ignore: unawaited_futures
        tray.clearByTag(original.id);
      }
    } catch (e) {
      debugPrint('[NotificationsInbox] markBundleRead($bundleKey) failed: $e');
      final reverted = [...state.items];
      originals.forEach((i, original) {
        reverted[i] = original;
      });
      state = state.copyWith(items: reverted);
      // ignore: unawaited_futures
      badge.refresh();
    }
  }

  /// Optimistic mark-all-read.
  Future<void> markAllRead() async {
    final now = DateTime.now().toUtc();
    final updated = state.items
        .map((it) => it.isUnread ? it.copyWith(readAt: now) : it)
        .toList(growable: false);
    state = state.copyWith(items: updated);
    ref.read(notificationsUnreadCountProvider.notifier).setLocal(0);
    try {
      await ref.read(notificationsApiProvider).markAllRead();
      // Sweep the OS tray in one round-trip — every delivered push is
      // now redundant with the in-app "all read" state.
      // ignore: unawaited_futures
      ref.read(osTrayChannelProvider).clearAll();
    } catch (e) {
      debugPrint('[NotificationsInbox] markAllRead failed: $e');
      // ignore: unawaited_futures
      refresh(mode: state.mode);
    }
  }

  /// Optimistic dismiss. The row stays in `items` (server keeps it as a
  /// soft-deleted row) but is filtered out of `state.visible`.
  Future<void> dismiss(String id) async {
    final idx = state.items.indexWhere((it) => it.id == id);
    if (idx < 0) return;
    final original = state.items[idx];
    final now = DateTime.now().toUtc();
    final updated = [...state.items]
      ..[idx] = original.copyWith(dismissedAt: now);
    state = state.copyWith(items: updated);
    if (original.isUnread) {
      // ignore: unawaited_futures
      ref.read(notificationsUnreadCountProvider.notifier).decrement();
    }
    try {
      await ref.read(notificationsApiProvider).dismiss(id);
      // Dismiss implies "I'm done with this" — clear the matching push
      // from the OS tray too.
      // ignore: unawaited_futures
      ref.read(osTrayChannelProvider).clearByTag(id);
    } catch (e) {
      debugPrint('[NotificationsInbox] dismiss($id) failed: $e');
      final reverted = [...state.items]..[idx] = original;
      state = state.copyWith(items: reverted);
      if (original.isUnread) {
        // ignore: unawaited_futures
        ref.read(notificationsUnreadCountProvider.notifier).refresh();
      }
    }
  }
}

final notificationsInboxProvider =
    NotifierProvider<NotificationsInboxNotifier, NotificationsInboxState>(
      NotificationsInboxNotifier.new,
    );

// ---------------------------------------------------------------------
// Unread-count provider — feeds the bottom-nav badge.
// ---------------------------------------------------------------------

/// Slim badge state. Owns its own GET /unread-count call so screens that
/// don't open the inbox still get a live count.
class NotificationsUnreadCountNotifier extends Notifier<int> {
  @override
  int build() {
    ref.listen<bool>(authStateProvider.select((s) => s.isAuthenticated), (
      prev,
      next,
    ) {
      if (next && prev != true) {
        // ignore: unawaited_futures
        refresh();
      } else if (!next && prev == true) {
        // Logged out — drop the badge.
        state = 0;
      }
    });
    // Cold-start path: when the provider is first built and the user is
    // already authed (token rehydrated from secure storage on launch),
    // the auth-transition listener above never fires — `isAuthenticated`
    // was `true` at init and stays `true`. Fetch the count eagerly so
    // the bell badge is correct on the first frame, not only after the
    // user opens the inbox or the app resumes from background.
    // Microtask so the initial `return 0` lands before `refresh()`
    // mutates state.
    //
    // PROD-2511 — skip the cold-start fetch when the engine kill-switch
    // is off. The badge is already hidden in that case, but skipping
    // the GET avoids a needless backend hop on every launch.
    final engineEnabled = ref
        .read(experimentServiceProvider)
        .notificationsEngineEnabled;
    if (engineEnabled && ref.read(authStateProvider).isAuthenticated) {
      Future.microtask(refresh);
    }
    return 0;
  }

  Future<void> refresh() async {
    // PROD-2511 — kill-switch: when the engine is disabled, clear the
    // badge and skip the GET. Refresh is called from the auth-flip
    // listener, the inbox screen pull-to-refresh, and the foreground
    // FCM handler — all of which can fire after a mid-session flag flip.
    if (!ref.read(experimentServiceProvider).notificationsEngineEnabled) {
      state = 0;
      return;
    }
    final auth = ref.read(authStateProvider);
    if (!auth.isAuthenticated) {
      state = 0;
      return;
    }
    try {
      final count = await ref.read(notificationsApiProvider).unreadCount();
      state = count;
    } catch (e) {
      debugPrint('[NotificationsUnreadCount] refresh failed: $e');
      // Leave the previous count in place — a transient blip shouldn't
      // wipe the badge.
    }
  }

  /// Optimistic local decrement triggered by mark-read / dismiss flows.
  /// Clamped at zero.
  void decrement() {
    if (state > 0) state = state - 1;
  }

  void setLocal(int value) {
    state = value < 0 ? 0 : value;
  }
}

final notificationsUnreadCountProvider =
    NotifierProvider<NotificationsUnreadCountNotifier, int>(
      NotificationsUnreadCountNotifier.new,
    );
