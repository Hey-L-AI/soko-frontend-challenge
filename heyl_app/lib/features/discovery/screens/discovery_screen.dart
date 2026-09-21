import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/environment.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../product_tour/models/tour_step.dart';
import '../../product_tour/providers/product_tour_controller.dart';
import '../../product_tour/providers/product_tour_keys_provider.dart';
import '../../product_tour/widgets/tour_spotlight.dart';
import '../../feature_spotlight/providers/feature_spotlight_service.dart';
import '../../feature_spotlight/spotlight_route_observer.dart';
import '../../feature_spotlight/widgets/spotlight_trigger.dart';
import '../../../core/services/experiment_service.dart';
import '../../research/widgets/research_invitation_banner.dart';
import '../../campaigns/providers/campaign_service.dart';
import '../../campaigns/utils/campaign_presenter.dart';
import '../../../data/models/campaign.dart';
import '../../../data/models/user_profile.dart' show UserRole;
import '../../../shared/widgets/city_action_bar.dart';
import '../providers/discovery_supported_city_provider.dart';
import '../providers/event_filters_provider.dart';
import '../providers/place_filters_provider.dart';
import '../providers/search_category_provider.dart';
import '../providers/search_open_provider.dart';
import '../providers/search_query_provider.dart';
import '../providers/search_results_provider.dart';
import '../widgets/discovery_chat_bar.dart';
import '../widgets/discovery_end_actions.dart';
import '../widgets/discovery_header.dart';
import '../widgets/discovery_help_us_actions.dart';
import '../widgets/discovery_map_button_slot.dart';
import '../widgets/discovery_search_overlay.dart';
import '../widgets/discovery_section_divider.dart';
import '../widgets/discovery_typeahead_overlay.dart';
import '../widgets/feed_scroll_controller_scope.dart';
import '../widgets/history_grid.dart';
import '../widgets/scroll_memory_observer.dart';
import '../widgets/sections/daily_drop_section.dart';
import '../widgets/sections/default_content_section.dart';
import '../widgets/sections/discovery_footer.dart';
import '../widgets/sections/discovery_new_city_section.dart';
import '../widgets/sections/readers_search_section.dart';
import '../widgets/sections/search_results_section.dart';
import '../widgets/sections/weekly_bundle_section.dart';
import '../widgets/shelves/city_guides_shelf.dart';
import '../widgets/shelves/discovery_feed_shelf.dart';
import '../widgets/shelves/editor_picks_shelf.dart';
import '../widgets/shelves/happening_shelf.dart';
import '../widgets/shelves/highlighted_shelf.dart';
import '../widgets/shelves/near_you_places_shelf.dart';
import '../widgets/shelves/recommended_shelf.dart';
import '../widgets/shelves/spaces_shelf.dart';
import '../widgets/shelves/locals_shelf.dart';
import '../widgets/shelves/trending_shelf.dart';
import '../widgets/discovery_shell.dart';
import '../widgets/shell_sliver_page.dart';

