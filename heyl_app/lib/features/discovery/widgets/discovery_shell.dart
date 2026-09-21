import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/defer_provider_write.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/orientation_utils.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../providers/detail_seed_provider.dart';
import '../../../shared/notifications/notifications_provider.dart';
import '../../../shared/widgets/admin_location_debug_box.dart';
import '../../feedback/widgets/feedback_side_tab.dart';
import '../../feedback/widgets/shake_to_feedback.dart';
import '../../guest/providers/guest_session_popup_provider.dart';
import '../../guest/widgets/guest_banner.dart';
import '../../guest/widgets/guest_session_popup.dart';
import '../../lists/providers/lists_refresh.dart';
import '../../product_tour/providers/product_tour_controller.dart';
import '../../product_tour/providers/product_tour_keys_provider.dart';
import '../../product_tour/widgets/product_tour_host.dart';
import '../../sessions/widgets/chat_sidebar_drawer.dart';
import '../providers/discovery_feed_refresh.dart';
import '../providers/search_open_provider.dart';
import '../providers/search_query_provider.dart';
import 'discovery_bottom_nav.dart';
import 'pinned_page_chrome.dart';
import 'shell_sliver_page.dart';

/// Page name set on the Discovery [NoTransitionPage] (see
/// `app_router.dart`). The [discoveryNavObserver] uses this to decide
/// whether the navigator's topmost route is Discovery.
///
/// Used as a string sentinel rather than a route path because the shell's
/// inner navigator hosts imperative `context.push('/venues/<id>')` calls
/// that don't update the URL — `GoRouterState.matchedLocation` stays at
/// `/discovery` even after the push, so route-path comparison can't see
/// the transition. [Page.name] DOES change because each pushed Page sets
/// its own name (or leaves it null for non-Discovery routes).
const String discoveryPageName = 'discovery';

/// Page name set on the list-detail [NoTransitionPage] (PROD-1702). The
/// [discoveryNavObserver] tracks this to drive the bottom-nav "Zines"
/// highlight without falling for the `matchedLocation` imperative-push
/// invisibility (see
/// `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`).
const String listDetailPageName = 'list-detail';

/// Page name set on the canonical chat [NoTransitionPage]s (`/chat` and
/// `/chat/:sessionId` — entry points to [ChatScreen] under
/// [DiscoveryShell] for all viewers post-PROD-1736).
///
/// The chat owns its own scrollable message list + keyboard-aware input
/// and is rendered **full-bleed** inside the shell (the shared
/// [SingleChildScrollView] + [PinnedPageChrome.reservedHeight] padding
/// would either clip the message list or trigger an unbounded-height
/// exception). The shell branches on this name to skip both. See
/// `_DiscoveryShellState.build` and `_isFullBleedRouteName`.
const String chatPageName = 'chat';

/// PROD-2671: the dedicated Map page (`/map`). Rendered **full-bleed**
/// like chat (the map owns the whole surface, so it skips the shared
/// scrollable + chrome padding via [_isFullBleedRouteName]), but it is a
/// top-level destination so the bottom nav stays visible — intentionally
/// NOT listed in [_navHiddenOnRoute].
const String mapPageName = 'mapa';

/// PROD-4103: the Biblioteca page (`/library`). A top-level destination, so
/// intentionally NOT in [_navHiddenOnRoute] — and the product tour's step 4
/// anchors on a nav cell, so hiding it here would silently break that step
/// (PROD-4167). Pinned by `discovery_shell_library_nav_visible_test.dart`.
const String libraryPageName = 'library';

/// Page name set on the `/discovery/lists/new` [NoTransitionPage]
/// (PROD-2157). The shell branches on this name so the observer-first
/// full-bleed check can correctly classify the route as non-full-bleed
/// when chat imperatively pushes into it — `matchedLocation` stays at
/// `/chat` during imperative pushes (see
/// `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`),
/// which used to mis-classify the create-zine route as full-bleed and
/// skip wrapping the child in [ShellSliverScope], leaving
/// [CreateZineScreen]'s [ShellSliverHost] to render `SizedBox.shrink()`
/// (white screen).
const String discoveryListCreatePageName = 'discovery-list-create';

/// Page names set on the venue/event detail [NoTransitionPage]s
/// (PROD-1670 / PROD-1671 / PROD-1703). [PinnedPageChrome] reads these
/// (via [discoveryNavObserver]) to decide which chrome variant to
/// render — `matchedLocation` is unreliable for the same reason the
/// list-detail name is needed (imperative `context.push` doesn't update
/// it).
const String standaloneVenueDetailPageName = 'venue-detail';
const String standaloneEventDetailPageName = 'event-detail';

/// PROD-2908 — the Daily Drop detail screen (`/drop/detail/:id`). A distinct
/// name so `discoveryNavObserver.isOnDiscovery` reports `false` while it's on
/// top (lifts tour suppression on pop, hides the bottom nav).
///
/// PROD-3950 — it used to serve only entity-less picks and so could hardcode
/// the standalone-*venue* chrome variant. Every ready drop opens it now, so the
/// surface follows the drop: see [dailyDropChromeIsEvent].
const String dailyDropDetailPageName = 'daily-drop-detail';

/// PROD-4068 — a feed bundle's see-all page (`/feed/bundle/:blockId`).
///
/// **Deliberately NOT the `shelfSeeMore` model, which keeps the nav.** A
/// shelf's see-more is a *destination*: you went somewhere. A bundle's see-all
/// is a *spinoff* of the block you tapped — it should read as opened on top of
/// the feed, covering it, and dismiss back to the state you left (Zé,
/// 2026-08-31). The nav is what breaks that illusion, so this page hides it,
/// exactly as [dailyDropDetailPageName] does.
///
/// **This name alone is what hides the nav.** `_effectiveTopRoute` does not
/// recognise it as a *chrome* route — correctly, since the page draws its own
/// header and `PinnedPageChrome._resolveSpec` returns null for it — so the
/// lookup falls through to its final branch and returns the observer's name
/// unchanged, which [_navHiddenOnRoute] then matches.
///
/// **There is no cold-load case to cover here**, unlike every other entry in
/// that switch: the route redirects to the feed when it has no `extra`
/// (D80), so a reloaded or pasted `/feed/bundle/:id` never renders this page
/// at all. The [_navHiddenOnLocation] entry is therefore only for
/// `_onLeftEdgeSwipe`'s null-observer fallback, not for the nav.
///
/// Registering here also feeds `isDetailRoute` in `_onLeftEdgeSwipe`, so the
/// shell stops hijacking a back-swipe to pop home and lets the route's own
/// back gesture return to the feed.
const String feedBundleSeeAllPageName = 'feed-bundle-see-all';

/// Whether a `/drop/detail/:id` route is showing an **event** drop, read from
/// the `Page.arguments` its route stashes (the drop's `item_type`).
///
/// PROD-3950 — the drop page's surface colour is decided in **two** places that
/// must agree: [PinnedPageChrome]'s `_resolveSpec` (the chrome behind the back
/// arrow) and [_pageBgForRoute] (the Scaffold beneath the body). Both are keyed
/// on the route *name*, which alone can't tell a place drop from an event one —
/// so both call this. Getting only one of them right is the exact bug this
/// replaces: an event drop under venue-blue chrome.
///
/// Reads `Page.arguments` rather than `matchedLocation` because the page is
/// always reached by imperative `context.push`, which leaves the URL stale
/// (`docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`).
/// Anything that isn't the event marker — including a null from the cold-load
/// URL fallback — resolves to venue, matching [SokoEntityKind.fromTypeString]'s
/// own default and the page body's.
bool dailyDropChromeIsEvent(Object? arguments) => arguments == 'event';
const String inListVenueDetailPageName = 'list-venue-detail';
const String inListEventDetailPageName = 'list-event-detail';

/// Page name set on the `/chat-map` route — the seeded chat map (the same
/// `MapScreen` as `/map`, fed a fixed list from chat). It's a full-screen
/// child route of [DiscoveryShell] so detail-sheet pushes from inside it stack
/// on the same shell navigator, and the shell hides its bottom nav while this
/// page is active (a full-screen map, not a tab).
const String chatPlacesMapPageName = 'chat-places-map';

