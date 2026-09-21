import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:showcaseview/showcaseview.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../discovery/providers/search_category_provider.dart';
import '../../onboarding_chat/providers/needs_onboarding_provider.dart'
    show newOnboardingCohortProvider, needsOnboardingProvider;
import '../models/tour_step.dart';
import '../providers/product_tour_controller.dart';
import '../providers/product_tour_keys_provider.dart';
import 'tour_tooltip.dart';

/// Wraps the discovery [Scaffold] in [ShowCaseWidget] so the spotlight
/// overlay can reach both `Scaffold.body` and
/// `Scaffold.bottomNavigationBar`. Inside the [ShowCaseWidget] builder a
/// nested [ConsumerWidget] binds the real [TourSideEffects] (which needs
/// a [WidgetRef], not the provider-level [Ref]) via a fresh
/// [ProviderScope] override. Listens to external providers to drive the
/// showcase transitions and abort on auth loss.
class ProductTourHost extends StatelessWidget {
  const ProductTourHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShowCaseWidget(
      onFinish: () {},
      builder: (showcaseContext) {
        return _TourBindings(showcaseContext: showcaseContext, child: child);
      },
    );
  }
}

/// Nested [ConsumerStatefulWidget] so we have a real [WidgetRef] inside the
/// [ShowCaseWidget] subtree. [RealTourSideEffects] needs a [WidgetRef]
/// for its provider reads.
///
/// Writes the real [TourSideEffects] into [tourSideEffectsProvider] (a
/// [StateProvider]) in a post-frame callback so the controller — which
/// lives in the outer container — reads the real impl instead of the
/// no-op default. A nested `ProviderScope.overrideWithValue` would NOT
/// work because the controller was instantiated in the outer container
/// and reads providers from there.
class _TourBindings extends ConsumerStatefulWidget {
  const _TourBindings({required this.showcaseContext, required this.child});

  final BuildContext showcaseContext;
  final Widget child;

  @override
  ConsumerState<_TourBindings> createState() => _TourBindingsState();
}

class _TourBindingsState extends ConsumerState<_TourBindings> {
  @override
  void initState() {
    super.initState();
    // Bind the real side effects after the first frame so we don't
    // mutate provider state during build.
    //
    // Rebind on every host mount: the host UNMOUNTS whenever the user
    // navigates outside the discovery shell (e.g. to
    // `/user-profiling/flow`, which is registered at the router root,
    // NOT inside the shell). On re-mount the captured `showcaseContext`
    // from the previous bind is disposed, so calls like
    // `navigateToLibrary` / `navigateToProfilingFlow` (which run
    // `context.go(...)`) throw silently and the tour stalls mid-flow.
    // Per user report (2026-05-30, "cliquei outra vez no replay tour
    // … nao faz nada o botao") — second replay was a no-op because the
    // stale RealTourSideEffects had a disposed context. Bail out ONLY
    // when a test fake is in place (anything that's neither Noop nor
    // Real); always rebind real instances with the fresh context.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = ref.read(tourSideEffectsProvider);
      if (current is! NoopTourSideEffects && current is! RealTourSideEffects) {
        return;
      }
      final realSideEffects = RealTourSideEffects(
        context: widget.showcaseContext,
        ref: ref,
      );
      ref.read(tourSideEffectsProvider.notifier).state = realSideEffects;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _TourStateListener(
      showcaseContext: widget.showcaseContext,
      child: widget.child,
    );
  }
}

class _TourStateListener extends ConsumerStatefulWidget {
  const _TourStateListener({
    required this.showcaseContext,
    required this.child,
  });

  final BuildContext showcaseContext;
  final Widget child;

  @override
  ConsumerState<_TourStateListener> createState() => _TourStateListenerState();
}

