import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/push_permission_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../data/models/daily_drop.dart';
import '../../../providers/providers.dart';
import '../../daily_drop/providers/daily_drop_provider.dart';
import '../../daily_drop/utils/daily_drop_deep_link_outcome.dart';
import '../../daily_drop/utils/daily_drop_destination.dart';
import '../../daily_drop/widgets/daily_drop_deep_link_sheet.dart';
import '../../daily_drop/widgets/daily_drop_generating_sheet.dart';
import '../../notifications/providers/notification_preferences_provider.dart';
import '../../product_tour/providers/product_tour_controller.dart';
import '../../user_profiling/providers/user_profiling_gate_provider.dart';
import '../../user_profiling/widgets/user_profiling_deep_link_sheet.dart';
import '../../weekly_bundle/providers/weekly_bundle_provider.dart';
import '../../weekly_bundle/weekly_bundle_nav.dart';
import '../../weekly_bundle/widgets/weekly_bundle_deep_link_sheet.dart';
import 'discovery_shell.dart' show discoveryNavObserver;

/// PROD-4431 — owns every home-surface deep-link marker, ABOVE the
/// legacy/v2 variant split.
///
/// **Why it isn't in `DiscoveryScreen` any more.** These four markers
/// (`?daily_drop=<n>`, `?rec_id=`, `?weekly_bundle=<n>`, `?user_profiling=<n>`)
/// are stamped by the `/drop`, `/weekly-bundle` and `/user-profiling/flow`
/// route redirects, which bounce through `/` expecting the home page to resolve
/// them. They used to be constructor args of `DiscoveryScreen` — i.e. of the
/// **legacy** page only — so `DiscoveryVariantPage` handing the route to
/// `DiscoveryFeedV2Screen` silently dropped every one of them: on the v2 feed a
/// daily-drop push tap, a weekly-bundle push tap and a guest profiling link all
/// landed on a bare feed and did nothing. Marker resolution is a property of
/// the *route*, not of which feed happens to render underneath, so it lives
/// here, wrapping the variant. PROD-4011 deleting the legacy page then cannot
/// take the deep links with it.
///
/// Renders [child] untouched; all of its work is post-frame side effects
/// (a pushed detail/overlay, or a cause-specific bottom sheet).
class DiscoveryDeepLinkResolver extends ConsumerStatefulWidget {
  const DiscoveryDeepLinkResolver({
    super.key,
    required this.child,
    this.dailyDropDeepLinkNonce,
    this.dailyDropRecId,
    this.weeklyBundleDeepLinkNonce,
    this.userProfilingDeepLinkNonce,
  });

  /// The home surface this resolver wraps — the variant page, not a feed.
  final Widget child;

  /// PROD-2908 — the exact recommendation id from a per-recommendation daily-
  /// drop push (`/recommendations/{id}` → `/drop?rec_id=` → forwarded here
  /// alongside [dailyDropDeepLinkNonce]). When present, the resolver opens that
  /// drop directly via a user-scoped, location-free `GET /recommendations/{id}`
  /// — the robust cold-start path, since the drop was generated hours before
  /// the push fired. Null for id-less entries (`/drop` short/bridge links),
  /// which fall back to the today+poll state machine.
  ///
  /// Note the push itself no longer arrives here: since PROD-4431
  /// `FcmHandlerService` leaves `/recommendations/{id}` alone so it hits the
  /// PROD-3730 route directly. This path stays for `/drop?rec_id=` links.
  final String? dailyDropRecId;

  /// PROD-2565 — non-null when the user arrived via the `/drop` deep link
  /// (router rewrites `/drop` → `/?daily_drop=<n>`). The value is a per-tap
  /// nonce: a *new* value means a fresh `/drop` open — so a warm-session
  /// re-tap of the same link re-fires — while the same value across rebuilds
  /// is the same open and doesn't. When set, the resolver settles today's
  /// Daily Drop and either pushes its detail page on top of home or
  /// shows a cause-specific empty-state sheet (logged-out / profiling /
  /// unsupported-area / come-back-tomorrow).
  final String? dailyDropDeepLinkNonce;

