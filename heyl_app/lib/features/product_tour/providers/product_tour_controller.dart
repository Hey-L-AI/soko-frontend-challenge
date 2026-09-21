import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../features/discovery/providers/search_open_provider.dart';
import '../../../features/discovery/widgets/create_menu_sheet.dart';
import '../../../features/onboarding_chat/providers/needs_onboarding_provider.dart'
    show newOnboardingCohortProvider;
import '../../../providers/providers.dart';
import '../models/tour_step.dart';
import '../services/tour_persistence.dart';

class ProductTourState {
  const ProductTourState({required this.step, required this.viewedSteps});

  final TourStep step;
  final List<TourStep> viewedSteps;

  static const initial = ProductTourState(step: TourStep.idle, viewedSteps: []);

  ProductTourState copyWith({TourStep? step, List<TourStep>? viewedSteps}) {
    return ProductTourState(
      step: step ?? this.step,
      viewedSteps: viewedSteps ?? this.viewedSteps,
    );
  }
}

/// Side effects the controller delegates to. Pure state transitions live
/// in the controller; this interface lets tests assert what was called
/// without a real Scaffold or Navigator.
abstract class TourSideEffects {
  Future<void> ensureOnHomeRoute();
  Future<void> navigateToHome();
  Future<void> navigateToLibrary();
  Future<void> openCreateSheet();
  Future<void> closeCreateSheet();
  Future<void> openSearchOverlay();
  Future<void> closeSearchOverlay();
  Future<void> navigateToProfilingFlow();
}

/// No-op default. Real implementation is bound by ProductTourHost.
class NoopTourSideEffects implements TourSideEffects {
  @override
  Future<void> ensureOnHomeRoute() async {}
  @override
  Future<void> navigateToHome() async {}
  @override
  Future<void> navigateToLibrary() async {}
  @override
  Future<void> openCreateSheet() async {}
  @override
  Future<void> closeCreateSheet() async {}
  @override
  Future<void> openSearchOverlay() async {}
  @override
  Future<void> closeSearchOverlay() async {}
  @override
  Future<void> navigateToProfilingFlow() async {}
}

/// The active [TourSideEffects] implementation. The default is the
/// no-op (used by unit tests that override directly + by code paths
/// where no host widget has registered the real impl yet). The
/// [ProductTourHost] writes [RealTourSideEffects] into this state in
/// its initState — that single write propagates to every reader,
/// avoiding the nested-ProviderScope-override bug where the
/// controller (instantiated in the outer container) would otherwise
/// read the no-op despite an inner scope having the real impl.
final tourSideEffectsProvider = StateProvider<TourSideEffects>((ref) {
  return NoopTourSideEffects();
});

/// Holds the discovery shell's `Scaffold` state so [RealTourSideEffects]
/// can open the Create sheet imperatively. `CreateMenuSheet.toggle()`
/// resolves the scaffold via `Scaffold.of(context)`, but the showcase
/// host's captured context lives ABOVE the Scaffold in the tree — the
/// lookup throws "No Scaffold ancestor". Stashing the ScaffoldState in
/// a provider sidesteps the lookup entirely. Registered by
/// [_DiscoveryShellState.initState].
final tourDiscoveryScaffoldKeyProvider =
    StateProvider<GlobalKey<ScaffoldState>?>((_) => null);

/// Transient flag flipped on by [ProductTourController.next] when the
/// user advances from step 2 (homeFeed) to step 3 (createSheet). True
/// for the ~500 ms window BEFORE the bottom sheet opens, so the
/// Create-+ button's secondary highlight can light up first — visually
/// "Soko taps Criar, then the menu appears". Flipped off after the
/// state advances into createSheet (where the standard
/// `activeOnSteps: {createSheet}` takes over the highlight).
final tourCreateButtonPreviewProvider = StateProvider<bool>((_) => false);

/// Identifies which UI element the cursor is currently animating to.
/// Distinct from [TourStep] because some transitions chain through
/// multiple click targets (step 3 → step 4 clicks the X close, then
/// the Create-+ nav button). A single transition may set this multiple
/// times in sequence — the cursor "continues" from the previous
/// target rather than teleporting back to viewport centre between
/// consecutive non-null values.
enum CursorTarget {
  searchBar,
  discoverCityPill,
  searchOverlayClose,
  createButton,
  yoursNav,
  profileMenu,
}

/// What the cursor is currently pointing at. Null = cursor hidden.
/// The controller sets this through a transition (sometimes multiple
/// values in sequence for chained moves like X-then-Create-+) and
/// clears it once the destination step's tooltip is ready.
final tourCursorTargetProvider = StateProvider<CursorTarget?>((_) => null);