class _TourStateListenerState extends ConsumerState<_TourStateListener>
    with WidgetsBindingObserver {
  /// The GoRouter we're subscribed to for route-change re-evaluation
  /// (defer-to-home). Tracked so we can detach cleanly and re-attach if the
  /// router instance ever changes.
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Try to auto-start the tour once the listener is mounted inside the
    // inner ProviderScope (where the real side effects are bound). Running
    // this from the discovery shell's ref would resolve providers in the
    // OUTER container, which has the _NoopSideEffects default — the
    // controller would advance state but the showcase overlay wouldn't.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStartTour());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Defer-to-home: subscribe to route changes so the trigger re-evaluates
    // when the user navigates. The host stays mounted across shell tab
    // switches, so a user who exited onboarding to /map or /chat (where
    // `_maybeStartTour` early-returns on the route gate) would otherwise never
    // get the tour — it only fires on the home route. Re-checking on every
    // navigation catches them the first time they land on `/`. Idempotent:
    // `_maybeStartTour` early-returns off-home / when already running, and
    // `start()` is once-only via `hasSeen`.
    final router = GoRouter.maybeOf(context);
    if (router != null && !identical(router, _router)) {
      _router?.routerDelegate.removeListener(_onRouteChanged);
      _router = router;
      router.routerDelegate.addListener(_onRouteChanged);
    }
  }

  void _onRouteChanged() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStartTour());
  }

  /// Fire-and-forget evaluation of whether the product tour should start
  /// right now. Called once after mount and again whenever a gating
  /// surface (profile drawer, sidebar, or initial user load)
  /// transitions from blocked → clear.
  ///
  /// Each guard short-circuits independently — order matches the spec:
  /// idle → authenticated → user id → on home → no profile drawer →
  /// no sidebar → no keyboard. The controller's `start()` is itself a
  /// no-op when the user has already seen the tour (TourPersistence
  /// check), so re-firing here is safe.
  void _maybeStartTour() {
    if (!mounted) return;
    // A route teardown (e.g. `context.go(home)` the instant chat onboarding
    // completes) fires `_onRouteChanged` mid-tear-down, which schedules this as
    // a post-frame callback. By the time it runs the element can still be
    // `mounted` yet momentarily DETACHED from the ProviderScope during the
    // shell rebuild — so the first `ref.read` below throws "No ProviderScope
    // found", and because that escapes a scheduler callback it kills the frame
    // and leaves the user on a grey screen (FLUTTER-1A3, escalating in
    // 1.1.24+116). `mounted` doesn't cover this (the element isn't disposed,
    // just detached), and `ProviderScope.containerOf` THROWS rather than
    // returning null when there's no scope — so probe it and bail. Once this
    // passes, the reads below are safe: they're synchronous, same-frame, no
    // await in between.
    try {
      ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return;
    }
    // PROD-2700: a deep-link drop/bundle detail is covering Discovery — don't
    // auto-start the tour over it (its coachmarks target hidden Discovery
    // elements). Cleared when the user returns to Discovery.
    if (ref.read(tourSuppressedForDeepLinkProvider)) return;
    final state = ref.read(productTourControllerProvider);
    if (state.step != TourStep.idle) return;
    // PROD-4071 — remote kill-switch. Off = the walkthrough never auto-starts.
    // The flag defaults true and confirms late, so a `ref.listen` below
    // re-fires this if it flips on after the user is already on home. The
    // admin manual replay path (`start(force: true)`) is intentionally NOT
    // gated by this.
    if (!ref.read(productTourEnabledProvider)) return;
    if (!ref.read(isAuthenticatedProvider)) return;
    if (ref.read(tourUserIdProvider) == null) return;
    // Onboarding-first: never auto-start the walkthrough while chat onboarding
    // is still pending for this user. Defends the ordering against the route
    // race where a cohort user sitting on `/` could otherwise start the tour
    // before GoRouter redirects them to /onboarding-chat. needsOnboardingProvider
    // is true only for the new-onboarding cohort with onboardingComplete=false;
    // false for legacy users and guests, so their behaviour is unchanged. It
    // flips to false the moment onboarding completes, and landing back on `/`
    // re-fires this method. (`null` = profile still loading — already covered by
    // the tourUserIdProvider guard above, so only block on an explicit `true`.)
    if (ref.read(needsOnboardingProvider) == true) return;
    // GoRouter is always present in the production tree, but widget tests
    // that mount `ProductTourHost` under a bare [MaterialApp] (no router)
    // don't have it. Treat absence as "route gate doesn't apply".
    try {
      final location = GoRouterState.of(context).matchedLocation;
      // AppRoutes.home == '/', so `startsWith` would always be true.
      // Compare exactly: tour only auto-fires on the home route, not on
      // /yours, /chat, or any other shell route.
      if (location != AppRoutes.home) return;
    } on GoError {
      // No GoRouter in the tree (tests). Skip the route check.
    }
    // Profile drawer was removed in PROD-2019 (now a full /menu route),
    // so it can no longer obscure the discovery surface — gate dropped.
    if (ref.read(sidebarOpenProvider)) return;
    if (MediaQuery.of(context).viewInsets.bottom > 0) return;
    unawaited(ref.read(productTourControllerProvider.notifier).start());
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_onRouteChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resume the tour where the user left off when the app
    // foregrounds (mobile `paused → resumed`, web `hidden → resumed`).
    // The controller's state survives backgrounding but the
    // showcaseview tooltip's mount can drop during the suspend/resume
    // cycle, so we re-fire the showcase for the current step.
    //
    // Previously this callback called `.skip()` on `paused | hidden`,
    // which marked the tour seen AND triggered the new-user
    // `navigateToProfilingFlow` side effect — coming back from a
    // background landed the user on the profiling screen instead of
    // the step they were on. Per user report (2026-06-03): the tour
    // must continue where the user left off.
    if (state != AppLifecycleState.resumed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tourState = ref.read(productTourControllerProvider);
      if (tourState.step == TourStep.idle || tourState.step == TourStep.done) {
        return;
      }
      final keys = ref.read(productTourKeysProvider);
      _showcaseFor(tourState.step, keys);
    });
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(productTourKeysProvider);

    // Drive showcase transitions from controller state. The cursor's
    // own provider ([tourCursorTargetProvider]) handles dismiss/show
    // around cursor animations; here we only react to plain state
    // changes that aren't gated by a cursor animation in flight.
    ref.listen<ProductTourState>(productTourControllerProvider, (prev, next) {
      if (prev?.step == next.step) return;
      // If a cursor animation is in flight, the cursor-listener below
      // will start the new tooltip when the cursor target clears
      // (controller flow always clears the cursor target AFTER
      // advancing state). Don't double-fire here.
      if (ref.read(tourCursorTargetProvider) != null) return;
      _showcaseFor(next.step, keys);
    });

    // Cursor-driven dismiss/show: when the cursor takes the stage,
    // hide the current tooltip. When it clears, start the tooltip
    // for the now-current step.
    ref.listen<CursorTarget?>(tourCursorTargetProvider, (prev, next) {
      final showcase = ShowCaseWidget.of(widget.showcaseContext);
      try {
        if (next != null && prev == null) {
          // Cursor just appeared → dismiss the outgoing tooltip.
          showcase.dismiss();
        } else if (next == null && prev != null) {
          // Cursor disappeared → state.step has already advanced;
          // start the tooltip for the now-current step.
          final step = ref.read(productTourControllerProvider).step;
          _showcaseFor(step, keys);
        }
      } catch (_) {
        // Swallow: same rationale as the state listener above.
      }
    });

    // Auth lost mid-tour → abort without persisting the seen flag.
    ref.listen<bool>(isAuthenticatedProvider, (prev, next) {
      if (prev == true && next == false) {
        ref.read(productTourControllerProvider.notifier).abort();
      }
    });

    // Sheet dismissed via drag/back-button/dismiss-overlay mid-step-3 →
    // advance to yoursNav (the dismiss IS the user's "next" gesture).
    ref.listen<dynamic>(createMenuControllerProvider, (prev, next) {
      if (prev != null && next == null) {
        ref
            .read(productTourControllerProvider.notifier)
            .onCreateSheetDismissed();
      }
    });

    // Re-evaluate the trigger whenever a gating surface clears. The
    // method is idempotent / early-returns on every gating signal, so
    // re-entry is safe.
    ref.listen<bool>(sidebarOpenProvider, (prev, next) {
      if (prev == true && next == false) _maybeStartTour();
    });
    // currentUserProvider may resolve AFTER isAuthenticatedProvider flips
    // true (auth state propagates first, user object loads after). The
    // initial post-frame trigger fires before the user id is available;
    // this re-fires once the user id materialises.
    ref.listen<String?>(tourUserIdProvider, (prev, next) {
      if (prev == null && next != null) _maybeStartTour();
    });
    // The new-onboarding cohort flag (PostHog) may resolve AFTER the user is
    // already on home post-onboarding. Re-fire when it flips true so a
    // late-arriving flag still arms the tour for a chat-onboarded user.
    ref.listen<bool>(newOnboardingCohortProvider, (prev, next) {
      if (prev != true && next == true) _maybeStartTour();
    });
    // PROD-4071 — the product-tour kill-switch flag confirms late (it starts at
    // its default and the real PostHog value lands after identify). Re-fire when
    // it flips on so a user already sitting on home still gets the walkthrough.
    ref.listen<bool>(productTourEnabledProvider, (prev, next) {
      if (prev != true && next == true) _maybeStartTour();
    });
    // Onboarding just completed (true → false) → re-evaluate so the walkthrough
    // can start now that onboarding is out of the way, even if the user didn't
    // trigger a fresh route push back onto home.
    ref.listen<bool?>(needsOnboardingProvider, (prev, next) {
      if (prev == true && next == false) _maybeStartTour();
    });
    // PROD-2700: a deep-link drop/bundle detail covering Discovery suppresses
    // the tour. Abort it the moment the detail is shown (its coachmarks would
    // target hidden Discovery elements), and re-evaluate the trigger once the
    // user returns to Discovery and the flag clears. `abort()` does NOT persist
    // the seen flag, so a not-onboarded user gets the tour fresh on return.
    ref.listen<bool>(tourSuppressedForDeepLinkProvider, (prev, next) {
      if (next) {
        ref.read(productTourControllerProvider.notifier).abort();
      } else {
        _maybeStartTour();
      }
    });

    // Wrap in a screen-spanning Stack so [_TourPulseGlow] and the
    // [_TourCursor] can position themselves at the active target's
    // global coordinates (using `RenderBox.localToGlobal`). Both live
    // ABOVE the Scaffold so they cover body widgets (chat bar, feed)
    // and bottom-nav widgets uniformly.
    // Per user spec (2026-05-30): during the tour, taps anywhere
    // OUTSIDE the Saltar / Próximo pills on the tooltip cards must
    // do absolutely nothing — even taps that would normally open
    // content (Daily Drop, shelves, search overlay tabs, drawer
    // items, etc.) are blocked. The full-screen [_TourTapBlocker]
    // sits BELOW the cards in the stack, so the cards receive taps
    // first (their buttons work as expected). Anything that misses
    // the card falls through to the blocker, whose `onTap: () {}`
    // absorbs the gesture without advancing or firing any side
    // effect. The app returns to normal interactivity only when
    // Saltar (skip) or Concluído (done) ends the tour.
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        // Soko-Ink-tinted scrim that dims the page during card phases
        // of the tour (sits BELOW the tap blocker, the cards and the
        // cursor). Hides itself during cursor animations so the
        // demo's choreography stays unobstructed. See [_TourScrim].
        const _TourScrim(),
        const _TourTapBlocker(),
        const _TourWelcomeTooltip(),
        const _TourProcuraTooltip(),
        const _TourDiscoverCityTooltip(),
        const _TourAdicionaTooltip(),
        const _TourDescobreTabsCursor(),
        const _TourCursor(),
      ],
    );
  }

  /// Starts the showcase tooltip for [step]. Swallows the exception
  /// the package throws when a key isn't mounted (tests, in-flight
  /// route transitions). Used by both the state-change listener and
  /// the transition-end listener.
  ///
  /// Every step fires immediately. PROD-4167 dropped yoursNav's 1300 ms
  /// deferral: it only existed to let the create-zine pill's blue rectangle
  /// draw first, and step 4 no longer has one.
  void _showcaseFor(TourStep step, ProductTourKeys keys) {
    final showcase = ShowCaseWidget.of(widget.showcaseContext);
    try {
      switch (step) {
        case TourStep.welcome:
        case TourStep.searchBar:
        case TourStep.discoverCity:
        case TourStep.createSheet:
          // These steps render their tooltip OUTSIDE showcaseview as
          // custom-positioned cards in the host's Stack
          // ([_TourWelcomeTooltip], [_TourProcuraTooltip],
          // [_TourDiscoverCityTooltip] and [_TourAdicionaTooltip]).
          // Each has its own positioning rationale — welcome is
          // viewport-centered (no anchor), searchBar drives the
          // chat-bar-rect → connector → card-border sequence, and the
          // discoverCity / createSheet steps would otherwise see the
          // showcase tooltip placed on top of UI that needs to stay
          // visible. Dismiss any in-flight showcase from a previous
          // step.
          showcase.dismiss();
          break;
        case TourStep.yoursNav:
          showcase.startShowCase([keys.yoursNav]);
          break;
        case TourStep.profileMenu:
          showcase.startShowCase([keys.profileMenu]);
          break;
        case TourStep.idle:
        case TourStep.done:
          showcase.dismiss();
          break;
      }
    } catch (_) {
      // Swallow: the controller already advanced; nothing to do.
    }
  }
}

/// Full-screen tap absorber active throughout the tour
/// (`state.step != idle && state.step != done`). Sits BELOW the
/// tooltip cards in the host's Stack, so the cards' Saltar / Próximo
/// pills receive taps first (Flutter hit-tests later-in-the-list
/// children first). Anything outside the card lands on this
/// `GestureDetector` whose `onTap: () {}` consumes the gesture
/// without advancing or firing any side effect — taps on Daily
/// Drop, shelves, search overlay tabs, drawer items, the bottom
/// nav, all become inert until the tour ends.
/// Per-step cutout spec: a target key (resolved to a global rect at
/// paint time), how much extra breathing room to inflate that rect by,
/// and the corner radius to round it with. Step 3 (createSheet) uses
/// two cutouts; every other step uses one.
class _TourScrimCutoutSpec {
  const _TourScrimCutoutSpec({
    required this.key,
    required this.radius,
    required this.padding,
  });

  final GlobalKey key;
  final double radius;
  final EdgeInsets padding;
}

/// Full-bleed Soko-Ink-tinted scrim that dims the page underneath the
/// tour cards. Cuts rounded-rect holes around the active step's
/// highlighted target(s) so the user's eye lands on the surface(s)
/// being explained while everything else recedes — same idiom as the
/// modal bottom sheets (`showBottomSheetWithHiddenNav` uses the same
/// [AppColors.sokoInkSecondary] barrier).
///
/// Visibility rules (in order of precedence, all must hold):
///   1. Tour is active (`step != idle` and `step != done`).
///   2. No transition cursor in flight
///      (`tourCursorTargetProvider == null`) — keeps the hand cursor's
///      choreography unobstructed.
///   3. The current step's card is on screen. For most steps this is
///      true the moment the step becomes active, but
///      [TourStep.discoverCity] also waits for
///      `tourDescobreTabsDoneProvider` — the looping Zines / Eventos /
///      Sítios demo cursor plays first, then the card slides in, then
///      the scrim appears. Per user spec (2026-06-01): the demo runs
///      against the real (un-dimmed) page so the user clearly sees the
///      category pills change selection.
///
/// Animates opacity over 250 ms to match the slide-in cadence of the
/// modal sheets and the cards' draw-in animation.
class _TourScrim extends ConsumerStatefulWidget {
  const _TourScrim();