/// Canonical home page (Discovery), mounted at `/` under [DiscoveryShell]
/// for all viewers post-PROD-1736. Sections (daily drop, history grid,
/// shelves) per `docs/designs/prod-1526-discovery-scaffold.md` and the
/// parent ticket PROD-1511.
class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  // PROD-4431 — the `/drop`, `/weekly-bundle` and `/user-profiling/flow`
  // deep-link markers used to arrive here as constructor args, which meant
  // only the LEGACY home page resolved them: `DiscoveryVariantPage` rendering
  // the v2 feed dropped every one. They now live one level up, in
  // [DiscoveryDeepLinkResolver], which wraps the variant.

  // TODO(desktop-redesign): no desktop designs yet — content uses the mobile
  // tree. The shell constrains width on desktop; the screen itself stays
  // identical across breakpoints.

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  // PROD-2263: ATT pre-prompt is now driven from `SokoApp` (auth listener +
  // lifecycle-resumed retry) so it fires regardless of whether the user
  // actually lands on Discovery post-signin. Previously gated here, which
  // Apple's reviewer never reached.
  bool _wasTopDiscoveryRoute = true;

  // Captured in initState so [_clearEventFilters] can run from dispose without
  // touching `ref` (illegal post-dispose — threw "Cannot use ref after the
  // widget was disposed", which aborted the unmount and cascaded into the
  // "Duplicate GlobalKey" / `_elements.contains` framework assertions). These
  // are global (non-autoDispose) StateProviders, so the notifiers outlive the
  // widget and are safe to mutate from dispose.
  late final StateController<EventTimeRange> _timeRangeController;
  late final StateController<Set<String>> _eventFacetController;
  late final StateController<Set<String>> _placeFacetController;

  /// PROD-1899: the Discovery feed owns its OWN scroll controller (each page
  /// under `DiscoveryShell` does now — see `ShellSliverHost`). Owned here (not
  /// inside `ShellSliverHost`) so page-level siblings of the scrollable — the
  /// floating `DiscoveryMapButton`, `DefaultContentSection`'s pager, and the
  /// search-overlay reset/restore — can share it via [FeedScrollControllerScope].
  /// Keeping its single [ScrollPosition] alive while Discovery sits offstage
  /// under a pushed detail is what makes back-nav reveal the feed already at its
  /// offset, with no restore jump.
  final ScrollController _feedController = ScrollController();


  @override
  void initState() {
    super.initState();
    // Register the feed controller so shell-level callers that aren't
    // descendants of the feed (bottom-nav Home-retap → animateToTop, search
    // overlay reset/restore) can drive it. Cleared in dispose. PROD-1899.
    discoveryFeedScroll.controller = _feedController;
    _timeRangeController = ref.read(eventTimeRangeProvider.notifier);
    _eventFacetController = ref.read(eventFacetFilterProvider.notifier);
    _placeFacetController = ref.read(placeTypeFacetFilterProvider.notifier);
    _wasTopDiscoveryRoute = discoveryNavObserver.isOnDiscovery;
    discoveryNavObserver.addListener(_handleDiscoveryRouteChange);
  }

  @override
  void dispose() {
    discoveryNavObserver.removeListener(_handleDiscoveryRouteChange);
    _clearEventFilters();
    // Identity-check before clearing so a transitional double-mount can't null
    // out a newer Discovery's registration.
    if (identical(discoveryFeedScroll.controller, _feedController)) {
      discoveryFeedScroll.controller = null;
    }
    _feedController.dispose();
    super.dispose();
  }

  void _handleDiscoveryRouteChange() {
    final isTopDiscoveryRoute = discoveryNavObserver.isOnDiscovery;
    // Clear the search filters on leaving Discovery — but NOT when what landed
    // on top is a result you opened from those very filters.
    //
    // `isOnDiscovery` alone can't tell the two apart: it is false both for a
    // venue/event pushed from the results and for a jump to another tab, and
    // those want opposite outcomes. Filtering, opening a place and coming back
    // must keep the filter; going to Home and back must not. `topRouteName`
    // says which happened.
    //
    // `dispose()` also clears, but it cannot carry this on its own: switching
    // tabs leaves Discovery mounted under the shell, so dispose never runs.
    if (_wasTopDiscoveryRoute && !isTopDiscoveryRoute) {
      const openedFromResults = {
        standaloneVenueDetailPageName,
        standaloneEventDetailPageName,
      };
      if (!openedFromResults.contains(discoveryNavObserver.topRouteName)) {
        _clearEventFilters();
      }
    }
    _wasTopDiscoveryRoute = isTopDiscoveryRoute;
  }

  void _clearEventFilters() {
    _timeRangeController.state = EventTimeRange.anytime;
    _eventFacetController.state = const <String>{};
    _placeFacetController.state = const <String>{};
  }

  @override
  Widget build(BuildContext context) {
    // Reserve space for the bottom nav (~80px including padding + label).
    const bottomNavReserve = 96.0;

    final searchOpen = ref.watch(searchOpenProvider);
    final searchQuery = ref.watch(searchQueryProvider).trim();
    // "Descobre a cidade" is an OVERLAY on this page, not a route — closing it
    // changes no route, so `_handleDiscoveryRouteChange` never sees it and the
    // filters would outlive the search that set them. Reopening the overlay
    // must start clean, so clear when it closes.
    //
    // Opening a result does not come through here: tapping a card pushes the
    // detail and leaves the overlay open, which is what keeps the filter alive
    // for the trip there and back.
    ref.listen<bool>(searchOpenProvider, (wasOpen, isOpen) {
      if (wasOpen == true && !isOpen) _clearEventFilters();
    });
    final l10n = Lt.of(context);
    // PROD-2671: floating entry point to the Map page. Now shown to **all
    // users** on every platform (web + native). Previously admin-gated for
    // pre-release dogfooding; opened to everyone in this release (ship-gated —
    // older installs never had this un-gated logic, so the Map only appears for
    // this app version onward). The `/map` route itself was always public; the
    // Map is not in the bottom nav.

    // PROD-1977: the page owns the scrollable via [ShellSliverHost],
    // which reads chrome / controller / refresh metadata from the
    // [ShellSliverScope] set up by [DiscoveryShell]. The page emits one
    // sliver containing the legacy non-scrolling Column wrapped in
    // [PageContent] (preserves the desktop 480-px max-width column).
    return PopScope(
      // PROD-1791: when the action-bar search overlay is open, intercept
      // the system / browser back so it closes the overlay (same effect
      // as the inline X) instead of trying to pop the route. Without
      // this, back from `/discovery` with results visible has no
      // intuitive target — search-open is page-local state, not
      // URL-encoded — and the user is stuck unless they spot the X.
      canPop: !searchOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ref.read(searchOpenProvider.notifier).state = false;
        ref.read(searchQueryProvider.notifier).state = '';
      },
      // Expose the feed controller to the page-level siblings that observe
      // feed scroll (map button, default-content pager, search overlay). Wraps
      // the whole Stack so the `Positioned` map button — a sibling of the
      // scrollable, not a descendant — can still reach it. PROD-1899.
      child: FeedScrollControllerScope(
        controller: _feedController,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ShellSliverHost(
              controller: _feedController,
              slivers: [
                SliverToBoxAdapter(
                  child: PageContent(
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          16,
                          16,
                          16,
                          bottomNavReserve,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // PROD-1983: re-opens the typeahead overlay (preserving
                            // query + filter) when the user back-arrows out of a
                            // detail page they reached via a typeahead result.
                            // Zero-size; subscribes to `discoveryNavObserver`.
                            const TypeaheadResumer(),
                            // PROD-2369/PROD-2466: warm the Eventos + Sítios facet
                            // catalogs as soon as Discovery mounts, so the filter
                            // chips are already cached and render instantly when the
                            // user opens "Discover the city". Zero-size.
                            const _FacetCatalogWarmer(),
                            // PROD-1517: Soko wordmark + chat card / Barra. The chat-bar
                            // group (40 px lead + bar + 16 px trail) collapses together
                            // when the action bar's search panel is open.
                            ResearchInvitationBanner(
                              scrollController: _feedController,
                            ),
                            const DiscoveryHeader(),
                            // Step 1 (Procura) — drawn-border rectangle and
                            // GlobalKey live INSIDE [_CollapsibleChatBarGroup]
                            // around just the [DiscoveryChatBar] input box
                            // (the "quadradinho cinzento"), NOT around the
                            // 40-px vertical-padding column. The host's
                            // [_TourProcuraTooltip] reads the GlobalKey's
                            // rect to anchor its connector + card below the
                            // chat-bar input rectangle.
                            _CollapsibleChatBarGroup(searchOpen: searchOpen),
                            // Action bar (search + create-zine + location) with a
                            // section divider above it. The action bar replaces the
                            // standalone `DiscoveryCityPill` — its right-aligned location
                            // pill opens the same picker (`showLocationScopePicker`
                            // writing `cityScopeProvider`) so the city-scoped
                            // shelves keep working unchanged.
                            // Figma redesign — with the search overlay open the
                            // page reads header → search row directly (no
                            // scallop between them); the divider + 30 px gap
                            // belong to the idle home only.
                            if (!searchOpen) ...[
                              const DiscoverySectionDivider(),
                              // Figma node `6346:12056`: 30 px below the scallop. When the
                              // user's selected city is not backend-marked "open"
                              // (`GeoCity.isOpen == false`, PROD-3675), the new-city
                              // expectation-setting hero slots in below the action bar with
                              // 30 px of gap above — see PROD-1849 +
                              // `docs/features/discovery-supported-cities.md`.
                              const SizedBox(height: 30),
                            ] else
                              const SizedBox(height: 12),
                            CityActionBar(
                              showSearchOverlay: searchOpen,
                              searchOverlay: const DiscoverySearchOverlay(),
                              onSearchTap: () {
                                // PROD-3168: "Descobre a cidade" opens the Discover
                                // surface — fires even with no query typed, so it's
                                // separable from `search`.
                                ref
                                    .read(unifiedAnalyticsProvider)
                                    .trackDiscoverOpen(
                                      entryPoint: EntryPoint.homePurpleButton,
                                    );
                                ref.read(searchOpenProvider.notifier).state =
                                    true;
                                // Snapshot the home scroll offset, then reset the
                                // feed behind the overlay to the top so "Descobre a
                                // cidade" always opens from a clean position. The
                                // saved offset is restored if the user closes via
                                // the input's X (see DiscoverySearchOverlay).
                                discoveryFeedScroll.resetForSearch();
                              },
                              // PROD-2221 — Discovery's action bar replaces the
                              // bare magnifier circle with a lilac
                              // "Discover the city" pill and drops the
                              // create-zine pill (the create flow has other
                              // entry points). `/yours` keeps the legacy
                              // circle + create-zine.
                              searchPillLabel: Lt.of(
                                context,
                              ).discoveryActionBarDiscoverCity,
                              showCreateZinePill: false,
                              // The location pill moved up into the chat bar's
                              // bottom row (the old Add-to-Soko slot), so the
                              // lilac "Descobre a cidade" pill now spans the
                              // full row.
                              showLocationPill: false,
                            ),
                            // PROD-2194: hide the new-city hero (illustration +
                            // two CTA pills) once the user is actively searching,
                            // matching the same predicate `_DiscoveryBody` uses to
                            // swap shelves for search results. Otherwise the hero
                            // sat on top of the results in unsupported cities.
                            if (!ref.watch(isCurrentCitySupportedProvider) &&
                                !(searchOpen &&
                                    searchQuery.length >=
                                        kDiscoverySearchMinQueryLength)) ...[
                              const SizedBox(height: 30),
                              const DiscoveryNewCitySection(),
                              const DiscoveryHelpUsActions(),
                            ],
                            const SizedBox(height: 16),
                            // The shelf stack and the search-results section are mutually
                            // exclusive: results take over while the user has typed a
                            // query in the open search panel; otherwise the shelves render
                            // (PROD-1520).
                            const _DiscoveryBody(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // The floating `Mapa` pill + its `map_page_v1` coachmark. Shared
            // with the v2 feed so the two entry points cannot drift; must stay
            // a direct child of this Stack (it returns a `Positioned`) and
            // mounted BEFORE `_CampaignWarmupTrigger` below, whose post-frame
            // callback has to register after the Map spotlight's.
            const DiscoveryMapButtonSlot(),
            // Ticket #8 — fake-door campaign warm-up trigger. Zero-size;
            // mounted LAST in this Stack's children so its post-frame
            // callback registers (and therefore runs) after the Map
            // `SpotlightTrigger` above — see the class doc for why that
            // ordering matters.
            const _CampaignWarmupTrigger(),
          ],
        ),
      ),
    );
  }
}

/// Three-state body switch (PROD-2221):
///   - Search overlay open + typed query (≥ 2 chars) → [SearchResultsSection]
///     (the normal search-results 2-up grid).
///   - Search overlay open + no query → [DefaultContentSection]
///     (the active-filter default feed: Most followed / A acontecer /
///     Perto de ti, vertical grid w/ infinite scroll). Daily Drop and
///     every other shelf are hidden in this state.
///   - Overlay closed (idle Discovery) → [_DiscoveryShelves] (Daily
///     Drop + the existing rich shelf stack, unchanged).
///
/// Pulling the swap into its own consumer keeps the screen-level
/// rebuild scope tight — only this subtree re-renders when the user
/// types or flips the chip.
class _DiscoveryBody extends ConsumerWidget {
  const _DiscoveryBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchOpen = ref.watch(searchOpenProvider);
    final query = ref.watch(searchQueryProvider).trim();
    final selectedCategory = ref.watch(searchCategoryProvider);
    final selectedPlaceFacets = ref.watch(placeTypeFacetFilterProvider);
    final shouldShowSearchResults =
        query.length >= kDiscoverySearchMinQueryLength ||
        selectedCategory == DiscoverySearchCategory.eventos ||
        (selectedCategory == DiscoverySearchCategory.sitios &&
            selectedPlaceFacets.isNotEmpty);
    if (searchOpen) {
      // Leitores (people) renders its own rows — both the typed-search
      // and the suggested-locals browse state live in the section.
      if (selectedCategory == DiscoverySearchCategory.leitores) {
        return const ReadersSearchSection();
      }
      if (shouldShowSearchResults) {
        return const SearchResultsSection();
      }
      return const DefaultContentSection();
    }
    return const _DiscoveryShelves();
  }
}