/// Page name set on the `/menu` [CupertinoPage]/[NoTransitionPage]
/// (PROD-2019). `/menu` replaces the legacy right-side `ProfileDrawer`
/// for the Profile root. The bottom nav stays visible while on `/menu`,
/// so it is intentionally NOT included in [_navHiddenOnRoute].
const String menuPageName = 'menu';

/// Page name set on the pushed social-profile pages `/u/:handle` and its
/// vanity alias `/@:handle` (PROD-2775 / PROD-2823). Required so the shell's
/// nav observer identifies the pushed profile page instead of retaining the
/// previous page's identity — without it (the routes used a bare `builder:`),
/// a profile pushed over an event detail kept the event's green
/// `PinnedPageChrome` and `sokoEvent` bg. Not a "chrome route" and has no
/// entry in `_pageBgForRoute`/`_resolveSpec`, so it correctly resolves to
/// no chrome + `sokoPaper`; the profile renders its own `SokoBackButton`.
const String publicProfilePageName = 'public-profile';

/// Page name set on the `/menu/account` [CupertinoPage]/[NoTransitionPage]
/// (PROD-2020).
const String menuAccountPageName = 'menu-account';

/// Page name set on the `/menu/account/merge`
/// [CupertinoPage]/[NoTransitionPage] (PROD-2023).
const String menuAccountMergePageName = 'menu-account-merge';

/// Page name set on the `/menu/account/blocked-users` page (PROD-2264).
const String menuAccountBlockedUsersPageName = 'menu-account-blocked-users';

/// Page name set on the `/menu/business-connections`
/// [CupertinoPage]/[NoTransitionPage] (PROD-2022).
const String menuBusinessConnectionsPageName = 'menu-business-connections';

/// Page name set on the `/business` Business Home dashboard page (PROD-4040).
const String businessHomePageName = 'business-home';

/// Page name set on the `/menu/preferences` [CupertinoPage]/[NoTransitionPage]
/// (PROD-2021).
const String menuPreferencesPageName = 'menu-preferences';

/// Page name set on the `/menu/preferences/language`
/// [CupertinoPage]/[NoTransitionPage] detail page (PROD-2073).
const String menuPreferencesLanguagePageName = 'menu-preferences-language';

/// Page name set on the `/menu/preferences/whatsapp`
/// [CupertinoPage]/[NoTransitionPage] detail page.
const String menuPreferencesWhatsappPageName = 'menu-preferences-whatsapp';

/// Page name set on the `/menu/support` [CupertinoPage]/[NoTransitionPage]
/// (PROD-2024).
const String menuSupportPageName = 'menu-support';

/// Page name set on the `/menu/about` [CupertinoPage]/[NoTransitionPage]
/// (PROD-2025).
const String menuAboutPageName = 'menu-about';

/// Page name set on the `/menu/notifications` [CupertinoPage]/[NoTransitionPage]
/// (PROD-2524 T-E — inbox screen).
const String menuNotificationsPageName = 'menu-notifications';

/// Page name set on the `/menu/memory` [CupertinoPage]/[NoTransitionPage].
const String menuMemoryPageName = 'menu-memory';

/// Page name set on the `/memory` [CupertinoPage]/[NoTransitionPage] — the
/// Memory page every header brain button opens (PROD-4164).
const String memoryPageName = 'memory';

/// Page name set on the `/menu/ai-data` [CupertinoPage]/[NoTransitionPage]
/// (PROD-2265 Phase 2 — AI consent review/revoke).
const String menuAiDataPageName = 'menu-ai-data';

/// Page name set on the `/user-profiling/lists` route. The route lives
/// INSIDE the discovery shell so the terminus smart-list grid can
/// `context.push('/lists/<id>')` onto the same nested navigator —
/// back from the list returns to the grid. The bottom nav stays
/// hidden (the screen has its own footer CTA).
const String userProfilingListsPageName = 'user-profiling-lists';

/// Top-level [NavigatorObserver] that tracks whether the Discovery page
/// (`name: '$discoveryPageName'`) is the topmost route in the
/// [DiscoveryShell]'s nested Navigator. Notifies listeners when that
/// changes (push of any other route OR pop back to Discovery).
///
/// Registered on the discovery [ShellRoute] via `observers:` in
/// `app_router.dart`. Listened to by [_DiscoveryShellState] to rebuild
/// the chrome (and by [DiscoveryBottomNav] to drive nav-pill highlight
/// logic). The matched-location signal can't be used here because
/// go_router's `context.push` does an imperative navigation that adds a
/// route on top of the navigator stack without changing the declared
/// route or URL.
///
/// Scroll position is preserved per-page natively (each page owns its own
/// `ScrollController` via `ShellSliverHost`), so there is no scroll observer
/// on this `ShellRoute` anymore — see `docs/infrastructure/scroll-position-memory.md`.
class _DiscoveryNavObserver extends NavigatorObserver with ChangeNotifier {
  // Optimistic — toggles on first push if wrong. The shell's first
  // mounted route is almost always `/discovery`; the rare cold-load
  // exception (a deep link straight to `/lists/<id>` etc.) corrects on
  // the first didPush callback.
  String? _topRouteName = discoveryPageName;
  Object? _topRouteArguments;

  // Mirror of the navigator's route stack. Mutated in didPush /
  // didPop / didReplace / didRemove. Used by [_refreshTopPage] to
  // find the topmost route whose `settings is Page`, ignoring any
  // overlay routes (PopupMenuRoute, DialogRoute, ModalBottomSheetRoute)
  // that may be on top. Tracking the stack here is the only way the
  // observer can answer "what page is underneath?" — Flutter's public
  // NavigatorObserver / NavigatorState APIs don't expose history.
  final List<Route<dynamic>> _stack = [];

  /// Name of the topmost **Page** route mounted under the Discovery
  /// shell, or `null` if there is no Page on the stack. Set by each
  /// route's `pageBuilder` via `NoTransitionPage(name: ...)`. Overlay
  /// routes on top of a Page (modals, dialogs, popups) are ignored —
  /// this lets the shell's chrome stay anchored to the underlying page
  /// while overlays are mounted.
  String? get topRouteName => _topRouteName;

  /// `arguments` passed to the topmost route's [NoTransitionPage] (or
  /// `null` if none). Used by [PinnedPageChrome] to extract the
  /// `listId` of in-list pages so the chrome can read the list name
  /// from `unifiedListProvider(listId)`. Reading the listId from
  /// `pathParameters` would require `GoRouterState.matchedLocation`,
  /// which is unreliable after imperative `context.push` (see
  /// `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`).
  Object? get topRouteArguments => _topRouteArguments;

  /// True iff the topmost mounted route is the Discovery page itself.
  bool get isOnDiscovery => _topRouteName == discoveryPageName;

  /// True iff the topmost mounted route is the list-detail page
  /// (PROD-1702 — drives the "Zines" bottom-nav highlight).
  bool get isOnListDetail => _topRouteName == listDetailPageName;

  /// Walk [_stack] top-down to find the topmost Page route. Apply its
  /// `(name, arguments)` to the observed top-route fields if changed,
  /// and notify listeners post-frame.
  ///
  /// Why "topmost Page" and not "topmost route": overlay routes
  /// (PopupMenuRoute, DialogRoute, ModalBottomSheetRoute) push onto
  /// the navigator but represent transient UI on *top of* a page. The
  /// shell's chrome (page-bg colour, bottom-nav visibility, pinned
  /// header) should stay anchored to the underlying page while an
  /// overlay is up. Tracking the topmost Page handles both directions:
  /// pushing a Page above an overlay (`MyRemindersSheet` → `/events/x`)
  /// updates correctly, and popping a Page above a still-mounted
  /// overlay reverts to the underlying page rather than leaving the
  /// chrome stale on the popped page. Without this, popping
  /// `/events/<id>` back to a still-open modal would leave the shell
  /// painted in the event-detail page-bg (sokoEvent green) until the
  /// modal itself closed.
  void _refreshTopPage() {
    Route<dynamic>? topPage;
    for (final r in _stack.reversed) {
      if (r.settings is Page) {
        topPage = r;
        break;
      }
    }
    final settings = topPage?.settings as Page?;
    final name = settings?.name;
    final arguments = settings?.arguments;
    if (name != _topRouteName || arguments != _topRouteArguments) {
      _topRouteName = name;
      _topRouteArguments = arguments;
      // Defer notifyListeners to post-frame: didPush fires synchronously
      // during Navigator.didUpdateWidget (parent build phase), so any
      // listener that calls setState/markNeedsBuild from inside its
      // notification handler (e.g., AnimatedBuilder) throws
      // "setState() called during build". Post-frame defers all listener
      // notifications to after the current frame, eliminating that class
      // of error for every listener at once. PROD-1738 diagnostic.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        notifyListeners();
      });
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _stack.add(route);
    _refreshTopPage();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _stack.remove(route);
    _refreshTopPage();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute != null) _stack.remove(oldRoute);
    if (newRoute != null) _stack.add(newRoute);
    _refreshTopPage();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _stack.remove(route);
    _refreshTopPage();
  }
}