  @override
  ConsumerState<_TourScrim> createState() => _TourScrimState();
}

class _TourScrimState extends ConsumerState<_TourScrim> {
  // Tour-local scrim — Soko Ink at ~50 % alpha (0x80). The shared
  // `AppColors.sokoInkSecondary` is 30 %, which other surfaces (modal
  // sheets, etc.) still use as their barrier. Per user spec
  // (2026-06-03): the tour's dim is noticeably darker than the rest
  // of the app so the spotlit target reads as the only thing on the
  // screen worth looking at.
  static const Color _scrimColor = Color(0x8044131D);

  // Chat-bar / search-overlay targets share a ~12 px corner-radius
  // language with the surrounding Soko Blue borders; bottom-nav cells
  // round at ~24 px so the cutout pill matches the icon-cell shape.
  static const EdgeInsets _smallPad = EdgeInsets.all(4);
  static const double _pillRadiusSmall = 12.0;
  static const double _pillRadiusNav = 24.0;

  /// Held by the [CustomPaint] so [_toLocalCutouts] can read the
  /// painter's own [RenderBox] and convert the globally-positioned
  /// cutout rects into the painter's local coordinate space. Without
  /// this the cutouts paint offset by the painter widget's distance
  /// from the viewport origin — invisible when the host's Stack is
  /// already at (0, 0) (Android, desktop) but a ~47 px shift on iOS
  /// where the host sits inside the status-bar safe area, leaving a
  /// strip of un-dimmed page beside the spotlighted target.
  final GlobalKey _paintKey = GlobalKey();

  /// Self-stabiliser for first-mount + async-asset layout (PROD-2353).
  ///
  /// On a new step's first render the target widget's render box can
  /// still be settling layout. Two distinct settling modes happen on
  /// Flutter Web first-login:
  ///
  /// 1. Synchronous layout settle on the first frame after the SCV
  ///    viewport lays out its children (~1 frame after the scrim mounts).
  /// 2. Asynchronous layout shift later when async assets (the SOKO
  ///    SvgPicture in [DiscoveryHeader]) finish loading and push the
  ///    chat bar down. The blue [TourSecondaryHighlight] rectangle
  ///    follows the chat bar (it's a child of the chat bar's Stack),
  ///    but the scrim's cutout — computed from `localToGlobal` — stays
  ///    at the old position because nothing in the scrim's watch list
  ///    invalidates on layout changes.
  ///
  /// A "compare-and-stop-when-stable" loop can't catch case (2) because
  /// it stops before the async asset has loaded. Instead, we rebuild
  /// every frame for a fixed window ([_convergeMaxFrames]) after each
  /// step change, picking up any layout shift in that window.
  ///
  /// Cost: ~120 builds per step change. Each is fast (cutout maths +
  /// painter dispatch). [_TourScrimPainter.shouldRepaint] returns
  /// `false` when cutouts match the previous frame, so the GPU layer
  /// only re-paints when the cutout actually moved. Web-only —
  /// `kIsWeb` guards the converger so iOS / Android keep their exact
  /// post-#762 production code path.
  TourStep? _convergeForStep;
  int _convergeFramesRemaining = 0;
  static const int _convergeMaxFrames = 120; // ~2 seconds at 60 fps

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(productTourControllerProvider.select((s) => s.step));
    final cursorTarget = ref.watch(tourCursorTargetProvider);
    final tabsDone = ref.watch(tourDescobreTabsDoneProvider);
    final adicionaReady = ref.watch(tourAdicionaCardReadyProvider);
    final keys = ref.watch(productTourKeysProvider);

    // Per user spec (2026-06-01): the yoursNav → profileMenu cursor
    // transition is the ONE moment where the scrim stays visible
    // while the hand-cursor is moving. The dim stays around the
    // cursor (cut out as a circle around its fingertip) so the
    // user's eye tracks the hand from Biblioteca to Home as the
    // controller hands off into the last step. Every other cursor
    // transition still hides the scrim (so the choreography reads
    // against the real, un-dimmed page).
    final isYoursToProfileTransition =
        step == TourStep.yoursNav && cursorTarget == CursorTarget.profileMenu;

    final visible =
        isYoursToProfileTransition ||
        (step != TourStep.idle &&
            step != TourStep.done &&
            cursorTarget == null &&
            _cardVisibleForStep(
              step,
              tabsDone: tabsDone,
              adicionaReady: adicionaReady,
            ));

    if (isYoursToProfileTransition) {
      // Follow-cursor mode: full-bleed scrim with NO cutout — the
      // hand cursor itself sits ABOVE the scrim in the host's Stack
      // and its asset's transparent pixels let the scrim show
      // through around the hand's silhouette. Per user spec
      // (2026-06-01 follow-up): "just having the hand icon not
      // shaded is enough, no need for that ball around it" — i.e.
      // no halo / cutout disc around the cursor.
      return Positioned.fill(
        child: IgnorePointer(
          ignoring: true,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            opacity: 1.0,
            child: CustomPaint(
              key: _paintKey,
              painter: _TourScrimPainter(color: _scrimColor, cutouts: const []),
            ),
          ),
        ),
      );
    }

    final globalCutouts = _resolveCutoutRects(_cutoutSpecsForStep(step, keys));
    final localCutouts = _toLocalCutouts(globalCutouts);

    // First-mount + async-asset layout self-stabiliser. See
    // [_convergeForStep] for the full rationale. Re-renders every
    // frame for ~2 seconds after each step change so the cutout
    // tracks the target widget through both synchronous layout
    // settle and later async-asset layout shifts (SOKO SVG load on
    // first-login pushing the chat bar down).
    //
    // Web-only — iOS / Android keep their exact PR #762 production
    // code path because mobile reaches the same surface with all
    // assets already cached and layout settled.
    if (kIsWeb && step != TourStep.idle && step != TourStep.done) {
      if (step != _convergeForStep) {
        _convergeForStep = step;
        _convergeFramesRemaining = _convergeMaxFrames;
      }
      if (_convergeFramesRemaining > 0) {
        _convergeFramesRemaining--;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
    }

    return Positioned.fill(
      child: IgnorePointer(
        // Scrim never receives taps — the tap blocker above it
        // absorbs every gesture in the body area.
        ignoring: true,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          opacity: visible ? 1.0 : 0.0,
          child: CustomPaint(
            key: _paintKey,
            painter: _TourScrimPainter(
              color: _scrimColor,
              cutouts: localCutouts,
            ),
          ),
        ),
      ),
    );
  }

  /// Convert each cutout's globally-positioned rect into the painter's
  /// local coordinate space. The painter draws on a canvas whose
  /// `(0, 0)` is the [CustomPaint] widget's top-left, not the
  /// viewport's; on iOS the host's Stack is inset by the status-bar
  /// safe area, so without this conversion the cutout drawn from a
  /// global `localToGlobal` read lands ~47 px below where the target
  /// actually is, leaving a strip of un-dimmed page beside it.
  /// Identity on platforms where the host already sits at the
  /// viewport origin (Android, web desktop).
  List<_ResolvedCutout> _toLocalCutouts(List<_ResolvedCutout> global) {
    if (global.isEmpty) return const [];
    // Flutter Web regression guard: pre-#762 web rendered cutouts at
    // their global coords directly (painter was assumed at viewport
    // origin, global == local). After #762, `painter.globalToLocal`
    // subtracted an offset that the chat-bar's `localToGlobal` had not
    // added, displacing the cutout. iOS nativo continues to need the
    // conversion (real safe-area inset); on web we restore the working
    // pre-#762 behaviour by returning the global rects unchanged.
    if (kIsWeb) return global;
    final ctx = _paintKey.currentContext;
    if (ctx == null) {
      // First frame after this scrim is built: the painter widget
      // hasn't laid out yet, so we can't read its local origin.
      // Schedule a rebuild for the next frame so the painter
      // self-corrects once its RenderBox is attached. Returning the
      // global rects here is a one-frame approximation — invisible
      // on Android (no inset to correct), one frame of misalignment
      // on iOS.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return global;
    }
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return global;
    final out = <_ResolvedCutout>[];
    for (final c in global) {
      try {
        final localTopLeft = ro.globalToLocal(c.rect.topLeft);
        out.add(
          _ResolvedCutout(rect: localTopLeft & c.rect.size, radius: c.radius),
        );
      } catch (_) {
        // Same `inactive` lifecycle assertion guard as
        // [_resolveCutoutRects]. Skip this cutout for the frame;
        // the next rebuild retries.
      }
    }
    return out;
  }

  /// Whether the step's card widget is actually rendered right now —
  /// must mirror the visibility conditions inside the corresponding
  /// `_Tour*Tooltip` widgets, otherwise the scrim either appears before
  /// the card slides in or lingers after the card dismisses.
  bool _cardVisibleForStep(
    TourStep step, {
    required bool tabsDone,
    required bool adicionaReady,
  }) {
    switch (step) {
      case TourStep.discoverCity:
        // [_TourDiscoverCityTooltip] gates its render on
        // [tourDescobreTabsDoneProvider] — see comment there.
        return tabsDone;
      case TourStep.createSheet:
        // Per user spec (2026-06-01): the createSheet step plays a
        // rectangle-around-drawer → connector → card sequence first;
        // the scrim only fills in once the card has actually
        // mounted. Gated on [tourAdicionaCardReadyProvider].
        return adicionaReady;
      case TourStep.yoursNav:
      case TourStep.welcome:
      case TourStep.searchBar:
      case TourStep.profileMenu:
        return true;
      case TourStep.idle:
      case TourStep.done:
        return false;
    }
  }

  /// Targets to cut out of the scrim for each step. The createSheet
  /// step intentionally returns no cutouts — per user spec
  /// (2026-06-01) the Adiciona card should sit over a fully-dimmed
  /// page; the card itself is the focal surface, not the buttons in
  /// the chat bar or nav.
  List<_TourScrimCutoutSpec> _cutoutSpecsForStep(
    TourStep step,
    ProductTourKeys keys,
  ) {
    switch (step) {
      case TourStep.searchBar:
        return [
          _TourScrimCutoutSpec(
            key: keys.searchBar,
            radius: _pillRadiusSmall,
            padding: _smallPad,
          ),
        ];
      case TourStep.discoverCity:
        return [
          _TourScrimCutoutSpec(
            key: keys.discoverCity,
            radius: _pillRadiusSmall,
            padding: _smallPad,
          ),
        ];
      case TourStep.createSheet:
        // Per user spec (2026-06-01 follow-up): the create menu
        // bottom drawer must remain un-dimmed during step 3 — the
        // card sits above the drawer and the connector links the
        // two, so dimming the drawer would muddle the visual
        // hierarchy. Cut out the drawer's full rect (radius matches
        // the [TourSecondaryHighlight] in `create_menu_sheet.dart`)
        // so it reads as a foregrounded surface alongside the card.
        // Note: only the tour's scrim cuts the drawer out — the
        // regular `_CreateMenuDismissOverlay` (used when the user
        // opens Create+ outside the tour) still dims the whole body
        // unchanged.
        return [
          _TourScrimCutoutSpec(
            key: keys.createSheet,
            radius: 20.0,
            padding: _smallPad,
          ),
        ];
      case TourStep.yoursNav:
        return [
          _TourScrimCutoutSpec(
            key: keys.yoursNav,
            radius: _pillRadiusNav,
            padding: _smallPad,
          ),
        ];
      case TourStep.profileMenu:
        return [
          _TourScrimCutoutSpec(
            key: keys.profileMenu,
            radius: _pillRadiusNav,
            padding: _smallPad,
          ),
        ];
      case TourStep.welcome:
      case TourStep.idle:
      case TourStep.done:
        return const [];
    }
  }

  List<_ResolvedCutout> _resolveCutoutRects(List<_TourScrimCutoutSpec> specs) {
    final out = <_ResolvedCutout>[];
    for (final spec in specs) {
      try {
        final ctx = spec.key.currentContext;
        if (ctx == null) continue;
        final renderObject = ctx.findRenderObject();
        if (renderObject is! RenderBox) continue;
        if (!renderObject.attached || !renderObject.hasSize) continue;
        final topLeft = renderObject.localToGlobal(Offset.zero);
        final rect = topLeft & renderObject.size;
        out.add(
          _ResolvedCutout(
            rect: spec.padding.inflateRect(rect),
            radius: spec.radius,
          ),
        );
      } catch (_) {
        // `findRenderObject` throws when an element is in the
        // transient `inactive` lifecycle state (mid widget-tree
        // deactivation, e.g. bottom drawer animating closed during a
        // step transition). Skip this cutout for the frame; the next
        // rebuild will re-attempt.
      }
    }
    return out;
  }
}