/// What the cursor has FINISHED moving toward — i.e. the hand is now
/// hovering over the target (the move animation is done, the click
/// pulse may or may not have fired yet). Null while the cursor is
/// still in flight, or after the transition completes.
///
/// Used by per-target highlights (e.g. the Descobre-a-cidade pill's
/// [TourSecondaryHighlight]) that should only light up AFTER the
/// hand arrives — drawing the blue rectangle WHILE the hand is still
/// travelling reads like the rectangle is leading the hand instead
/// of being summoned by it.
final tourCursorArrivedProvider = StateProvider<CursorTarget?>((_) => null);

/// Set to true once the looping demo cursor that walks Zines →
/// Eventos → Sítios in the search overlay finishes its tour. The
/// Descobre card (`_TourDiscoverCityTooltip`) gates its render on
/// this so the card only appears AFTER the user has seen what the
/// category tabs do — drawing the card immediately would hide the
/// tabs the demo is meant to highlight. Per user spec (2026-05-30).
/// Reset to false on every step transition and on abort/complete.
final tourDescobreTabsDoneProvider = StateProvider<bool>((_) => false);

/// Set to true once the Adiciona step's drawer-rect → connector →
/// card-mount sequence finishes. The host's scrim gates createSheet
/// visibility on this so the rectangle is drawn around the create
/// menu bottom drawer first (no dim), then the connector + card
/// land, then the dim fills in around the card. Mirrors how
/// [tourDescobreTabsDoneProvider] gates step 2's card + scrim.
/// Reset to false on every step transition and on abort/complete.
/// Per user spec (2026-06-01).
final tourAdicionaCardReadyProvider = StateProvider<bool>((_) => false);

/// PROD-2700: true while a deep-link drop/bundle DETAIL is pushed over
/// Discovery (`/drop` → venue/event detail, `/weekly-bundle` → overlay). The
/// tour must not run under it — its coachmarks target Discovery elements that
/// the pushed detail hides. Set by the discovery deep-link handlers
/// (`discovery_screen.dart`); the tour host aborts the tour when this flips
/// true and re-fires `_maybeStartTour` when it flips back false (so the tour
/// starts fresh once the user returns to Discovery). `abort()` doesn't persist
/// the seen flag, so the re-fire is clean.
final tourSuppressedForDeepLinkProvider = StateProvider<bool>((_) => false);

/// Cursor-move + click-pulse durations, exposed as providers so unit
/// tests can override to zero and skip the 1.1 s real-time wait per
/// transition. Production code reads these via the providers — keep
/// the cursor widget's internal move/click controller durations in
/// sync if you bump the defaults.
const Duration kTourCursorMoveDuration = Duration(milliseconds: 850);
const Duration kTourCursorClickDuration = Duration(milliseconds: 280);

/// Time the hand dwells over the target AFTER the move completes but
/// BEFORE the click pulse fires. Sized to cover the per-target
/// highlight rectangle's full draw window
/// ([TourSecondaryHighlight] = 400 ms delay + 650 ms draw) so the
/// rectangle is fully visible before the cursor pulses and the
/// side-effect (e.g. opening the search overlay or the create
/// sheet) fires. Per user spec (2026-05-30) — without this dwell
/// the rectangle is still inside its delay window when the overlay
/// opens, so the user never sees the spotlight on the target.
const Duration kTourCursorHoverDuration = Duration(milliseconds: 1100);
final tourCursorMoveDurationProvider = Provider<Duration>(
  (_) => kTourCursorMoveDuration,
);
final tourCursorClickDurationProvider = Provider<Duration>(
  (_) => kTourCursorClickDuration,
);
final tourCursorHoverDurationProvider = Provider<Duration>(
  (_) => kTourCursorHoverDuration,
);
final tourTransitionDurationProvider = Provider<Duration>(
  (ref) =>
      ref.watch(tourCursorMoveDurationProvider) +
      ref.watch(tourCursorClickDurationProvider),
);

/// Current authenticated user id, derived from [currentUserProvider]
/// (Task 13). Returns `null` when no user is signed in so the controller
/// can no-op `start()` / `_complete()` cleanly.
final tourUserIdProvider = Provider<String?>((ref) {
  return ref.watch(currentUserProvider)?.id;
});

/// Server-side "post-signup flow already completed" flag, derived from
/// [currentUserProvider]'s `onboardingComplete`. The tour treats this
/// as a hard "skip for existing users" gate — when true, neither the
/// auto-trigger nor the after-tour profiling navigation fire.
///
/// New users (just signed up) have `onboardingComplete=false` until
/// the profiling flow marks it server-side, so they pass through
/// signup → tour → profiling → home naturally.
///
/// Tests override this directly (default false = "new user that
/// still needs onboarding") so they don't have to wire up the entire
/// `currentUserProvider` → `authApiProvider` chain.
final tourOnboardingCompleteProvider = Provider<bool>((ref) {
  return ref.watch(currentUserProvider)?.onboardingComplete ?? false;
});

