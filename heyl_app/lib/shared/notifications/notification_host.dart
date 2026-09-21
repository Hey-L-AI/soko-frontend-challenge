import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../data/models/import_job.dart';
import '../../data/models/instagram_share.dart';
import '../../features/contributions/providers/contribution_polling_provider.dart';
import '../../features/event_detail/providers/event_detail_provider.dart';
import '../../features/instagram_share/instagram_share_open_helpers.dart';
import '../../features/instagram_share/providers/instagram_share_polling_provider.dart';
import '../../features/instagram_share/widgets/instagram_share_review_sheet.dart';
import '../../l10n/generated/l10n.dart';
import '../../providers/import_list_provider.dart';
import 'heyl_notification.dart';
import 'notification_state.dart';
import 'notifications_provider.dart';

/// Mounted at `MaterialApp.builder` so its `Stack` sibling sits above the
/// entire Navigator (and therefore above every route, dialog, and modal
/// sheet). Owns:
///   - the in/out animation controller
///   - the listener that maps `instagramSharePollingProvider` transitions
///     to notification calls (replaces the old shell-level IG banner).
///   - the listener that maps `importListProvider` (Google Maps list import)
///     transitions to notification calls (PROD-1931, replaces the in-hub
///     `ImportProgressCard` orphaned by PROD-1911's hub rewrite).
///   - the listener that maps `contributionPollingProvider` (photo → event
///     contribution) transitions to notification calls (PROD-2404, replaces
///     the in-sheet polling/result steps).
class NotificationHost extends ConsumerStatefulWidget {
  final Widget child;
  const NotificationHost({super.key, required this.child});

  @override
  ConsumerState<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends ConsumerState<NotificationHost>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  ProviderSubscription<InstagramSharePollingState>? _sharePollingSubscription;
  ProviderSubscription<ContributionPollingState>?
  _contributionPollingSubscription;
  bool _didSubscribeToSharePolling = false;

  /// Keeps a pre-warmed `eventDetailProvider` (an autoDispose family) alive
  /// while the IG-share "ready" banner is showing, so tapping "Open" lands on
  /// an already-loaded detail screen. See [_prewarmDetail].
  ProviderSubscription<AsyncValue<EventDetailSnapshot>>? _detailPrewarmSub;

  /// The share id we've already pre-warmed a detail for — guards against
  /// re-warming on every state emission while the banner stays visible.
  String? _prewarmedShareId;