class _ResolvedCutout {
  const _ResolvedCutout({required this.rect, required this.radius});

  final Rect rect;
  final double radius;
}

class _TourScrimPainter extends CustomPainter {
  _TourScrimPainter({required this.color, required this.cutouts});

  final Color color;
  final List<_ResolvedCutout> cutouts;

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Offset.zero & size;
    final paint = Paint()..color = color;
    if (cutouts.isEmpty) {
      canvas.drawRect(screen, paint);
      return;
    }
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(screen);
    var addedAny = false;
    for (final cutout in cutouts) {
      if (!cutout.rect.overlaps(screen)) continue;
      path.addRRect(
        RRect.fromRectAndRadius(cutout.rect, Radius.circular(cutout.radius)),
      );
      addedAny = true;
    }
    if (!addedAny) {
      canvas.drawRect(screen, paint);
      return;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TourScrimPainter old) {
    if (old.color != color) return true;
    if (old.cutouts.length != cutouts.length) return true;
    for (var i = 0; i < cutouts.length; i++) {
      if (old.cutouts[i].rect != cutouts[i].rect ||
          old.cutouts[i].radius != cutouts[i].radius) {
        return true;
      }
    }
    return false;
  }
}

class _TourTapBlocker extends ConsumerWidget {
  const _TourTapBlocker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = ref.watch(productTourControllerProvider.select((s) => s.step));
    final isActive = step != TourStep.idle && step != TourStep.done;
    if (!isActive) return const SizedBox.shrink();
    return Positioned.fill(
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}),
    );
  }
}

/// Looping demo cursor visible only during the discoverCity step
/// (when the user is reading the Descobre tooltip card). Cycles
/// through the three category tabs in the search overlay — Eventos
/// → Sítios → Zines → repeat — actually CLICKING each one so the
/// user sees the selection change underneath. Demonstrates what the
/// tabs do without the user having to tap.
///
/// Hides as soon as a real transition cursor takes the stage
/// (`tourCursorTargetProvider != null`) so the two cursors don't
/// fight for attention when the user taps Next.
class _TourDescobreTabsCursor extends ConsumerStatefulWidget {
  const _TourDescobreTabsCursor();

  @override
  ConsumerState<_TourDescobreTabsCursor> createState() =>
      _TourDescobreTabsCursorState();
}

class _TourDescobreTabsCursorState
    extends ConsumerState<_TourDescobreTabsCursor>
    with TickerProviderStateMixin {
  static const Duration _moveDuration = Duration(milliseconds: 850);
  static const Duration _clickDuration = Duration(milliseconds: 280);
  static const Duration _dwellAfterClick = Duration(milliseconds: 350);

  /// The cursor's HOP destinations after the initial landing on
  /// Zines. Per spec ("zines, eventos, sitios e zines outra vez"):
  /// start visible at Zines, then hop through Eventos → Sítios →
  /// Zines, clicking each. After the final Zines hop the cursor
  /// hides — one cycle only.
  static const List<DiscoverySearchCategory> _hops = [
    DiscoverySearchCategory.eventos,
    DiscoverySearchCategory.sitios,
    DiscoverySearchCategory.zines,
  ];

  late final AnimationController _moveController;
  late final AnimationController _clickController;
  late final Animation<double> _clickScale;
  late final AnimationController _ambientTicker;

  Timer? _phaseTimer;
  Timer? _clickTimer;
  // -1 = sitting at the initial Zines position before the first hop
  //   N = currently hopping toward `_hops[N]`.
  int _phaseIndex = -1;
  Offset? _moveStart;
  Offset? _lastEndCenter;
  bool _active = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _moveController = AnimationController(vsync: this, duration: _moveDuration);
    _clickController = AnimationController(
      vsync: this,
      duration: _clickDuration,
    );
    _clickScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.7,
        ).chain(CurveTween(curve: Curves.easeInQuad)),
        weight: 45,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.7,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 55,
      ),
    ]).animate(_clickController);
    _ambientTicker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _phaseTimer?.cancel();
    _clickTimer?.cancel();
    _moveController.dispose();
    _clickController.dispose();
    _ambientTicker.dispose();
    super.dispose();
  }

  Offset? _readTargetCenter(GlobalKey key) {
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return null;
    final position = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    return Offset(position.dx + size.width / 2, position.dy + size.height / 2);
  }

  GlobalKey _keyForCategory(
    DiscoverySearchCategory category,
    ProductTourKeys keys,
  ) {
    switch (category) {
      case DiscoverySearchCategory.eventos:
        return keys.discoverTabEventos;
      case DiscoverySearchCategory.sitios:
        return keys.discoverTabSitios;
      case DiscoverySearchCategory.zines:
        return keys.discoverTabZines;
      case DiscoverySearchCategory.all:
      case DiscoverySearchCategory.leitores:
        // Neither is in the tour's cycle; defensively return zines's
        // key so the switch is exhaustive.
        return keys.discoverTabZines;
    }
  }

  /// Schedules the next hop: snapshot the last reached position as
  /// the move start, advance the phase index, start the move
  /// controller, schedule the click pulse + category set + next
  /// phase. Once `_phaseIndex` walks past the end of `_hops` the
  /// cursor finishes and hides.
  void _startNextHop() {
    if (!_active || !mounted) return;
    if (_phaseIndex + 1 >= _hops.length) {
      // All hops done — fade out by marking finished. Builder
      // returns SizedBox once `_finished` is true. ALSO flip the
      // shared `tourDescobreTabsDoneProvider` flag so the Descobre
      // card knows it can now appear — it waits for the tab demo
      // to finish so it doesn't cover the tabs the cursor is
      // demonstrating.
      setState(() {
        _finished = true;
      });
      ref.read(tourDescobreTabsDoneProvider.notifier).state = true;
      return;
    }
    _moveStart = _lastEndCenter ?? _moveStart;
    _phaseIndex += 1;
    _moveController.forward(from: 0);
    _clickTimer?.cancel();
    _clickTimer = Timer(_moveDuration, () {
      if (!mounted || !_active) return;
      _clickController.forward(from: 0);
      // Actually flip the search category at the click moment so the
      // user sees the underlying tabs change selection.
      ref.read(searchCategoryProvider.notifier).state = _hops[_phaseIndex];
    });
    _phaseTimer?.cancel();
    _phaseTimer = Timer(
      _moveDuration + _clickDuration + _dwellAfterClick,
      _startNextHop,
    );
  }

  void _stop() {
    _active = false;
    _finished = false;
    _phaseTimer?.cancel();
    _clickTimer?.cancel();
    _moveController.stop();
    _clickController.stop();
    _phaseIndex = -1;
    _moveStart = null;
    _lastEndCenter = null;
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(productTourControllerProvider.select((s) => s.step));
    final cursorTarget = ref.watch(tourCursorTargetProvider);
    final keys = ref.watch(productTourKeysProvider);

    final shouldBeActive =
        step == TourStep.discoverCity && cursorTarget == null;
    if (!shouldBeActive) {
      if (_active || _finished) _stop();
      return const SizedBox.shrink();
    }
    if (_finished) return const SizedBox.shrink();

    // Lazy start: appear at the Zines tab position (no movement),
    // dwell briefly, then start hopping. Without the lazy start the
    // timer fires before the search overlay's open animation has
    // settled and all tab RenderBoxes would be null.
    if (!_active) {
      final zinesEnd = _readTargetCenter(
        _keyForCategory(DiscoverySearchCategory.zines, keys),
      );
      if (zinesEnd == null) {
        return const SizedBox.shrink();
      }
      _active = true;
      _moveStart = zinesEnd;
      _lastEndCenter = zinesEnd;
      _moveController.value = 1.0; // appear at destination immediately
      // After a brief dwell, start the first hop (Zines → Eventos).
      _phaseTimer = Timer(_dwellAfterClick, _startNextHop);
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        _moveController,
        _clickController,
        _ambientTicker,
      ]),
      builder: (_, __) {
        final currentCategory = _phaseIndex < 0
            ? DiscoverySearchCategory.zines
            : _hops[_phaseIndex];
        final end = _readTargetCenter(_keyForCategory(currentCategory, keys));
        if (end == null) return const SizedBox.shrink();
        final start = _moveStart ?? end;
        _lastEndCenter = end;
        final t = Curves.easeInOutCubic.transform(_moveController.value);
        final center = Offset.lerp(start, end, t)!;
        // Anchor the hand by its fingertip — the [_CursorPointer.tip]
        // offset is the asset-local point that should land on the
        // target. Without this the asset centre would land on the
        // target and the fingertip would point past it.
        return Positioned(
          left: center.dx - _CursorPointer.tip.dx,
          top: center.dy - _CursorPointer.tip.dy,
          width: _CursorPointer.size.width,
          height: _CursorPointer.size.height,
          child: IgnorePointer(
            child: Transform.scale(
              scale: _clickScale.value,
              alignment: Alignment.topLeft.add(
                Alignment(
                  (_CursorPointer.tip.dx / _CursorPointer.size.width) * 2,
                  (_CursorPointer.tip.dy / _CursorPointer.size.height) * 2,
                ),
              ),
              child: const _CursorPointer(),
            ),
          ),
        );
      },
    );
  }
}