/// Zero-size warmer (PROD-2369 / PROD-2466). `watch`es the two facet-catalog
/// providers so they start fetching the moment Discovery mounts — well before
/// the user taps "Discover the city". Both are global (non-autoDispose)
/// `FutureProvider`s, so one fetch per app session populates a cache that the
/// Eventos/Sítios filter bars then read instantly. Guest-safe + locale-
/// independent, so there's nothing to invalidate per user/locale. Isolated in
/// its own leaf so resolving the futures doesn't rebuild the whole screen.
class _FacetCatalogWarmer extends ConsumerWidget {
  const _FacetCatalogWarmer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Gate on a token existing before warming. The facet endpoints are
    // auth-gated; firing on a cold load can race the async guest-token mint,
    // go out tokenless → 401, and the global FutureProvider caches that error
    // for the whole session (blank chips). Watch `accessToken != null` — NOT
    // isAuthenticated (guests carry a token but isAuthenticated is false) — so
    // this leaf rebuilds and fires the (now authenticated) fetch the instant
    // the guest mint / token restore completes.
    final hasToken = ref.watch(
      authStateProvider.select((s) => s.accessToken != null),
    );
    if (hasToken) {
      ref.watch(eventCategoryFacetsProvider);
      ref.watch(placeTypeFacetsProvider);
    }
    return const SizedBox.shrink();
  }
}