  /// Cached state used while the reverse animation plays — keeps the
  /// outgoing notification visible until the slide-up + fade-out
  /// completes, then we drop it.
  SokoState? _displayed;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didSubscribeToSharePolling) return;
    _didSubscribeToSharePolling = true;
    // Adapter: map IG share polling state to notifications. Owned by the
    // host (not by feature code) so the IG banner can be retired without
    // leaving cross-cutting context.push wiring sprinkled across the
    // share-pipeline. listenManual keeps the subscription alive for the
    // host's lifetime; disposed in dispose().
    _sharePollingSubscription = ref.listenManual<InstagramSharePollingState>(
      instagramSharePollingProvider,
      (prev, next) => _onShareStateChanged(prev, next),
      fireImmediately: true,
    );

    // Adapter: map Google Maps list-import state to notifications (PROD-1931).
    // Same shape as the IG adapter above — long-running background task →
    // sticky loading → success with "Ver" action / error with "Repetir".
    // Replaces the in-hub `ImportProgressCard` retired by PROD-1911.
    ref.listenManual<ImportListState>(
      importListProvider,
      (prev, next) => _onImportStateChanged(prev, next),
      fireImmediately: true,
    );

    // Adapter: map photo→event contribution polling to notifications
    // (PROD-2404). Mirrors IG share — the bottom sheet pops on submit,
    // and processing/success/failure are surfaced as toasts.
    _contributionPollingSubscription = ref
        .listenManual<ContributionPollingState>(
          contributionPollingProvider,
          (prev, next) => _onContributionStateChanged(prev, next),
          fireImmediately: true,
        );
  }

  @override
  void dispose() {
    _sharePollingSubscription?.close();
    _contributionPollingSubscription?.close();
    _detailPrewarmSub?.close();
    _ctrl.dispose();
    super.dispose();
  }

  void _onShareStateChanged(
    InstagramSharePollingState? prev,
    InstagramSharePollingState next,
  ) {
    final l10n = Lt.of(context);
    final notifier = ref.read(notificationsProvider.notifier);

    // Hidden states → clear any IG-share notification.
    if (!next.shouldShow) {
      // Only dismiss if the currently-visible notification belongs to
      // us; we don't want to nuke an unrelated success/error toast.
      final cur = ref.read(notificationsProvider);
      if (cur != null && cur.message == _lastShownMessage) {
        notifier.dismiss();
      }
      _lastShownMessage = null;
      return;
    }

    if (next.isProcessing) {
      _showShare(
        message: l10n.instagramShareBannerProcessing,
        variant: SokoVariant.loading,
      );
      return;
    }

    if (next.producedEntities) {
      final share = next.activeShare!;
      final String message;
      if (share.classification == 'venue_update') {
        message = l10n.instagramShareBannerLastShareVenue;
      } else if (share.eventIds.isNotEmpty) {
        message = l10n.instagramShareBannerLastShareEvents(
          share.eventIds.length,
        );
      } else {
        message = l10n.instagramShareBannerLastShareReady;
      }
      final showReviewPicker =
          share.eventIds.length >= 2 ||
          (share.classification == 'event_announcement' &&
              share.venueId != null);
      final actionLabel = showReviewPicker
          ? l10n.instagramShareBannerReview
          : l10n.importToastViewAction;

      // Single-event auto-open path: warm the event detail now so the "Open"
      // tap lands instantly instead of waiting on fresh network calls.
      if (!showReviewPicker) {
        _prewarmDetail(share, next.targetListId);
      }

      _showShare(
        message: message,
        variant: SokoVariant.success,
        action: SokoAction(
          label: actionLabel,
          onTap: () {
            // `NotificationHost`'s own context sits ABOVE the Navigator
            // (we're at `MaterialApp.builder` level), so passing it to
            // `showModalBottomSheet` / `context.push` would fail to find
            // a Navigator. Reach down to the router's navigator context
            // — the same trick `app.dart:_waitForNavigatorReady` uses.
            final navCtx = ref
                .read(appRouterProvider)
                .routerDelegate
                .navigatorKey
                .currentContext;
            if (navCtx == null) return;
            if (showReviewPicker) {
              showInstagramShareReviewSheet(
                context: navCtx,
                ref: ref,
                share: share,
                targetListId: next.targetListId,
              );
            } else {
              openIngestedItem(navCtx, ref: ref);
            }
          },
        ),
      );
      return;
    }

    // Terminal / failed / past_event.
    _showShare(
      message: l10n.instagramShareBannerFailed,
      variant: SokoVariant.error,
    );
  }

  /// Warm `eventDetailProvider` the moment a single-event share is ready, so the
  /// banner's "Open" CTA — which routes to `/lists/<listId>/events/<eventId>`
  /// via [openIngestedItem] — lands on an already-loaded detail screen instead
  /// of a spinner. Holding the `listenManual` subscription keeps the autoDispose
  /// provider (and its fetched result) alive across the tap until
  /// `EventDetailScreen` mounts and watches the same key; the subscription is
  /// deliberately NOT closed on banner dismiss so the warmed result survives the
  /// `dismiss()` → `context.push` gap. It's superseded by the next share and
  /// closed in [dispose].
  ///
  /// Requires a known target list — the detail is keyed by `(eventId, listId)`
  /// and needs the same non-null `listId` the route uses. The chat / native
  /// flows (no `targetListId`) resolve the list on tap and skip this. Fires once
  /// per share; venue-only shares carry no `eventId` and are skipped.
  void _prewarmDetail(SharedPostOut share, String? listId) {
    if (listId == null) return;
    if (_prewarmedShareId == share.id) return;

    final eventId =
        share.eventId ??
        (share.eventIds.isNotEmpty ? share.eventIds.first : null);
    if (eventId == null || eventId.isEmpty) return;

    _prewarmedShareId = share.id;
    _detailPrewarmSub?.close();
    // Empty listener body — holding the subscription is enough to keep the
    // provider (and its in-flight/settled fetch) alive.
    _detailPrewarmSub = ref.listenManual(
      eventDetailProvider(EventDetailKey(eventId: eventId, listId: listId)),
      (_, __) {},
    );
  }

  /// Track the last IG-share message we shoved into the notification
  /// system so we can tell whether a `dismiss` is safe (don't kill an
  /// unrelated notification when the polling state clears).
  String? _lastShownMessage;

  void _showShare({
    required String message,
    required SokoVariant variant,
    SokoAction? action,
  }) {
    _lastShownMessage = message;
    ref
        .read(notificationsProvider.notifier)
        .show(
          message: message,
          variant: variant,
          action: action,
          // IG share lifecycle is owned by the polling provider — the
          // notification clears when state.dismissed flips (via X tap
          // wired into the card) or when shouldShow goes false. No
          // auto-dismiss timer.
          sticky: true,
          // X tap (or action-button auto-dismiss) clears only the
          // notification widget; without this wire-up the polling
          // provider stays at shouldShow=true and the listener re-emits
          // the toast on the next poll tick. The provider's dismiss()
          // is idempotent on the host's own programmatic dismiss path
          // (`!next.shouldShow` branch above) since the state is
          // already terminal there.
          onDismissed: () =>
              ref.read(instagramSharePollingProvider.notifier).dismiss(),
        );
  }

  // ── Photo→event contribution adapter (PROD-2404) ─────────────────────
  // Mirrors the IG-share adapter above. The contribution sheet pops on
  // submit; processing/success/failure are surfaced via this toast.

  String? _lastShownContributionMessage;

  void _onContributionStateChanged(
    ContributionPollingState? prev,
    ContributionPollingState next,
  ) {
    final l10n = Lt.of(context);
    final notifier = ref.read(notificationsProvider.notifier);

    if (!next.shouldShow) {
      final cur = ref.read(notificationsProvider);
      if (cur != null && cur.message == _lastShownContributionMessage) {
        notifier.dismiss();
      }
      _lastShownContributionMessage = null;
      return;
    }

    if (next.isProcessing) {
      _showContribution(
        message: l10n.photoContributionBannerProcessing,
        variant: SokoVariant.loading,
      );
      return;
    }

    if (next.producedEntities) {
      final c = next.activeContribution!;
      final count = c.eventIds.length;
      final message = count == 1
          ? l10n.photoContributionBannerSuccessSingle
          : l10n.photoContributionBannerSuccessMultiple(count);
      _showContribution(
        message: message,
        variant: SokoVariant.success,
        action: c.eventIds.isEmpty
            ? null
            : SokoAction(
                label: l10n.photoContributionBannerView,
                onTap: () {
                  // NotificationHost sits ABOVE the Navigator (we're at
                  // `MaterialApp.builder` level), so reach the router's
                  // navigator context to push — same trick the IG /
                  // import adapters use.
                  final navCtx = ref
                      .read(appRouterProvider)
                      .routerDelegate
                      .navigatorKey
                      .currentContext;
                  if (navCtx == null) return;
                  // First event for v1 — multi-event review picker is
                  // an IG-share feature only at this point.
                  navCtx.push('/events/${c.eventIds.first}');
                },
              ),
      );
      return;
    }

    // Terminal / failed.
    _showContribution(
      message: l10n.photoContributionBannerFailed,
      variant: SokoVariant.error,
    );
  }

  void _showContribution({
    required String message,
    required SokoVariant variant,
    SokoAction? action,
  }) {
    _lastShownContributionMessage = message;
    ref
        .read(notificationsProvider.notifier)
        .show(
          message: message,
          variant: variant,
          action: action,
          // Lifecycle owned by `contributionPollingProvider` — clears via
          // its auto-dismiss timer (30 s after terminal) or the X tap.
          sticky: true,
          // X tap (or action-button auto-dismiss) clears only the
          // notification widget; without this wire-up the polling
          // provider stays at shouldShow=true and the listener re-emits
          // the toast on the next poll tick. The provider's dismiss()
          // is idempotent on the host's own programmatic dismiss path
          // (`!next.shouldShow` branch above) since the state is
          // already terminal there.
          onDismissed: () =>
              ref.read(contributionPollingProvider.notifier).dismiss(),
        );
  }

  // ── Import (Google Maps list import) adapter ─────────────────────────
  // Mirrors the IG-share adapter above. Two tracking fields:
  //   - `_lastShownImportMessage`: same role as `_lastShownMessage` — only
  //     dismiss our own notification when the import state clears.
  //   - `_lastEmittedImportKey`: dedup on (status, phase). The provider
  //     polls every 3 s; without this we'd retrigger the sticky loading
  //     notification on every tick instead of only when the phase changes.

  String? _lastShownImportMessage;

  ({ImportJobStatus? status, ImportPhase? phase})? _lastEmittedImportKey;

  /// Most recent terminal job we've already notified for, so the same
  /// success/failure doesn't re-emit if the provider state lingers.
  String? _lastEmittedTerminalJobId;

  void _onImportStateChanged(ImportListState? prev, ImportListState next) {
    final l10n = Lt.of(context);
    final notifier = ref.read(notificationsProvider.notifier);

    // No active job → drop our notification (only if it's still ours, so
    // an unrelated success/error toast isn't nuked).
    if (!next.hasJob) {
      final cur = ref.read(notificationsProvider);
      if (cur != null && cur.message == _lastShownImportMessage) {
        notifier.dismiss();
      }
      _lastShownImportMessage = null;
      _lastEmittedImportKey = null;
      _lastEmittedTerminalJobId = null;
      return;
    }

    // Dedup: only emit when the (status, phase) tuple changes. Provider
    // polls every 3 s with the same (processing, scraping) for several
    // seconds at a time — without this we'd thrash the notification.
    final key = (status: next.status, phase: next.progress?.phase);
    if (key == _lastEmittedImportKey) return;
    _lastEmittedImportKey = key;

    if (next.isActive) {
      _showImport(
        message: _importLoadingMessage(next, l10n),
        variant: SokoVariant.loading,
        sticky: true,
      );
      return;
    }

    if (next.isCompleted) {
      // Guard against re-emitting the same terminal state. Provider keeps
      // `isCompleted` until something resets it; the listener might fire
      // again under a re-mount (hot reload, etc.) with the same job.
      if (next.jobId != null && next.jobId == _lastEmittedTerminalJobId) {
        return;
      }
      _lastEmittedTerminalJobId = next.jobId;
      _showImportCompleted(next, l10n);
      return;
    }

    if (next.isFailed) {
      if (next.jobId != null && next.jobId == _lastEmittedTerminalJobId) {
        return;
      }
      _lastEmittedTerminalJobId = next.jobId;
      _showImport(
        message: l10n.importToastFailed,
        variant: SokoVariant.error,
        action: SokoAction(
          label: l10n.importToastRetryAction,
          onTap: () => ref.read(importListProvider.notifier).retryImport(),
        ),
        sticky: false,
      );
      return;
    }
  }

  void _showImportCompleted(ImportListState state, Lt l10n) {
    final result = state.result;
    final listId = result?.listId;
    final listName = state.listName ?? result?.listName ?? '';
    final imported = result?.imported ?? 0;
    final total = result?.total;
    // BE PROD-1933 added `with_notes_count` to the result — when the
    // source Maps list had personal notes attached to places, the import
    // pipes each note into `UserListItem.tip`. Surface it in the toast
    // copy so the win is visible ("18 with your notes"). Falls back to
    // the no-notes copy when the count is 0 (no notes on the source
    // list, OR a pre-PROD-1933 BE that doesn't send the field — the
    // model defaults to 0).
    final withNotes = result?.withNotesCount ?? 0;
    final isPartial = total != null && total > imported;
    final String message;
    if (withNotes > 0) {
      message = isPartial
          ? l10n.importToastPartialSuccessWithNotes(
              listName,
              imported,
              total,
              withNotes,
            )
          : l10n.importToastSuccessWithNotes(listName, imported, withNotes);
    } else {
      message = isPartial
          ? l10n.importToastPartialSuccess(listName, imported, total)
          : l10n.importToastSuccess(listName, imported);
    }
    _showImport(
      message: message,
      variant: SokoVariant.success,
      action: listId == null
          ? null
          : SokoAction(
              label: l10n.importToastViewAction,
              onTap: () {
                // Same trick as the IG adapter — `NotificationHost`'s own
                // context sits ABOVE the Navigator (we're at
                // `MaterialApp.builder` level), so reach down to the
                // router's navigator context for the push.
                final navCtx = ref
                    .read(appRouterProvider)
                    .routerDelegate
                    .navigatorKey
                    .currentContext;
                if (navCtx == null) return;
                navCtx.push('/lists/$listId');
              },
            ),
      sticky: false,
    );
  }

  String _importLoadingMessage(ImportListState s, Lt l10n) {
    switch (s.progress?.phase) {
      case ImportPhase.scraping:
        return l10n.importPhaseScraping;
      case ImportPhase.enriching:
        return l10n.importPhaseEnriching;
      case ImportPhase.creatingVenues:
        return l10n.importPhaseCreatingVenues;
      case ImportPhase.creatingList:
        return l10n.importPhaseCreatingList;
      case ImportPhase.done:
        return l10n.importPhaseDone;
      case null:
        return l10n.importPhaseQueued;
    }
  }

  void _showImport({
    required String message,
    required SokoVariant variant,
    SokoAction? action,
    required bool sticky,
  }) {
    _lastShownImportMessage = message;
    ref
        .read(notificationsProvider.notifier)
        .show(
          message: message,
          variant: variant,
          action: action,
          sticky: sticky,
        );
  }

  @override
  Widget build(BuildContext context) {
    // Drive the animation off the provider state.
    final state = ref.watch(notificationsProvider);

    if (state != null && state != _displayed) {
      _displayed = state;
      _ctrl.forward();
    } else if (state == null && _displayed != null) {
      _ctrl.reverse().then((_) {
        if (!mounted) return;
        if (ref.read(notificationsProvider) == null) {
          setState(() => _displayed = null);
        }
      });
    }

    // PROD-1885: anchor the toast to the BOTTOM of the viewport (used to
    // be top), and reserve clearance above the [DiscoveryBottomNav] when
    // it's mounted so the toast never sits on top of the nav. The
    // clearance is published by the shell into
    // [notificationBottomInsetProvider] — `0.0` outside the shell, at
    // which point we fall back to the viewport's own bottom safe-area
    // inset (iOS home indicator / browser chrome).
    final navClearance = ref.watch(notificationBottomInsetProvider);
    final mq = MediaQuery.of(context);
    final bottomInset =
        (navClearance > 0 ? navClearance : mq.viewPadding.bottom) + 8;

    return Stack(
      children: [
        widget.child,
        if (_displayed != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: bottomInset,
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, child) {
                final t = Curves.easeOutCubic.transform(_ctrl.value);
                return Opacity(
                  opacity: t,
                  // Slide UP from below (the toast lives at the bottom
                  // now, so the in-animation rises into place).
                  child: Transform.translate(
                    offset: Offset(0, (1 - t) * 24),
                    child: child,
                  ),
                );
              },
              // PROD-1885: cap the toast at 600 px on wide viewports —
              // a 1920-px-wide pink banner reads as a page-level error,
              // not a contextual toast. Centered with `Align` so the
              // edge insets above (`left/right: 16`) still apply when
              // the viewport is narrower than the cap.
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: SokoCard(state: _displayed!),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