/// Singleton observer instance. Constructed lazily; safe to register on
/// the ShellRoute's `observers` list and to listen to from the shell.
final discoveryNavObserver = _DiscoveryNavObserver();

/// Shell that wraps every Discovery / chat / lists / memories /
/// detail route post-PROD-1736 (the global app-shell cutover).
///
/// History: forked from `MainShell` during the redesign so the new shell
/// could iterate without disturbing the live app. PROD-1736 retired
/// `MainShell` and made this shell the only shell.
///
/// Responsibilities:
/// - Render the [DiscoveryBottomNav] at the bottom.
/// - Mount the [ChatSidebarDrawer] (used by the chat bar's history button —
///   PROD-1517). The drawer watches `sidebarOpenProvider`.
/// - Show the offline banner when the device is offline.
/// - Constrain content to a max width on desktop (interim — desktop designs
///   for Discovery don't exist yet).
///
/// The shell no longer owns a scroll controller: each routed page owns its own
/// via `ShellSliverHost`, which preserves scroll position per-page natively
/// (see `docs/infrastructure/scroll-position-memory.md`).
class DiscoveryShell extends ConsumerStatefulWidget {
  final Widget child;

  const DiscoveryShell({super.key, required this.child});

  @override
  ConsumerState<DiscoveryShell> createState() => _DiscoveryShellState();
}

class _DiscoveryShellState extends ConsumerState<DiscoveryShell> {
  /// Identifies the shell's Scaffold so the product-tour controller can
  /// open the Create sheet from a context that lives ABOVE the Scaffold
  /// (the ShowCaseWidget overlay). Stashed in
  /// [tourDiscoveryScaffoldKeyProvider] in [initState].
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>(
    debugLabel: 'discoveryShellScaffold',
  );

  /// Per-mount [ProductTourKeys] instance. Created in the State's
  /// field-initializer (so every fresh `_DiscoveryShellState` gets fresh
  /// `GlobalKey` instances) and injected into the subtree via a
  /// `ProviderScope` override on [productTourKeysProvider] in [build].
  ///
  /// **Not load-bearing for any known on-device crash.** The post-
  /// profiling `Explorar o app` → `/` assertion (PROD-2438) was
  /// originally misdiagnosed as a `ProductTourKeys` collision and
  /// triggered several rounds of fixes targeting this provider. The
  /// actual culprit was go_router's inner `_CustomNavigator`
  /// `GlobalObjectKey(navigatorKey.hashCode)` reparenting across shell
  /// unmount/remount — fixed structurally by switching profiling-
  /// internal `context.go` to `context.pushReplacement` so the shell
  /// never unmounts in the first place. See
  /// `docs/learnings/go-router-shell-navigator-globalobjectkey-collision.md`.
  ///
  /// The override is still useful: it gives widget tests deterministic
  /// `GlobalKey` lifetime per mount (no Riverpod autoDispose timing
  /// dependency) and isolates test runs from each other when multiple
  /// `DiscoveryShell` instances pump in sequence.
  final ProductTourKeys _tourKeys = ProductTourKeys();

  // Edge-swipe gesture config. Mobile only; desktop skips the gesture
  // entirely.
  //
  // Tuning rationale: the edge-zone needs to be wider than iOS's
  // reserved system-gesture strip (~16 px) — empirically logged touches
  // started a swipe land at dx≈28–36 even when the user thinks they're
  // swiping from the bezel. 40 px catches those without false-firing on
  // horizontal scrolling cards (which start their hits well inside the
  // body). The 100 px distance OR 300 px/s velocity threshold mirrors
  // iOS-style "back swipe" ergonomics — either a slow deliberate drag
  // past 100 px or a quick flick from the edge triggers the action.
  static const double _desktopBreakpoint = 1024;
  static const double _edgeZone = 40;
  static const double _minDragDistance = 100;
  static const double _minVelocity = 300;

  // Left-edge drag tracking — opens [ChatSidebarDrawer] via
  // [sidebarOpenProvider].
  bool _isDraggingFromLeftEdge = false;
  double _leftDragDistance = 0;

  // Captured in initState so dispose can reset the inset without touching
  // `ref` (illegal post-dispose — throws "Cannot use ref after the widget was
  // disposed", which aborts the unmount and cascades into framework
  // assertions). Global (non-autoDispose) StateProvider → the notifier
  // outlives the widget. See PROD-2530.
  late final StateController<double> _notificationBottomInsetController;

  /// How many [DiscoveryShell]s are mounted right now.
  ///
  /// Exists only to order the dispose-time reset against a replacement shell:
  /// the incoming shell increments in `initState` (during `buildScope`) before
  /// the outgoing one decrements in `dispose` (during `finalizeTree`), so a
  /// non-zero count at post-frame time means someone else owns the inset and
  /// this reset must not fire. Static because the provider it guards is
  /// global — one value, however many shells.
  static int _liveShells = 0;

  // PROD-2627: 5 s warm-up before the guest popup opens, so a guest gets to
  // see the discovery feed first instead of being slapped by the modal on
  // arrival. Timer is held in state so [dispose] can cancel it — without
  // cancellation, an unmount inside the window (logout, off-shell nav) would
  // leave a pending fire that calls `showDialog` against a dead context.
  static const Duration _guestPopupDelay = Duration(seconds: 5);
  Timer? _guestPopupTimer;