/// Zero-size fake-door campaign warm-up trigger (ticket #8).
///
/// Watching [campaignServiceProvider] here is what "warms" it up — the same
/// implicit pattern `SpotlightTrigger` relies on for
/// `featureSpotlightServiceProvider` (PROD-2808): a `NotifierProvider`'s
/// `build()` — which fires the local hydrate + the `/active` server fetch —
/// runs on first access, whether that access is a `watch` or a `read`. So
/// this widget both keeps campaign state warmed up for the whole app and
/// decides, at most once per Discovery mount, whether to surface one.
///
/// Fire sequence mirrors `SpotlightTrigger`: a post-frame check, then a 3 s
/// pre-fire delay (same cadence, so the two don't visually collide even
/// when both become eligible on the same load), re-validated at fire time.
/// Gates checked both times:
///   * signed in (a guest's response POST would 401 anyway);
///   * no bottom sheet/dialog on top (`spotlightModalObserver` — covers the
///     daily-drop/weekly-bundle/profiling deep-link sheets and any other
///     modal, e.g. add-to-list);
///   * no feature spotlight already holding the single nudge slot
///     (`featureSpotlightServiceProvider().activeFeatureId`) — this widget
///     is mounted LAST in the screen's Stack (see the call site) so its
///     post-frame callback runs after the Map `SpotlightTrigger`'s, which
///     reserves synchronously in its own `_maybeStart` before this widget's
///     callback fires;
///   * the product tour isn't actively running.
///
/// Does NOT defer to a same-frame push-route deep-link handler (daily drop
/// ready state, weekly bundle overlay) — those push a normal route, not a
/// `PopupRoute`, so `spotlightModalObserver` can't see them. This is the
/// same gap `SpotlightTrigger` already has; not solved here either.
class _CampaignWarmupTrigger extends ConsumerStatefulWidget {
  const _CampaignWarmupTrigger();