/// Approximate rendered height of a [TourTooltip] card with one
/// headline line, two body lines, and the three-pill action row.
/// Used to clamp [_positionedTourCard]'s top so the card never
/// disappears below the bottom safe-area on short viewports.
/// Overestimates intentionally — a 20 px buffer is cheaper than a
/// card that runs off-screen on a small iPhone. Updated for the
/// compact card variant (2026-05-30): headline 34 px, body 12 px,
/// pill height 32 px, 11 px container padding.
const double _kApproxCardHeight = 215.0;

/// Reserve at the bottom of the viewport for the discovery shell's
/// bottom-nav (~ 48 px) + iOS home indicator inset (~ 34 px) + 18 px
/// of breathing room. Used by the clamp below.
const double _kBottomNavReserve = 100.0;

/// Renders [TourTooltip] in a Positioned card with a viewport-aware
/// vertical position and shared max-width.
///
/// [preferredTopOffset] is the gap (in logical pixels) between the
/// MediaQuery top safe-area inset and the card's top edge. It is
/// CLAMPED so the card stays visible on short viewports — on a tall
/// desktop the preferred offset is honoured verbatim; on a short
/// iPhone SE the card is pushed up far enough to clear the bottom
/// nav. The width is also viewport-aware via [tourCardMaxWidth] so
/// the card never touches the screen edge.
///
/// Each card site picks a [preferredTopOffset] that avoids the
/// step's important UI:
///   * discoverCity → below the search input + category tabs.
///   * createSheet → below the chat-bar's AddToSoko pill, above the
///     bottom drawer's body content.
Widget _positionedTourCard({
  required BuildContext context,
  required Widget child,
  required double preferredTopOffset,
}) {
  final mq = MediaQuery.of(context);
  final topInset = mq.padding.top;
  final maxTop = math.max(
    topInset + 16,
    mq.size.height - _kBottomNavReserve - _kApproxCardHeight,
  );
  final clampedTop = math
      .min(topInset + preferredTopOffset, maxTop)
      .clamp(topInset + 16.0, double.infinity);
  return Positioned(
    left: 0,
    right: 0,
    top: clampedTop,
    child: SafeArea(
      top: false,
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: tourCardMaxWidth(context)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Material(color: Colors.transparent, child: child),
          ),
        ),
      ),
    ),
  );
}