/// PROD-4071 — remote gate for the product-tour walkthrough. Backed by the
/// PostHog `product-tour` flag ([ExperimentState.enableProductTour], default
/// `true`). Read by `ProductTourHost._maybeStartTour` to suppress the
/// auto-start; the admin manual replay path deliberately ignores it.
final productTourEnabledProvider = Provider<bool>(
  (ref) => ref.watch(experimentServiceProvider).enableProductTour,
);

final tourPersistenceProvider = Provider<TourPersistence>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return TourPersistence(prefs);
});

final productTourControllerProvider =
    NotifierProvider<ProductTourController, ProductTourState>(
      ProductTourController.new,
    );

class ProductTourController extends Notifier<ProductTourState> {
  DateTime? _startedAt;

  /// Suppresses [onCreateSheetDismissed] while the controller is
  /// driving the createSheet → yoursNav transition itself. Without
  /// this, the dismissal listener races the controlled `next()` flow:
  /// when [_sideEffects.closeCreateSheet] finishes its exit animation
  /// the listener fires, advances state straight to yoursNav AND
  /// navigates to /yours immediately — so the cursor's "Biblioteca
  /// click" animation ends up playing on the /yours page instead of
  /// on home. Set true around the controlled close, reset right
  /// after the cursor click has driven the navigation itself.
  bool _isControlledSheetClose = false;

  /// Monotonic counter bumped by [skip], [abort] and the force-replay
  /// path of [start] to cancel any cursor sequence already in flight.
  /// [_runCursorClick] snapshots this at entry and bails between its
  /// awaits if it changes — without this, the chain of uncancellable
  /// `Future.delayed` timers inside `_runCursorClick` (~2.5s per step)
  /// keeps running after Skip: it re-fires `tourCursorArrivedProvider`
  /// (blue highlight reappears) and the `beforeClick`/`afterClick` side
  /// effects (opens sheets/navigates) on top of the post-Skip screen.
  /// The `state.step != from` guard in each `next()` case is the
  /// matching safeguard against `state = _advance(...)` overwriting the
  /// freshly-set `done` step after the in-flight call returns.
  int _runEpoch = 0;

  @override
  ProductTourState build() => ProductTourState.initial;

  TourSideEffects get _sideEffects => ref.read(tourSideEffectsProvider);
  TourPersistence get _persistence => ref.read(tourPersistenceProvider);
  String? get _userId => ref.read(tourUserIdProvider);
  UnifiedAnalyticsService get _analytics => ref.read(unifiedAnalyticsProvider);