  @override
  ConsumerState<_CampaignWarmupTrigger> createState() =>
      _CampaignWarmupTriggerState();
}

class _CampaignWarmupTriggerState
    extends ConsumerState<_CampaignWarmupTrigger> {
  static const Duration _fireDelay = Duration(seconds: 3);

  Timer? _fireDelayTimer;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    spotlightModalObserver.activeModalCount.addListener(_onModalCountChanged);
    WidgetsBinding.instance.addPostFrameCallback(_maybeStart);
  }

  @override
  void dispose() {
    spotlightModalObserver.activeModalCount.removeListener(
      _onModalCountChanged,
    );
    _fireDelayTimer?.cancel();
    super.dispose();
  }

  void _onModalCountChanged() {
    if (!mounted || _started) return;
    if (spotlightModalObserver.activeModalCount.value != 0) return;
    if (_fireDelayTimer != null) return;
    _maybeStart(Duration.zero);
  }

  bool _isBlocked() {
    if (!ref.read(isAuthenticatedProvider)) return true;
    // Master feature gate — fake-door campaigns are admin-only for now
    // (PostHog `fake-door-campaigns` flag, targeted to is_admin).
    if (!ref.read(experimentServiceProvider).enableFakeDoorCampaigns) {
      return true;
    }
    // Admin kill-switch for the auto-surfacing warm-up (menu → toggle).
    if (!ref.read(campaignServiceProvider).warmupEnabled) return true;
    if (spotlightModalObserver.activeModalCount.value > 0) return true;
    if (ref.read(featureSpotlightServiceProvider).activeFeatureId != null) {
      return true;
    }
    final tourStep = ref.read(productTourControllerProvider).step;
    return tourStep != TourStep.idle && tourStep != TourStep.done;
  }

  void _maybeStart(Duration _) {
    if (!mounted || _started || _fireDelayTimer != null) return;
    if (_isBlocked()) return;
    final campaign = ref
        .read(campaignServiceProvider.notifier)
        .nextEligibleCampaign();
    if (campaign == null) return;
    _fireDelayTimer = Timer(_fireDelay, () => _fireNow(campaign));
  }

  void _fireNow(Campaign campaign) {
    _fireDelayTimer = null;
    if (!mounted || _started) return;
    // Re-check everything at fire time — any gate can have flipped during
    // the 3 s delay (a sheet opened, a spotlight fired, the tour started,
    // `_syncFromServer` marked the campaign inactive/already responded).
    if (_isBlocked()) return;
    final service = ref.read(campaignServiceProvider.notifier);
    if (!service.shouldShow(campaign.key)) return;
    if (!service.tryReserve(campaign.key)) return;
    _started = true;
    // `presentCampaign` picks sheet / fullscreen / page from
    // `campaign.presentation`. `CampaignFlowScreen`'s own `initState`
    // re-reserves (idempotent — the slot is already held by this key) and
    // its `dispose` releases it, so nothing further to clean up here.
    presentCampaign(context, ref, campaign);
  }

  @override
  Widget build(BuildContext context) {
    // `ref.listen` both warms `campaignServiceProvider` (see class doc) and
    // retries `_maybeStart` once hydration/the `/active` fetch lands — the
    // initState post-frame callback above runs before that async fetch
    // typically resolves, so without this a late-arriving eligible
    // campaign would never get a second look this session.
    ref.listen<CampaignState>(campaignServiceProvider, (previous, next) {
      if (!_started) _maybeStart(Duration.zero);
    });
    return const SizedBox.shrink();
  }
}

