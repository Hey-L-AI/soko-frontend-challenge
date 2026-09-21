import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/auth_gating.dart';
import '../../feature_spotlight/widgets/spotlight_trigger.dart';
import '../../library/models/library_filter.dart';
import '../../library/providers/library_filter_provider.dart';
import '../../profile/widgets/soko_mutual_follow_card.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../product_tour/models/tour_step.dart';
import '../../product_tour/providers/product_tour_controller.dart';
import '../../product_tour/providers/product_tour_keys_provider.dart';
import '../../product_tour/widgets/tour_spotlight.dart';
import '../../../shared/providers/shell_stray_tap_provider.dart';
import '../../map/providers/map_leave_prompt_provider.dart';
import '../providers/search_open_provider.dart';
import '../providers/search_query_provider.dart';
import 'create_menu_sheet.dart';
import 'discovery_shell.dart';
import 'scroll_memory_observer.dart';

/// Discovery bottom nav: 5 items per the figma cache
/// (`docs/ui/figma-cache/screens/discovery/bottom-nav.md`) and the
/// Soko -- shared figma file, node `4037:5909`.
///
/// Order (left → right): Chat · Zines · Home · Criar · Menu.
/// Full-bleed surface anchored to the bottom — flat top edge, no shadow.
///
/// **Active state** is conveyed by a 400ms animated transition (PROD-1952):
/// label fades out (and collapses), icon scales 20→28 (Home: 22→28) into
/// the freed space, and the SVG swaps to the `*-active` variant where one
/// exists. Curve is `Curves.easeInOutCubic` (symmetric S) so the cell
/// flows between states. Menu has no active SVG variant (no
/// `*-active.svg` asset); it only animates the scale + label fade. Home
/// also has no variant but adds a stamp-bounce + damped wobble to the
/// scale so the Soko brand mark lands like an ink stamp on select.
///
/// Hosted in [DiscoveryShell] via `Scaffold.bottomNavigationBar` (NOT a
/// `Positioned` overlay in the body Stack). The shell wraps it in
/// `AnimatedSize` and computes the visibility AND of:
/// `bottomNavVisibleProvider`, route predicate, keyboard inset, drawer
/// open-state. See `discovery_shell.dart` for the visibility composition.
///
/// Selected-state combines TWO signals because no single source covers
/// every navigation path. See
/// `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`.
///
/// - [discoveryNavObserver] — fires `didPush`/`didPop` on the discovery
///   shell's nested navigator. Catches same-shell imperative pushes
///   (e.g., a discovery shelf card → `/venues/<id>`) where
///   `matchedLocation` would stay stuck at `/discovery`.
/// - [GoRouterState.matchedLocation] — reflects the URL after a
///   declarative reroute. Catches cross-shell navigations.
///
/// The shell already setStates on `discoveryNavObserver` changes
/// (see `_DiscoveryShellState._onNavChange`), which propagates rebuilds
/// down to this widget — so no inner `AnimatedBuilder` is needed.
class DiscoveryBottomNav extends ConsumerStatefulWidget {
  const DiscoveryBottomNav({super.key});

  @override
  ConsumerState<DiscoveryBottomNav> createState() => _DiscoveryBottomNavState();
}

class _DiscoveryBottomNavState extends ConsumerState<DiscoveryBottomNav> {
  // TODO(desktop-redesign): replace with proper desktop nav layout once
  // designs land. For now the mobile bar is constrained to this width on
  // desktop so it doesn't span 1920px.
  static const double _desktopMaxWidth = 600;

  // Inactive variants.
  static const String _chatIconPath = 'assets/images/icons/nav/search.svg';
  static const String _zinesIconPath = 'assets/images/icons/nav/book-open.svg';
  static const String _createIconPath = 'assets/images/icons/nav/plus.svg';
  // The last slot is the "Profile" hub for everyone, with a person glyph.
  // Filled variant lights up when the profile tab is selected.
  static const String _profileIconPath = 'assets/images/icons/nav/profile.svg';
  static const String _profileActiveIconPath =
      'assets/images/icons/nav/profile-active.svg';
  // Active variants (swapped in when the corresponding tab is selected).
  // Home + Menu have no active variant per figma node 4037:5909.
  // ARB keys + SVG filenames retain the legacy "search" name (the slot
  // was relabelled from Search → Chat in PR #357 without renaming the
  // underlying assets — handler-side rename only, per PROD-1825).
  static const String _chatActiveIconPath =
      'assets/images/icons/nav/search-active.svg';
  static const String _zinesActiveIconPath =
      'assets/images/icons/nav/book-open-active.svg';
  // PROD-1952: Criar does NOT swap to a separate asset when selected.
  // Instead, the existing `plus.svg` is rotated 45° (→ ×) in lockstep
  // with the icon-scale animation. See `_NavItem.rotateOnSelect`. The
  // legacy `plus-active.svg` is unused.