/// Centered welcome card shown the moment the tour starts (step
/// `welcome`). Sits above the scrim with no anchor — the user sees
/// the Soko-voice intro ("Olá, vizinho.") and taps Vamos to begin
/// the numbered choreography. No counter (this card is outside the
/// 1–5 step flow). Skip dismisses the whole tour, matching every
/// other step.
class _TourWelcomeTooltip extends ConsumerWidget {
  const _TourWelcomeTooltip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = ref.watch(productTourControllerProvider.select((s) => s.step));
    if (step != TourStep.welcome) return const SizedBox.shrink();
    final notifier = ref.read(productTourControllerProvider.notifier);
    final l10n = Lt.of(context);
    return Positioned.fill(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: tourCardMaxWidth(context)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Material(
                color: Colors.transparent,
                child: TourTooltip(
                  headline: l10n.productTourWelcomeHeadline,
                  body: l10n.productTourWelcomeBody,
                  currentStep: 0,
                  totalSteps: 0,
                  isLastStep: false,
                  showCounter: false,
                  // "Let me explore" is the primary (prominent blue) pill;
                  // "Walk me through" the secondary. Behaviour is unchanged —
                  // explore dismisses the tour, walk-through starts it — only
                  // the emphasis is swapped, so the primary slot (onNext) runs
                  // skip() and the secondary slot (onSkip) runs next().
                  nextLabel: l10n.productTourWelcomeSkip,
                  skipLabel: l10n.productTourWelcomeCta,
                  onNext: notifier.skip,
                  onSkip: notifier.next,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Step 1 (Procura) custom card + connector orchestrator. Sequences
/// three animations end-to-end (user spec 2026-05-30):
///   1. **Chat-bar rectangle** (~1050 ms) — drawn by
///      [TourSecondaryHighlight] on the chat-bar widget itself
///      (separate widget, runs in parallel; sequencing is purely
///      time-based here).
///   2. **Connector** (~250 ms) — straight Soko-Blue line from the
///      chat-bar's bottom-left to where the card's top-left will be.
///   3. **Card** (~650 ms) — the card pops in AFTER the connector
///      lands, with its outer Soko-Blue rectangle DRAWING IN at the
///      same time. The card body (headline / pills) appears
///      instantly; only the outer border has the draw-in animation.
///
/// All three play one after the other so the user reads a single
/// continuous "Soko hand sketches the spotlight, the line, and the
/// card frame" motion.
class _TourProcuraTooltip extends ConsumerStatefulWidget {
  const _TourProcuraTooltip();

  @override
  ConsumerState<_TourProcuraTooltip> createState() =>
      _TourProcuraTooltipState();
}

class _TourProcuraTooltipState extends ConsumerState<_TourProcuraTooltip>
    with TickerProviderStateMixin {
  /// Timings for the three sequential beats. Card border starts as
  /// soon as the connector ends so the user reads one continuous
  /// motion: spotlight → line → card frame.
  static const Duration _chatBarRectDuration = Duration(milliseconds: 1050);
  static const Duration _connectorDuration = Duration(milliseconds: 250);

  late final AnimationController _connectorController;

  /// True once the connector finishes — gates when the card mounts.
  /// The card's own outer-rect draw-in is animated INTERNALLY by
  /// [TourTooltip] (its `_borderController` auto-forwards on
  /// mount), so this widget just decides when to start showing
  /// the card.
  bool _cardMounted = false;

  /// Per-frame rebuild driver so [_readTargetCenter]-style
  /// `RenderBox.localToGlobal` reads pick up keyboard / scroll
  /// shifts.
  late final AnimationController _ambientTicker;

  /// `GlobalKey` on the card so the connector painter can read its
  /// actual rendered top-left + width.
  final GlobalKey _cardKey = GlobalKey(debugLabel: 'tour_procuraCard');

  Timer? _scheduleConnector;
  Timer? _scheduleCardBorder;
  TourStep? _previousStep;

  @override
  void initState() {
    super.initState();
    _connectorController = AnimationController(
      vsync: this,
      duration: _connectorDuration,
    );
    _ambientTicker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _scheduleConnector?.cancel();
    _scheduleCardBorder?.cancel();
    _connectorController.dispose();
    _ambientTicker.dispose();
    super.dispose();
  }

  void _reset() {
    _scheduleConnector?.cancel();
    _scheduleCardBorder?.cancel();
    _connectorController.value = 0;
    if (_cardMounted) setState(() => _cardMounted = false);
  }

  void _kickOffSequence() {
    _scheduleConnector?.cancel();
    _scheduleCardBorder?.cancel();
    _connectorController.value = 0;
    if (_cardMounted) {
      setState(() => _cardMounted = false);
    }
    _scheduleConnector = Timer(_chatBarRectDuration, () {
      if (!mounted) return;
      _connectorController.forward();
    });
    // Card pops in AFTER the connector finishes. Its own
    // outer-rect draw-in is then driven by TourTooltip's internal
    // border controller (auto-forwards on mount).
    _scheduleCardBorder = Timer(_chatBarRectDuration + _connectorDuration, () {
      if (!mounted) return;
      setState(() => _cardMounted = true);
    });
  }

  Rect? _readTargetRect(GlobalKey key) {
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return null;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    return topLeft & renderObject.size;
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(productTourControllerProvider.select((s) => s.step));
    final cursorTarget = ref.watch(tourCursorTargetProvider);
    // Hide the card while a transition cursor is travelling (matches
    // the other custom cards' pattern).
    if (step != TourStep.searchBar || cursorTarget != null) {
      if (_previousStep == TourStep.searchBar) _reset();
      _previousStep = step;
      return const SizedBox.shrink();
    }
    if (_previousStep != TourStep.searchBar) {
      _previousStep = TourStep.searchBar;
      // Defer the sequence kick-off to AFTER the current build phase
      // so the AnimationController resets (which notify their
      // listeners) don't fight a build in-flight. Necessary for the
      // replay-from-/menu path: state advances mid-frame and this
      // build runs before the AnimatedBuilder below has subscribed,
      // so a synchronous _kickOffSequence() inside build could miss
      // its target frame and leave the timers desynced from when the
      // card actually appears on screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(productTourControllerProvider).step !=
            TourStep.searchBar) {
          return;
        }
        if (ref.read(tourCursorTargetProvider) != null) return;
        _kickOffSequence();
      });
    }

    final keys = ref.watch(productTourKeysProvider);
    final notifier = ref.read(productTourControllerProvider.notifier);
    final l10n = Lt.of(context);

    return AnimatedBuilder(
      animation: Listenable.merge([_connectorController, _ambientTicker]),
      builder: (_, __) {
        final chatBarRect = _readTargetRect(keys.searchBar);
        if (chatBarRect == null) return const SizedBox.shrink();

        // Card top-left: just below the chat bar, aligned to the
        // chat-bar's left edge so the connector reads as a short,
        // mostly-vertical link rather than a long diagonal.
        const cardGap = 36.0;
        final cardLeft = chatBarRect.left;
        final cardTop = chatBarRect.bottom + cardGap;

        // The connector reads the card's *actual* rendered top-left
        // from the GlobalKey (so its width-driven horizontal extent
        // matches reality). On the FIRST frame, before the card has
        // been laid out, fall back to the computed position above.
        final cardRect = _readTargetRect(_cardKey);
        final connectorAnchor = cardRect?.topLeft ?? Offset(cardLeft, cardTop);

        return Stack(
          children: [
            // Connector — painted by a Positioned.fill so the
            // CustomPainter has the whole viewport to draw the curve.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TourProcuraConnectorPainter(
                    from: Offset(chatBarRect.left + 24, chatBarRect.bottom),
                    to: Offset(connectorAnchor.dx + 24, connectorAnchor.dy),
                    progress: _connectorController.value,
                    color: AppColors.sokoBlue,
                    // Match the chat-bar rectangle + card outer-rect
                    // stroke (both 6 px) so the three elements read
                    // as the same family of hand-drawn strokes.
                    strokeWidth: 6.0,
                  ),
                ),
              ),
            ),
            // Card — mounts ONLY once the connector has landed. The
            // card body (headline / pills) appears instantly on
            // mount; the outer Soko-Blue rectangle draws in via
            // TourTooltip's INTERNAL `_borderController` (auto-
            // forwards on mount). Every step's card gets the same
            // animation, so the logic lives in TourTooltip itself
            // rather than in this orchestrator.
            if (_cardMounted)
              Positioned(
                left: cardLeft,
                top: cardTop,
                child: KeyedSubtree(
                  key: _cardKey,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      // Card never wider than the chat bar — keeps the
                      // connector short and the visual reading "the
                      // card is a child of the chat bar". Also capped
                      // by [tourCardMaxWidth] so on wide desktops
                      // where the chat bar stretches past the
                      // editorial card proportions, the card stays
                      // compact.
                      maxWidth: math.min(
                        chatBarRect.width,
                        tourCardMaxWidth(context),
                      ),
                    ),
                    child: TourTooltip(
                      headline: l10n.productTourStep1SearchHeadline,
                      body: l10n.productTourStep1SearchBody,
                      currentStep: 1,
                      totalSteps: 5,
                      isLastStep: false,
                      onNext: notifier.next,
                      onSkip: notifier.skip,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Paints the curved Soko-Blue connector that links the chat-bar
/// spotlight's bottom edge to the Procura card's top edge during
/// step 1. `progress` ∈ [0, 1] grows the visible length of the curve
/// from `from` toward `to` so the line appears to be drawn by hand.
class _TourProcuraConnectorPainter extends CustomPainter {
  _TourProcuraConnectorPainter({
    required this.from,
    required this.to,
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  final Offset from;
  final Offset to;
  final double progress;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    // Straight line from chat-bar bottom-left to card top-left. The
    // earlier cubic bezier bowed left and read as a wavy connector
    // — needs to be exactly straight.
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..lineTo(to.dx, to.dy);

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final visibleLength = metric.length * progress.clamp(0.0, 1.0);
    canvas.drawPath(metric.extractPath(0, visibleLength), paint);
  }

  @override
  bool shouldRepaint(_TourProcuraConnectorPainter old) =>
      from != old.from ||
      to != old.to ||
      progress != old.progress ||
      color != old.color ||
      strokeWidth != old.strokeWidth;
}

/// Bottom-anchored tooltip card shown only during the discoverCity
/// step. The search overlay is already on screen (just opened by the
/// cursor's click on the "Descobre a cidade" pill), so there's no
/// spotlight rectangle for this step — the card itself sits on top of
/// the overlay, anchored near the bottom safe-area inset.
class _TourDiscoverCityTooltip extends ConsumerWidget {
  const _TourDiscoverCityTooltip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = ref.watch(productTourControllerProvider.select((s) => s.step));
    // Hide the card the moment the cursor starts transitioning out
    // (cursor target becomes non-null while on discoverCity). The
    // X-close → AddToSoko chain plays without the Descobre card
    // blocking the cursor's path.
    final cursorTarget = ref.watch(tourCursorTargetProvider);
    // The Descobre card waits for the looping demo cursor
    // ([_TourDescobreTabsCursor]) to finish its Zines → Eventos →
    // Sítios cycle before appearing. Per user spec (2026-05-30): the
    // tabs demo needs to play first so the user sees the category
    // pills change selection; only then does the card slide in to
    // explain what just happened. Gated on
    // [tourDescobreTabsDoneProvider], which the demo cursor flips
    // true when its last hop completes.
    final tabsDone = ref.watch(tourDescobreTabsDoneProvider);
    if (step != TourStep.discoverCity || cursorTarget != null || !tabsDone) {
      return const SizedBox.shrink();
    }
    final notifier = ref.read(productTourControllerProvider.notifier);
    final l10n = Lt.of(context);
    // Sits roughly mid-screen: low enough to clear the search input
    // + category tabs (~190 px) AND the first row of result cards
    // (~170 px more), so the user can see what they'd be searching
    // for while reading the tooltip.
    return _positionedTourCard(
      context: context,
      preferredTopOffset: 340,
      child: TourTooltip(
        headline: l10n.productTourStep3DiscoverHeadline,
        body: l10n.productTourStep3DiscoverBody,
        currentStep: 2,
        totalSteps: 5,
        isLastStep: false,
        onNext: notifier.next,
        onSkip: notifier.skip,
      ),
    );
  }
}

/// Bottom-anchored tooltip card shown only during the createSheet
/// (Adiciona) step. Replaces the package-driven showcase tooltip —
/// the default placement put the card on top of the AddToSoko pill
/// in the chat bar, which the user needed to remain visible.
///
/// Per user spec (2026-06-01): plays the same three-beat sequence as
/// the step-1 [_TourProcuraTooltip]:
///   1. The Soko-Blue rectangle draws around the create-menu bottom
///      drawer (handled externally by the [TourSecondaryHighlight]
///      wrapping `CreateMenuSheet`'s `DSSheetShell` — same painter as
///      the step-1 chat-bar rect).
///   2. The connector hairline draws up from the drawer's top edge
///      to where the card will mount.
///   3. The card mounts, animates its outer-rect draw-in, and the
///      scrim fills in around it (the scrim gates `createSheet`
///      visibility on [tourAdicionaCardReadyProvider], which this
///      widget flips true at card-mount time).
///
/// Card positioning is viewport-aware: on desktop (width ≥ 800) the
/// card sits ABOVE the drawer (so the page-wide horizontal layout
/// keeps the card in the editorial column rather than crashing into
/// the drawer's content); on mobile it stays anchored just below the
/// AddToSoko pill (the established behaviour — same as before).
class _TourAdicionaTooltip extends ConsumerStatefulWidget {
  const _TourAdicionaTooltip();

  @override
  ConsumerState<_TourAdicionaTooltip> createState() =>
      _TourAdicionaTooltipState();
}

class _TourAdicionaTooltipState extends ConsumerState<_TourAdicionaTooltip>
    with TickerProviderStateMixin {
  /// Mirrors step 1's beats. The drawer rect's 1050 ms is the
  /// external [TourSecondaryHighlight]'s 400 ms entry delay + 650 ms
  /// draw window — keep in sync if those constants drift.
  static const Duration _drawerRectDuration = Duration(milliseconds: 1050);
  static const Duration _connectorDuration = Duration(milliseconds: 250);

  late final AnimationController _connectorController;
  late final AnimationController _ambientTicker;
  final GlobalKey _cardKey = GlobalKey(debugLabel: 'tour_adicionaCard');

  bool _cardMounted = false;
  Timer? _scheduleConnector;
  Timer? _scheduleCardMount;
  TourStep? _previousStep;

  @override
  void initState() {
    super.initState();
    _connectorController = AnimationController(
      vsync: this,
      duration: _connectorDuration,
    );
    _ambientTicker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _scheduleConnector?.cancel();
    _scheduleCardMount?.cancel();
    _connectorController.dispose();
    _ambientTicker.dispose();
    super.dispose();
  }

  void _reset() {
    _scheduleConnector?.cancel();
    _scheduleCardMount?.cancel();
    _connectorController.value = 0;
    if (_cardMounted) setState(() => _cardMounted = false);
    // Provider mutation must not happen synchronously when [_reset]
    // is reached from inside build() — Riverpod throws if a notifier
    // is poked while the framework is mid-build. Defer to the next
    // frame; the controller's own reset paths (start/abort/_complete)
    // also clear this flag, so a slight delay here is safe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(tourAdicionaCardReadyProvider)) {
        ref.read(tourAdicionaCardReadyProvider.notifier).state = false;
      }
    });
  }

  void _kickOffSequence() {
    _scheduleConnector?.cancel();
    _scheduleCardMount?.cancel();
    _connectorController.value = 0;
    if (_cardMounted) {
      setState(() => _cardMounted = false);
    }
    if (ref.read(tourAdicionaCardReadyProvider)) {
      ref.read(tourAdicionaCardReadyProvider.notifier).state = false;
    }
    _scheduleConnector = Timer(_drawerRectDuration, () {
      if (!mounted) return;
      _connectorController.forward();
    });
    _scheduleCardMount = Timer(_drawerRectDuration + _connectorDuration, () {
      if (!mounted) return;
      setState(() => _cardMounted = true);
      ref.read(tourAdicionaCardReadyProvider.notifier).state = true;
    });
  }

  Rect? _readTargetRect(GlobalKey key) {
    // [findRenderObject] throws when the element's lifecycle state is
    // `inactive` (a transient state during widget-tree deactivation —
    // e.g. the create menu sheet is mid-animation closing for the
    // step 3 → 4 transition). The element's `currentContext` is
    // still non-null at that moment, so the null-guard before the
    // call doesn't help. Swallow the exception and treat it as
    // "rect not available right now" — the next frame's ambient
    // ticker rebuild will re-attempt and either succeed (target
    // re-mounted) or stay null (target gone).
    try {
      final ctx = key.currentContext;
      if (ctx == null) return null;
      final renderObject = ctx.findRenderObject();
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        return null;
      }
      final topLeft = renderObject.localToGlobal(Offset.zero);
      return topLeft & renderObject.size;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(productTourControllerProvider.select((s) => s.step));
    final cursorTarget = ref.watch(tourCursorTargetProvider);
    if (step != TourStep.createSheet || cursorTarget != null) {
      if (_previousStep == TourStep.createSheet) _reset();
      _previousStep = step;
      return const SizedBox.shrink();
    }
    if (_previousStep != TourStep.createSheet) {
      _previousStep = TourStep.createSheet;
      // Defer to after the current build so the AnimationController
      // resets (which notify their listeners) don't fight an in-flight
      // build, and so the drawer key has had a chance to mount.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(productTourControllerProvider).step !=
            TourStep.createSheet) {
          return;
        }
        if (ref.read(tourCursorTargetProvider) != null) return;
        _kickOffSequence();
      });
    }