  /// PROD-2564 — the Weekly Bundle analog of [dailyDropDeepLinkNonce] (router
  /// rewrites `/weekly-bundle` → `/?weekly_bundle=<n>`). When set, the resolver
  /// awaits the weekly-bundle provider's terminal state and either pushes the
  /// Weekly Bundle overlay on top of home or shows a cause-specific
  /// empty-state sheet (logged-out / unsupported-area / come-back).
  final String? weeklyBundleDeepLinkNonce;

  /// PROD-2566 — non-null when a LOGGED-OUT user arrived via the
  /// `/user-profiling/flow` deep link (router rewrites it to the
  /// `?user_profiling=N` marker for guests only; authed taps go straight to the
  /// flow / persona landing). When set, the resolver shows the "log in to do the
  /// profiling" sheet over guest home. Per-tap nonce, same re-fire
  /// semantics as [dailyDropDeepLinkNonce].
  final String? userProfilingDeepLinkNonce;

  @override
  ConsumerState<DiscoveryDeepLinkResolver> createState() =>
      _DiscoveryDeepLinkResolverState();
}

class _DiscoveryDeepLinkResolverState
    extends ConsumerState<DiscoveryDeepLinkResolver> {
  /// PROD-2565 — the last `/drop` nonce handled. Guards against re-firing on
  /// an unrelated rebuild (same nonce → no-op) while still firing on a fresh
  /// tap (new nonce). This resolver stays mounted under the pushed detail /
  /// sheet, so backing out keeps the same nonce and never re-triggers.
  String? _handledDailyDropNonce;

  /// PROD-2564 — the Weekly Bundle analog of [_handledDailyDropNonce].
  String? _handledWeeklyBundleNonce;

  /// PROD-2566 — the profiling-deep-link analog of [_handledDailyDropNonce].
  String? _handledUserProfilingNonce;

  /// Previous "home is the top route" reading, for the PROD-2700 tour
  /// un-suppression edge below.
  bool _wasTopDiscoveryRoute = true;

  @override
  void initState() {
    super.initState();
    _wasTopDiscoveryRoute = discoveryNavObserver.isOnDiscovery;
    discoveryNavObserver.addListener(_handleDiscoveryRouteChange);
    _maybeHandleDailyDropDeepLink();
    _maybeHandleWeeklyBundleDeepLink();
    _maybeHandleUserProfilingDeepLink();
  }

  @override
  void didUpdateWidget(covariant DiscoveryDeepLinkResolver oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Warm-app case: a `/drop` tap while home is already mounted rebuilds
    // this widget with a fresh nonce (same `/` page, State reused). The nonce
    // comparison inside fires on a new tap and no-ops on unrelated rebuilds.
    _maybeHandleDailyDropDeepLink();
    _maybeHandleWeeklyBundleDeepLink();
    _maybeHandleUserProfilingDeepLink();
  }

  @override
  void dispose() {
    discoveryNavObserver.removeListener(_handleDiscoveryRouteChange);
    super.dispose();
  }

  /// PROD-2700: returning to home as the top route (e.g. backing out of a
  /// deep-link drop/bundle detail) lifts the tour suppression this resolver
  /// sets, so the tour can start fresh. Safe no-op when it was never set.
  /// Owned here rather than in `DiscoveryScreen` because the suppression is
  /// set here, and `ProductTourHost` lives in the shell above both variants —
  /// so the v2 feed would otherwise stay suppressed for the whole session.
  void _handleDiscoveryRouteChange() {
    final isTopDiscoveryRoute = discoveryNavObserver.isOnDiscovery;
    if (!_wasTopDiscoveryRoute && isTopDiscoveryRoute) {
      ref.read(tourSuppressedForDeepLinkProvider.notifier).state = false;
    }
    _wasTopDiscoveryRoute = isTopDiscoveryRoute;
  }

  @override
  Widget build(BuildContext context) => widget.child;

  // ── PROD-2565: `/drop` deep-link resolution ──────────────────────────────

  void _maybeHandleDailyDropDeepLink() {
    final nonce = widget.dailyDropDeepLinkNonce;
    if (nonce == null || nonce == _handledDailyDropNonce) return;
    _handledDailyDropNonce = nonce;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_resolveDailyDropDeepLink());
    });
  }

  /// Remove the `daily_drop=1` marker from the URL (keeping any other query,
  /// e.g. `utm_*`), returning the location to `/`. Back-nav from the pushed
  /// detail/sheet then lands on a clean `/`, and clearing the marker re-arms
  /// the one-shot guard (see [didUpdateWidget]) so a later `/drop` tap fires
  /// again. **Authenticated path only** — for a logged-out user the marker is
  /// the signal that exempts the entry from the no-choice-yet `/login` bounce
  /// ([_isDailyDropDeepLinkEntry]), so stripping it before the login sheet
  /// would bounce a first-time guest to `/login` instead.
  void _stripDailyDropMarker() {
    final params =
        Map<String, String>.from(GoRouterState.of(context).uri.queryParameters)
          ..remove('daily_drop')
          // PROD-2908 — drop the per-rec id alongside the marker so it doesn't
          // linger in the URL and re-fire the by-id fetch on an unrelated rebuild.
          ..remove('rec_id');
    context.replace(
      params.isEmpty ? '/' : Uri(path: '/', queryParameters: params).toString(),
    );
  }

  Future<void> _resolveDailyDropDeepLink() async {
    final analytics = ref.read(unifiedAnalyticsProvider);
    final actionContext = analytics.actionContext;
    // Capture the per-rec id up front: [_stripDailyDropMarker] below rewrites
    // the URL, which rebuilds this widget with `dailyDropRecId == null`.
    final recId = widget.dailyDropRecId;

    // Logged-out → login sheet (Decision #12). The drop is personalized, so
    // there's nothing to resolve for a guest; the CTA returns to `/drop`
    // after auth, dismissing keeps them on guest Discovery. We deliberately
    // do NOT strip the `daily_drop=1` marker here: it keeps the no-choice-yet
    // `/login` exemption active so the guest lands on Discovery + the sheet
    // (post-login reopen comes via returnUrl=/drop and a fresh mount).
    if (!ref.read(isAuthenticatedProvider)) {
      await showDailyDropLoginSheet(context, ref);
      return;
    }

    // Authenticated: no no-choice bounce applies, so it's safe to strip the
    // marker now — clean back-nav + re-fire on a second tap.
    _stripDailyDropMarker();

    // PROD-2908 by-id fast path. A per-recommendation push carries the exact
    // id, and the drop was generated hours before the push fired, so a single
    // user-scoped, location-free `GET /recommendations/{id}` returns it
    // deterministically — no dependence on the today+generating state machine
    // nor on location being resolved yet on a cold start (the two things that
    // made the old 4 s cap fire "come back tomorrow" over an existing drop). A
    // transient miss (network error / empty) falls through to the poller path;
    // a fetch failure must never masquerade as "no drop".
    if (recId != null && recId.isNotEmpty) {
      final byId = await _fetchDropById(recId);
      if (!mounted || !analytics.isActionContextCurrent(actionContext)) return;
      if (byId != null && byId.hasRecommendation) {
        _openReadyDrop(byId, analytics);
        return;
      }
    }

    final state = await _awaitDailyDropTerminal();
    if (!mounted || !analytics.isActionContextCurrent(actionContext)) return;

    // Classify the settled state (pure — unit-tested in
    // `daily_drop_deep_link_outcome_test.dart`) and act on it. A ready drop
    // opens its detail (mirrors `DailyDropSection._onTap`): a local venue/event
    // pick opens its detail route; an entity-less pick (Google Places /
    // editorial, `venue_id == null`) opens the daily-drop detail screen
    // (PROD-2908) rather than the come-back-tomorrow sheet. The other outcomes
    // each get a cause-specific bottom sheet — critically, `no_drop` (genuine
    // empty) and `generating` (still on the way) are now distinct so we never
    // say "no drop" over a drop that already exists / is moments away.
    switch (dailyDropDeepLinkOutcome(
      state,
      staleProfilingCta: _isStaleProfilingCta(state),
    )) {
      case DailyDropDeepLinkOutcome.ready:
        _openReadyDrop(state.drop!, analytics);
      case DailyDropDeepLinkOutcome.ctaProfiling:
        analytics.trackDailyDropOpen(reason: 'cta_profiling');
        await showDailyDropProfilingSheet(context, ref);
      case DailyDropDeepLinkOutcome.unsupportedCity:
        analytics.trackDailyDropOpen(reason: 'unsupported_city');
        await showDailyDropUnsupportedAreaSheet(context, ref);
      case DailyDropDeepLinkOutcome.noDrop:
        // The provider's poller ran its full course (2-min cap) or init failed
        // without ever seeing a drop → genuinely nothing today. PROD-2908: this
        // now fires only after a REAL terminal, never at a premature 4 s cap
        // while the (already-generated) drop was still being fetched.
        analytics.trackDailyDropOpen(reason: 'no_drop');
        await showDailyDropComeBackTomorrowSheet(context, ref);
      case DailyDropDeepLinkOutcome.generating:
        // The safety cap elapsed while the drop was still generating (rare
        // stuck-epoch case). Report 'generating', NOT 'no_drop', so the metric
        // separates real latency from genuine empties (mirrors weekly bundle).
        // PROD-3730 — show the honest waiting sheet (with a push nudge, per
        // Decision 18) rather than lying with come-back-tomorrow.
        analytics.trackDailyDropOpen(reason: 'generating');
        await showDailyDropWaitSheet(
          context,
          ref,
          nudge: _resolveNudgeForSheet(),
        );
    }
  }

  /// Push a ready drop's detail on top of Discovery — shared by the PROD-2908
  /// by-id fast path and the poller path so the two never drift. Emits
  /// `daily_drop_open reason='deep_link'` and suppresses the product tour so
  /// its coachmarks don't fire over the pushed detail (PROD-2700; cleared on
  /// return to Discovery in [_handleDiscoveryRouteChange]).
  void _openReadyDrop(DailyDrop drop, UnifiedAnalyticsService analytics) {
    analytics.trackDailyDropOpen(
      recommendationId: drop.recommendationId,
      itemType: drop.itemType,
      category: drop.category,
      reason: 'deep_link',
    );
    ref.read(tourSuppressedForDeepLinkProvider.notifier).state = true;
    pushDailyDropDestination(context, drop);
  }

  /// PROD-2908 — fetch a specific daily drop by id for the deep-link fast path.
  /// Reuses the in-memory provider drop when it already holds this id (mirrors
  /// `dailyDropReasonProvider`), else hits `GET /recommendations/{id}`. Returns
  /// null on any error or empty response so the caller falls through to the
  /// poller path — a transient failure must not surface as "no drop".
  Future<DailyDrop?> _fetchDropById(String recommendationId) async {
    final current = ref.read(dailyDropProvider).drop;
    if (current != null && current.recommendationId == recommendationId) {
      return current;
    }
    try {
      return await ref
          .read(dailyDropApiProvider)
          .getRecommendationById(recommendationId);
    } catch (_) {
      return null;
    }
  }

  /// PROD-3730 — resolve the push-nudge state for the generating sheet.
  ///
  /// `ref.read` (not watch): the sheet is a one-shot, and re-resolving it
  /// mid-sheet would not update the already-built widget anyway.
  DailyDropNudge _resolveNudgeForSheet() {
    final pushUi = ref.read(pushPermissionServiceProvider);
    final prefsState = ref.read(notificationPreferencesProvider);
    return resolveDailyDropNudge(
      permission: pushUi.permission,
      prefsLoaded: prefsState.hasLoadedOnce,
      dailyDropTypeEnabled: dailyDropTypeEnabledFrom(prefsState.preferences),
    );
  }

  // ── PROD-2566: `/user-profiling/flow` logged-out deep-link resolution ──────

  void _maybeHandleUserProfilingDeepLink() {
    final nonce = widget.userProfilingDeepLinkNonce;
    if (nonce == null || nonce == _handledUserProfilingNonce) return;
    _handledUserProfilingNonce = nonce;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_resolveUserProfilingDeepLink());
    });
  }

  /// The `?user_profiling=<n>` marker is only ever stamped for a LOGGED-OUT tap
  /// (authed taps route straight to the flow / persona landing), so resolution
  /// is simple: show the "log in to do the profiling" sheet over guest
  /// Discovery. We deliberately do NOT strip the marker — it keeps the
  /// no-choice-yet `/login` exemption active so the guest stays on Discovery +
  /// the sheet (post-login reopen comes via returnUrl=/user-profiling/flow + a
  /// fresh mount). If the user somehow authenticated in the meantime, send them
  /// into the flow and let the route gate decide flow vs persona landing.
  Future<void> _resolveUserProfilingDeepLink() async {
    if (ref.read(isAuthenticatedProvider)) {
      // String literal (not AppRoutes) to match this file's existing nav style
      // and avoid an app_router back-import.
      if (mounted) context.go('/user-profiling/flow');
      return;
    }
    ref
        .read(unifiedAnalyticsProvider)
        .trackProfilingDeepLink(reason: 'logged_out');
    await showUserProfilingLoginSheet(context, ref);
  }

  /// `isCtaProfiling` is *stale* when the FE already knows the user finished
  /// profiling locally and the BE read path just hasn't caught up. The
  /// provider re-initializes and polls in that window (mirrors
  /// `DailyDropSection`), so the deep-link handler must not treat it as a real
  /// CTA and bounce the user back into profiling they just completed.
  bool _isStaleProfilingCta(DailyDropState s) =>
      s.isCtaProfiling && ref.read(hasFinishedUserProfilingLocallyProvider);

  /// Await the daily-drop provider settling into a terminal state. The only
  /// non-terminal state is `isGenerating`, which the provider's own poller
  /// resolves to ready / unsupported / error (its 2-min `onTimeout` flips to
  /// the terminal `hasError`, so this always completes). Discovery's section
  /// skeleton covers the wait.
  ///
  /// PROD-2908: there is deliberately NO short (4 s) cap here anymore — that
  /// cap fired "come back tomorrow" over drops that already existed on the
  /// server but hadn't finished being fetched on a cold start. We now wait for
  /// a real terminal, keeping only a defensive cap just above the poller's own
  /// 2-min ceiling so the future can never hang if the poller was superseded
  /// (stuck-epoch) without reaching a terminal state.
  Future<DailyDropState> _awaitDailyDropTerminal() async {
    // A stale profiling CTA (finished-locally, BE catching up) is NOT terminal
    // — the provider re-polls toward a real drop, so keep waiting.
    bool isTerminal(DailyDropState s) =>
        (s.isReady && s.drop != null) ||
        s.isUnsupportedCity ||
        (s.isCtaProfiling && !_isStaleProfilingCta(s)) ||
        s.hasError ||
        s.hasTimedOut;

    var current = ref.read(dailyDropProvider);
    // Kick off a fetch when the provider is pristine (the section's own init
    // may not have fired yet) OR is showing a stale profiling CTA — both need
    // a re-init to poll toward a terminal state.
    if (current.isPristine || _isStaleProfilingCta(current)) {
      unawaited(ref.read(dailyDropProvider.notifier).initialize());
      current = ref.read(dailyDropProvider);
    }
    if (isTerminal(current)) return current;

    final completer = Completer<DailyDropState>();
    final sub = ref.listenManual<DailyDropState>(dailyDropProvider, (_, next) {
      if (isTerminal(next) && !completer.isCompleted) completer.complete(next);
    });
    try {
      // Defensive cap only (see doc comment) — just above the provider poller's
      // 2-min ceiling. In practice the poller's own `onTimeout` → `hasError`
      // completes the terminal predicate well before this fires.
      return await completer.future.timeout(
        const Duration(seconds: 130),
        onTimeout: () => ref.read(dailyDropProvider),
      );
    } finally {
      sub.close();
    }
  }

  // ── PROD-2564: `/weekly-bundle` deep-link resolution ─────────────────────

  void _maybeHandleWeeklyBundleDeepLink() {
    final nonce = widget.weeklyBundleDeepLinkNonce;
    if (nonce == null || nonce == _handledWeeklyBundleNonce) return;
    _handledWeeklyBundleNonce = nonce;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_resolveWeeklyBundleDeepLink());
    });
  }

  /// Remove the `weekly_bundle=<n>` marker from the URL (keeping any other
  /// query, e.g. `utm_*`), returning the location to `/`. Mirrors
  /// [_stripDailyDropMarker] — **authenticated path only**: for a logged-out
  /// user the marker is the signal that exempts the entry from the no-choice-yet
  /// `/login` bounce, so stripping it before the login sheet would bounce a
  /// first-time guest to `/login`.
  void _stripWeeklyBundleMarker() {
    final params = Map<String, String>.from(
      GoRouterState.of(context).uri.queryParameters,
    )..remove('weekly_bundle');
    context.replace(
      params.isEmpty ? '/' : Uri(path: '/', queryParameters: params).toString(),
    );
  }

  Future<void> _resolveWeeklyBundleDeepLink() async {
    final analytics = ref.read(unifiedAnalyticsProvider);
    final actionContext = analytics.actionContext;
    // Logged-out → login sheet (mirrors Daily Drop Decision #12). The bundle is
    // city-gated + auth-gated, so there's nothing to resolve for a guest; the
    // CTA returns to `/weekly-bundle` after auth, dismissing keeps them on guest
    // Discovery. We deliberately do NOT strip the marker here: it keeps the
    // no-choice-yet `/login` exemption active.
    if (!ref.read(isAuthenticatedProvider)) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackWeeklyBundleOpen(reason: 'logged_out');
      await showWeeklyBundleLoginSheet(context, ref);
      return;
    }

    // Authenticated: no no-choice bounce applies, so it's safe to strip the
    // marker now — clean back-nav + re-fire on a second tap.
    _stripWeeklyBundleMarker();

    final state = await _awaitWeeklyBundleTerminal();
    if (!mounted || !analytics.isActionContextCurrent(actionContext)) return;
    final bundle = state.bundle;

    // Happy path: a ready bundle WITH renderable pages → push the Weekly Bundle
    // overlay on top of Discovery (mirrors `WeeklyBundleSection._onTap`). The
    // `hasPages` check is required — `isReady` alone (status == 'ready') can
    // still spin if `pageImageUrls` is empty. The overlay fires
    // `weekly_bundle_open` with reason `deep_link` via the nav extra.
    if (state.isReady && bundle != null && bundle.hasPages) {
      // PROD-2700: mirror the daily-drop handler — the bundle overlay is about
      // to cover Discovery, so suppress the product tour. Cleared on return to
      // Discovery in [_handleDiscoveryRouteChange].
      ref.read(tourSuppressedForDeepLinkProvider.notifier).state = true;
      // String literal (not AppRoutes.weeklyBundle) to avoid importing
      // app_router here — it imports DiscoveryScreen, so the constant would
      // create an import cycle; the daily-drop handler uses literals for the
      // same reason. Value is pinned by the router test + AASA/manifest.
      context.push('/weekly-bundle', extra: const WeeklyBundleNav.deepLink());
      return;
    }

    // No openable bundle → a cause-specific bottom sheet over Discovery.
    if (state.isUnsupportedCity) {
      analytics.trackWeeklyBundleOpen(reason: 'unsupported_city');
      await showWeeklyBundleUnsupportedAreaSheet(context, ref);
    } else if (state.isGenerating) {
      // The ~4 s cap timed out while the bundle is still being prepared (the
      // provider's 2-min poller is still running). Distinguish from a confirmed
      // empty week so Growth doesn't read normal image-gen latency as a true
      // failure.
      analytics.trackWeeklyBundleOpen(reason: 'generating');
      await showWeeklyBundleComeBackSheet(context, ref);
    } else {
      // hasError / ready-without-pages / no bundle this week.
      analytics.trackWeeklyBundleOpen(reason: 'no_bundle');
      await showWeeklyBundleComeBackSheet(context, ref);
    }
  }

  /// Await the weekly-bundle provider settling into a terminal state, with a
  /// ~4 s safety cap (Discovery's section skeleton covers the wait). `isReady`
  /// is treated as terminal — the caller then branches on `hasPages`.
  /// `isGenerating` is the only non-terminal state; the provider's own poller
  /// resolves it to ready / unsupported / error (2-min cap).
  Future<WeeklyBundleState> _awaitWeeklyBundleTerminal() async {
    bool isTerminal(WeeklyBundleState s) =>
        s.isReady || s.isUnsupportedCity || s.hasError;

    var current = ref.read(weeklyBundleProvider);
    // Kick off a fetch when the provider is pristine (on a cold deep-link the
    // section's own init may not have fired yet).
    final isPristine =
        !current.isReady &&
        !current.isGenerating &&
        !current.isUnsupportedCity &&
        !current.hasError &&
        current.bundle == null;
    if (isPristine) {
      unawaited(ref.read(weeklyBundleProvider.notifier).initialize());
      current = ref.read(weeklyBundleProvider);
    }
    if (isTerminal(current)) return current;

    final completer = Completer<WeeklyBundleState>();
    final sub = ref.listenManual<WeeklyBundleState>(weeklyBundleProvider, (
      _,
      next,
    ) {
      if (isTerminal(next) && !completer.isCompleted) completer.complete(next);
    });
    try {
      return await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => ref.read(weeklyBundleProvider),
      );
    } finally {
      sub.close();
    }
  }
}