  // PROD-1825: Chat-tap toggles between the new-conversation input
  // (/chat) and the active session (/chat/$activeSessionId). Debounce
  // swallows accidental double-taps that would otherwise toggle right
  // back to the original URL.
  DateTime? _lastChatTap;
  static const _chatTapDebounce = Duration(milliseconds: 500);

  /// PROD-3627 — a page-local overlay (today: the map's focused search mode)
  /// is up, and this nav tap is a **stray** one: it dismisses that overlay and
  /// does nothing else. A second tap navigates normally.
  ///
  /// ⚠️ **Must run FIRST in every tab handler**, which is why it lives here
  /// rather than inside [_navigate]. The handlers do real work before they
  /// navigate — `trackTabChange`, `_closeCreateSheetIfOpen`, the guest
  /// `requireAuth` prompt — and **Criar never calls [_navigate] at all**, it
  /// toggles a sheet. Guarding only the navigation would still fire analytics,
  /// close sheets and open the create menu on a tap meant to dismiss.
  ///
  /// The bottom nav is the Scaffold's `bottomNavigationBar`, a sibling of the
  /// body the map's focused overlay fills, so its scrim can never absorb these
  /// taps — this is the only place the rule can hold for them.
  bool _consumedByStrayTap() {
    final dismiss = ref.read(shellStrayTapDismissProvider);
    return dismiss != null && dismiss();
  }

  void _navigate(String target, {VoidCallback? beforeNavigate}) {
    // Capture the router at TAP time. The leave guard can dispose THIS State
    // before it calls back: the map's divergence sheet is shown via
    // `showBottomSheetWithHiddenNav`, which flips `bottomNavVisibleProvider`
    // and makes DiscoveryShell swap this widget for a `SizedBox.shrink()`.
    // A State-bound `mounted`/`context` check would then silently swallow the
    // navigation while the map had ALREADY latched `_allowRoutePop` — leaving
    // the user on the map with every later nav tap dead.
    final router = GoRouter.of(context);
    unawaited(
      ref.read(mapLeaveNavigationGuardProvider).navigate(() {
        beforeNavigate?.call();
        router.go(target);
      }),
    );
  }

  void _onChatPressed() {
    final now = DateTime.now();
    if (_lastChatTap != null &&
        now.difference(_lastChatTap!) < _chatTapDebounce) {
      return;
    }
    _lastChatTap = now;

    // PROD-3168: a real (non-debounced) Chat-tab tap opens the conversation.
    ref
        .read(unifiedAnalyticsProvider)
        .trackChatOpen(entryPoint: EntryPoint.navTab);

    final location = GoRouterState.of(context).matchedLocation;
    final activeSessionId = ref.read(activeSessionIdProvider);

    // PROD-1736: post-cutover the canonical chat URLs are `/chat[/...]`
    // for all viewers (the pre-cutover `/discovery/chat[/...]` admin
    // bridge collapsed back onto canonical).
    final onSession = RegExp(r'^/chat/[^/]+$').hasMatch(location);
    final onChatInput = location == AppRoutes.chat;

    String? target;
    if (onSession) {
      // On an active session → flip to the new-conversation input.
      //
      // Clearing `activeSessionIdProvider` is load-bearing: ChatScreen
      // mounted at `/chat` (no `widget.sessionId`) explicitly resumes
      // whatever is in the provider. Without this clear, navigating from
      // `/chat/:id` to `/chat` re-resumes the same session and the user
      // sees no visible change.
      target = AppRoutes.chat;
    } else if (onChatInput) {
      // On the new-conversation input → flip to the active session if
      // one exists; otherwise no-op (we're already where the toggle
      // would land us).
      if (activeSessionId != null) {
        target = '/chat/$activeSessionId';
      }
    } else {
      // Anywhere else (/discovery, /lists, /lists/:id, …) → land on the
      // active session if one exists, else the new-conversation input.
      target = activeSessionId != null
          ? '/chat/$activeSessionId'
          : AppRoutes.chat;
    }

    if (target != null) {
      // Captured at tap time for the same reason as the router in [_navigate]:
      // `ref` on a disposed ConsumerState THROWS, and the leave guard can call
      // this back after the divergence sheet has disposed us.
      final activeSession = ref.read(activeSessionIdProvider.notifier);
      _navigate(
        target,
        beforeNavigate: onSession
            ? () => activeSession.setActiveSession(null)
            : null,
      );
    }
  }