    final keys = ref.watch(productTourKeysProvider);
    final notifier = ref.read(productTourControllerProvider.notifier);
    final l10n = Lt.of(context);

    return AnimatedBuilder(
      animation: Listenable.merge([_connectorController, _ambientTicker]),
      builder: (_, __) {
        final topInset = MediaQuery.paddingOf(context).top;

        final drawerRect = _readTargetRect(keys.createSheet);

        // Anchor the card just above the drawer (mobile + desktop
        // share the same anchor now — per user spec 2026-06-01
        // follow-up the card should sit close to the drawer with a
        // short vertical connector, mirroring step 1's chat-bar →
        // card rhythm). [_positionedTourCard]'s clamp keeps it on
        // screen if a short viewport would otherwise push it past
        // the top safe area; the fixed 110 is the fallback for the
        // (rare) frame where the drawer hasn't mounted yet. (It used
        // to fall back to the "Adiciona à Soko" pill's rect — that
        // pill was removed from the chat bar in #1224.)
        const cardGap = 16.0;
        double preferredTopOffset;
        if (drawerRect != null) {
          preferredTopOffset =
              drawerRect.top - _kApproxCardHeight - cardGap - topInset;
          if (preferredTopOffset < 16) preferredTopOffset = 16;
        } else {
          preferredTopOffset = 110;
        }

        // Connector geometry: a strictly VERTICAL line on the
        // card's left side. Step 1's [_TourProcuraTooltip] aligns
        // its card with the chat bar's left edge, so its `from`
        // and `to` X coordinates match by construction. Step 3's
        // card is centered via [_positionedTourCard] (so its left
        // edge does NOT line up with the drawer's left edge), so
        // we anchor BOTH endpoints on the card's left + 24 — the
        // line drops from the drawer plane straight down to the
        // card's left margin, no diagonal.
        const connectorXOffset = 24.0;
        Offset? connectorFrom;
        Offset? connectorTo;
        if (drawerRect != null) {
          final cardRect = _readTargetRect(_cardKey);
          if (cardRect != null) {
            final xCoord = cardRect.left + connectorXOffset;
            connectorFrom = Offset(xCoord, drawerRect.top);
            connectorTo = Offset(xCoord, cardRect.bottom);
          }
        }

        return Stack(
          children: [
            // Connector — only paints when both endpoints are known
            // AND the controller is past 0.
            if (connectorFrom != null &&
                connectorTo != null &&
                _connectorController.value > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _TourProcuraConnectorPainter(
                      from: connectorFrom,
                      to: connectorTo,
                      progress: _connectorController.value,
                      color: AppColors.sokoBlue,
                      // Match the drawer rectangle + card outer-rect
                      // stroke (both 6 px) so all step-3 strokes read
                      // as the same family — same rule as step 1.
                      strokeWidth: 6.0,
                    ),
                  ),
                ),
              ),
            if (_cardMounted)
              _positionedTourCard(
                context: context,
                preferredTopOffset: preferredTopOffset,
                child: KeyedSubtree(
                  key: _cardKey,
                  child: TourTooltip(
                    headline: l10n.productTourStep3CreateHeadline,
                    body: l10n.productTourStep3CreateBody,
                    currentStep: 3,
                    totalSteps: 5,
                    isLastStep: false,
                    onNext: notifier.next,
                    onSkip: notifier.skip,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Simulated mouse cursor painted ABOVE the Scaffold. Glides between
/// the clickable button of each step and performs a click-pulse on
/// arrival, so the user gets a brand-flavoured "this is what to tap"
/// hint without seeing a literal OS cursor.
///
/// Design: a 36 px translucent Soko-Blue ring with a soft outer glow.
/// Reads as a "hand pointer" without being a literal mouse glyph —
/// matches Soko's playful, illustrative tone.
///
/// The clickable-button target is intentionally distinct from the
/// primary spotlight target ([_PulseConfig]) — for example, step 2's
/// spotlight is on the Daily Drop feed, but the cursor lands on the
/// "Descobre a cidade" pill because THAT is the user's next tap.
class _TourCursor extends ConsumerStatefulWidget {
  const _TourCursor();

  @override
  ConsumerState<_TourCursor> createState() => _TourCursorState();
}

class _TourCursorState extends ConsumerState<_TourCursor>
    with TickerProviderStateMixin {
  /// Drives the move toward the current cursor target. Restarts on
  /// every [tourCursorTargetProvider] change.
  late final AnimationController _moveController;

  /// Drives the click pulse (scale dip 1.0 → 0.7 → 1.0). Started a
  /// fixed [kTourCursorMoveDuration] after the move begins (so it
  /// fires at the moment the cursor reaches the target).
  late final AnimationController _clickController;
  late final Animation<double> _clickScale;

  /// Per-frame rebuild driver so `_readTargetCenter` always sees the
  /// live `RenderBox` position — the target can shift if the user
  /// scrolls or the keyboard insets the layout mid-transition.
  late final AnimationController _ambientTicker;

  /// Tracks the in-flight click-pulse timer so [dispose] can cancel it.
  Timer? _pulseTimer;

  CursorTarget? _runningTarget;

  /// Start point for the current move animation. Set at the moment
  /// the cursor target changes — viewport centre for a fresh
  /// transition, or the previous target's centre for a chained move
  /// (so the cursor "continues" from where it landed rather than
  /// teleporting back to centre between waypoints).
  Offset? _moveStart;

  /// Last destination the cursor reached, in global coords. Used as
  /// the [_moveStart] for the next chained waypoint.
  Offset? _lastEndCenter;

  /// Tracks whether [_moveController.forward] has been called for the
  /// current target. We defer the start until the target's RenderBox
  /// is actually mounted — otherwise a late layout would leave the
  /// cursor stuck at viewport centre for the entire move duration.
  bool _animationStarted = false;

  @override
  void initState() {
    super.initState();
    _moveController = AnimationController(
      vsync: this,
      duration: kTourCursorMoveDuration,
    );
    _clickController = AnimationController(
      vsync: this,
      duration: kTourCursorClickDuration,
    );
    _clickScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.7,
        ).chain(CurveTween(curve: Curves.easeInQuad)),
        weight: 45,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.7,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 55,
      ),
    ]).animate(_clickController);
    _ambientTicker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _moveController.dispose();
    _clickController.dispose();
    _ambientTicker.dispose();
    super.dispose();
  }

  /// Centre (in global coords) of the target's RenderBox. Null until
  /// the target widget has been laid out.
  Offset? _readTargetCenter(CursorTarget target, ProductTourKeys keys) {
    final key = _keyForTarget(target, keys);
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return null;
    final position = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    return Offset(position.dx + size.width / 2, position.dy + size.height / 2);
  }

  @override
  Widget build(BuildContext context) {
    final cursorTarget = ref.watch(tourCursorTargetProvider);
    final keys = ref.watch(productTourKeysProvider);

    if (cursorTarget == null) {
      if (_runningTarget != null) {
        _runningTarget = null;
        _moveStart = null;
        _lastEndCenter = null;
        _animationStarted = false;
        _pulseTimer?.cancel();
        _moveController.stop();
        _clickController.stop();
      }
      return const SizedBox.shrink();
    }

    // Target changed → snapshot the start point. Animation start is
    // DEFERRED to the AnimatedBuilder below so we don't kick off the
    // move controller until the target's `RenderBox` is actually
    // mounted — otherwise a bottom-nav remount that finishes a frame
    // after the controller fires would consume the entire 850 ms
    // move duration with `end == null`, leaving the cursor visually
    // stuck at viewport centre.
    if (_runningTarget != cursorTarget) {
      final wasIdle = _runningTarget == null;
      _runningTarget = cursorTarget;
      final screen = MediaQuery.of(context).size;
      final viewportCentre = Offset(screen.width / 2, screen.height / 2);
      _moveStart = wasIdle
          ? viewportCentre
          : (_lastEndCenter ?? viewportCentre);
      _animationStarted = false;
      _moveController.value = 0;
      _clickController.value = 0;
      _pulseTimer?.cancel();
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        _moveController,
        _clickController,
        _ambientTicker,
      ]),
      builder: (_, __) {
        final rawEnd = _readTargetCenter(cursorTarget, keys);
        // Fallback destination: if the target's RenderBox can't be
        // read (key not attached on this frame — happens during route
        // transitions and on the first frame after a sheet closes),
        // animate to a sensible viewport-relative position derived
        // from the target's role. Without this the cursor would
        // freeze at viewport centre for the entire animation window
        // because [end] is null on every frame.
        final screen = MediaQuery.of(context).size;
        final end = rawEnd ?? _fallbackTargetCenter(cursorTarget, screen);

        // Kick off the move controller and click-pulse timer the
        // first frame we have a destination (fallback ensures we
        // always do). The click pulse is deferred to AFTER the hover
        // dwell that [_runCursorClick] adds, so the visual click
        // lands at the same moment the side-effect (search overlay /
        // create sheet / etc.) actually fires — not 1.1 s before,
        // which made the cursor look "stuck" between arrival and
        // open. Per user spec (2026-05-30).
        if (!_animationStarted) {
          _animationStarted = true;
          _moveController.forward(from: 0);
          _pulseTimer = Timer(
            kTourCursorMoveDuration + kTourCursorHoverDuration,
            () {
              if (!mounted) return;
              _clickController.forward(from: 0);
            },
          );
        }

        final start = _moveStart ?? end;
        _lastEndCenter = end;

        final t = Curves.easeInOutCubic.transform(_moveController.value);
        final center = Offset.lerp(start, end, t)!;

        // Anchor by the fingertip (see [_CursorPointer.tip]) so the
        // hand's index-finger tip — not the asset centre — lands on
        // each target. Scale anchored at the same point so the
        // click pulse "pulses around the fingertip".
        return Positioned(
          left: center.dx - _CursorPointer.tip.dx,
          top: center.dy - _CursorPointer.tip.dy,
          width: _CursorPointer.size.width,
          height: _CursorPointer.size.height,
          child: IgnorePointer(
            child: Transform.scale(
              scale: _clickScale.value,
              alignment: Alignment.topLeft.add(
                Alignment(
                  (_CursorPointer.tip.dx / _CursorPointer.size.width) * 2,
                  (_CursorPointer.tip.dy / _CursorPointer.size.height) * 2,
                ),
              ),
              child: const _CursorPointer(),
            ),
          ),
        );
      },
    );
  }