class _DiscoveryShelves extends ConsumerWidget {
  const _DiscoveryShelves();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // PROD-1979 — per-section guest treatment.
    //   • Daily Drop → real (BE-dummy) card behind a blur + a Daily-Drop-
    //     specific "Get your first daily drop" CTA. Owns its own blur
    //     overlay (`DailyDropSection(guestMode: true)`) so the CTA copy
    //     and the blur framing stay coupled to the section.
    //   • Weekly Bundle → hidden entirely for guests (no CTA placeholder).
    //   • Yours → mock list cards behind a centered "Create your first
    //     list" CTA. Title + divider stay sharp; only the cards row
    //     blurs (handled by `DiscoveryShelf.guestOverlay`).
    //   • Highlighted, Near You, Trending, Editor Picks, Spaces, City
    //     Guides → shown clearly (their feeds will accept guest
    //     requests after the parallel BE ticket lands).
    //   • Recommended → same in-shelf blur pattern as Yours; the shelf
    //     itself owns the overlay so the "Recomendado" title reads
    //     above the blurred cards.
    final isGuest = !ref.watch(isAuthenticatedProvider);
    // PROD-1849: when the new-city hero is shown at the top of the page,
    // suppress the "That's all folks" footer at the bottom — the new-city
    // illustration already serves as the page's visual full-stop, and a
    // second cartoon would muddy the message.
    final isCitySupported = ref.watch(isCurrentCitySupportedProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // PROD-1518 — Daily Drop image-template card.
        // PROD-1979 — guests see the BE-provided dummy drop behind a blur
        // with a Daily-Drop-specific CTA overlay.
        DailyDropSection(guestMode: isGuest),
        // PROD-1521 — History grid (recent activity).
        // Gated by `EnvironmentConfig.discoveryHistoryGridEnabled` (default
        // off). When the kill switch is false the widget is never built, so
        // `historyGridProvider` is never watched and `GET /users/me/activity`
        // is never called. Flip the const to true to re-enable.
        if (EnvironmentConfig.discoveryHistoryGridEnabled) const HistoryGrid(),
        // PROD-1522 / PROD-1963 shelves. The previous combined "Near
        // you" shelf has been split into "Happening" (events) and "Near
        // you" (places), both promoted ahead of Weekly Bundle so the
        // proximity feed is the user's first scroll target. Em destaque
        // sits below them; Espaços lands between Recomendado and the
        // out-of-scope Jardins shelf per
        // `figma-cache/screens/discovery/shelves.md`. Verificados is
        // dropped per product decision.
        //
        // The dotted divider between shelves (Figma node `6144:5109`,
        // 30 px / dotted / 30 px) is owned by each shelf as a *leading*
        // divider — embedded inside the shelf's render so it disappears
        // together with the shelf when the BE returns empty/error and
        // the shelf collapses to `SizedBox.shrink()`. The footer follows
        // the same rule.
        // PROD-3927 — admin-only discovery feed shelves. Self-hide for
        // non-admins; placed first so admins can evaluate the Discovery API's
        // for_you ranking (per entity type, with horizontal infinite scroll)
        // against the shelves below.
        const DiscoveryFeedShelf(
          entityTypes: 'events',
          shelfId: 'discovery_events',
          title: 'Discovery — Events',
        ),
        const DiscoveryFeedShelf(
          entityTypes: 'venues',
          shelfId: 'discovery_venues',
          title: 'Discovery — Venues',
        ),
        const HappeningShelf(),
        const NearYouPlacesShelf(),
        // PROD-1518 — Weekly Bundle image-template card.
        // PROD-1979 — hidden entirely for guests (no CTA placeholder).
        if (!isGuest) const WeeklyBundleSection(),
        const HighlightedShelf(),
        const TrendingShelf(),
        // Locals — suggested people, deliberately right after "Mais
        // seguidas"; its see-more continues on the find-people page.
        const LocalsShelf(),
        const EditorPicksShelf(),
        // PROD-1979 — Recommended for guests shows the cards behind a
        // super-soft σ=1.5 blur with a centered sign-in CTA; the rest
        // of the trailing shelves (Espaços, City Guides) stay visible.
        RecommendedShelf(guestMode: isGuest),
        const SpacesShelf(),
        const CityGuidesShelf(),
        // PROD-1980 — end-of-scroll CTAs (Add to Soko / Talk to Soko).
        // The footer drops its 104 px trailing reserve when followed by
        // [DiscoveryEndActions]; the screen's existing 96 px bottomNavReserve
        // owns the gap below the pills.
        if (isCitySupported) const DiscoveryFooter(hasTrailingGap: false),
        const DiscoveryEndActions(),
      ],
    );
  }
}