  /// Clear every applied library filter and return to the merged feed — the
  /// state a fresh landing shows. Fired when Library is tapped while already
  /// on `/library`, where the navigation itself is a no-op.
  ///
  /// Layout (list vs grid) is a preference, not a filter, so it survives.
  /// Scroll is left alone to match a filter-bar tab switch, which does not
  /// jump to the top either.
  void _resetLibraryToMergedView() {
    ref.read(libraryTabProvider.notifier).state = LibraryFilter.initial;
    // Defensive, not load-bearing: `LibraryScreen` already clears the query
    // when the search overlay closes and again on mount, so it is normally
    // empty by the time this tap is possible. Cheap insurance, since the
    // debounced query is what actually drives the feed.
    resetLibrarySearch(ref);
    ref.read(librarySortProvider.notifier).state = LibrarySort.recent;
  }

  /// PROD-1952: close the persistent Create sheet if it's open.
  /// Called as a side-effect by every non-Criar nav button so that any
  /// click outside the sheet dismisses it (the dismiss-overlay in
  /// DiscoveryShell handles taps on body content; this method handles
  /// taps on the bottom nav itself).
  void _closeCreateSheetIfOpen() {
    ref.read(createMenuControllerProvider)?.close();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = Lt.of(context);

    final location = GoRouterState.of(context).matchedLocation;
    final locationOnLibrary =
        location == AppRoutes.library ||
        location.startsWith('${AppRoutes.library}/');
    final locationOnChat =
        location == AppRoutes.chat ||
        RegExp(r'^/chat/[^/]+$').hasMatch(location);

    // Chat selected when ChatScreen is mounted under DiscoveryShell
    // (chat-bridge twin-paths from `/chat[/...]` → `/discovery/chat[/...]`
    // for admins).
    //
    // OR'd from BOTH the observer's [Page.name] AND `matchedLocation` —
    // mirrors the Zines highlight below. The observer is a top-level
    // singleton whose state can be stale during the first frame after a
    // cold-load OR a cross-shell remount (the inner Navigator's didPush
    // fires AFTER the shell rebuild). `matchedLocation` is the router's
    // resolved URL, fresh on every build, so this combination lights up
    // the active icon on the very first frame instead of needing the
    // observer to catch up.
    final isChatSelected =
        discoveryNavObserver.topRouteName == chatPageName || locationOnChat;
    final isZinesSelected =
        discoveryNavObserver.isOnListDetail || locationOnLibrary;
    // Início is selected when we're on `/` exactly, OR when the
    // navigator's top route IS discovery (covers venue/event detail
    // pushed under discovery). The observer-only branch isn't enough on
    // its own: cross-shell navigation (e.g. Zines → Home via
    // `context.go('/')`) doesn't fire didPop on the discovery
    // navigator, so the observer's `_topRouteName` stays stuck on the
    // previous discovery sub-route. The URL signal is fresh on every
    // build and catches that case. Guard with `!isZinesSelected &&
    // !isChatSelected` to defuse the symmetric optimism (observer still
    // reports `discovery` after a cross-shell push AWAY from discovery).
    final locationOnHome = location == AppRoutes.home;
    // PROD-2280: the discovery search overlay reads to the user as a
    // standalone page (full-bleed grid + dedicated input), even though it
    // lives ON `/`. While it's open, treat Home as deselected so the
    // bottom nav reads "Início" with the small icon — same affordance as
    // when the user is on /lists, /chat, etc. — and so the stamp-bounce
    // animation actually plays when they tap Home to come back.
    final searchOverlayOpen = ref.watch(searchOpenProvider);
    // Keep Home DESELECTED on the full-bleed Map page, so tapping it closes the
    // map back to Discovery instead of no-opping on the `if (!isHomeSelected)`
    // guard in `onHomeTap`.
    //
    // PROD-2992 needed the observer because `/map` was reached by an imperative
    // `context.push('/map')`, which left `matchedLocation` (→ `location`) stale
    // at `/` and wrongly lit Home. **PROD-3524 removed that cause** — `/map` is
    // now a child route of `/` entered with `context.go`, so `matchedLocation`
    // is `/map` and `locationOnHome` is already false here. The observer check
    // stays because it is the signal that is correct on the FIRST frame:
    // `matchedLocation` is fresh on declarative navigation, but this widget also
    // rebuilds from the observer, and keeping both means neither a stale
    // location nor a stale observer can light Home on the map.
    final isOnMapPage = discoveryNavObserver.topRouteName == mapPageName;
    // Same stale-`locationOnHome` trap as the map (above): a person card in a
    // home shelf opens `/u/:handle` via an imperative `context.push`, which
    // does NOT update `matchedLocation` — so `locationOnHome` stays true, Home
    // stays lit, and the Home tap no-ops. The nav observer's top-route name is
    // reliable, so exclude the public profile to keep Home DESELECTED there;
    // tapping Home then pops back to Discovery.
    final isOnPublicProfile =
        discoveryNavObserver.topRouteName == publicProfilePageName;
    final isHomeSelected =
        !isZinesSelected &&
        !isChatSelected &&
        !searchOverlayOpen &&
        !isOnMapPage &&
        !isOnPublicProfile &&
        (locationOnHome || discoveryNavObserver.isOnDiscovery);
    // PROD-1952: Criar's selected state tracks whether the Create-menu
    // bottom sheet is mounted. The sheet keeps the nav visible so the
    // selected icon (rotated `+` → `×`) is actually seen.
    final isCreateSelected = ref.watch(createMenuControllerProvider) != null;
    // PROD-2019: Menu is a real route (`/menu`). URL-based selection only
    // — there's no observer signal to OR with because `/menu` is a
    // declarative top-level shell route (no imperative `context.push` that
    // would slip past `matchedLocation`).
    //
    // Lit on `/menu` AND every `/menu/*` detail page (same pattern as
    // `locationOnLibrary`), so the icon stays selected as the user drills in.
    // The click handler uses `isOnMenuRoot` (not `isMenuSelected`) so a tap
    // from a detail page still routes back to `/menu` instead of no-op'ing.
    final isOnMenuRoot = location == AppRoutes.menu;
    // The social profile is the last nav slot for EVERYONE now (the profile is
    // the hub; Settings/account live behind the gear in its header). `/menu` is
    // still reachable from that gear, so the slot highlights on either route.
    final isMenuSelected =
        isOnMenuRoot ||
        location.startsWith('${AppRoutes.menu}/') ||
        location == AppRoutes.profile;

    // PROD-3168: the tab the user is currently on, used as `from_tab` for
    // nav_tab_change. Priority mirrors the mutually-exclusive selected flags
    // above; Home is the default when nothing else is lit.
    final currentTab = isChatSelected
        ? NavTab.chat
        : isZinesSelected
        ? NavTab.library
        : isCreateSelected
        ? NavTab.create
        : isMenuSelected
        ? NavTab.profile
        : NavTab.home;
    void trackTabChange(String tab) {
      if (tab == currentTab) return;
      ref
          .read(unifiedAnalyticsProvider)
          .trackNavTabChange(tab: tab, fromTab: currentTab);
    }

    // `Align(heightFactor: 1.0)` shrink-wraps the nav's vertical extent
    // to its intrinsic height — `Center` would over-claim available
    // height inside `Scaffold.bottomNavigationBar`'s loose-vertical
    // slot, leaving the nav floating mid-viewport. Horizontal centring
    // still works because no `widthFactor` is set.
    return Align(
      alignment: Alignment.center,
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _desktopMaxWidth),
        child: _NavBar(
          isDark: isDark,
          l10n: l10n,
          isHomeSelected: isHomeSelected,
          isChatSelected: isChatSelected,
          isZinesSelected: isZinesSelected,
          isCreateSelected: isCreateSelected,
          isMenuSelected: isMenuSelected,
          // Profile hub for everyone now → the profile_v1 coachmark wraps this
          // slot for all users (was admin-only).
          isProfileSlot: true,
          menuLabel: l10n.profileTitle,
          chatIconPath: _chatIconPath,
          chatActiveIconPath: _chatActiveIconPath,
          zinesIconPath: _zinesIconPath,
          zinesActiveIconPath: _zinesActiveIconPath,
          createIconPath: _createIconPath,
          menuIconPath: _profileIconPath,
          menuActiveIconPath: _profileActiveIconPath,
          onChatTap: () {
            if (_consumedByStrayTap()) return;
            trackTabChange(NavTab.chat);
            _closeCreateSheetIfOpen();
            _onChatPressed();
          },
          onZinesTap: () {
            if (_consumedByStrayTap()) return;
            trackTabChange(NavTab.library);
            _closeCreateSheetIfOpen();
            // Already on the library itself: the `go` would be a no-op, so
            // spend the tap on clearing the filters instead. A library
            // SUB-route still just navigates back — those filters are the
            // state the user is returning to, not state to throw away.
            if (location == AppRoutes.library) {
              _resetLibraryToMergedView();
              return;
            }
            _navigate(AppRoutes.library);
          },
          onHomeTap: () {
            if (_consumedByStrayTap()) return;
            // Last tour step (profileMenu / "Personalizar") demos the
            // Home click via the cursor + `navigateToHome` side effect.
            // A real user tap here would race the demo and let the user
            // exit the tour through the nav instead of the card's
            // Concluído pill — gate it out so only the card CTA advances.
            final tourStep = ref.read(
              productTourControllerProvider.select((s) => s.step),
            );
            if (tourStep == TourStep.profileMenu) return;
            trackTabChange(NavTab.home);
            _closeCreateSheetIfOpen();
            // PROD-2280: the discovery search overlay is page-local state
            // on `/` (not URL-encoded), so a plain `context.go('/')` from
            // /lists, /chat, etc. leaves the overlay visible and the user
            // appears stuck on Discovery. Mirror the X-button + PopScope:
            // flip `searchOpenProvider` off and clear the query so Home
            // always lands on the actual homepage view — including the
            // already-on-`/` case where the route push would no-op.
            if (ref.read(searchOpenProvider)) {
              ref.read(searchOpenProvider.notifier).state = false;
              ref.read(searchQueryProvider.notifier).state = '';
              return;
            }
            // Already on the actual Discovery feed → re-tapping Home scrolls
            // it back to the top (the common "tap the active tab again"
            // affordance). On another tab, or a detail pushed under Home,
            // navigate to the feed instead.
            //
            // BOTH signals are required, and neither is sufficient alone:
            //
            //   • `locationOnHome` alone is stale-TRUE on a detail page
            //     reached by an imperative `context.push` (the
            //     matchedLocation trap) — we'd scroll an invisible feed
            //     instead of popping back to it.
            //   • `isOnDiscovery` alone is stale-TRUE on `/yours`. The
            //     `/` and `/yours` pages are both keyless
            //     `NoTransitionPage`s, so `Page.canUpdate` (runtimeType +
            //     key) matches them and the Navigator UPDATES the existing
            //     route in place rather than pushing a new one — no
            //     `didPush`/`didPop` ever reaches `discoveryNavObserver`,
            //     which stays frozen on `discovery`. Tapping Início from a
            //     scrolled library then scrolled the library to the top and
            //     never navigated. (Every other shell page carries a
            //     `key:`, which is why only this pair breaks.)
            //
            // AND-ing them is safe in both directions: the URL is fresh on
            // every build (kills the `/yours` false-positive) and the
            // observer sees imperative pushes the URL can't (kills the
            // detail-page false-positive).
            if (locationOnHome && discoveryNavObserver.isOnDiscovery) {
              discoveryFeedScroll.animateToTop();
            } else {
              _navigate(AppRoutes.home);
            }
          },
          // `CreateMenuSheet.toggle` opens if closed, closes if open —
          // so this naturally subsumes the "tap-Criar-again-to-dismiss"
          // case alongside the dismiss-overlay's tap-anywhere behavior.
          // The Scaffold context used inside `toggle` is sourced from
          // the captured `_` builder context, which IS a descendant of
          // the DiscoveryShell Scaffold (the bottom nav sits in the
          // Scaffold's `bottomNavigationBar` slot).
          onCreateTap: () {
            // PROD-3627: Criar is the one tab that never reaches `_navigate`
            // — it toggles a sheet — so without this a stray tap would OPEN
            // the create menu instead of dismissing the search.
            if (_consumedByStrayTap()) return;
            // PROD-3168: nav_tab_change only on the OPEN direction; create_open
            // itself is fired inside CreateMenuSheet once the sheet mounts.
            if (!isCreateSelected) {
              trackTabChange(NavTab.create);
            }
            CreateMenuSheet.toggle(context, ref, entryPoint: EntryPoint.navTab);
          },
          onMenuTap: () {
            // Before `requireAuth`, which would otherwise show a guest a login
            // prompt on a tap that was only meant to dismiss.
            if (_consumedByStrayTap()) return;
            _closeCreateSheetIfOpen();
            // `/menu` is a top-level shell tab (symmetric with `/chat`,
            // `/yours`, `/`). Always `go` — no `isOnMenuRoot` guard: the
            // sub-routes (`/menu/about`, `/menu/account`, ...) are reached
            // via `context.push`, which leaves `matchedLocation` stuck at
            // `/menu` (see
            // `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`).
            // Guarding on the stale URL would no-op on those sub-pages.
            // The slot is the social profile hub for everyone now.
            //
            // PROD-3142 — but "everyone" still needs an account to HAVE a
            // profile. `/profile` renders [SelfProfileScreen], which reads
            // `currentUserProvider.handle`; for a guest that's null, so the
            // screen fell through to its "Your account has no handle yet."
            // placeholder — shown to someone with no account at all, and
            // with no way forward from there.
            requireAuth(
              context,
              ref,
              action: l10n.guestProfileAction,
              referrer: AuthReferrer.guestProfile,
              onAuthenticated: () {
                trackTabChange(NavTab.profile);
                _navigate(AppRoutes.profile);
              },
            );
          },
        ),
      ),
    );
  }
}