  Future<void> start({bool force = false}) async {
    final userId = _userId;
    if (userId == null) return;
    if (!force) {
      // Local "user already saw the tour" flag — same persistence
      // pattern as `userProfilingGateProvider`, scoped to userId.
      if (await _persistence.hasSeen(userId)) return;
      // Existing-user gate: `user.onboardingComplete=true` means the
      // user has already gone through the post-signup flow at some
      // point in the past (originally only the profiling existed —
      // when the tour was added we don't want to retroactively
      // re-onboard anyone). Only NEW users land here with this
      // flag still false; old users skip the tour entirely.
      //
      // EXCEPTION — the new-onboarding cohort: chat onboarding sets
      // `onboardingComplete=true` at completion, so these users would be
      // mis-classified as "existing" and never get the tour. Let them
      // through; it fires on their first home visit after onboarding and
      // stays once-only via `hasSeen` above. Users OUTSIDE the cohort keep
      // the original grandfather behaviour.
      final inNewOnboardingCohort = ref.read(newOnboardingCohortProvider);
      if (ref.read(tourOnboardingCompleteProvider) && !inNewOnboardingCohort) {
        return;
      }
    }
    await _sideEffects.ensureOnHomeRoute();
    _startedAt = DateTime.now();
    // Step 1 (Procura) opens directly — no cursor animation. The
    // chat-bar tooltip + drawn rectangle appear immediately so the
    // user can read it. The cursor only appears AFTER they tap Next
    // on this first step.
    //
    // Force-replay path: cycle through `idle` first so subscribers
    // using `.select((s) => s.step)` see a real step transition even
    // when the previous step was already `searchBar` (e.g. the user
    // ran the tour, used the browser back-button to /menu mid-step,
    // and tapped Repetir tour before completing). Without the
    // intermediate reset, the second replay's `copyWith(step:
    // searchBar)` is a same-value assignment for the selector and
    // `_TourProcuraTooltip` never rebuilds → kick-off never fires.
    // Also covers the "skip mid-tour → /menu → replay" path where
    // the chat-bar's `TourSecondaryHighlight._wasActive` would
    // otherwise stay true across the same-step assignment and the
    // edge-triggered draw animation never replays.
    if (force) {
      // Cancel any cursor sequence still in flight from the previous
      // run so it doesn't steamroll the fresh state.
      _runEpoch++;
      state = ProductTourState.initial;
      // Reset transient flags too so the replay starts from a clean
      // slate (otherwise e.g. the Descobre demo-tabs-done flag from
      // the previous run would suppress the tabs animation on the
      // next discoverCity step entry).
      ref.read(tourDescobreTabsDoneProvider.notifier).state = false;
      ref.read(tourAdicionaCardReadyProvider.notifier).state = false;
      ref.read(tourCursorTargetProvider.notifier).state = null;
      ref.read(tourCursorArrivedProvider.notifier).state = null;
      ref.read(tourCreateButtonPreviewProvider.notifier).state = false;
      // Belt-and-braces: close any UI surfaces the previous tour run
      // might have left open. Per user report (2026-05-30) — second
      // replay was getting stuck with the cursor frozen over the
      // Descobre-a-cidade pill because the search overlay was
      // already open from a prior skip / mid-flow exit, so
      // `openSearchOverlay` setting `searchOpenProvider = true`
      // again was a no-op and the cursor's afterClick effectively
      // did nothing visible. Closing both surfaces here resets them
      // to a known state so the upcoming `next()` chain re-opens
      // them cleanly.
      await _sideEffects.closeSearchOverlay();
      await _sideEffects.closeCreateSheet();
    }
    // Tour opens on a centered welcome card — see [_TourWelcomeTooltip]
    // in product_tour_host.dart. Tapping its CTA advances to searchBar
    // and the rest of the choreography is unchanged.
    state = state.copyWith(
      step: TourStep.welcome,
      viewedSteps: [TourStep.welcome],
    );
    _analytics.trackTourStep(
      step: TourStep.welcome.stepNumber,
      stepName: TourStep.welcome.analyticsName,
      action: 'view',
    );
  }