/// Wraps the chat bar with its surrounding spacing so the leading 40 px
/// gap and trailing 16 px gap collapse together with the bar when the
/// action bar's search panel opens. Keeping the gaps inside the same
/// `AnimatedSize` avoids a "shrunk bar with two big empty SizedBoxes"
/// gap during the transition.
class _CollapsibleChatBarGroup extends ConsumerWidget {
  final bool searchOpen;
  const _CollapsibleChatBarGroup({required this.searchOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchBarKey = ref.watch(productTourKeysProvider).searchBar;
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: searchOpen
          // Fully collapsed while the search overlay is open — the mock
          // reads header → search row directly; the spacing between them
          // is owned by the screen's single gap below.
          ? const SizedBox(width: double.infinity, height: 0)
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 40),
                // The product-tour step-1 rectangle wraps ONLY the
                // chat-bar input box (the grey/Soko-Shade5 surface),
                // not the surrounding 40-px gaps. Per Figma frame
                // 9378 + the user's reference shot at
                // 2026-05-30 153428: the rectangle's edges are the
                // chat-bar input box's edges.
                TourSecondaryHighlight(
                  activeOnSteps: const {TourStep.searchBar},
                  borderRadius: 6,
                  // Matches the Procurar card's outer-rect stroke (6 px)
                  // and the connector line — per user spec (2026-05-30)
                  // all step-1 strokes share the same thickness.
                  strokeWidth: 6.0,
                  // Start drawing at the bottom-left area of the rect
                  // (50 % around the perimeter from the RRect's
                  // natural top-right start) so the rect's ink
                  // begins at the same point where the connector
                  // tracinho subsequently starts — visually one
                  // continuous stroke: rect traces CW around the
                  // chat bar, returns to bottom-left, connector
                  // continues downward to the card. Per user spec
                  // (2026-05-30): "o retângulo azul quando desenha
                  // deve começar pelo o conector, e fazer com que
                  // fique fluído".
                  startFraction: 0.5,
                  // Hide the rectangle the moment the user taps
                  // Seguinte and the cursor starts its trip to
                  // Descobre-a-cidade. Per user spec: "o retângulo
                  // azul do passo do procurar deve desaparecer assim
                  // que eu clico em seguinte". Without this, the
                  // chat-bar rectangle stays lit through the entire
                  // ~2.2 s cursor flight + hover dwell because
                  // `state.step` only flips to `discoverCity` after
                  // `_runCursorClick` returns.
                  hideDuringCursorTransition: true,
                  child: KeyedSubtree(
                    key: searchBarKey,
                    child: const DiscoveryChatBar(
                      enableTypeaheadOnFocus: true,
                      showDiscoveryActions: true,
                    ),
                  ),
                ),
                // Figma `6144:4995`: 40 px between the chat bar and the
                // scallop divider that follows.
                const SizedBox(height: 40),
              ],
            ),
    );
  }
}
