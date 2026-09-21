import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/notifications/providers/notifications_provider.dart';
import '../services/analytics/app_entry_providers.dart';
import '../../features/venue_claim/providers/venue_claim_provider.dart';
import '../../providers/api_provider.dart';
import '../../providers/auth_provider.dart';
import '../../shared/notifications/notification_state.dart';
import '../../shared/notifications/notifications_provider.dart';
import '../router/app_router.dart';
import '../services/experiment_service.dart';
import '../services/unified_analytics_service.dart';
import 'notification_tap_resume.dart';
import 'os_tray_channel.dart';

/// PROD-2523 T-D — wires the three foreground/tap FCM entry points to the
/// in-app router. The background isolate handler lives in
/// `fcm_background_handler.dart` and is registered separately in
/// `main.dart` because it must be set before `runApp`.
///
/// Tap policy: every tap goes through [_navigateOrStash], which ALWAYS
/// stashes the `route_path` via [NotificationTapResume] first. If the
/// session is valid, it navigates immediately and clears the stash
/// after a short race window. If not, it forces login; the auth-state
/// listener in `app.dart` consumes the stash on the next transition to
/// authenticated. Stashing unconditionally covers the cached-but-dead-
/// token cold-start case where `isAuthenticated` is true at tap time
/// but a `/auth/me` 401 triggers `forceLogout()` seconds later — the
/// post-login resumer needs the stash to recover the destination.
class FcmHandlerService {
  FcmHandlerService(this._ref);

  final Ref _ref;
  bool _initialised = false;
  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onOpenedAppSub;
  Timer? _stashClearTimer;