  @override
  void initState() {
    super.initState();
    // Incremented here, decremented in dispose — see [_liveShells]. This runs
    // during `buildScope`, i.e. BEFORE an outgoing shell's `dispose` runs in
    // `finalizeTree`, which is exactly what makes the count a valid guard.
    _liveShells++;
    discoveryNavObserver.addListener(_onNavChange);
    _notificationBottomInsetController = ref.read(
      notificationBottomInsetProvider.notifier,
    );
    // Stash the shell's Scaffold key into the product-tour provider.
    // Lets [RealTourSideEffects.openCreateSheet] drive the sheet
    // from a context that lives ABOVE the Scaffold (the
    // ShowCaseWidget overlay's). Without it the
    // discoverCity → createSheet transition silently throws "No
    // Scaffold ancestor".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(tourDiscoveryScaffoldKeyProvider.notifier).state = _scaffoldKey;
    });
  }

  @override
  void dispose() {
    discoveryNavObserver.removeListener(_onNavChange);
    _guestPopupTimer?.cancel();
    // PROD-1885: reset the bottom-anchored toast's clearance — the
    // [DiscoveryBottomNav] is unmounting (cross-shell nav to auth /
    // onboarding), so the toast should fall back to the viewport's own
    // safe-area inset until the next shell mounts. Uses the captured notifier
    // (NOT `ref`) — see field doc + PROD-2530.
    //
    // Deferred out of the build phase — see [deferProviderWrite]. Capturing the
    // notifier fixed *reachability* (PROD-2530); it did nothing about *phase*,
    // and the synchronous write here red-screened app launch.
    //
    // Guarded on [_liveShells] because deferring inverts an ordering. `build`
    // schedules its own post-frame write of the real clearance, and
    // `buildScope` runs before `finalizeTree` — so on a shell REPLACEMENT the
    // incoming shell's callback is registered first and this one would run
    // after it, resetting to 0 the clearance that shell just set. The count
    // says what we actually mean: reset only when no shell owns the value.
    _liveShells--;
    final controller = _notificationBottomInsetController;
    deferProviderWrite(() {
      if (_liveShells == 0) controller.state = 0.0;
    });
    super.dispose();
  }

  /// Fired by [discoveryNavObserver] when the topmost mounted route in
  /// the shell's Navigator changes. Rebuilds the shell so
  /// [PinnedPageChrome] and the SCV's `chromeReserved` top padding pick
  /// up the new top route — the chrome reads the route name + arguments
  /// straight from [discoveryNavObserver], not from
  /// `GoRouterState.matchedLocation` (which doesn't update on imperative
  /// `context.push`).
  ///
  /// **The rebuild is deferred to a post-frame callback** because the
  /// observer's `notifyListeners` fires synchronously from
  /// `NavigatorObserver.didPush` — which can happen mid-build of the
  /// new route. Calling `setState` synchronously there throws
  /// "setState() called during build" and the rebuild never happens,
  /// leaving the chrome (and `chromeReserved`) stuck on the previous
  /// route's value.
  ///
  /// Scroll save/restore used to live here too (Discovery-specific via
  /// `discoveryScrollOffsetProvider`, later a shell-wide observer); scroll
  /// position is now preserved per-page natively by each page's own
  /// `ScrollController` (see `ShellSliverHost`), so there's nothing scroll-
  /// related to do here anymore.
  void _onNavChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  // Edge-swipe gesture handlers. The release action varies by route:
  //
  // - LEFT edge on a detail page: handled by `CupertinoPage`'s built-in
  //   interactive back-gesture detector (`_CupertinoBackGestureDetector`),
  //   not by this shell drag. Cupertino sits inside the route, deeper in
  //   the hit list, so it wins the gesture arena for detail pages. Our
  //   shell drag still receives the gesture as a fallback, but
  //   `_onLeftEdgeSwipe` short-circuits on detail routes to avoid a
  //   double pop.
  // - LEFT edge on `/chat` or `/chat/<id>`: open the chat-history sidebar
  //   (`sidebarOpenProvider`). From there the user can resume a past
  //   conversation or start a new chat. PROD-2531 inverted the chat vs
  //   non-chat behavior (superseding PROD-1804's chat-as-Discovery-subpage
  //   model): on the chat surface the swipe surfaces history rather than
  //   retreating.
  // - LEFT edge anywhere else (Discovery, lists hub, memories, any
  //   future DiscoveryShell route): back-pop via [popOrFallback] (falls
  //   back to `/` when there's nothing to pop, e.g. cold-load), retreating
  //   toward the home/Discovery surface. PROD-2531.
  //
  // PROD-2019 removed the right-edge swipe (previously opened the
  // legacy profile drawer) — Menu is now reached via the bottom-nav
  // Menu button pushing `/menu`.
  void _onHorizontalDragStart(DragStartDetails details) {
    _isDraggingFromLeftEdge = details.localPosition.dx < _edgeZone;
    _leftDragDistance = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_isDraggingFromLeftEdge) {
      _leftDragDistance += details.delta.dx;
    }
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_isDraggingFromLeftEdge) {
      final velocity = details.velocity.pixelsPerSecond.dx;
      if (_leftDragDistance > _minDragDistance || velocity > _minVelocity) {
        _onLeftEdgeSwipe();
      }
    }

    _isDraggingFromLeftEdge = false;
    _leftDragDistance = 0;
  }

  /// Resolves a left-edge swipe to either a chat-history sidebar open (on
  /// chat routes) or a back-pop toward home (everywhere else; detail pages
  /// short-circuit earlier). The route classification uses
  /// [discoveryNavObserver] for in-shell push transitions and falls back to
  /// [GoRouterState.matchedLocation] for cold-load — same source strategy as
  /// [_isFullBleedRouteName] / [_isFullBleedLocation]. PROD-2531 inverted the
  /// chat vs non-chat mapping (was: chat pops, others open the sidebar).
  ///
  /// Back-pop delegates to the shared [popOrFallback] helper so this
  /// gesture and [PinnedPageChrome]'s back-button apply the same
  /// cold-load fallback policy (in-list detail → parent list page;
  /// everything else → `/`). PROD-1736 retro fold-in from PROD-1734.
  void _onLeftEdgeSwipe() {
    final observerRouteName = discoveryNavObserver.topRouteName;
    final routeLocation = GoRouterState.of(context).matchedLocation;
    final isDetailRoute = observerRouteName != null
        ? _navHiddenOnRoute(observerRouteName)
        : _navHiddenOnLocation(routeLocation);

    // On iOS, `CupertinoPage`'s interactive back gesture wins the arena
    // for detail routes (it sits inside the route, deeper in the hit
    // list). On Android we deliberately don't pop in-app from a left
    // swipe (PROD-1804 — Android uses the system back button instead).
    // Either way this shell drag should not double-trigger a pop, so
    // bail.
    if (isDetailRoute) return;

    // Chat routes open the chat-history sidebar; everywhere else pops home.
    final isChatRoute =
        observerRouteName == chatPageName ||
        (observerRouteName == null &&
            (routeLocation == AppRoutes.chat ||
                RegExp(r'^/chat/[^/]+$').hasMatch(routeLocation)));
    if (isChatRoute) {
      ref.read(sidebarOpenProvider.notifier).state = true;
      return;
    }

    popOrFallback(context);
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(isOnlineProvider);
    final isSidebarOpen = ref.watch(sidebarOpenProvider);
    final isManuallyVisible = ref.watch(bottomNavVisibleProvider);
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // PROD-2072: guest banner shows on every platform so guests always
    // have a visible [Log in] CTA (Apple 5.1.1(v)). The once-per-session
    // popup stays web-only — its copy + CTA are about installing the
    // native app, which is meaningless when the user is already in it.
    // Watching `authStateProvider.select` rebuilds the shell when the
    // user logs in/out so the banner appears/vanishes without a route
    // change.
    final isGuest = ref.watch(authStateProvider.select((s) => s.isGuest));
    final showGuestChrome = isGuest;

    // Pop the popup ONCE per session, on the first frame where guest
    // chrome would render. Post-frame so we don't trigger a navigator
    // mutation during build. The provider flag is flipped synchronously
    // before scheduling so a same-frame (or pre-fire) rebuild can't
    // re-enter and queue a second timer.
    //
    // PROD-2627: 5 s warm-up via [_guestPopupDelay] so the guest sees the
    // feed first. Path is captured at schedule time (not at fire time) —
    // by the time the timer fires the user may have navigated to a child
    // route, and the popup CTA should still deep-link back to the path
    // where the warm-up started.
    if (showGuestChrome && kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(guestSessionPopupShownProvider)) return;
        ref.read(guestSessionPopupShownProvider.notifier).state = true;
        final currentPath = GoRouterState.of(context).matchedLocation;
        _guestPopupTimer = Timer(_guestPopupDelay, () {
          if (!mounted) return;
          // Guard: if the user logged in during the warm-up window, drop
          // the popup — its CTA opens the native app, which is pointless
          // for a now-authenticated session.
          if (!ref.read(authStateProvider).isGuest) return;
          showDialog<void>(
            context: context,
            barrierDismissible: true,
            builder: (_) => Dialog(
              backgroundColor: Colors.transparent,
              elevation: 0,
              insetPadding: const EdgeInsets.all(24),
              child: GuestSessionPopup(currentPath: currentPath),
            ),
          );
        });
      });
    }

    // Bottom-nav visibility — composite of 5 signals. ANDed here at the
    // shell so the [DiscoveryBottomNav] widget itself doesn't need to
    // know about route names, drawers, or keyboard.
    //
    // - [bottomNavVisibleProvider] — manual toggle for sheets
    //   (`bottom_sheet_utils.dart`) to suppress the nav while a sheet is open.
    // - Route predicate via [discoveryNavObserver.topRouteName] (NOT
    //   `matchedLocation`; see
    //   `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`).
    //   Hides on detail pages where [PinnedPageChrome] is taking over.
    // - `viewInsets.bottom > 0` — soft-keyboard rise. Centralised here so
    //   future text-input screens under DiscoveryShell hide the nav for
    //   free without needing to wire `bottomNavVisibleProvider`.
    // - `!isSidebarOpen` — the chat-history drawer used to cover the
    //   nav when it was inside the body Stack. Now that the nav lives
    //   in `Scaffold.bottomNavigationBar` (a region OUTSIDE Scaffold.body),
    //   the drawer's `Positioned.fill` no longer reaches the nav slot —
    //   so we hide it explicitly while the drawer is open.
    // PROD-2258: resolve the effective top route (observer-first, with a
    // matchedLocation fallback). The observer is authoritative for imperative
    // `context.push` (which leaves matchedLocation stale), but it fails to
    // name a chrome route in two native cases: the optimistic `discovery`
    // default before its first didPush (cold-load), and a nameless transient
    // route that lands on top during warm same-shell deep-link nav. In both,
    // matchedLocation correctly points at the detail route, so fall back to
    // the URL whenever the observer doesn't name a chrome route. See
    // `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`.
    final routeLocation = GoRouterState.of(context).matchedLocation;
    final effectiveTopRoute = _effectiveTopRoute(routeLocation);
    final effectiveRouteName = effectiveTopRoute.name;

    final navVisible =
        isManuallyVisible &&
        !_navHiddenOnRoute(effectiveRouteName) &&
        !keyboardOpen &&
        !isSidebarOpen;

    // PROD-1885: publish the nav's effective height (incl. iOS home-
    // indicator safe-area inset) so the bottom-anchored toast in
    // [NotificationHost] can slide in immediately ABOVE the nav rather
    // than overlapping it. Pushed post-frame because `ref.read(...)
    // .state = ...` during build would otherwise trip the
    // setState-during-build assertion. `_NavBar._barHeight` is private to
    // `discovery_bottom_nav.dart`; mirrored here as a constant to avoid
    // exporting it.
    final navClearance = navVisible
        ? 64.0 + MediaQuery.of(context).viewPadding.bottom
        : 0.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(notificationBottomInsetProvider.notifier);
      if (notifier.state != navClearance) {
        notifier.state = navClearance;
      }
    });

    // Shell-level chrome (PinnedPageChrome) reserves top space inside
    // the SingleChildScrollView so body widgets don't disappear under it.
    final chromeReserved = PinnedPageChrome.reservedHeight(
      routeName: effectiveRouteName,
      topInset: MediaQuery.of(context).padding.top,
    );

    // Per-page background colour (sokoVenue / sokoEvent / sokoPaper for
    // detail routes; null for shell-level routes that use the default
    // Scaffold bg).
    //
    // PROD-4160-followup — a standalone event/venue detail page paints the
    // entity's image-derived pastel instead of the fixed Soko/Green|Blue. The
    // detail screen publishes it to [standaloneDetailBgProvider]; the shell and
    // [PinnedPageChrome] both read it here so the full-bleed Scaffold bg and
    // the chrome strip stay in lock-step (same "one resolver, two paint sites"
    // shape as the daily-drop colour). Null — e.g. a cold deep-link's first
    // loading frame, before the entity image is known — falls back to the
    // route constant.
    final isStandaloneDetail =
        effectiveRouteName == standaloneEventDetailPageName ||
        effectiveRouteName == standaloneVenueDetailPageName;
    final standaloneDetailBg = isStandaloneDetail
        ? ref.watch(standaloneDetailBgProvider)
        : null;
    final pageBgOverride =
        standaloneDetailBg ??
        _pageBgForRoute(effectiveRouteName, effectiveTopRoute.args);

    // Full-bleed mode: chat owns its own header + scrollable + input.
    // Detail pages stay non-full-bleed so the shell's outer SCV +
    // chromeReserved padding apply (the chrome stays at the shell level,
    // so during the iOS interactive pop the body slides under it).
    final goRouterState = GoRouterState.of(context);
    final observerRouteName = discoveryNavObserver.topRouteName;
    final observerOnPushedDetail =
        observerRouteName != null && _navHiddenOnRoute(observerRouteName);
    // Observer-first (with URL fallback for cold-load before the
    // observer has seen its first push). PROD-2157: a chat→
    // `/discovery/lists/new` imperative push leaves `matchedLocation`
    // pinned to `/chat`, so the URL-only check used to mis-classify
    // the create-zine route as full-bleed and skip wrapping the child
    // in [ShellSliverScope]. The observer reads `Page.name` from the
    // nav `didPush` callback and is always current — same fix shape
    // as `_navHiddenOnRoute` / `_navHiddenOnLocation` above.
    final isFullBleed = observerOnPushedDetail
        ? false
        : (observerRouteName != null
              ? _isFullBleedRouteName(observerRouteName)
              : _isFullBleedLocation(routeLocation));

    // PROD-1977: the shell never owns a `CustomScrollView` anymore.
    // Every non-full-bleed routed page builds its OWN scrollable via
    // [ShellSliverHost], which consumes chrome metadata + the shared
    // scroll controller from [ShellSliverScope] (set up below). The
    // tree shape under `widget.child` is now constant across route
    // transitions (always `ScrollConfiguration > ShellSliverScope >
    // widget.child`), which eliminates the structural-rebuild cascade
    // that triggered `framework.dart:2168` / `object.dart:2524`
    // assertions when the shell previously branched on `isSliverRoute`
    // and changed `widget.child`'s ancestor depth on every push/pop.
    // See `docs/learnings/discoveryshell-sliver-aware-host.md` § "Why
    // the always-sliver architecture".
    //
    // Pages that want desktop's 480-px max-width column wrap their
    // sliver content in `SliverToBoxAdapter(child: PageContent(child:
    // ...))` themselves — `PageContent` is no longer applied at the
    // shell level.
    Widget body;
    if (isFullBleed) {
      body = widget.child;
    } else {
      // Route-aware pull-to-refresh handler — null on non-feed routes.
      // `ShellSliverHost` reads this from the scope and prepends a
      // `CupertinoSliverRefreshControl` between the chrome spacer and
      // the page's slivers when non-null.
      final feedRefresh = _feedRefreshForRoute(goRouterState);
      // Bouncing parent on feed routes so the body visibly slides down
      // with the pull (the sliver refresh control needs overscroll to
      // expand). Non-feed routes keep clamping — no surprise bounce on
      // detail pages.
      final physics = feedRefresh != null
          ? const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics())
          : const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            );

      body = ScrollConfiguration(
        behavior: const _NoScrollbarScrollBehavior(),
        child: ShellSliverScope(
          chromeReserved: chromeReserved,
          physics: physics,
          onFeedRefresh: feedRefresh == null ? null : () => feedRefresh(ref),
          cacheExtent: 600,
          child: widget.child,
        ),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= _desktopBreakpoint;

    Widget content = Column(
      children: [
        if (!isOnline) const _OfflineBanner(),
        Expanded(child: body),
      ],
    );

    // Mobile-only edge-swipe gestures (route-aware release actions; see
    // `_onHorizontalDragEnd` / `_onLeftEdgeSwipe`). Wrap [content] — NOT
    // the inner [ScrollConfiguration] — so the gestures cover BOTH the
    // full-bleed branch (chat) and the scrollable branch (Discovery,
    // list, detail). Drawers live above this in the Scaffold body Stack
    // and their open-state scrims swallow pointer events first, so
    // re-triggering on an already-open drawer is a non-issue.
    // [HitTestBehavior.translucent] keeps taps inside the body (cards,
    // buttons, chat input) working.
    if (!isDesktop) {
      content = GestureDetector(
        onHorizontalDragStart: _onHorizontalDragStart,
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        // Tap-to-dismiss the soft keyboard is owned by `MaterialApp.builder`
        // (see app.dart). Adding a second `onTap: unfocus` here would stack
        // a redundant translucent GestureDetector in the ancestor chain of
        // every TextField under this shell — exactly the topology that
        // caused the PROD-1804 two-tap-to-focus bug. Keep the horizontal
        // drag handlers (edge swipes) here; let the global wrapper own
        // dismissal.
        behavior: HitTestBehavior.translucent,
        child: content,
      );
    }

    // PROD-2072: when guest chrome is active, the [GuestBanner] sits
    // ABOVE the existing Stack so [PinnedPageChrome]'s `Positioned(top:
    // 0, ...)` resolves to "just below the banner" rather than under it
    // — gives the chrome back arrow room to render. When guest chrome is
    // inactive, the body is the original Stack and layout is unchanged.
    final shellStack = Stack(
      children: [
        content,
        // Pinned chrome (back arrow + optional list-name title) sits
        // above the scrollable but below the modal drawers. Stays at
        // the shell level: making it per-page (so it slides with the
        // Cupertino interactive pop) caused native UiKitView layout
        // assertions in the body's Mapbox maps. Revisit when a clean
        // per-page approach is found.
        PinnedPageChrome(
          routeName: effectiveRouteName,
          arguments: effectiveTopRoute.args,
          backgroundOverride: standaloneDetailBg,
        ),
        // PROD-1952: tap-anywhere-outside dismiss for the Create
        // menu's persistent bottom sheet. Sits ABOVE the chrome so
        // that even chrome-area taps close the sheet (Option B from
        // the PROD-1952 discussion). Inert (IgnorePointer) when the
        // sheet is closed, so it doesn't interfere with normal
        // page interactions. The drawers below mount AFTER this,
        // so when both are open the drawers take precedence.
        const _CreateMenuDismissOverlay(),
        // Past-conversations drawer used by DiscoveryChatBar's history
        // button (PROD-1517). Toggled via `sidebarOpenProvider`.
        const ChatSidebarDrawer(),
      ],
    );

    final scaffoldBody = showGuestChrome
        ? Column(
            children: [
              GuestBanner(
                currentPath: GoRouterState.of(context).matchedLocation,
              ),
              Expanded(child: shellStack),
            ],
          )
        : shellStack;

    final scaffold = Scaffold(
      key: _scaffoldKey,
      // Light mode: Soko/Paper (#F9F0F0) per design-system token (Figma
      // node `6353:26730`). The legacy `AppColors.background` (#F5F1EC,
      // Lovable cream) is kept on auth/onboarding screens that haven't
      // been re-skinned to the Soko system yet.
      backgroundColor:
          pageBgOverride ??
          (isDark ? AppColors.backgroundDark : AppColors.sokoPaper),
      body: scaffoldBody,
      // Bottom nav lives in Scaffold's dedicated slot (NOT a Positioned
      // overlay in the body Stack). This eliminates the content-overlap
      // bug: Scaffold reserves the nav's height inside body's layout, so
      // bottom-most content is never obscured. PROD-1760.
      //
      // Wrapped in [AnimatedSize] so visibility transitions collapse the
      // nav to height 0 (and body grows to fill) instead of paying for a
      // hidden-but-laid-out widget. Curve + duration match Scaffold's
      // keyboard-inset animation (`Curves.fastOutSlowIn`, ~250ms) so the
      // nav's collapse and the keyboard's rise stay visually in sync.
      //
      // NOT const: `const DiscoveryBottomNav()` would be canonicalized,
      // and `Element.updateChild` short-circuits when newWidget ===
      // oldWidget, skipping the nav's rebuild. The nav reads
      // `discoveryNavObserver` non-reactively (no inner AnimatedBuilder)
      // so it depends on parent-rebuild propagation. Same fix as
      // [PinnedPageChrome] above. PROD-1738 / PROD-1760.
      bottomNavigationBar: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.fastOutSlowIn,
        alignment: Alignment.topCenter,
        child: navVisible ? DiscoveryBottomNav() : const SizedBox.shrink(),
      ),
    );

    // Wrap the whole Scaffold in [ProductTourHost] so the showcase
    // spotlight overlay can cover both `Scaffold.body` (search bar,
    // home feed) and `Scaffold.bottomNavigationBar` (Create button,
    // Zines tab). The host is a no-op until the controller transitions
    // out of [TourStep.idle].
    //
    // The `ProviderScope` injects the per-mount [_tourKeys] for every
    // descendant that reads `productTourKeysProvider` (chat bar, city
    // action bar, bottom nav, search overlay, create-menu sheet, the
    // host itself). Critical: the override is fixed for the entire
    // shell-mount lifetime, so the `KeyedSubtree(key: tourKeys.searchBar,
    // …)` (`discovery_screen.dart`) NEVER sees a mid-build key change —
    // that's what triggered the `framework.dart:2168` cascade the
    // earlier `ref.invalidate` attempt produced. See [_tourKeys]
    // docstring for the full attempt log.
    final shellTree = ProviderScope(
      overrides: [productTourKeysProvider.overrideWith((ref) => _tourKeys)],
      child: ProductTourHost(
        child: Stack(
          children: [
            scaffold,
            // Always-there app-wide feedback tab (PROD-2911): floated above the
            // whole Scaffold so it stays visible over the Create-menu bottom
            // sheet and the bottom nav on every shell surface. Modal sheets
            // (root navigator) still render above it.
            const FeedbackSideTab(),
            // Admin-only location diagnostics: a right-edge tab (stacked below
            // the feedback tab) that toggles a docked panel showing GPS / user
            // loc / chat + discovery search centers. Self-gates for non-admins.
            const LocationDebugTab(),
            const LocationDebugPanel(),
            // Shake-to-open the feedback sheet (PROD-2953). Renders nothing;
            // listens for a shake on every shell surface.
            const ShakeToFeedback(),
          ],
        ),
      ),
    );

    // PROD-2874: on native Android the system back button is dispatched only
    // to the root navigator (inner-route PopScopes never fire — verified on
    // device). So this single root-level PopScope resolves every case:
    // retreat to home from chat/library/menu, close the search overlay or
    // history drawer first, pop a pushed detail, and exit only on home.
    // iOS (edge-swipe) and web (browser back) keep their own handling — the
    // guard installs only on native Android.
    final androidSystemBack =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (!androidSystemBack) return shellTree;

    final backAction = resolveAndroidShellBack(
      sidebarOpen: isSidebarOpen,
      searchOpen: ref.watch(searchOpenProvider),
      canPopStack: context.canPop(),
      // `matchedLocation` is reliable for tab roots (reached via `context.go`).
      onHome: GoRouterState.of(context).matchedLocation == AppRoutes.home,
    );
    return PopScope(
      canPop: backAction == AndroidShellBack.systemPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        switch (backAction) {
          case AndroidShellBack.closeSidebar:
            ref.read(sidebarOpenProvider.notifier).state = false;
          case AndroidShellBack.closeSearch:
            ref.read(searchOpenProvider.notifier).state = false;
            ref.read(searchQueryProvider.notifier).state = '';
          case AndroidShellBack.goHome:
            popOrFallback(context);
          case AndroidShellBack.systemPop:
            break; // canPop already true — nothing to intercept.
        }
      },
      child: shellTree,
    );
  }
}