  Future<void> next() async {
    final from = state.step;
    switch (from) {
      case TourStep.idle:
      case TourStep.done:
        return;
      case TourStep.welcome:
        _trackNext(from);
        // welcome → searchBar: no cursor animation, just advance.
        // The standard searchBar choreography (chat-bar rect →
        // connector → card) is driven by the searchBar step entry.
        state = _advance(TourStep.searchBar);
        _trackView(TourStep.searchBar);
        return;
      case TourStep.searchBar:
        _trackNext(from);
        // searchBar → discoverCity: cursor → "Descobre a cidade"
        // pill → click → openSearchOverlay(). The Sente / homeFeed
        // step was removed per spec; the tour now hops directly from
        // the chat-bar intro to the search-overlay demo.
        final epoch = _runEpoch;
        await _runCursorClick(
          CursorTarget.discoverCityPill,
          afterClick: _sideEffects.openSearchOverlay,
        );
        // Skip / abort / force-replay landed mid-cursor — don't
        // resurrect the tour by overwriting the new state with
        // discoverCity.
        if (epoch != _runEpoch) return;
        state = _advance(TourStep.discoverCity);
        ref.read(tourCursorTargetProvider.notifier).state = null;
        ref.read(tourCursorArrivedProvider.notifier).state = null;
        _trackView(TourStep.discoverCity);
        return;
      case TourStep.discoverCity:
        _trackNext(from);
        // discoverCity → createSheet: close the search overlay
        // programmatically (no cursor X-click animation per spec —
        // the user wants to land back on home and watch the cursor
        // hop straight to the Create entry-point). Then cursor →
        // Create-+ nav button → click → openCreateSheet, with the
        // button's own blue rectangle lighting up at the click
        // instant.
        //
        // Until 2026-07 this pointed at the "Adiciona à Soko" pill in
        // the chat bar. #1224 replaced that pill with the location
        // pill, so `keys.addToSoko` stopped being attached to anything
        // and the cursor fell back to the pill's OLD viewport
        // coordinates — the hand flew to the location pill and clicked
        // empty air. The Create-+ button is now the only entry-point
        // this step is about, so the cursor points there.
        final epoch = _runEpoch;
        await _sideEffects.closeSearchOverlay();
        if (epoch != _runEpoch) return;
        await _runCursorClick(
          CursorTarget.createButton,
          beforeClick: () async {
            ref.read(tourCreateButtonPreviewProvider.notifier).state = true;
          },
          afterClick: _sideEffects.openCreateSheet,
        );
        if (epoch != _runEpoch) {
          // Skip / abort fired mid-cursor — `beforeClick` may have
          // flipped the preview flag before the cancel landed, so
          // belt-and-braces clear it before bailing.
          ref.read(tourCreateButtonPreviewProvider.notifier).state = false;
          return;
        }
        state = _advance(TourStep.createSheet);
        ref.read(tourCursorTargetProvider.notifier).state = null;
        ref.read(tourCursorArrivedProvider.notifier).state = null;
        ref.read(tourCreateButtonPreviewProvider.notifier).state = false;
        _trackView(TourStep.createSheet);
        return;
      case TourStep.createSheet:
        _trackNext(from);
        // createSheet → yoursNav: close the sheet first (so the
        // Biblioteca nav-button is uncovered), then cursor →
        // Biblioteca on the HOME route, then navigate to /library at
        // the click instant. The [_isControlledSheetClose] flag
        // suppresses the dismissal listener so it doesn't race
        // navigation: without it, the listener fires when the sheet
        // animates out, jumps state straight to yoursNav AND
        // navigates immediately, so the cursor click animation ends
        // up playing on /library instead of on home.
        final epoch = _runEpoch;
        _isControlledSheetClose = true;
        await _sideEffects.closeCreateSheet();
        if (epoch != _runEpoch) {
          _isControlledSheetClose = false;
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (epoch != _runEpoch) {
          _isControlledSheetClose = false;
          return;
        }
        await _runCursorClick(
          CursorTarget.yoursNav,
          beforeClick: _sideEffects.navigateToLibrary,
        );
        _isControlledSheetClose = false;
        // Skip / abort fired mid-cursor — bail before re-advancing.
        // `navigateToLibrary` may have already run as `beforeClick`; that
        // navigation is a no-op visual artifact we accept rather than
        // try to reverse.
        if (epoch != _runEpoch) return;
        state = _advance(TourStep.yoursNav);
        ref.read(tourCursorTargetProvider.notifier).state = null;
        ref.read(tourCursorArrivedProvider.notifier).state = null;
        _trackView(TourStep.yoursNav);
        return;
      case TourStep.yoursNav:
        _trackNext(from);
        // yoursNav → profileMenu: cursor → Home nav-button → click →
        // navigate to /. The card with the "Personalize" copy then
        // appears anchored to the Home button. Lands the user on
        // the home route so the production after-tour handoff to
        // the profiling banner reads naturally. Per user spec
        // (2026-06-01 follow-up): keep [navigateToHome] as
        // [afterClick] so the click pulse plays on the Home cell
        // in `/biblioteca` (registers as "the tour clicked Home"),
        // then the page swaps.
        //
        // Hover trimmed to 300 ms because the Home cell has no
        // [TourSecondaryHighlight] sibling to wait for — the
        // default 1100 ms reads as dead air.
        final epoch = _runEpoch;
        await _runCursorClick(
          CursorTarget.profileMenu,
          hoverDuration: const Duration(milliseconds: 300),
          afterClick: _sideEffects.navigateToHome,
        );
        // Skip / abort fired mid-cursor — bail before re-advancing.
        if (epoch != _runEpoch) return;
        state = _advance(TourStep.profileMenu);
        ref.read(tourCursorTargetProvider.notifier).state = null;
        ref.read(tourCursorArrivedProvider.notifier).state = null;
        _trackView(TourStep.profileMenu);
        return;
      case TourStep.profileMenu:
        _trackNext(from);
        await _complete();
        return;
    }
  }

  /// One cursor waypoint: sets [tourCursorTargetProvider] to [target],
  /// waits the move duration, optionally runs [beforeClick] at the
  /// click instant, waits the click-pulse duration, then runs
  /// [afterClick] (the actual side effect the click would have
  /// triggered — e.g. openSearchOverlay, openCreateSheet).
  ///
  /// Caller is responsible for clearing the cursor target after the
  /// chain finishes. Leaving it set across consecutive calls lets
  /// the cursor "continue" from one waypoint to the next without
  /// teleporting back to viewport centre between them.
  Future<void> _runCursorClick(
    CursorTarget target, {
    Future<void> Function()? beforeClick,
    Future<void> Function()? afterClick,
    Duration? hoverDuration,
  }) async {
    // Snapshot the run epoch so a concurrent skip/abort/force-replay
    // can cancel this sequence mid-flight. Any of the awaits below
    // would otherwise re-fire highlight providers and side effects
    // long after the cancellation took effect.
    final epoch = _runEpoch;
    bool cancelled() => epoch != _runEpoch;

    // Pre-check: skip may have run while the caller was paused in an
    // earlier await (e.g. closeSearchOverlay / closeCreateSheet /
    // Future.delayed). Without this, a stale call would briefly set
    // the cursor target on the post-skip screen.
    if (cancelled()) return;
    ref.read(tourCursorTargetProvider.notifier).state = target;
    await Future<void>.delayed(ref.read(tourCursorMoveDurationProvider));
    if (cancelled()) return;
    // Hand has arrived at the target. Per-target highlights (e.g.
    // the Descobre-a-cidade pill's blue rectangle) gate their
    // activation on this signal so they only appear AFTER the
    // hand is over them, not while the cursor is still in flight.
    ref.read(tourCursorArrivedProvider.notifier).state = target;
    // [beforeClick] flips any preview flags (e.g.
    // tourCreateButtonPreviewProvider) so their highlights start
    // drawing. We THEN dwell on the target so the rectangle has
    // time to fully paint before the click pulse fires and the
    // side-effect (e.g. openSearchOverlay / openCreateSheet)
    // covers the screen. Per user spec (2026-05-30) — without
    // this dwell the user never sees the spotlight; the overlay
    // opens while the rect is still in its 400 ms delay window.
    //
    // [hoverDuration] override lets callers shorten the dwell on
    // targets that DON'T have a per-target highlight to wait for
    // (e.g. the profileMenu Home cell on the last transition —
    // no `TourSecondaryHighlight` there, so the 1100 ms default
    // reads as dead air).
    if (cancelled()) return;
    await beforeClick?.call();
    if (cancelled()) return;
    await Future<void>.delayed(
      hoverDuration ?? ref.read(tourCursorHoverDurationProvider),
    );
    if (cancelled()) return;
    await Future<void>.delayed(ref.read(tourCursorClickDurationProvider));
    if (cancelled()) return;
    // Settle gap so the click pulse animation's last frame paints
    // BEFORE the side-effect (page nav, overlay open, sheet open)
    // repaints the screen. Per user reports (2026-05-30): without
    // this gap the Biblioteca nav was changing route on the same
    // frame the click pulse ended and the user perceived "page
    // change → click". An earlier 150 ms value helped but didn't
    // fully kill the perception — 300 ms (~18 frames @ 60 fps)
    // gives the pulse a clear "settled" moment before the route
    // transition starts, even on slower web rebuilds.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (cancelled()) return;
    await afterClick?.call();
  }

  /// Walks the tour ONE step backward. Reverses the previous step's
  /// side effects (close any sheet/overlay it opened, navigate back
  /// to home if it pushed us to /yours) without re-running the
  /// cursor demonstrations. No-op when already on the first step.
  ///
  /// Suppresses [onCreateSheetDismissed] while it programmatically
  /// closes the create sheet — same race fix as the forward flow.
  Future<void> back() async {
    final from = state.step;
    switch (from) {
      case TourStep.idle:
      case TourStep.done:
      case TourStep.welcome:
      case TourStep.searchBar:
        return;
      case TourStep.discoverCity:
        await _sideEffects.closeSearchOverlay();
        state = state.copyWith(step: TourStep.searchBar);
        _trackView(TourStep.searchBar);
        return;
      case TourStep.createSheet:
        _isControlledSheetClose = true;
        await _sideEffects.closeCreateSheet();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await _sideEffects.openSearchOverlay();
        _isControlledSheetClose = false;
        state = state.copyWith(step: TourStep.discoverCity);
        _trackView(TourStep.discoverCity);
        return;
      case TourStep.yoursNav:
        await _sideEffects.ensureOnHomeRoute();
        await _sideEffects.openCreateSheet();
        state = state.copyWith(step: TourStep.createSheet);
        _trackView(TourStep.createSheet);
        return;
      case TourStep.profileMenu:
        state = state.copyWith(step: TourStep.yoursNav);
        _trackView(TourStep.yoursNav);
        return;
    }
  }

  Future<void> skip() async {
    // Cancel any in-flight `_runCursorClick` BEFORE doing anything
    // else — otherwise its remaining ~2.5s of `Future.delayed` chain
    // would re-fire the cursor/highlight providers and side-effects
    // on top of whatever screen the user lands on next.
    _runEpoch++;
    _analytics.trackTourSkipped(atStep: state.step.stepNumber);
    // Capture the source step BEFORE wiping state below — the
    // close-sheet branch needs it.
    final wasOnCreateSheet = state.step == TourStep.createSheet;
    // Synchronous tear-down — hoists what `_complete` does anyway so
    // the cursor, blue highlights, tooltip cards, scrim and tap
    // blocker disappear on the same frame as the tap, independent of
    // how long the async cleanup (closeCreateSheet animation +
    // markSeen + navigation push) takes.
    _clearTourVisibleState();
    if (wasOnCreateSheet) {
      await _sideEffects.closeCreateSheet();
    }
    await _complete(fromSkip: true);
  }

  /// Synchronously clears every provider that drives the tour's
  /// visible surface — cursor, blue highlights, tooltip-card visibility
  /// (via `state.step`), scrim, tap blocker. Called from [skip] before
  /// any await so the overlay vanishes instantly; [_complete] re-does
  /// these same writes (idempotent) so the natural-completion path is
  /// unchanged.
  void _clearTourVisibleState() {
    state = state.copyWith(step: TourStep.done);
    ref.read(tourCursorTargetProvider.notifier).state = null;
    ref.read(tourCursorArrivedProvider.notifier).state = null;
    ref.read(tourCreateButtonPreviewProvider.notifier).state = false;
    ref.read(tourDescobreTabsDoneProvider.notifier).state = false;
    ref.read(tourAdicionaCardReadyProvider.notifier).state = false;
  }

  /// User dismissed the Create sheet via drag/back-button/dismiss-overlay
  /// while we were on the createSheet step. Advance to yoursNav.
  ///
  /// Suppressed by [_isControlledSheetClose] when the controller's own
  /// `next()` flow is the one closing the sheet — otherwise the
  /// listener races the controlled transition and navigates BEFORE
  /// the cursor's Biblioteca click animation has had a chance to play
  /// on the home route.
  Future<void> onCreateSheetDismissed() async {
    if (_isControlledSheetClose) return;
    if (state.step != TourStep.createSheet) return;
    await _sideEffects.navigateToLibrary();
    state = _advance(TourStep.yoursNav);
    _trackView(TourStep.yoursNav);
  }

  /// Abort the tour without persisting the seen flag. Called when auth is
  /// lost mid-tour so that the next user (or the same user re-signing in)
  /// still sees the tour. Intentionally emits NO analytics.
  void abort() {
    _runEpoch++;
    if (state.step == TourStep.createSheet) {
      _sideEffects.closeCreateSheet();
    }
    ref.read(tourCreateButtonPreviewProvider.notifier).state = false;
    ref.read(tourCursorTargetProvider.notifier).state = null;
    ref.read(tourCursorArrivedProvider.notifier).state = null;
    ref.read(tourDescobreTabsDoneProvider.notifier).state = false;
    ref.read(tourAdicionaCardReadyProvider.notifier).state = false;
    state = ProductTourState.initial;
  }

  Future<void> _complete({bool fromSkip = false}) async {
    final userId = _userId;
    if (userId != null) {
      await _persistence.markSeen(userId);
    }
    // Belt-and-suspenders: if the user skipped during the transition
    // window between homeFeed and createSheet, the flag would still
    // be true. Clear it so the next replay starts clean.
    ref.read(tourCreateButtonPreviewProvider.notifier).state = false;
    // Same for the cursor target — if skip/complete fires mid
    // transition, clear it so the next replay starts clean rather
    // than picking up a stale pending cursor target.
    ref.read(tourCursorTargetProvider.notifier).state = null;
    ref.read(tourCursorArrivedProvider.notifier).state = null;
    ref.read(tourDescobreTabsDoneProvider.notifier).state = false;
    ref.read(tourAdicionaCardReadyProvider.notifier).state = false;
    if (!fromSkip) {
      final elapsed = _startedAt != null
          ? DateTime.now().difference(_startedAt!).inSeconds
          : 0;
      _analytics.trackTourCompleted(
        totalTimeSeconds: elapsed,
        viewedSteps: state.viewedSteps.map((s) => s.analyticsName).toList(),
      );
    }
    state = state.copyWith(step: TourStep.done);
    // After-tour navigation: route to the profiling flow ONLY for
    // users who haven't completed it yet (`onboardingComplete=false`).
    // This covers the natural new-user path (signup → tour → profiling
    // → app) without sending force-replays from the menu into
    // profiling (existing users have `onboardingComplete=true` and
    // stay on whatever route they replayed from).
    if (!ref.read(tourOnboardingCompleteProvider)) {
      await _sideEffects.navigateToProfilingFlow();
    }
  }

  void _trackNext(TourStep step) {
    _analytics.trackTourStep(
      step: step.stepNumber,
      stepName: step.analyticsName,
      action: 'next',
    );
  }

  void _trackView(TourStep step) {
    _analytics.trackTourStep(
      step: step.stepNumber,
      stepName: step.analyticsName,
      action: 'view',
    );
  }

  ProductTourState _advance(TourStep next) {
    return state.copyWith(
      step: next,
      viewedSteps: [...state.viewedSteps, next],
    );
  }
}

class RealTourSideEffects implements TourSideEffects {
  RealTourSideEffects({required this.context, required this.ref});