  /// Race-window between a tap-time navigation and `forceLogout()` from
  /// the background `/auth/me` validation. If the user is still
  /// authenticated this long after the navigate, the stash isn't needed
  /// and is cleared to avoid replaying the destination on a future
  /// non-notification cold-start.
  static const _stashRaceWindow = Duration(seconds: 8);

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  /// Idempotent. Called once from `app.dart` after first frame so the
  /// GoRouter and `authStateProvider` are mounted by the time
  /// `getInitialMessage` resolves on cold-start.
  Future<void> initialise() async {
    if (_initialised || !_isMobile) return;
    _initialised = true;

    _onMessageSub = FirebaseMessaging.onMessage.listen(_handleForeground);
    _onOpenedAppSub = FirebaseMessaging.onMessageOpenedApp.listen(
      (msg) => unawaited(_handleTap(msg, entry: 'background')),
    );

    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        await _handleTap(initial, entry: 'cold_start');
      }
    } catch (e, st) {
      debugPrint('[FcmHandlerService] getInitialMessage failed: $e\n$st');
    }
  }

  void dispose() {
    _onMessageSub?.cancel();
    _onOpenedAppSub?.cancel();
    _stashClearTimer?.cancel();
    _onMessageSub = null;
    _onOpenedAppSub = null;
    _stashClearTimer = null;
    _initialised = false;
  }

  // ---- handlers ----

  void _handleForeground(RemoteMessage message) {
    // PROD-2511 kill-switch — if the engine has been flipped off mid-
    // session (handlers can't be torn down once registered), drop the
    // event on the floor. No toast, no badge refresh, no analytics.
    if (!_ref.read(experimentServiceProvider).notificationsEngineEnabled) {
      return;
    }
    // A business-claim transition (approved/rejected/revoked) changes this
    // venue's ownership — refresh the cached claim state now so an open detail
    // page flips to "Managed"/"Claim" without waiting for a manual reload.
    _maybeRefreshOwnershipState(message);
    // App is in the foreground — FCM doesn't show the OS tray on iOS or
    // Android in this state by default. Mirror title+body into the
    // in-app toast so the user still has a tap target.
    final notification = message.notification;
    final title = notification?.title?.trim();
    final body = notification?.body?.trim();
    // PROD-2524 T-E: refresh the inbox-badge unread count whenever a
    // push lands in the foreground. The badge would otherwise lag until
    // the next manual screen open / app resume.
    // ignore: unawaited_futures
    _ref.read(notificationsUnreadCountProvider.notifier).refresh();

    // Analytics: foreground delivery — pair with `notification_push_tap`
    // for open-rate.
    final notificationId = _readNotificationId(message);
    if (notificationId != null) {
      _ref
          .read(unifiedAnalyticsProvider)
          .trackNotificationReceived(
            notificationId: notificationId,
            category: _readCategory(message),
            notificationType: _readType(message),
          );
    }

    final text = [
      if (title != null && title.isNotEmpty) title,
      if (body != null && body.isNotEmpty) body,
    ].join(' · ');
    if (text.isEmpty) return;

    final route = _readRoutePath(message);
    _ref
        .read(notificationsProvider.notifier)
        .show(
          message: text,
          variant: SokoVariant.info,
          action: route != null
              ? SokoAction(
                  label: 'Abrir',
                  onTap: () {
                    if (notificationId != null) {
                      _ref
                          .read(unifiedAnalyticsProvider)
                          .trackNotificationPushTap(
                            notificationId: notificationId,
                            entry: 'foreground_toast',
                            category: _readCategory(message),
                            notificationType: _readType(message),
                          );
                    }
                    unawaited(_navigateOrStash(route));
                  },
                )
              : null,
        );
  }

  Future<void> _handleTap(
    RemoteMessage message, {
    required String entry,
  }) async {
    // PROD-2511 kill-switch — drop taps on the floor when the engine is
    // off. Both background and cold-start entries route through here.
    if (!_ref.read(experimentServiceProvider).notificationsEngineEnabled) {
      return;
    }
    // Refresh ownership before navigating so the venue the tap lands on (or any
    // warm-cached detail page) reflects the claim transition immediately.
    _maybeRefreshOwnershipState(message);
    final tappedNotificationId = _readNotificationId(message);
    if (tappedNotificationId != null) {
      _ref
          .read(unifiedAnalyticsProvider)
          .trackNotificationPushTap(
            notificationId: tappedNotificationId,
            entry: entry,
            category: _readCategory(message),
            notificationType: _readType(message),
          );
    }
    // PROD-2524 — mark the inbox row read on tap. Backend PATCH is
    // idempotent (re-PATCH already-read returns changed=false) so a
    // double-tap or a tap-then-open-inbox sequence is safe. Gated on
    // auth at tap time: when the user is logged out we stash the
    // route via [_navigateOrStash] below and route them through login;
    // marking-read can wait for them to open the inbox manually
    // post-auth (rare path, not worth threading the id through the
    // stash).
    //
    // Routed through the API directly (NOT
    // ``notificationsInboxProvider.notifier.markRead``) because the
    // inbox-state path short-circuits when the matching item isn't
    // already in ``state.items`` — i.e. exactly the cold-tap-from-
    // background case this handler exists for. The unread-badge
    // refresh is owned here too so the decrement happens whether or
    // not the inbox screen is mounted.
    if (tappedNotificationId != null &&
        _ref.read(authStateProvider).isAuthenticated) {
      unawaited(_markReadFireAndForget(tappedNotificationId));
    }

    final route = _readRoutePath(message);
    // Tier 2: a push tap is a `push` entry door, routed or not.
    _ref.read(appEntryTrackerProvider).notePush(route);
    if (route == null) return;
    await _navigateOrStash(route);
  }

  Future<void> _markReadFireAndForget(String notificationId) async {
    try {
      await _ref.read(notificationsApiProvider).markRead(notificationId);
      _ref.read(notificationsUnreadCountProvider.notifier).decrement();
      // PROD-2781 follow-up — clear the tapped push from the OS tray.
      // The system already removes the tapped one on user tap, but a
      // sibling delivered with the same `apns-collapse-id` / tag (the
      // notification_id stamped by backend) is collapsed/cancelled
      // here too, so duplicate notifications don't linger.
      unawaited(_ref.read(osTrayChannelProvider).clearByTag(notificationId));
    } catch (e) {
      debugPrint('[FcmHandlerService] markRead($notificationId) failed: $e');
    }
  }

  Future<void> _navigateOrStash(String routePath) async {
    // Stash unconditionally before navigating. On cold-start the cached
    // access token makes `isAuthenticated` true BEFORE `/auth/me` has
    // validated it; if that validation 401s seconds later and triggers
    // `forceLogout()`, the post-login resumer at
    // `app.dart:_resumeNotificationTapIfStashed` needs the stash to
    // send the user to `routePath` instead of stranding them on login.
    await NotificationTapResume.stash(routePath);

    final auth = _ref.read(authStateProvider);
    if (auth.isAuthenticated) {
      try {
        _ref.read(appRouterProvider).go(routePath);
      } catch (e, st) {
        debugPrint('[FcmHandlerService] router.go($routePath) failed: $e\n$st');
      }
      // If the race didn't fire within the window, the user is safely
      // on `routePath` and the stash is no longer needed. Clearing it
      // here prevents a future cold-start (icon tap, not notification)
      // from replaying the navigation via the unauth→auth listener.
      // The stash file's TTL is the backstop if the app is killed
      // before this timer runs.
      _stashClearTimer?.cancel();
      _stashClearTimer = Timer(_stashRaceWindow, () async {
        if (_ref.read(authStateProvider).isAuthenticated) {
          await NotificationTapResume.consume();
        }
      });
      return;
    }
    try {
      _ref.read(appRouterProvider).go(AppRoutes.login);
    } catch (e, st) {
      debugPrint('[FcmHandlerService] router.go(login) failed: $e\n$st');
    }
  }

  /// Business-claim push types that change a venue's ownership state.
  static const _claimTransitionTypes = {
    'business_claim_approved',
    'business_claim_rejected',
    'business_claim_revoked',
  };

  /// Invalidate the cached ownership providers on a claim-transition push so
  /// every claim-aware surface (detail CTA, "Managed" badge, owned-venues
  /// shelf) refetches. The venue id rides in `data['venue_id']`; the push
  /// itself routes to the notifications inbox, so we key off the type + id
  /// rather than the route.
  void _maybeRefreshOwnershipState(RemoteMessage message) {
    final type = _readType(message);
    if (type == null || !_claimTransitionTypes.contains(type)) return;
    final venueId = message.data['venue_id'];
    if (venueId is String && venueId.trim().isNotEmpty) {
      _ref.invalidate(venueClaimStateProvider(venueId.trim()));
    }
    _ref.invalidate(ownedVenueIdsProvider);
    _ref.invalidate(ownedBusinessProfileEntriesProvider);
  }

  static String? _readRoutePath(RemoteMessage message) {
    final raw = message.data['route_path'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('/')) return null;
    return mapNotificationRoute(trimmed);
  }

  /// Maps the id-less legacy daily-drop targets onto the `/drop` deep link.
  ///
  /// **History, because the shape of this method is the bug that was here.**
  /// PROD-2908 rewrote the per-id `route_path=/recommendations/{id}` (stamped
  /// by the backend's `daily_tasks.py`) into `/drop?rec_id={id}`, because at
  /// the time the client router had no `/recommendations/:id` GoRoute and a raw
  /// `router.go` dead-ended at `_UnknownRouteRedirect`. PROD-3730 then added
  /// that route (`RecommendationDeepLinkScreen`), which resolves the id and
  /// opens its destination **independently of which Discovery feed variant is
  /// live** — but this rewrite kept intercepting first, so the push never
  /// reached it and instead went through `/drop` → `/?daily_drop=<n>&rec_id=`,
  /// which only the legacy home page knew how to resolve. PROD-4431 drops the
  /// per-id rewrite: `/recommendations/{id}` now passes through to its own
  /// route, exactly like the in-app inbox tap already did (which is why the
  /// inbox row worked while the push tap did not).
  ///
  /// Still mapped: the id-less `/recommendations` and the legacy
  /// `/recommendations/today`, neither of which matches the per-id route, both
  /// meaning "today's drop" → `/drop`. Every other route passes through
  /// untouched. Applied at the read boundary so the live navigate, the
  /// unconditional stash, and the post-login stash replay all use the same
  /// mapped route.
  @visibleForTesting
  static String mapNotificationRoute(String routePath) {
    final uri = Uri.tryParse(routePath);
    if (uri == null) return routePath;
    final segments = uri.pathSegments;
    if (segments.isEmpty || segments.first != 'recommendations') {
      return routePath;
    }
    // A per-id target owns its own route (PROD-3730) — hands off.
    if (segments.length >= 2 && segments[1] != 'today') return routePath;
    // `/recommendations` or `/recommendations/today` → generic daily-drop entry.
    return AppRoutes.dailyDrop;
  }

  static String? _readNotificationId(RemoteMessage message) {
    final raw = message.data['notification_id'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _readCategory(RemoteMessage message) {
    final raw = message.data['category'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// The notification sub-type (`new_follower`, `zine_item_added`, …).
  /// `FirebasePushClient` always sets `data["type"]` alongside
  /// `notification_id` / `category`, so this is present on every push.
  /// Carried into the analytics events so per-type open-rate is sliceable.
  static String? _readType(RemoteMessage message) {
    final raw = message.data['type'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

final fcmHandlerServiceProvider = Provider<FcmHandlerService>((ref) {
  final service = FcmHandlerService(ref);
  ref.onDispose(service.dispose);
  return service;
});