/// URLs whose body widget owns its own scrollable + chrome and must be
/// mounted directly inside the shell's [Expanded] (NOT wrapped in the
/// shared [SingleChildScrollView] + chrome-reserved padding).
///
/// Wrapping a body that contains its own vertical scrollable inside
/// another vertical scrollable either (a) clips the inner list to its
/// intrinsic height, (b) throws "Vertical viewport was given unbounded
/// height", or (c) lays out the inner widget at zero size — neither is
/// recoverable without per-route handling. Concretely: the bug that
/// motivated this is the bottom-nav Chat tap empty-screen issue
/// (PROD-1736 cutover smoke testing).
///
/// Currently used for canonical chat URLs. Add new full-bleed URLs
/// here as needed.
bool _isFullBleedLocation(String location) {
  return location == AppRoutes.chat ||
      location == AppRoutes.mapa ||
      RegExp(r'^/chat/[^/]+$').hasMatch(location);
}

/// Observer-driven mirror of [_isFullBleedLocation]. Preferred over the
/// URL form because imperative `context.push` doesn't update
/// `matchedLocation` (see
/// `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`),
/// so a push from `/chat` into a sibling shell route (e.g.
/// `/discovery/lists/new` via the "Criar lista" chat banner) would
/// otherwise still resolve to full-bleed and skip the
/// [ShellSliverScope] wrap — PROD-2157.
bool _isFullBleedRouteName(String? routeName) {
  return routeName == chatPageName || routeName == mapPageName;
}