  final BuildContext context;
  final WidgetRef ref;

  @override
  Future<void> ensureOnHomeRoute() async {
    // The [context] captured here is the showcase context from the
    // host's first mount. It can become "deactivated" between then
    // and now (the discovery shell rebuilds when its inner route
    // changes; some showcaseview-internal element gets detached even
    // though the host's outer Element survives). In that case
    // `GoRouterState.of(context)` throws
    // `_debugCheckStateIsActiveForAncestorLookup`. Per user report
    // (2026-05-30, "tento dar replay tour" stack), the menu screen's
    // replay handler already calls `context.go(home)` BEFORE
    // scheduling `start(force: true)` on a post-frame, so if our
    // lookup fails we can safely assume navigation is already on its
    // way and just yield a few frames for the discovery shell to
    // settle.
    String? location;
    try {
      location = GoRouterState.of(context).matchedLocation;
    } catch (_) {
      // Context stale — trust the caller to have navigated. Yield
      // three frames so the discovery shell + chat-bar GlobalKey
      // are attached before the controller advances state.
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      return;
    }
    // AppRoutes.home == '/', so `startsWith` would always be true.
    // Compare exactly: only navigate when we're NOT on the home route.
    if (location != AppRoutes.home) {
      // The control flow above either set [location] synchronously
      // (no await) or returned out of the function entirely. The
      // analyzer can't reason about that across the try/catch, so
      // suppress the use_build_context_synchronously warning here.
      // ignore: use_build_context_synchronously
      context.go(AppRoutes.home);
      // Wait three frames: one for GoRouter to swap the route, one for
      // DiscoveryScreen to mount its subtree, one more for the
      // `Showcase.withWidget` wrappers' post-frame registration with
      // the ShowCaseWidget. Without this, replay-from-/yours fires
      // `startShowCase([keys.searchBar])` before the chat-bar key is
      // attached and the call silently no-ops.
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// PROD-4167 — must match where a real Biblioteca tap goes
  /// (`discovery_bottom_nav.dart`, `onZinesTap`).
  @override
  Future<void> navigateToLibrary() async {
    context.go(AppRoutes.library);
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<void> navigateToHome() async {
    context.go(AppRoutes.home);
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<void> openCreateSheet() async {
    if (ref.read(createMenuControllerProvider) != null) return;
    // The captured `context` is the ShowCaseWidget's — an ANCESTOR of
    // the Scaffold, so `Scaffold.of(context)` would throw. The shell
    // stashes its ScaffoldState in [tourDiscoveryScaffoldKeyProvider]
    // expressly so we can open the sheet from outside its subtree.
    final scaffoldKey = ref.read(tourDiscoveryScaffoldKeyProvider);
    final scaffoldState = scaffoldKey?.currentState;
    if (scaffoldState == null) {
      // Shell hasn't mounted yet (or unmounted between frames). The
      // listener's catch swallows the resulting silent state-only
      // advance; user can re-trigger next().
      return;
    }
    CreateMenuSheet.openWithScaffoldState(scaffoldState, ref);
    // Wait two frames: one for showBottomSheet build to run, one for
    // the Showcase wrapper inside the sheet to register its GlobalKey.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<void> closeCreateSheet() async {
    ref.read(createMenuControllerProvider)?.close();
  }

  @override
  Future<void> openSearchOverlay() async {
    // The DiscoverySearchOverlay binds to [searchOpenProvider]; setting
    // it `true` mounts the overlay subtree (input + tabs + results).
    // Wait two frames so the overlay's first build settles before the
    // tour advances to the discoverCity step (lets the close button's
    // RenderBox attach so the next-transition cursor can find it).
    ref.read(searchOpenProvider.notifier).state = true;
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<void> closeSearchOverlay() async {
    ref.read(searchOpenProvider.notifier).state = false;
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<void> navigateToProfilingFlow() async {
    // PROD-2438: context.push (NOT context.go) so `shellHome` stays at
    // the bottom of the navigator stack across the profiling flow. The
    // tour fires this on completion for new users (`onboardingComplete=
    // false`) — at that point the user is on `/` with the discovery
    // shell mounted. `context.go` would replace the entire matchList
    // with `[profilingFlow]`, evicting the shell. When the user later
    // tapped "Explorar o app" the FRESH shell mount hit a
    // `GlobalObjectKey(navigatorKey.hashCode)` reparenting collision on
    // go_router's inner `_CustomNavigator` because the previous shell's
    // navigator was still in the framework's `_inactive` list. Using
    // `push` keeps the shell mounted; the profiling-internal
    // `pushReplacement` chain in `user_profiling_*_screen.dart`
    // preserves it through the flow, and `context.go('/')` from the
    // Explore CTA pops profiling off cleanly without remounting the
    // shell. See `docs/learnings/go-router-shell-navigator-globalobjectkey-collision.md`.
    // PROD-2566: attribute `profiling_started` to the product tour.
    context.push('${AppRoutes.userProfilingFlow}?source=product_tour');
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  }
}