  /// Viewport-relative fallback for the cursor's destination. Used
  /// when the GlobalKey's RenderBox can't be read (mid-route-change,
  /// post-sheet-close before the next layout, etc.). The numbers map
  /// the bottom-nav slots' typical positions on a discovery shell.
  Offset _fallbackTargetCenter(CursorTarget target, Size screen) {
    // On viewports ≥ [PageLayout.desktopBreakpoint], both the bottom
    // nav (capped at 600 px, see `discovery_bottom_nav.dart`) and the
    // page body (capped at [PageLayout.desktopContentMaxWidth] = 480
    // px, see `PageContent`) render CENTRED inside fixed-width
    // columns. A naive `screen.width / 5` slot-centre on a 1400-px
    // browser puts the cursor 160-380 px AWAY from the actual nav
    // buttons — visibly "outside the app". So we compute fallback
    // positions inside the effective column the target's parent
    // actually uses, then offset by half the side-margin so the
    // coordinate matches the centred render box.
    const navMaxWidth = 600.0;
    const bodyMaxWidth = PageLayout.desktopContentMaxWidth; // 480
    final isDesktop = screen.width >= PageLayout.desktopBreakpoint;

    final navWidth = isDesktop
        ? navMaxWidth.clamp(0.0, screen.width)
        : screen.width;
    final navLeft = (screen.width - navWidth) / 2;
    final bodyWidth = isDesktop
        ? bodyMaxWidth.clamp(0.0, screen.width)
        : screen.width;
    final bodyLeft = (screen.width - bodyWidth) / 2;

    final navY = screen.height - 48.0;
    final slotW = navWidth / 5;
    switch (target) {
      case CursorTarget.yoursNav:
        // Biblioteca — 2nd slot (index 1).
        return Offset(navLeft + slotW * 1 + slotW / 2, navY);
      case CursorTarget.profileMenu:
        // Home — 3rd slot (index 2). The last step's spotlight key
        // moved from the Menu nav button to the Home nav button so
        // the cursor click lands the user on `/` rather than `/menu`,
        // which connects naturally to the after-tour profiling
        // banner in production.
        return Offset(navLeft + slotW * 2 + slotW / 2, navY);
      case CursorTarget.createButton:
        // Criar (+) — 4th slot (index 3) in the bottom nav.
        return Offset(navLeft + slotW * 3 + slotW / 2, navY);
      case CursorTarget.discoverCityPill:
        // Search pill is just above the feed shelves, near the top
        // of the centred body column.
        return Offset(bodyLeft + bodyWidth * 0.4, screen.height * 0.3);
      case CursorTarget.searchOverlayClose:
        // X close in the search overlay's input row, top-right of
        // the centred body column.
        return Offset(bodyLeft + bodyWidth * 0.9, screen.height * 0.15);
      case CursorTarget.searchBar:
        // Chat bar sits high on the discovery screen, horizontally
        // centred inside the body column.
        return Offset(bodyLeft + bodyWidth / 2, screen.height * 0.2);
    }
  }

  GlobalKey _keyForTarget(CursorTarget target, ProductTourKeys keys) {
    switch (target) {
      case CursorTarget.searchBar:
        return keys.searchBar;
      case CursorTarget.discoverCityPill:
        return keys.discoverCity;
      case CursorTarget.searchOverlayClose:
        return keys.searchOverlayClose;
      case CursorTarget.createButton:
        return keys.createButton;
      case CursorTarget.yoursNav:
        return keys.yoursNav;
      case CursorTarget.profileMenu:
        return keys.profileMenu;
    }
  }
}

/// Soko's hand-drawn cursor glyph — a 46×52 hand pointing upward,
/// from Figma node 6777:16461 (see `assets/images/tour_hand.png`).
/// Replaces the previous Soko-Blue ring; matches the rest of the
/// tour's zine voice and lets the cursor read as a "Soko hand"
/// rather than an abstract pointer.
///
/// The fingertip sits near the top-centre of the asset, so callers
/// should anchor the cursor's reported "centre" against the [tip]
/// offset to make the fingertip — not the asset centre — land on
/// the target button.
class _CursorPointer extends StatelessWidget {
  const _CursorPointer();

  /// Asset's natural size (matches the Figma frame).
  static const Size size = Size(46, 52);

  /// Local offset from the asset's top-left to where the fingertip
  /// actually points — the cursor's logical "click point". The
  /// fingertip in the artwork sits roughly at (33%, 8%) of the
  /// asset's bounding box; tuning the value here adjusts where the
  /// cursor lands on every target.
  static const Offset tip = Offset(15.0, 4.0);

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/tour_hand.png',
      width: size.width,
      height: size.height,
      fit: BoxFit.contain,
    );
  }
}