/// Signature for a pull-to-refresh handler attached to a feed-shaped
/// route. Closes over any route params it needs (e.g. listId) so the
/// caller can fire it with just `ref`.
typedef _FeedRefreshHandler = Future<void> Function(WidgetRef ref);

/// Picks the pull-to-refresh handler for the current top route, or null
/// for non-feed routes (detail pages, create-zine, chat, etc.) — in which
/// case the shell skips wrapping with `RefreshIndicator` entirely.
///
/// Source-of-truth is [discoveryNavObserver], NOT `state.matchedLocation`:
/// imperative `context.push` (used to land on list-detail) doesn't update
/// matchedLocation in this codebase — see
/// `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`
/// and the same caveat on [_navHiddenOnRoute] below. The observer reads
/// `Page.name` from the nav `didPush`/`didPop` callbacks and is always
/// current. The list-detail pageBuilder stashes the `listId` in
/// `Page.arguments` precisely so feed-level consumers (chrome, this) can
/// read it without depending on matchedLocation.
///
/// Feed routes today: Discovery (Page name = [discoveryPageName], path
/// `/` — `/discovery` is a legacy redirect alias), Lists hub (path
/// `/lists`, no `Page.name` — reached declaratively so matchedLocation
/// IS reliable), and list detail (Page name = [listDetailPageName],
/// `listId` from `topRouteArguments`).
_FeedRefreshHandler? _feedRefreshForRoute(GoRouterState state) {
  final topName = discoveryNavObserver.topRouteName;
  final topArgs = discoveryNavObserver.topRouteArguments;

  if (topName == discoveryPageName) {
    return refreshDiscoveryFeed;
  }
  if (topName == listDetailPageName) {
    if (topArgs is String && topArgs.isNotEmpty) {
      final id = topArgs;
      return (ref) => refreshListDetail(ref, id);
    }
    return null;
  }
  return null;
}