class _NavBar extends ConsumerWidget {
  // PROD-1952: 64px content height (was ~88px). Excludes iOS SafeArea
  // bottom inset, which the outer SafeArea wrapper still applies on
  // notched devices.
  static const double _barHeight = 64;

  final bool isDark;
  final Lt l10n;
  final bool isHomeSelected;
  final bool isChatSelected;
  final bool isZinesSelected;
  final bool isCreateSelected;
  final bool isMenuSelected;

  /// True when the last nav slot is the admin-pilot "Profile" tab (routes to
  /// `/profile`). Drives the `profile_v1` spotlight, which only wraps that slot.
  final bool isProfileSlot;
  final String menuLabel;
  final String? menuActiveIconPath;
  final String chatIconPath;
  final String chatActiveIconPath;
  final String zinesIconPath;
  final String zinesActiveIconPath;
  final String createIconPath;
  final String menuIconPath;
  final VoidCallback onChatTap;
  final VoidCallback onZinesTap;
  final VoidCallback onHomeTap;
  final VoidCallback onCreateTap;
  final VoidCallback onMenuTap;

  const _NavBar({
    required this.isDark,
    required this.l10n,
    required this.isHomeSelected,
    required this.isChatSelected,
    required this.isZinesSelected,
    required this.isCreateSelected,
    required this.isMenuSelected,
    required this.isProfileSlot,
    required this.menuLabel,
    this.menuActiveIconPath,
    required this.chatIconPath,
    required this.chatActiveIconPath,
    required this.zinesIconPath,
    required this.zinesActiveIconPath,
    required this.createIconPath,
    required this.menuIconPath,
    required this.onChatTap,
    required this.onZinesTap,
    required this.onHomeTap,
    required this.onCreateTap,
    required this.onMenuTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(productTourKeysProvider);
    final bgColor = isDark
        ? AppColors.sokoPaper.withValues(alpha: 0.1)
        : AppColors.sokoPaper;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;

    // Last tour step (profileMenu / "Personalizar") demos the Home click
    // via the cursor + `navigateToHome` side effect. We make the real
    // button inert so a stray user tap can't race the demo, hijack the
    // showcase dismissal, or skip past the Concluído card CTA.
    final isHomeLockedByTour = ref.watch(
      productTourControllerProvider.select(
        (s) => s.step == TourStep.profileMenu,
      ),
    );

    // Home uses a different SVG per theme (the Soko brand mark has no
    // colorFilter applied — its colors are baked in).
    final homeIconPath = isDark
        ? 'assets/images/logos/soko-icon-paper.svg'
        : 'assets/images/logos/soko-icon-blood-1.svg';

    // Last nav slot. On the admin-pilot Profile slot it also hosts the
    // `profile_v1` feature spotlight (hand + "this is your profile" + a
    // mutual-follow Soko card), gated to the home/discovery surface only — the
    // nav is present on every shell route. `map_page_v1` (discovery_screen)
    // gates behind this being seen so the two coachmarks stay sequential.
    Widget menuSlot = _NavItem(
      inactiveAsset: menuIconPath,
      // PROD-2019: the Menu slot has no active variant (size + label animate
      // only). The admin Profile slot supplies a filled `profile-active.svg`.
      activeAsset: menuActiveIconPath,
      label: menuLabel,
      color: inkColor,
      isSelected: isMenuSelected,
      onTap: onMenuTap,
    );
    if (isProfileSlot) {
      menuSlot = SpotlightTrigger(
        featureId: 'profile_v1',
        gate: () => discoveryNavObserver.isOnDiscovery,
        content: const SokoMutualFollowCard(),
        onCtaAction: () => context.go(AppRoutes.profile),
        targetCornerRadius: 24,
        targetPadding: const EdgeInsets.all(4),
        child: menuSlot,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: const Border(
          top: BorderSide(color: AppColors.sokoInk8, width: 1),
        ),
      ),
      // Scaffold does NOT auto-apply SafeArea to bottomNavigationBar; we
      // consume MediaQuery.viewPadding.bottom here so the bar grows on
      // iOS notched devices (home indicator) without double-padding.
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _barHeight,
          child: Row(
            children: [
              Expanded(
                child: _NavItem(
                  inactiveAsset: chatIconPath,
                  activeAsset: chatActiveIconPath,
                  label: l10n.discoveryNavSearch,
                  color: inkColor,
                  isSelected: isChatSelected,
                  onTap: onChatTap,
                ),
              ),
              Expanded(
                child: TourSpotlight(
                  // PROD-2222 / PROD-4167 — the Guarda step has no blue
                  // rectangle anywhere now. `step: null` keeps this as a
                  // key holder for the tooltip + cursor click target.
                  tourKey: keys.yoursNav,
                  headline: Lt.of(context).productTourStep4CreateSaveHeadline,
                  body: Lt.of(context).productTourStep4YoursBody,
                  currentStep: 4,
                  isLastStep: false,
                  targetCornerRadius: 24,
                  targetPadding: const EdgeInsets.all(4),
                  child: _NavItem(
                    inactiveAsset: zinesIconPath,
                    activeAsset: zinesActiveIconPath,
                    label: l10n.discoveryNavZines,
                    color: inkColor,
                    isSelected: isZinesSelected,
                    onTap: onZinesTap,
                  ),
                ),
              ),
              Expanded(
                // `step: null` (no `TourSecondaryHighlight` wrap) so
                // the Home nav button doesn't get a blue rectangle
                // around it on step 5 — per user spec (2026-05-30).
                // The Home spot is still the click target via
                // [tourKey] and the showcase tooltip anchors here.
                child: TourSpotlight(
                  tourKey: keys.profileMenu,
                  headline: Lt.of(context).productTourStep5ProfileHeadline,
                  body: Lt.of(context).productTourStep5Profile,
                  currentStep: 5,
                  isLastStep: true,
                  targetCornerRadius: 24,
                  targetPadding: const EdgeInsets.all(4),
                  // The Home button IS this showcase's target. The
                  // showcaseview package's default on target tap is
                  // "dismiss + advance" — we don't want that here:
                  // the user must complete the tour via the card's
                  // Concluído pill. [blockTargetTap] wires the
                  // package's paired no-op handlers.
                  blockTargetTap: true,
                  child: IgnorePointer(
                    ignoring: isHomeLockedByTour,
                    child: _NavItem(
                      inactiveAsset: homeIconPath,
                      // Home has no active variant — the Soko brand mark
                      // is shown at both sizes. The size animates with an
                      // elastic overshoot + a damped wobble so the mark
                      // lands like an ink stamp on selection.
                      activeAsset: null,
                      label: l10n.navHome,
                      color: inkColor,
                      isSelected: isHomeSelected,
                      baseIconSize: 22,
                      applyColorFilter: false,
                      bounceOnSelect: true,
                      wobbleOnSelect: true,
                      onTap: onHomeTap,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: TourSpotlight(
                  tourKey: keys.createButton,
                  headline: Lt.of(context).productTourStep3CreateHeadline,
                  body: Lt.of(context).productTourStep3CreateBody,
                  currentStep: 3,
                  isLastStep: false,
                  targetCornerRadius: 24,
                  targetPadding: const EdgeInsets.all(4),
                  // Secondary blue frame on the Create-+ button. Lit in
                  // TWO moments to telegraph the step 2 → step 3 link:
                  //   • preview window (500 ms before sheet opens) —
                  //     `tourCreateButtonPreviewProvider` flips on
                  //     after the user taps Next on step 2, so the
                  //     border appears "Soko-tapping" this button
                  //     BEFORE the bottom sheet slides up.
                  //   • createSheet step — `activeOnSteps` keeps the
                  //     border on while the sheet is the spotlight.
                  // See [TourSecondaryHighlight].
                  child: TourSecondaryHighlight(
                    activeOnSteps: const {TourStep.createSheet},
                    extraActive: ref.watch(tourCreateButtonPreviewProvider),
                    // Disappear when user taps Next on Adiciona →
                    // cursor heads to Biblioteca (transition target
                    // becomes yoursNav, which isn't this trigger).
                    hideDuringCursorTransition: true,
                    borderRadius: 24,
                    child: _NavItem(
                      inactiveAsset: createIconPath,
                      // Criar uses rotation (`+` → `×`) instead of an
                      // asset swap. See `_NavItem.rotateOnSelect`.
                      activeAsset: null,
                      rotateOnSelect: true,
                      label: l10n.discoveryNavCreate,
                      color: inkColor,
                      isSelected: isCreateSelected,
                      onTap: onCreateTap,
                    ),
                  ),
                ),
              ),
              Expanded(child: menuSlot),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated nav cell. Cell fills its parent (`Expanded`) so the entire
/// cell is the tap target.
///
/// Selection transition (PROD-1952): 400 ms / easeInOutCubic. Two
/// continuous sub-animations + one discrete swap.
///
/// | Tween             | Forward interval | Effect                        |
/// |-------------------|------------------|-------------------------------|
/// | SVG variant swap  | instant @ t=0    | inactive → active             |
/// | Label opacity     | 0.00 – 0.30      | 1.0 → 0.0 (height collapses)  |
/// | Icon scale        | 0.25 – 0.85      | base → [_selectedIconSize]    |
///
/// The SVG swap is driven by [widget.isSelected] directly (not the
/// controller value), so the variant flips the moment the parent
/// rebuilds with the new selected state — *before* the icon scale
/// animation runs. The user sees: "icon swaps, then expands" on select,
/// and symmetrically "icon swaps, then contracts" on deselect.
///
/// For items without an active variant ([activeAsset] is null) the SVG
/// swap is a no-op — only the size animates (e.g. Home).
class _NavItem extends StatefulWidget {
  static const double _selectedIconSize = 28;
  static const Duration _duration = Duration(milliseconds: 400);
  // PROD-1952: Criar rotates its `+` icon by 45° (→ `×`) on select
  // instead of swapping to an active variant. Driven by the same
  // `_iconProgress` animation that handles the scale, so the rotation
  // is in lockstep with the expand.
  static const double _selectedRotationRadians = 0.7853981633974483; // π / 4

  final String inactiveAsset;
  final String? activeAsset;
  final String label;
  final Color color;
  final bool isSelected;
  final double baseIconSize;
  final bool applyColorFilter;

  /// If true, the icon rotates 0 → π/4 (45°) in lockstep with the
  /// scale animation when selected. Used by Criar so that the `+`
  /// reads as `×` while the Create sheet is open. Ignored when an
  /// [activeAsset] is also supplied — rotation and asset-swap are
  /// mutually exclusive selection visuals.
  final bool rotateOnSelect;

  /// If true, the scale transition uses `elasticOut`/`elasticIn` for
  /// a ~12% overshoot before settling — an "ink stamp landing" feel.
  /// Layered on top of the existing `_iconProgress` scale.
  final bool bounceOnSelect;

  /// If true, adds a damped sine rotation (≈ ±2.9°) that decays to
  /// upright by the end of the selection animation. Pairs with
  /// [bounceOnSelect] for a hand-stamped flourish. Mutually exclusive
  /// with [rotateOnSelect] (Criar already owns that slot).
  final bool wobbleOnSelect;
  final VoidCallback onTap;

  const _NavItem({
    required this.inactiveAsset,
    required this.activeAsset,
    required this.label,
    required this.color,
    required this.isSelected,
    required this.onTap,
    this.baseIconSize = 20,
    this.applyColorFilter = true,
    this.rotateOnSelect = false,
    this.bounceOnSelect = false,
    this.wobbleOnSelect = false,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _labelOpacity;
  late final Animation<double> _iconProgress;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _NavItem._duration,
      value: widget.isSelected ? 1.0 : 0.0,
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    // Label fades out in the first 30% of the animation; reversed so
    // value 0 = fully opaque, value 1 = transparent.
    _labelOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: curved, curve: const Interval(0.0, 0.30)),
    );
    // Icon scales from 0.25 → 0.85, leaving a tail for the SVG swap.
    _iconProgress = CurvedAnimation(
      parent: curved,
      curve: const Interval(0.25, 0.85),
    );
  }

  @override
  void didUpdateWidget(covariant _NavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelected != oldWidget.isSelected) {
      if (widget.isSelected) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            // `bounceOnSelect` re-curves the scale through elasticOut
            // so the icon springs past its target and settles — an
            // unmistakable "ink stamp landing" feel.
            final scaleT = widget.bounceOnSelect
                ? Curves.elasticOut.transform(_iconProgress.value)
                : _iconProgress.value;
            final size =
                widget.baseIconSize +
                (_NavItem._selectedIconSize - widget.baseIconSize) * scaleT;
            // Swap the SVG variant the instant [widget.isSelected]
            // flips — *before* the icon-scale animation runs. The user
            // sees "icon changes, then expands/contracts" on both
            // directions. Items without an active variant fall back to
            // the inactive asset throughout (e.g. Home).
            final showActive = widget.activeAsset != null && widget.isSelected;
            final asset = showActive
                ? widget.activeAsset!
                : widget.inactiveAsset;

            // Rotation in lockstep with the scale (same `_iconProgress`
            // interval). 0 → π/4 (45°) when `rotateOnSelect` is true,
            // 0 → 0 otherwise. `wobbleOnSelect` adds a damped sine
            // (~±8°) on top — decays to upright by the end of the
            // selection animation so the icon settles flat.
            final p = _iconProgress.value;
            final wobble = widget.wobbleOnSelect
                ? math.sin(p * 2 * math.pi) * 0.14 * (1.0 - p)
                : 0.0;
            final rotation = widget.rotateOnSelect
                ? _NavItem._selectedRotationRadians * p + wobble
                : wobble;

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.rotate(
                  angle: rotation,
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: SvgPicture.asset(
                      asset,
                      width: size,
                      height: size,
                      colorFilter: widget.applyColorFilter
                          ? ColorFilter.mode(widget.color, BlendMode.srcIn)
                          : null,
                    ),
                  ),
                ),
                // Label region: height collapses to 0 in sync with the
                // opacity fade so the icon migrates to the cell's true
                // vertical center when selected. The 6px gap above the
                // text is inside the collapsing region, so it disappears
                // too. ClipRect prevents transient overflow during the
                // tween.
                ClipRect(
                  child: Align(
                    alignment: Alignment.topCenter,
                    heightFactor: _labelOpacity.value,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Opacity(
                        opacity: _labelOpacity.value,
                        child: Text(
                          widget.label,
                          style: TextStyle(
                            color: widget.color,
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            height: 1.2,
                            letterSpacing: -0.12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