/// Routes where the [DiscoveryBottomNav] is hidden because
/// [PinnedPageChrome] is taking over the chrome surface and the nav
/// would be redundant. Mirrors the route set in
/// `PinnedPageChrome._resolveSpec` — keep the two in agreement.
///
/// Source: [discoveryNavObserver.topRouteName] (NOT `matchedLocation` —
/// imperative `context.push` doesn't update it; see
/// `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`).
bool _navHiddenOnRoute(String? routeName) {
  switch (routeName) {
    case standaloneVenueDetailPageName:
    case standaloneEventDetailPageName:
    case dailyDropDetailPageName:
    case feedBundleSeeAllPageName:
    case listDetailPageName:
    case inListVenueDetailPageName:
    case inListEventDetailPageName:
    case chatPlacesMapPageName:
    case userProfilingListsPageName:
    // Notifications inbox is a full-page surface — the user is reading
    // their own queue, not navigating shells. Hide the nav so the screen
    // covers the bottom of the viewport like list/venue detail does.
    case menuNotificationsPageName:
      return true;
    default:
      return false;
  }
}

/// PROD-2258: map a URL to the (chrome route name, listId) it represents,
/// covering the full set [_navHiddenOnRoute] recognises. The `matchedLocation`
/// fallback for [_effectiveTopRoute]. Mirrors the route paths in
/// `app_router.dart`. Returns null for URLs with no shell chrome. `listId` is
/// percent-decoded to match the key `app_router`'s pageBuilder stashes (which
/// comes from `state.pathParameters`, already decoded by GoRouter).
@visibleForTesting
({String name, String? listId})? detailRouteFromLocation(String location) {
  final listVenue = RegExp(
    r'^/lists/([^/]+)/venues/[^/]+$',
  ).firstMatch(location);
  if (listVenue != null) {
    return (
      name: inListVenueDetailPageName,
      listId: Uri.decodeComponent(listVenue.group(1)!),
    );
  }
  final listEvent = RegExp(
    r'^/lists/([^/]+)/events/[^/]+$',
  ).firstMatch(location);
  if (listEvent != null) {
    return (
      name: inListEventDetailPageName,
      listId: Uri.decodeComponent(listEvent.group(1)!),
    );
  }
  final listDetail = RegExp(r'^/lists/([^/]+)$').firstMatch(location);
  if (listDetail != null) {
    final id = listDetail.group(1)!;
    // Legacy lists-hub filter literals share the `/lists/<x>` shape but are
    // dropped routes, not list-detail. Excluded defensively.
    const hubFilters = {'yours', 'soko', 'following', 'recommended'};
    if (!hubFilters.contains(id)) {
      return (name: listDetailPageName, listId: Uri.decodeComponent(id));
    }
  }
  if (RegExp(r'^/venues/[^/]+$').hasMatch(location)) {
    return (name: standaloneVenueDetailPageName, listId: null);
  }
  if (RegExp(r'^/events/[^/]+$').hasMatch(location)) {
    return (name: standaloneEventDetailPageName, listId: null);
  }
  if (location == '/chat-map') {
    return (name: chatPlacesMapPageName, listId: null);
  }
  return null;
}

/// True iff [name] is a route the shell renders dedicated chrome / nav-hiding
/// for. When the observer reports one of these we trust it; otherwise we fall
/// back to the URL. Mirrors [_navHiddenOnRoute].
bool _isChromeRouteName(String? name) {
  switch (name) {
    case standaloneVenueDetailPageName:
    case standaloneEventDetailPageName:
    case dailyDropDetailPageName:
    case listDetailPageName:
    case inListVenueDetailPageName:
    case inListEventDetailPageName:
    case chatPlacesMapPageName:
      return true;
    default:
      return false;
  }
}

/// PROD-2258: effective (routeName, arguments) for chrome / nav-visibility /
/// page-bg, reconciling [discoveryNavObserver] with `matchedLocation`.
///
/// The observer is authoritative for imperative `context.push` (which leaves
/// `matchedLocation` stale), so when it names a chrome route we trust it and
/// its stashed `listId`. But it fails to name a chrome route in two native
/// cases — the optimistic `discovery` default before its first didPush
/// (cold-load), and a nameless transient route that lands on top during warm
/// same-shell deep-link navigation (PROD-2258). In both, `matchedLocation` is
/// the reliable signal (declarative `go` + the initial route both update it),
/// so derive the route from the URL.
({String? name, Object? args}) _effectiveTopRoute(String matchedLocation) {
  final obsName = discoveryNavObserver.topRouteName;
  if (_isChromeRouteName(obsName)) {
    return (name: obsName, args: discoveryNavObserver.topRouteArguments);
  }
  // The social profile (`/u/:handle`, `/@:handle`) is pushed imperatively over
  // a detail page, which leaves `matchedLocation` stale (e.g. `/events/<id>`).
  // The profile renders no shell chrome; without trusting the observer here the
  // stale-URL fallback below would re-derive the underlying event and keep
  // painting its green chrome (PROD-3134 follow-up). The observer is
  // authoritative for the pushed page, so trust it.
  if (obsName == publicProfilePageName) {
    return (name: obsName, args: discoveryNavObserver.topRouteArguments);
  }
  final fromUrl = detailRouteFromLocation(matchedLocation);
  if (fromUrl != null) {
    return (name: fromUrl.name, args: fromUrl.listId);
  }
  return (name: obsName, args: discoveryNavObserver.topRouteArguments);
}

/// URL-based mirror of [_navHiddenOnRoute], used by edge-swipe handlers
/// (`_onLeftEdgeSwipe`) as a cold-load fallback before
/// [discoveryNavObserver] has seen its first push. Matches the URLs
/// declared in `app_router.dart` for the routes returning true above.
///
/// Excludes the lists-hub filter URLs (`/lists/yours`, `/lists/soko`,
/// `/lists/following`, `/lists/recommended`) which match the
/// `/lists/<id>` shape but are hub views, NOT list-detail views.
bool _navHiddenOnLocation(String location) {
  const hubFilterPaths = {
    '/lists/yours',
    '/lists/soko',
    '/lists/following',
    '/lists/recommended',
  };
  if (hubFilterPaths.contains(location)) return false;

  return RegExp(r'^/venues/[^/]+$').hasMatch(location) ||
      RegExp(r'^/events/[^/]+$').hasMatch(location) ||
      RegExp(r'^/lists/[^/]+$').hasMatch(location) ||
      RegExp(r'^/lists/[^/]+/venues/[^/]+$').hasMatch(location) ||
      RegExp(r'^/lists/[^/]+/events/[^/]+$').hasMatch(location) ||
      // PROD-4068: a bundle's see-all page. The BOTTOM NAV does not reach
      // here — it goes through `_effectiveTopRoute`, which returns the
      // observer's name for this page. This entry serves only the edge-swipe
      // handler's fallback for the transient window where the observer names
      // nothing.
      RegExp(r'^/feed/bundle/[^/]+$').hasMatch(location) ||
      // The seeded chat map is a full-screen route — hide the bottom nav
      // while it's active. URL is the literal `/chat-map`.
      location == '/chat-map' ||
      // Notifications inbox is full-page (same mental model as a
      // detail view); the observer-based path above is the primary
      // signal, this URL mirror is the cold-load fallback.
      location == '/menu/notifications';
}

/// PROD-2874: what a native-Android system back press should do on the
/// shell. In this app the Android hardware/gesture back is dispatched only
/// to the ROOT navigator (verified on device: inner-route PopScopes — e.g.
/// [DiscoveryScreen]'s search-overlay guard — never fire on Android back).
/// So a single root-level [PopScope] in [DiscoveryShell] must resolve every
/// case, including closing the search overlay and history drawer.
enum AndroidShellBack {
  /// Let the framework pop run (home exits the app; a pushed detail pops).
  systemPop,

  /// Close the open chat-history drawer first.
  closeSidebar,

  /// Close the open "Descobre a cidade" search overlay first (on Android the
  /// inner [DiscoveryScreen] PopScope can't — see enum doc).
  closeSearch,

  /// A non-home tab (chat / library / menu) with an empty stack — retreat to
  /// home instead of letting the OS exit the app.
  goHome,
}

/// Resolves the Android system-back action for the shell. Pure so it can be
/// unit-tested without pumping the (heavy) [DiscoveryShell].
///
/// Order matters: transient overlays (drawer, search) close before any
/// navigation; then a poppable detail pops; then home exits; else retreat
/// home.
///
/// - [sidebarOpen]: the chat-history drawer is open.
/// - [searchOpen]: the discovery search overlay is open. Only actionable on
///   home — `searchOpenProvider` is a global flag that PERSISTS when the user
///   leaves `/` with the overlay open (PROD-2280: it's home-local state that
///   reappears on return), so gating on [onHome] stops a stale flag from
///   swallowing a back-to-home on chat/library/menu.
/// - [canPopStack]: a pushed route (e.g. a detail page) can pop normally.
/// - [onHome]: home (`/`) is the top surface — the legitimate exit point.
/// Whether the bottom nav is hidden while [routeName] is the effective top
/// route. Test seam over the private predicate — the set it encodes is a
/// product decision (which surfaces read as full-screen), so it is worth
/// pinning directly rather than only through a mounted shell.
@visibleForTesting
bool navHiddenForRouteName(String? routeName) => _navHiddenOnRoute(routeName);

@visibleForTesting
AndroidShellBack resolveAndroidShellBack({
  required bool sidebarOpen,
  required bool searchOpen,
  required bool canPopStack,
  required bool onHome,
}) {
  if (sidebarOpen) return AndroidShellBack.closeSidebar;
  if (searchOpen && onHome) return AndroidShellBack.closeSearch;
  if (canPopStack || onHome) return AndroidShellBack.systemPop;
  return AndroidShellBack.goHome;
}

/// Pop the current route, or fall back to a route-aware destination when
/// the navigator stack is empty (a cold-load deep-link to a detail URL).
///
/// Shared by [PinnedPageChrome]'s back-button (`_back`) and
/// [DiscoveryShell]'s left-edge swipe-back (`_onLeftEdgeSwipe`) so the
/// two affordances apply the SAME fallback policy:
/// - In-list detail (`/lists/<listId>/{venues,events}/<id>`) → parent
///   list page (`/lists/<listId>`), closer to the user's mental model.
/// - Everything else (standalone venue/event, list page) → `/` (Discovery).
///
/// **Always uses GoRouter's `canPop` / `pop`**, never
/// `Navigator.of(context)`. The chrome lives as a sibling to the shell's
/// nested Navigator in the Scaffold body Stack (not a descendant), so
/// `Navigator.of(context)` from the chrome resolves UP to the root
/// navigator and misses routes added via `context.push`. The shell's
/// swipe handler has the same constraint by symmetry. PROD-1734 retro.
void popOrFallback(BuildContext context, {String? parentListId}) {
  if (context.canPop()) {
    context.pop();
    return;
  }
  if (parentListId != null) {
    context.go('/lists/$parentListId');
    return;
  }
  context.go('/');
}

/// Maps the topmost route (name + `Page.arguments`, from
/// [discoveryNavObserver]) to the page-level Scaffold bg colour. Returns `null`
/// for routes that use the shell's default bg.
///
/// PROD-3950 — takes [args] because the daily-drop route's colour depends on
/// the drop, not just the route name. This is the second of the two sites that
/// must agree on that (the other is `PinnedPageChrome._resolveSpec`); both
/// defer to [dailyDropChromeIsEvent].
Color? _pageBgForRoute(String? name, Object? args) {
  switch (name) {
    case listDetailPageName:
    case inListVenueDetailPageName:
    case inListEventDetailPageName:
      return AppColors.sokoPaper;
    case standaloneVenueDetailPageName:
      return AppColors.sokoVenue;
    case standaloneEventDetailPageName:
      return AppColors.sokoEvent;
    // PROD-2908 / PROD-3950 — daily-drop detail follows the drop's own kind:
    // event drops get the event (green) surface, everything else venue (blue).
    case dailyDropDetailPageName:
      return dailyDropChromeIsEvent(args)
          ? AppColors.sokoEvent
          : AppColors.sokoVenue;
    default:
      return null;
  }
}

/// Hides the default scrollbar on the Discovery page (per design) while
/// keeping mouse + trackpad drag-to-scroll wired up on web/desktop.
class _NoScrollbarScrollBehavior extends MaterialScrollBehavior {
  const _NoScrollbarScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

/// Shown across the top when the device is offline.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        top: OrientationUtils.safeTop(context, additionalPadding: 4),
        bottom: 8,
        left: 16,
        right: 16,
      ),
      color: AppColors.warning,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off, size: 16, color: AppColors.textOnPrimary),
          const SizedBox(width: 8),
          Text(
            Lt.of(context).offlineBannerText,
            style: TextStyle(
              color: AppColors.textOnPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// PROD-1952: full-bleed scrim + tap-to-dismiss layer for the Create
/// menu's persistent bottom sheet.
///
/// Inert when the sheet is closed: `IgnorePointer(ignoring: true)`
/// lets all underlying gestures (card taps, scroll, chrome buttons)
/// through normally. When the sheet is open: `HitTestBehavior.opaque`
/// absorbs every tap in the body area and closes the sheet — no
/// underlying widget gets the gesture, by design.
///
/// Visually it fades in a Soko-Ink-tinted scrim
/// ([AppColors.sokoInkSecondary], the same 30 %-alpha ink used as the
/// modal-sheet barrier in [showBottomSheetWithHiddenNav]) so the
/// persistent Create sheet reads with the same "this surface owns the
/// foreground" affordance as the Importa / Instagram / etc. modal
/// sheets it launches into. Over the Discovery surface's `sokoPaper`
/// background the ink reads as a muted pink, matching the modal-sheet
/// look.
///
/// Sits inside the Scaffold body Stack ABOVE the chrome but BELOW the
/// drawers (Profile / ChatSidebar), so when both are open the drawers
/// take precedence over this dismisser.
class _CreateMenuDismissOverlay extends ConsumerWidget {
  const _CreateMenuDismissOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(createMenuControllerProvider);
    final isOpen = controller != null;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !isOpen,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => controller?.close(),
          // 250 ms matches the persistent bottom sheet's slide-in
          // animation in Material, so the scrim grows in lockstep
          // with the sheet rising from below instead of popping
          // ahead of it.
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            color: isOpen
                ? AppColors.sokoInkSecondary
                : AppColors.sokoInkSecondary.withValues(alpha: 0),
          ),
        ),
      ),
    );
  }
}
