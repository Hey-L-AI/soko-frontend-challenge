// PROD-4005 — the server-driven Discovery feed page.
//
// A **sibling page inside `DiscoveryShell`, not a fork of it** (D45): deep
// links, scroll restoration, bottom nav and the search overlay already live in
// the shell, and forking would mean reimplementing all of it — and would turn
// deleting the old page into an untangle rather than a deletion. Only the page
// *content* forks.
//
// Since PROD-1977 the shell owns no `CustomScrollView`; a page builds its own
// via `ShellSliverHost`, which supplies the chrome reservation, scroll
// controller, physics and pull-to-refresh from `ShellSliverScope`. Note that
// `DiscoveryScreen` itself is still the legacy shape — one `SliverToBoxAdapter`
// wrapping a non-scrolling `Column` — which is exactly what defeats viewport
// culling. It is the page next door and the tempting template; it is the wrong
// one to copy for a cursor-paged feed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/page_layout.dart';
import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/services/discovery_session_tracker.dart';
import '../../../../providers/api_provider.dart';
import '../../../../data/models/feed_home.dart';
import '../../../../shared/widgets/search_overlay.dart'
    show kSearchOverlayDefaultDebounce;
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/auth_provider.dart';
import '../../../../shared/widgets/search/unified_search_overlay.dart';
import '../../../../shared/widgets/soko_pinned_header_block.dart';
import '../../../../shared/widgets/soko_tag_chip.dart' show kSokoTagBarMargin;
import '../../../../shared/widgets/soko_pinned_header_host.dart';
import '../../../../shared/widgets/trailing_gap.dart';
import '../../providers/event_filters_provider.dart';
import '../../providers/place_filters_provider.dart';
import '../../providers/search_results_provider.dart'
    show kDiscoverySearchMinQueryLength;
import '../../widgets/discovery_map_button_slot.dart';
import '../../widgets/event_filters_bar.dart';
import '../../widgets/place_filters_bar.dart';
import '../../widgets/sections/search_results_section.dart';
import '../../widgets/feed_scroll_controller_scope.dart';
import '../../widgets/shell_sliver_page.dart';
import '../providers/feed_filter_provider.dart';
import '../providers/feed_home_provider.dart';
import '../providers/feed_chrome_providers.dart';
import '../providers/feed_top_slot_provider.dart';
import '../providers/procura_search_providers.dart';
import '../utils/feed_debug_blocks.dart';
import '../widgets/feed_block_divider.dart';
import '../widgets/feed_block_dispatcher.dart';
import '../widgets/feed_filter_bar.dart';
import '../widgets/feed_loading_state.dart';
import '../widgets/feed_location_band.dart';
import '../widgets/feed_notice_states.dart';
import '../widgets/feed_page_content.dart';
import '../widgets/feed_pinned_header.dart';
import '../widgets/feed_procura_results.dart';
import '../widgets/feed_procura_row.dart';
import '../widgets/feed_top_header.dart';
import '../widgets/feed_top_cards.dart';

/// Whether Procura has taken the page over from the feed.
///
/// **Pure, and top-level, precisely so both callers can use it and a test can
/// reach it.** `build` obtains its inputs by watching; the scroll listener
/// obtains them by reading, because a listener must not register build
/// dependencies. Folding the rule back into the watching path would put that
/// difference beyond reach again — which is how the first version shipped with
/// a `ref.watch` on a scroll callback and nothing red.
///
/// `leitores` takes over with no query at all: its section answers the
/// no-query case itself with suggested locals.
///
/// **A selected facet counts as a query** (Zé, 2026-09-03). The rule was
/// originally "the feed stays until a query exists", which left the facet
/// strips the morph brings in — the time range, the event categories, the place
/// types — visibly enabled and doing nothing until the reader typed. A tapped
/// chip is intent, so it takes over exactly as typing does. `SearchResultsSection`
/// already supports the empty-query search this produces: its own
/// `shouldSearchEmptyEvents` / `shouldSearchEmptyPlaces` branches predate this
/// and are unchanged.
///
/// Which facets belong to which category lives here rather than at the two call
/// sites, so the scroll listener and `build` cannot disagree about what counts.
/// Unified-search: Procura takes over the feed as soon as there is a query long
/// enough to search on. The category chips are now toggle FILTERS over the
/// grouped results (not a takeover trigger), and facets no longer live on the
/// typed search — so the rule collapses to "is there a query?".
bool feedProcuraTakesOver({required bool procura, required String query}) {
  if (!procura) return false;
  return query.trim().length >= kDiscoverySearchMinQueryLength;
}

/// Whether the FACET strips have taken the page over from the feed.
///
/// **A selected facet counts as a query** (Zé, 2026-09-03) — the rule the
/// unified-search cut removed along with the strips themselves, restored here
/// on the surface the strips came back to. A chip left visibly enabled and
/// doing nothing until the reader types is the defect this exists to prevent.
///
/// The corpus is the selected FEED FILTER, not a search category: the strips
/// hang off the feed's own chip row now, so `Eventos` owns the time range plus
/// the event categories and `Sítios` owns the place types. `Zines` and
/// `Pessoas` carry no strip, so there is nothing here that could stand in for a
/// query and they can never take over.
///
/// **It does not change what the feed is composed of.** The feed request is
/// untouched; a live facet swaps the feed OUT for `SearchResultsSection`'s
/// results grid and putting the facets back restores it — the same two-state
/// page the query path already uses.
///
/// Pure and top-level for the same reason [feedProcuraTakesOver] is: `build`
/// obtains its inputs by watching and the scroll listener by reading, and one
/// shared rule is what keeps those two from disagreeing about what counts.
bool feedFacetsTakeOver({
  required FeedFilter filter,
  required EventTimeRange timeRange,
  required Set<String> eventFacets,
  required Set<String> placeFacets,
}) => switch (filter) {
  FeedFilter.events =>
    timeRange != EventTimeRange.anytime || eventFacets.isNotEmpty,
  FeedFilter.venues => placeFacets.isNotEmpty,
  FeedFilter.zines || FeedFilter.people => false,
};

/// `surface` reported by the feed's facet strips on `filter_applied` /
/// `filters_reset`. Distinct from the legacy page's `discover_events` /
/// `discover_places`, which the same two bars report elsewhere.
const String kFeedEventFacetSurface = 'feed_events';
const String kFeedPlaceFacetSurface = 'feed_venues';

/// `source` reported by the feed's search events (`search_opened`,
/// `search_submitted`, `search_result_click`). Kept as `procura` — the name the
/// control has carried since PROD-4081 — so the existing `search_submitted`
/// series is continuous across the unified-search rewrite.
const String kFeedSearchSource = 'procura';

/// PROD-4179 — how long the filter row takes to become the search chrome, and
/// to come back. The same 240 ms the band→bar hand-over uses, so the two
/// animations on this page's chrome move at one speed.
const Duration kFeedProcuraMorph = Duration(milliseconds: 240);

/// PROD-4316 — how long the filter row takes to grow out from under the bar.
///
/// The same 240 ms as the band→bar hand-over, deliberately: they are two parts
/// of one header, and a row that unfolded on its own timing would read as a
/// separate surface arriving.
const Duration kFeedFilterRowReveal = Duration(milliseconds: 240);

/// Distance from the bottom at which the next page is requested. Matches the
/// existing Discovery pager (`default_content_section.dart`).
const double kFeedLoadMoreThreshold = 800;

/// The feed's pinned chrome — **one block in two states**: the location band
/// when it first pins, the bar once it has taken over, and the transition
/// between them. Keyed so a test can measure the block rather than inferring
/// its extent from the widgets inside it.
///
/// Which state it is in is `find.byType(FeedPinnedHeader)`, not this key: the
/// bar's chrome only mounts once the transition starts.
const Key kFeedPinnedChromeKey = ValueKey('feed-pinned-chrome');

/// The clip that reveals the filter row as it grows out from under the bar.
///
/// Keyed so a test can measure **the revealed height** rather than the block's.
/// The block's height also moves while the gap above the row animates, so it
/// cannot tell "the row grows" from "the gap grows" — a mutation that snapped
/// the row to full height on the first frame passed against it (PROD-4316).
const Key kFeedFilterRowClipKey = ValueKey('feed-filter-row-clip');

/// The opaque strip over the status-bar inset. Keyed so a test can assert it
/// is there and what colour it is, at an offset where no header is up.
const Key kFeedNotchBandKey = ValueKey('feed-notch-band');

/// Bottom padding so the last block clears the floating bottom nav.
const double _kBottomNavReserve = 96;

class DiscoveryFeedV2Screen extends ConsumerStatefulWidget {
  const DiscoveryFeedV2Screen({super.key});

  @override
  ConsumerState<DiscoveryFeedV2Screen> createState() =>
      _DiscoveryFeedV2ScreenState();
}

class _DiscoveryFeedV2ScreenState extends ConsumerState<DiscoveryFeedV2Screen> {
  /// Page-owned, like `DiscoveryScreen._feedController`, so page-level siblings
  /// of the scrollable (the pinned header's overlay, the filter bar) can reach
  /// it without going through the shell.
  final ScrollController _controller = ScrollController();

  /// Scroll offset at which the INLINE FILTER ROW's trailing edge reaches the
  /// top of the viewport.
  ///
  /// Written during layout by the sentinel sliver in [_host] and read by the
  /// `SokoPinnedHeaderHost`'s `revealAfter` getter in [build]. `infinity` until
  /// the first layout, so the pinned header stays hidden rather than flashing
  /// on before anything is measured.
  ///
  /// **The bar reveals a whole block-height BEFORE this**, not at it — see the
  /// `revealAfter` in [build]. The rule the trigger enforces is "never two
  /// filter bars on screen", and the row stops being on screen when the header
  /// covers it, not when it leaves the viewport.
  double _filterRowScrollEnd = double.infinity;

  /// Scroll offset at which the TOP HEADER's trailing edge — the scallop, and
  /// therefore the bottom of [FeedLocationBand] — reaches the top of the
  /// viewport. Written by the second sentinel in [_host].
  ///
  /// The sticky overlay's trigger is this minus the band's own height minus
  /// where the block puts its content, so the band pins at the exact offset
  /// where the in-flow copy arrives at the pinned position. `infinity` until
  /// the first layout, so it stays hidden rather than flashing on top of a
  /// header that is still on screen.
  double _topHeaderScrollExtent = double.infinity;

  /// Whether the pinned chrome should be showing the BAR (D32) rather than the
  /// location band.
  ///
  /// The block reads this as the target of its own transition, so flipping it
  /// starts an animation rather than swapping one widget for another — which
  /// is what lets the location slide from one header to the next instead of
  /// disappearing from one and reappearing in the other.
  ///
  /// A `ValueNotifier` rather than `setState` so the hand-over rebuilds the
  /// header and not the page's slivers underneath it.
  final ValueNotifier<bool> _barMode = ValueNotifier<bool>(false);

  /// The bar block's resting height. Build-derived (it reads `MediaQuery`), and
  /// genuinely constant between builds, so a snapshot is honest here.
  double _closedBarBlockHeight = 0;

  /// Scroll offset at which the BAR takes over from the inline filter row.
  ///
  /// **A getter, and it has to be** — the same discipline `revealAfter` is
  /// documented with. `_filterRowScrollEnd` is rewritten by its sentinel on
  /// every LAYOUT, and layout runs long after the `build` that preceded it: on
  /// this page it settles from 522.85 to 257.18 once the ritual-card slot
  /// reports it has nothing to show and its `TrailingGap` collapses. A value
  /// snapshotted in `build` is that first number forever, because nothing
  /// rebuilds the page afterwards — which is the same "read it live, never
  /// cache it" trap the sentinels' own comments warn about.
  ///
  /// It is also the exact boundary the two filter-change behaviours split on:
  /// below it the reader can still see the inline row, at or above it the bar
  /// is covering it.
  double get _barRevealOffset => _filterRowScrollEnd - _closedBarBlockHeight;

  /// Non-null while a filter change is in flight: the offset the page must be
  /// holding when the new feed arrives.
  ///
  /// **It also switches on the reserve sliver**, and that is the load-bearing
  /// half. Changing filter empties the block list, so without a reserve the
  /// page collapses to shorter than the viewport, `maxScrollExtent` goes to 0
  /// and the offset is slammed to the top — the "abrupt jump" (Zé, 2026-09-01).
  /// Holding a scroll offset over an empty feed requires the extent to still be
  /// there; there is nothing else to stand on.
  double? _filterChangeScrollTarget;

  /// PROD-4179 — the last offset the reader held while the FEED was on screen.
  ///
  /// The blank space under short search results is exactly this tall, so the
  /// page cannot collapse under the reader and throw them to the top (Zé,
  /// 2026-09-03: typing into a search opened halfway down the feed should not
  /// move you). Captured continuously rather than at the swap — by the time
  /// results are observable, the collapse would already have happened.
  ///
  /// It stops updating while results show, because [_onScroll] returns before
  /// it does. That is deliberate: the reserve stays constant for as long as it
  /// is needed, so scrolling inside the results cannot move the ground under
  /// them.
  double _lastFeedOffset = 0;

  /// Scroll offset at which the chrome sliver BEGINS, so `end - start` is its
  /// measured height.
  ///
  /// The second sentinel exists because Procura mode makes the chrome taller by
  /// an amount nothing can compute up front — the facet strips are provider-fed
  /// widgets of unknown height. Estimating it would put the bar's takeover
  /// threshold out by however wrong the estimate was, and the symptom of that is
  /// two search chromes on screen at once. Measuring both edges costs one more
  /// zero-extent sliver and cannot drift.
  double _filterRowScrollStart = 0;

  /// The chrome sliver's measured height, or the filter row's own height until
  /// the first layout has run.
  double get _chromeExtent {
    final measured = _filterRowScrollEnd - _filterRowScrollStart;
    return measured.isFinite && measured > 0 ? measured : kFeedFilterBarHeight;
  }

  /// PROD-4179 — the search field's text, owned by the PAGE.
  ///
  /// It cannot live in `FeedProcuraRow`: that row is mounted twice (inline and
  /// in the pinned header) and two controllers would mean two different queries
  /// depending on which copy the user had typed into. `SearchOverlay` owns its
  /// own for the opposite reason — it is only ever mounted once.
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;

  /// The discovery-session tracker, captured in [initState] so [dispose] can
  /// end the visit without touching `ref` (illegal post-dispose). Safe to hold:
  /// the provider is `keepAlive`, so the instance outlives this screen.
  DiscoverySessionTracker? _sessionTracker;

  /// Dedupe state for `page_presented` (PROD-4303): the run id and block count
  /// of the last page reported as rendered, so the `feedHomeProvider` listener
  /// — which also fires for `isLoadingMore` flips and error writes — emits once
  /// per landed page rather than once per state write.
  String? _lastPresentedRunId;
  int _lastPresentedBlockCount = 0;

  /// Whether the facet strips are currently showing results instead of the
  /// feed. The edge this flips on is what [_syncFacetContext] reports.
  bool _facetsTookOver = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
    // Acquire the 'feed' surface for this visit (PROD-4257). The tracker
    // counts HOLDERS, not calls: the session opens on the first acquire and
    // stays open while any discovery surface (this feed, a bundle see-all)
    // still holds it, so a feed → see-all hand-over is one visit.
    //
    // Kept alongside the VisibilityDetector in [build] (PROD-4303): the
    // detector's callbacks are sampled on `VisibilityDetectorController`'s
    // global updateInterval, so the first visibility report can lag the first
    // frame. `acquireSurface` is idempotent per tag, so the detector
    // re-asserting an already-held surface is a no-op.
    final tracker = ref.read(discoverySessionTrackerProvider);
    _sessionTracker = tracker;
    tracker.acquireSurface('feed');
  }

  @override
  void dispose() {
    // End the visit before tearing down — flushes session_end + any buffered
    // events. Uses the captured tracker, never `ref`, which is dead here.
    //
    // `endSession`, deliberately NOT `releaseSurface('feed')`: this screen
    // disposing means the discovery stack is going away, so every holder is
    // cleared and the visit closes IMMEDIATELY — no 800 ms close-linger left
    // pending (which a widget test's `!timersPending` would trip on). Usually
    // a no-op anyway: the VisibilityDetector's `visibleFraction == 0` callback
    // has already released the surface (and the linger has closed the visit as
    // `screen_hidden`) by the time a kept-alive screen is actually torn down.
    _sessionTracker?.endSession(reason: 'disposed');
    _controller.removeListener(_onScroll);
    _controller.dispose();
    _barMode.dispose();
    _searchDebounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Debounced write into [procuraSearchQueryProvider].
  ///
  /// Deliberately a copy of `_SearchOverlayState`'s, not a shared helper: the
  /// difference is which widget owns the controller, and factoring the timer
  /// out would not remove that. The 600 ms is the shared
  /// [kSearchOverlayDefaultDebounce] so the two cannot drift on the number that
  /// matters.
  void _onSearchChanged() {
    final trimmed = _searchController.text.trim();
    if (trimmed.isEmpty) {
      _searchDebounce?.cancel();
      _setQuery('');
      return;
    }
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      kSearchOverlayDefaultDebounce,
      () => _setQuery(trimmed),
    );
  }

  void _setQuery(String value) {
    if (!mounted) return;
    final notifier = ref.read(procuraSearchQueryProvider.notifier);
    if (notifier.state != value) notifier.state = value;
  }

  void _onScroll() {
    // PROD-3058 — the shell's controller can have more than one attached
    // position while a detail route sits on top of Discovery, and
    // `controller.position` then throws `StateError: Too many elements` in
    // release (the debug asserts that would catch it are stripped). Guard on
    // `positions.length` the way scroll_memory_observer and the existing pager
    // already do.
    if (_controller.positions.length != 1) return;

    // PROD-4316 — scrolling the feed puts the filter row away (Zé).
    //
    // **Above the paging guards below, deliberately.** Those return early for
    // reasons that have nothing to do with the row (a filter change in the air,
    // Procura showing results), and the row would then survive a scroll in
    // exactly the states where it is most in the way.
    //
    // **Gated on `userScrollDirection`**, so this is the reader's own scroll
    // and not the page's. `_onFilterChanged` animates the offset after a filter
    // change, and D38 already closes the row on selection — without the gate
    // that programmatic scroll would be the thing "closing" it, which is both
    // invisible in the common case and wrong in the uncommon one.
    //
    // Its coarser sibling still stands: `onVisibilityChanged` closes the row
    // when the pinned bar itself leaves, because a row hanging under a bar that
    // is no longer there is not a state the design has.
    if (_controller.position.userScrollDirection != ScrollDirection.idle &&
        ref.read(feedFilterBarOpenProvider)) {
      _closeFilters();
    }

    // NOTE: unlike the legacy Discovery pager, this deliberately does NOT skip
    // paging for guests *in general*. Guests are served the feed (D27); the
    // backend decides what they see via `blurred`, and the client applies no
    // policy of its own.
    //
    // ⚠️ **The one exception is the sign-in-gated filter** (PROD-4445). There
    // Not while a filter change is in the air. The reserve sliver deliberately
    // keeps the page's extent open over an EMPTY feed, which puts the end of
    // the page inside the trigger distance — so without this the switch fires
    // a page request built from the OUTGOING feed's cursor. The notifier's
    // `_fetchVersion` guard would drop the answer, so this costs a wasted
    // round trip rather than a wrong page; it is still a round trip nobody
    // asked for, on the one screen where the user is waiting for another.
    if (_filterChangeScrollTarget != null) return;

    // Nor while Procura is showing results: the feed is off screen, and its
    // pager would fetch a page nobody can see. The results run their own
    // load-more from a visibility detector in their footer.
    //
    // ⚠️ `ref.read`, via the pure predicate — NOT `_procuraBody`, which
    // watches. A scroll listener runs outside `build`, and `WidgetRef.watch`
    // there **subscribes**: `flutter_riverpod` 2.6.1's `watch` asserts only
    // that the element is still mounted (`listen` is the one that asserts
    // `debugDoingBuild`), so it does not throw — it quietly registers a
    // dependency whose callback is `markNeedsBuild`, from a callback that runs
    // on every scroll frame. Reviewed as a crash; it is not one on this
    // version, which is worth knowing before someone "restores" the shorter
    // spelling. It is still wrong: dependency bookkeeping belongs to the build
    // cycle, not to a listener.
    if (feedProcuraTakesOver(
          procura: ref.read(feedProcuraModeProvider),
          query: ref.read(procuraSearchQueryProvider),
        ) ||
        feedFacetsTakeOver(
          filter: ref.read(feedFilterProvider),
          timeRange: ref.read(eventTimeRangeProvider),
          eventFacets: ref.read(eventFacetFilterProvider),
          placeFacets: ref.read(placeTypeFacetFilterProvider),
        )) {
      return;
    }

    final pos = _controller.position;
    // The feed is what is on screen, so this is the offset worth holding if a
    // search replaces it. Recorded here rather than at the swap: by then the
    // collapse has already clamped it away.
    _lastFeedOffset = pos.pixels;
    if (pos.maxScrollExtent - pos.pixels > kFeedLoadMoreThreshold) return;

    // context_changed for the page fetch this is about to trigger (PROD-4303).
    // Gated on the same conditions `loadMore` no-ops on — otherwise this
    // listener, which runs every scroll frame inside the threshold, would emit
    // one `page:N` per frame while a fetch is already in flight or the feed is
    // exhausted. `+ 2`: page 1 is the initial build, and `requestedCursors`
    // counts only cursors already sent, so the fetch being triggered here is
    // ordinal (sent + 2).
    final feedState = ref.read(feedHomeProvider).valueOrNull;
    if (feedState != null &&
        !feedState.isLoadingMore &&
        feedState.loadMoreError == null &&
        feedState.hasMore &&
        !feedState.requestedCursors.contains(feedState.nextCursor)) {
      _sessionTracker?.contextChanged(
        context: 'page:${feedState.requestedCursors.length + 2}',
      );
    }

    // Fire-and-forget — the notifier's own `isLoadingMore` guards re-entry.
    ref.read(feedHomeProvider.notifier).loadMore();
  }

  /// D32 follow-up (Zé, 2026-09-01) — what a filter change does to the scroll.
  ///
  /// Two behaviours, split on whether the reader can still SEE the inline
  /// filter row, which is exactly [_barRevealOffset]:
  ///
  /// - **Row still visible** — hold the offset exactly. The feed area below
  ///   simply goes empty while the new one loads. Nothing moves under the
  ///   reader's thumb.
  /// - **Past the row** — the old content goes, and the page lands at the top
  ///   of the feed, which is where the bar takes over. Instant, not animated:
  ///   animating a page whose content has just been emptied reads as a glitch.
  ///   The bar is up before and after and never blinks, because the target IS
  ///   its reveal threshold and the comparison is `>=`.
  void _onFilterChanged() {
    if (_controller.positions.length != 1) return;
    final pos = _controller.position;
    if (!pos.hasPixels) return;
    // `infinity` until the first layout has measured the row. Nothing to hold
    // onto, so leave the page alone rather than guess.
    if (!_barRevealOffset.isFinite) return;

    final target = pos.pixels >= _barRevealOffset
        ? _barRevealOffset
        : pos.pixels;
    setState(() => _filterChangeScrollTarget = target);

    // After the frame, so the reserve sliver this just switched on has been
    // laid out — `jumpTo` clamps to `maxScrollExtent`, and before the reserve
    // exists that extent is still the collapsed one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_controller.positions.length != 1) return;
      final p = _controller.position;
      if (!p.hasPixels) return;
      final clamped = target.clamp(p.minScrollExtent, p.maxScrollExtent);
      if ((p.pixels - clamped).abs() > 0.5) p.jumpTo(clamped);
    });
  }

  /// PROD-4303 — emit `context_changed` when the facets take the feed over, or
  /// give it back.
  ///
  /// The ledger's `context_changed` covers "filter / refresh / pagination", and
  /// a facet selection is the third way this page swaps what it is showing —
  /// alongside the filter chips (`filter:<name>`) and slate paging
  /// (`page:slate`). Without it a session's events jump from feed impressions
  /// to nothing, with no recorded reason: the reader is looking at a results
  /// grid the ledger has no idea they asked for.
  ///
  /// **Edge-triggered on the boolean, not on the selection.** Every chip tap
  /// while results are already up keeps the same context — the PostHog
  /// `filter_applied` event carries which chip moved. What this marks is the
  /// boundary.
  void _syncFacetContext() {
    final takeOver = feedFacetsTakeOver(
      filter: ref.read(feedFilterProvider),
      timeRange: ref.read(eventTimeRangeProvider),
      eventFacets: ref.read(eventFacetFilterProvider),
      placeFacets: ref.read(placeTypeFacetFilterProvider),
    );
    if (takeOver == _facetsTookOver) return;
    _facetsTookOver = takeOver;
    _sessionTracker?.contextChanged(
      context: takeOver
          ? 'facets:${ref.read(feedFilterProvider).name}'
          : 'facets:cleared',
    );
  }

  /// The pinned header's filters button: **put the chrome away, or bring it
  /// back** (Zé, 2026-09-03).
  ///
  /// One control, two chromes, and it always collapses whatever is showing:
  ///
  ///  * in Procura mode it leaves the search AND closes the row, landing the
  ///    reader on the plain feed in one tap;
  ///  * otherwise it toggles the filter row, which it did not do before — it
  ///    only ever opened it, so a reader who revealed it by accident had to tap
  ///    outside or scroll back to the top.
  void _toggleFilters() {
    if (ref.read(feedProcuraModeProvider)) {
      _exitProcura();
      _closeFilters();
      return;
    }
    final open = ref.read(feedFilterBarOpenProvider.notifier);
    open.state = !open.state;
  }

  void _closeFilters() =>
      ref.read(feedFilterBarOpenProvider.notifier).state = false;

  /// Unified-search (Rafael): tapping the Procura circle opens the focused
  /// search OVERLAY (dimmed background + pinned input), the same experience
  /// onboarding and the library use — instead of the in-page morph. The overlay
  /// owns its own query + chip state, so nothing on the feed changes underneath.
  /// The morph machinery (`feedProcuraModeProvider`, `FeedProcuraRow`'s `t > 0`
  /// growth) is left in place but dormant; the filter row it renders at rest is
  /// still the entry point.
  void _openSearchOverlay() {
    final analytics = ref.read(unifiedAnalyticsProvider);
    // PROD-4303 measurement — opening search is a user action, and until now it
    // was the only one on this page that left no trace at all.
    analytics.trackSearchOpened(source: kFeedSearchSource);
    openUnifiedSearchOverlay(
      context,
      hintText: Lt.of(context).discoveryActionBarSearchHint,
      guestWall: true,
      heroTag: kFeedSearchHeroTag,
      // **This is where `search_submitted` comes from now.** The page still
      // holds a `procuraSearchQueryProvider` listener's worth of history in its
      // comments, but the overlay owns its own query — so the listener that
      // used to emit this never fired again after the unified-search rewrite,
      // and every search typed on the feed went uncounted. Gated on the same
      // minimum length that actually triggers a fetch, so a one-character pause
      // is not counted as a search; the overlay's own debounce means once per
      // settled query rather than per keystroke.
      onSearch: (query) {
        final trimmed = query.trim();
        if (trimmed.length < kDiscoverySearchMinQueryLength) return;
        analytics.trackSearchSubmitted(
          searchTerm: trimmed,
          source: kFeedSearchSource,
        );
      },
      // `false` — record the tap, then let the overlay route as it always
      // does. Returning true would make this host responsible for navigation.
      onOpen: (row) {
        analytics.trackSearchResultClick(
          surface: kFeedSearchSource,
          itemType: row.category?.name,
          itemName: row.title,
        );
        return false;
      },
    );
  }

  /// Leave Procura mode.
  ///
  /// **It does not touch the scroll position, and that is the fix rather than
  /// the omission.** Two cases, and the page already answers both:
  ///
  ///  * nothing moved the feed — entering no longer scrolls either, so the
  ///    reader is exactly where they were and there is nothing to restore;
  ///  * a category chip moved the feed filter — `_onFilterChanged` already ran
  ///    and applied the page's own rule (hold the offset while the row is
  ///    visible, else land where the bar reveals, which IS the top of the feed
  ///    content). Zé's ruling was "keep the selection, land at the top"; that
  ///    rule delivers it in the feed's own vocabulary.
  ///
  /// An earlier version jumped to literal 0 here and fought that rule — two
  /// post-frame callbacks racing for the same position, which is how it ended
  /// up neither at 0 nor where the filter change had put it.
  void _exitProcura() {
    if (!ref.read(feedProcuraModeProvider)) return;
    ref.read(feedProcuraModeProvider.notifier).state = false;
    _searchDebounce?.cancel();
    _searchFocus.unfocus();
    _resetSearchState();
  }

  /// Clear everything a search leaves behind.
  ///
  /// The same three the pushed screen cleared on pop, plus the field itself.
  /// The facets are **shared** with "Descobre a cidade" (D123 forks only the
  /// category), so leaving a `Música` chip set here would silently filter that
  /// surface afterwards.
  void _resetSearchState() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _setQuery('');
    _clearFacets();
  }

  /// Drop every facet selection. Used on the way out of a search and on a feed
  /// filter change.
  ///
  /// **Deliberately NOT called from [dispose].** The three providers are
  /// top-level and outlive this screen, and by the time a test's (or the app's)
  /// container is being torn down the controllers may already be disposed —
  /// writing them there throws `Tried to use StateController after dispose`.
  /// The selections are visible wherever they apply (every surface that reads
  /// them also renders the chips that set them), so leaving them set is a state
  /// the reader can see and undo, not a silent filter.
  void _clearFacets() {
    ref.read(eventTimeRangeProvider.notifier).state = EventTimeRange.anytime;
    ref.read(eventFacetFilterProvider.notifier).state = const <String>{};
    ref.read(placeTypeFacetFilterProvider.notifier).state = const <String>{};
  }

  @override
  Widget build(BuildContext context) {
    // PROD-4301 — is there a location we could even send? `null` while the
    // gate is still resolving.
    final hasLocation = ref.watch(feedLocationGateProvider).valueOrNull;

    // ⚠️ **Subscribed only when a location exists, and that is the feature.**
    // With no location the request would carry no signal and the contract
    // answers 400 — so the page must not ask at all. `feedHomeProvider` is
    // autoDispose, so not watching it is what genuinely means no request is
    // issued (the two `ref.listen`s below subscribe too, and are gated on the
    // same condition for that reason).
    //
    // ⚠️ **This is not the only subscription in `lib/`** — this comment used to
    // say it was, and PROD-4445 found otherwise. `feedExposureProvider` watches
    // it as well, and carries the same gates for the same reason. A rule of the
    // form "the feed must not be requested when X" has to be applied in BOTH
    // places or it is not a rule: the screen can render the right thing while
    // the request goes out anyway, which looks identical on screen.
    //
    // A synthesised `loading` rather than a nullable local: `_host` and the
    // reserve box both take an `AsyncValue`, and the branches below short-
    // circuit before `feed.when` is ever reached in the no-location case.
    // PROD-4520 — a guest on *Pessoas* is no longer gated here. The request is
    // issued for them like any other filter and the backend answers with a
    // `sign_in_gate` block, which renders through the ordinary block path.
    final feed = (hasLocation == true)
        ? ref.watch(feedHomeProvider)
        : const AsyncValue<FeedHomeState>.loading();

    // Watched, not read: the loading state's copy names this feed, so the
    // page has to repaint when it changes. `feedHomeProvider` is keyed on it
    // and so re-runs anyway — this only makes the dependency explicit for
    // the chrome that also reads it.
    final filter = ref.watch(feedFilterProvider);

    final filtersOpen = ref.watch(feedFilterBarOpenProvider);
    final procura = ref.watch(feedProcuraModeProvider);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    // How much the bar's block hides when it arrives — **asked of the block
    // this page builds**, so the trigger cannot drift from the thing it is
    // measuring (`heightFor` reads the block's own margin; PROD-4101).
    //
    // `filtersOpen: false` deliberately: this is the block at rest, and it is
    // the resting height that decides when the bar may appear. Opening the row
    // makes the block taller, and feeding that back into the threshold would
    // move the boundary under the user while they are using it.
    final closedBarBlockHeight = _headerChrome(
      1,
      openT: 0,
      procuraT: procura ? 1 : 0,
    ).heightFor(context, belowHeight: procura ? _chromeExtent : 0);
    _closedBarBlockHeight = closedBarBlockHeight;

    // The filter row writes `feedFilterProvider`; the page reacts here rather
    // than in the row's `onSelected` so a filter set from anywhere — the
    // pinned header's copy of the row, a deep link, a test — gets the same
    // treatment.
    ref.listen<FeedFilter>(feedFilterProvider, (prev, next) {
      if (prev == next) return;
      // context_changed (PROD-4303): the feed is recomposed per filter, so a
      // filter switch is a context boundary inside the same visit. Same seam
      // as the scroll handling below — it catches a filter set from anywhere.
      // `.wire`, not `.name` (PROD-4532): the two agree for all four filters
      // today, so this is not a data change — but `.wire` is the value the
      // contract and `feed_slate_advance` already use, and the opening beat in
      // `DiscoverySessionTracker._open` uses it too. One vocabulary means a
      // future rename cannot split the switch beats from the opening ones.
      _sessionTracker?.contextChanged(context: 'filter:${next.wire}');
      // The strips belong to the filter above them: `Eventos`' time range means
      // nothing on `Sítios`. Left in place, a facet selected under one filter
      // would stay live but invisible — and take the page over again the moment
      // the reader came back to it, with no chip on screen explaining why the
      // feed had been replaced by a results grid.
      _clearFacets();
      // `_clearFacets` writes the three providers, and the listeners above
      // answer for that. But a filter change with NO facets set moves nothing,
      // so nothing fires — and the recorded context would name the old filter
      // if the takeover were still latched. Cheap and idempotent: the sync
      // returns immediately when the boolean has not moved.
      _syncFacetContext();
      _onFilterChanged();
    });

    // The reserve exists only while the new feed is in the air. Dropping it on
    // the first non-loading state hands the extent back to the real content.
    // Gated with the watch above: `ref.listen` SUBSCRIBES, so an ungated one
    // would construct `feedHomeProvider` and fire the request this whole
    // branch exists to avoid.
    if (hasLocation == true) {
      ref.listen<AsyncValue<FeedHomeState>>(feedHomeProvider, (prev, next) {
        // Forward the fetched page's run_id to the engagement tracker (PROD-4257).
        // Done from the screen, which already holds the tracker — the notifier
        // deliberately does NOT reach the tracker (it would drag the engagement/
        // API-client provider chain into every feed widget test).
        _sessionTracker?.setCurrentRunId(next.valueOrNull?.runId);

        // page_presented (PROD-4303) — a NEW page's blocks are about to render.
        // "New" = the run id moved to a non-null value, or the block list grew
        // (a loadMore/loadSlate on the run-less composed feed). The listener
        // also fires for `isLoadingMore` flips and error writes, which the
        // dedupe fields filter out. A full reload (filter change / refresh
        // rebuilds this autoDispose provider) passes through `isLoading`, which
        // resets the baseline so its page 1 counts as new again.
        final landed = next.valueOrNull;

        // context_changed for slate paging (PROD-4303). The trigger sits inside
        // `feed_end` block widgets, but the fetch is observable here as the
        // `isLoadingSlate` flip — same screen/provider seam as everything else,
        // and it cannot double-emit (the notifier guards re-entry).
        if (landed != null &&
            landed.isLoadingSlate &&
            !(prev?.valueOrNull?.isLoadingSlate ?? false)) {
          _sessionTracker?.contextChanged(context: 'page:slate');
        }

        if (next.isLoading) {
          _lastPresentedRunId = null;
          _lastPresentedBlockCount = 0;
        } else if (landed != null) {
          final newRun =
              landed.runId != null && landed.runId != _lastPresentedRunId;
          final grew = landed.blocks.length > _lastPresentedBlockCount;
          if (newRun || grew) {
            _lastPresentedRunId = landed.runId ?? _lastPresentedRunId;
            _lastPresentedBlockCount = landed.blocks.length;
            final runId = landed.runId;
            // Post-frame, so the event marks the blocks RENDERING, not the
            // fetch resolving — the contract separates delivered candidates
            // from presented content.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _sessionTracker?.pagePresented(runId: runId);
            });
          }
        }

        if (_filterChangeScrollTarget == null || next.isLoading) return;
        setState(() => _filterChangeScrollTarget = null);
      });
    }

    // The one place the failure is written down. `FeedErrorState` used to log
    // from its `build`, which re-runs on any unrelated rebuild and so printed
    // one failure many times (codex, 2026-09-08). A transition listener fires
    // once per failure, which is what a diagnostic is for.
    if (hasLocation == true) {
      ref.listen<AsyncValue<FeedHomeState>>(feedHomeProvider, (prev, next) {
        if (next.hasError && !(prev?.hasError ?? false)) {
          debugPrint('[Feed] request failed: ${next.error}');
        }
      });
    }

    // Where the sticky band's block puts its content: the notch, then the
    // page margin. Captured here rather than stored on the state because
    // `revealAfter` is rebuilt with every `build`, so a rotation or a
    // changed inset cannot leave a stale number behind.
    final topInset = MediaQuery.of(context).padding.top;

    // D32 — the header takes over once the top header has scrolled away and
    // OVERLAYS the feed rather than reserving a band above it, which is
    // `SokoHeaderPlacement.pinnedOverlay`. The page supplies the trigger and
    // what to do when it flips; the mechanism belongs to the design system.
    // PROD-3533's AppsFlyer `af_search` signal **used to be listened for here**,
    // on `procuraSearchQueryProvider`. It moved into `_openSearchOverlay`'s
    // `onSearch` when the overlay took over the typing: the overlay owns its
    // own query and never writes this provider, so the listener sat here firing
    // for nothing while every search typed on the feed went uncounted.
    //
    // PROD-4303 — `context_changed` for the facet takeover. Listened for rather
    // than computed in `build`, for the reason every other emission on this
    // page is: `build` runs for scroll, layout and animation frames, and an
    // event emitted from it would be emitted again on all of them.
    ref.listen<EventTimeRange>(
      eventTimeRangeProvider,
      (_, __) => _syncFacetContext(),
    );
    ref.listen<Set<String>>(
      eventFacetFilterProvider,
      (_, __) => _syncFacetContext(),
    );
    ref.listen<Set<String>>(
      placeTypeFacetFilterProvider,
      (_, __) => _syncFacetContext(),
    );

    // **The only way back that the OS knows about.** Procura pushes no route,
    // so without this, Android back and the browser's back button would leave
    // the feed entirely from inside a search — the user's model is that they
    // are one level deep, and the navigator disagrees (Zé, 2026-09-03).
    final page = SokoPinnedHeaderHost.pinnedOverlay(
      controller: _controller,
      // D31/D32 — **only one filter bar, and only one header, ever on screen.**
      //
      // The trigger is the moment the bar's own block COVERS the inline filter
      // row, which is a block-height before that row's trailing edge reaches
      // the viewport top. Waiting for the row to leave entirely — which is what
      // this did until the location band landed — held the bar back by a whole
      // header plus the 30 px gap, long after there was anything left to
      // collide with (Zé, on device, 2026-09-01).
      //
      // Measured against the BAR's block rather than the band's, because the
      // rule is about what the bar hides when it arrives. The band's block is
      // 5 px taller, so it has already covered the row by the time this fires;
      // the strict reading of "swap once the band covers the row" is 5 px of
      // scroll earlier and does not enforce the invariant that matters.
      //
      // Triggering on the TOP HEADER alone — the version before all of this —
      // put the pinned bar on screen with the inline filter bar still fully
      // visible: two filter bars, one of them reachable through the pinned
      // header's left button. It only looked fine because the chrome's paper
      // happened to cover the inline bar with 3 px to spare; a taller wordmark
      // or a large textScaler exposed it. Deriving the trigger from the block's
      // measured height instead of a fixed wait makes that structural.
      //
      // ⚠️ A SCROLL OFFSET measured during layout, never the chrome's painted
      // position. `RenderViewport` parks a sliver it has culled at layout
      // offset 0 (`layoutChildSequence` advances `layoutOffset` by each child's
      // *layoutExtent*, which is 0 once scrolled away), so asking a
      // scrolled-away widget where it is reports y=0 forever and the swap never
      // fires. Passed as a getter because the sentinel rewrites it on every
      // layout.
      revealAfter: () => _barRevealOffset,
      // The filter row hangs off the pinned header (D38). Scrolling back to the
      // top takes the header away, and a filter row left floating over the feed
      // with nothing above it is not a state the design has.
      onVisibilityChanged: (visible) {
        if (!visible && ref.read(feedFilterBarOpenProvider)) _closeFilters();
        // Hands the top edge over to the bar, and takes it back on the way up.
        _barMode.value = visible;
      },
      // **This host draws nothing.** Since the band and the bar became one
      // block that morphs, there is only one header to paint and the host
      // below paints it. What is still needed here is the THRESHOLD: "has the
      // scroll passed this point, reported reliably including at mount and
      // after a controller swap" is exactly what this widget computes, and
      // re-deriving it on the page would mean re-deriving the multi-position
      // guard and the post-frame sync with it.
      header: const SizedBox.shrink(),
      // The INTERMEDIATE header, nested so it paints UNDER the one above.
      //
      // The feedback this answers: between the top header leaving and the
      // pinned bar arriving there was ~300 px of scrolling with no location on
      // screen and nothing opaque at the top edge, so the feed slid visibly
      // through the status bar. The band stops instead of leaving — and
      // because `SokoPinnedHeaderBlock` paints its paper full-bleed with only
      // the CONTENT inset (PROD-4085), the moment it pins the top edge is
      // opaque and stays opaque through the hand-over to the bar. The wordmark
      // passing under the notch on the way there is the one thing that still
      // does, deliberately (Zé, 2026-09-01).
      //
      // A second host rather than a hand-rolled overlay: the mount-time sync,
      // the multi-position guard and the `hasPixels` bail are all things this
      // page would otherwise re-derive, and it is the same mechanism reading
      // the same controller at a different threshold.
      child: SokoPinnedHeaderHost.pinnedOverlay(
        controller: _controller,
        // The visible one.
        // Where the in-flow band's TOP edge reaches the pinned position — i.e.
        // the offset at which the two copies coincide exactly, which is what
        // makes the swap invisible. Derived from the header's measured
        // trailing edge (the scallop) rather than summed from the wordmark's
        // height, which nothing knows until the SVG has been laid out.
        revealAfter: () =>
            _topHeaderScrollExtent -
            kFeedLocationBandHeight -
            topInset -
            kSokoPageMargin,
        header: ValueListenableBuilder<bool>(
          valueListenable: _barMode,
          builder: (context, barMode, _) => TweenAnimationBuilder<double>(
            // **Implicit, so there is no controller to own or dispose.** The
            // tween's end changes when the threshold flips and the builder is
            // handed every value in between; the block is a pure function of
            // that number, and both ends of it are the exact geometry the two
            // headers had.
            tween: Tween<double>(end: barMode ? 1 : 0),
            // PROD-4299 — one duration for every viewer. The alternative bar
            // used to get `Duration.zero` here, because it drew its own
            // location at its own size and so had no shared element to slide.
            // It now shares the band's, so it slides like everything else.
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOut,
            builder: (context, t, __) => TweenAnimationBuilder<double>(
              // The morph, driven implicitly for the same reason the band→bar
              // hand-over above is: the end moves when the mode flips and the
              // builder is handed every value in between, so there is no
              // controller to own, dispose, or get out of sync between the two
              // mounted copies of the row.
              tween: Tween<double>(end: procura ? 1 : 0),
              duration: kFeedProcuraMorph,
              curve: Curves.easeInOut,
              builder: (context, procuraT, ___) => TweenAnimationBuilder<double>(
                // PROD-4316 — the filter row's reveal. Implicit like its
                // two neighbours, for the same reason: the end moves when
                // the flag flips and the builder is handed every value in
                // between, so there is no controller to own or dispose.
                tween: Tween<double>(end: filtersOpen ? 1 : 0),
                // The header's own hand-over timing, so opening the row and
                // the bar arriving read as one piece of chrome moving.
                //
                // Honours reduce motion, which its two neighbours do not —
                // they predate the rule and retrofitting them is a separate
                // change. `TweenAnimationBuilder` takes `Duration.zero`
                // safely; `AnimatedSize` is the one that cannot (see
                // `docs/learnings/animatedsize-cannot-take-a-zero-duration.md`).
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : kFeedFilterRowReveal,
                curve: Curves.easeInOut,
                builder: (context, openT, ____) =>
                    _headerChrome(t, openT: openT, procuraT: procuraT),
              ),
            ),
          ),
        ),
        // The floating map button is a `Positioned` SIBLING of the scrollable,
        // not a descendant, so it cannot reach the controller from inside the
        // host's subtree — the same reason `DiscoveryScreen` wraps its own
        // Stack (PROD-1899). Without the scope the button still renders, but
        // `maybeOf` returns null and it never collapses on scroll.
        child: FeedScrollControllerScope(
          controller: _controller,
          child: Stack(
            children: [
              _host(feed, procura, filter, hasLocation),
              // **The strip the wordmark slides UNDER**, opaque at every offset,
              // under both headers.
              //
              // Not decoration. Without it the logo is still partly on screen —
              // inside the notch, over the clock — at the moment the location
              // band pins, and the band's paper cuts it off in a single frame:
              // "the soko logo disappears instantly" (Zé, on device,
              // 2026-09-01). With it the logo is occluded progressively from the
              // top and is fully gone ~15 px of scroll BEFORE the band arrives,
              // so the pin covers nothing that was still visible.
              //
              // Invisible at rest: the same colour `DiscoveryShell` paints
              // behind this page, so at offset 0 there is nothing to see. That
              // is also why it is not `AppColors.sokoPaper` outright — in dark
              // mode that would put a paper strip across the top of the page.
              //
              // `IgnorePointer` so a tap near the status bar still reaches the
              // feed; `ColoredBox` is hit-test opaque.
              if (topInset > 0)
                Positioned(
                  key: kFeedNotchBandKey,
                  top: 0,
                  left: 0,
                  right: 0,
                  height: topInset,
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: isDark
                          ? AppColors.backgroundDark
                          : AppColors.sokoPaper,
                    ),
                  ),
                ),
              // Mounted BELOW the filter row's dismiss layer on purpose: while
              // the row is open the button is "outside" it, so the first tap
              // closes the row rather than leaving the page.
              //
              // ABOVE the status-bar strip: the strip exists to occlude
              // SCROLLING content, and this button is chrome.
              const DiscoveryMapButtonSlot(),
              // D38 — tap outside to dismiss. **Transparent, and BELOW the
              // chrome**: the filter row overlays the feed, it does not take it
              // over. Inside the host's `child`, so the header still paints
              // above.
              //
              // What this replaces painted a 15 % ink wash over the page AND, far
              // worse, a full sheet of paper: it wrapped `FeedPageContent` in
              // `Align(topCenter) > Material(color: paper)`, and `PageContent` is
              // a `Center`. A `Center` under BOUNDED height expands to fill it,
              // so the Material grew to the whole page and the filter row landed
              // in the middle of it — "centred vertically, hides everything".
              // Inside the Column below the height is unbounded, so the same
              // widget shrink-wraps and the bug cannot recur.
              if (filtersOpen)
                Positioned.fill(
                  child: GestureDetector(
                    // ⚠️ **`translucent`, NOT `opaque`** (PROD-4316, Zé on
                    // device: "the scroll underneath is disabled"). An opaque
                    // target *prevents targets visually behind it from
                    // receiving events* — so this sheet, which covers the whole
                    // page, was the hit-test target for every pointer and the
                    // feed's scrollable never saw one. The page was frozen for
                    // as long as the row was open.
                    //
                    // Translucent targets receive events within their bounds
                    // **and** let them through, so this recogniser and the
                    // scrollable's drag recogniser both enter the gesture
                    // arena — which already resolves it correctly: a stationary
                    // press loses nothing and the tap wins (the row closes),
                    // while a press that travels past touch slop is claimed by
                    // the drag (the feed scrolls).
                    behavior: HitTestBehavior.translucent,
                    onTap: _closeFilters,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    // **The only way back that the OS knows about.** Procura pushes no route,
    // so without this, Android back and the browser's back button would leave
    // the feed entirely from inside a search — the reader's model is that they
    // are one level deep and the navigator disagrees (Zé, 2026-09-03).
    // The type argument is explicit so a test can find exactly this one:
    // `PopScope(...)` in a `Widget` slot infers `PopScope<dynamic>`, which no
    // `find.byType` spelling matches reliably.
    return PopScope<Object?>(
      canPop: !procura,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitProcura();
      },
      // PROD-4303 — the session follows what the reader can SEE, not the
      // widget's mount. This screen stays mounted under a pushed detail route
      // and under other bottom-nav tabs, so a mount-driven session kept a feed
      // visit open while the reader was somewhere else entirely. Fully hidden
      // RELEASES this screen's hold on the visit (`screen_hidden`) — the
      // tracker closes it only when no other discovery surface (a bundle
      // see-all on top) still holds it, after an 800 ms linger that bridges
      // the hand-over window where this surface reports hidden before the
      // incoming one reports visible. Any visibility re-acquires the hold
      // (`acquireSurface` is idempotent per tag, so a partial→full transition
      // is a no-op). Callbacks are sampled on the detector's global
      // updateInterval — boundary timing is approximate by design, which is
      // fine for visit bracketing. Visual-tree-only wrapper: it adds no layout
      // and cannot disturb the sentinel-measured offsets or
      // `_filterChangeScrollTarget`.
      child: VisibilityDetector(
        key: const ValueKey('discovery-feed-session'),
        onVisibilityChanged: (info) {
          // A detector callback can be delivered a frame AFTER this state is
          // disposed; a late `> 0` report would then re-open a session nobody
          // ever closes (and leave the sender's debounce timer pending —
          // caught by widget tests as `!timersPending`).
          if (!mounted) return;
          if (info.visibleFraction == 0) {
            _sessionTracker?.releaseSurface('feed', reason: 'screen_hidden');
          } else {
            _sessionTracker?.acquireSurface('feed');
          }
        },
        child: page,
      ),
    );
  }

  /// The feed's pinned chrome, at any point between the location band and the
  /// bar: `SafeArea(top) · 15 · [band → bar] · [30 · filter row] · 15`.
  ///
  /// **One block in two states rather than two blocks that swap**, because the
  /// location appears in both headers and must not blink out between them (Zé,
  /// 2026-09-01). [FeedLocationBand] owns the morph and, crucially, owns the
  /// single location widget that slides from hard right to the bar's centre;
  /// the bar's chrome is handed to it WITHOUT a location for exactly that
  /// reason.
  ///
  /// [t] is 0 at the band and 1 at the bar. At `t == 0` the block is
  /// pixel-identical to the band inside `FeedTopHeader`, which is what makes
  /// the pin invisible; at `t == 1` it is the bar block the design system
  /// describes, which is what makes `heightFor` — and therefore the reveal
  /// threshold in [build] — still true.
  ///
  /// The rhythm and the safe-area ordering live in [SokoPinnedHeaderBlock],
  /// which is exactly why PROD-4081 could not reproduce them (PROD-4101). All
  /// this method decides is what goes in the two slots.
  ///
  /// **The paper is full-bleed while the content keeps the page margin.** Put
  /// the background on the padded box instead and the feed scrolls up through a
  /// 15 px gutter down each side of the bar.
  SokoPinnedHeaderBlock _headerChrome(
    double t, {
    required double openT,
    double procuraT = 0,
  }) {
    // How much of the filter row is showing: 0 is closed, 1 is open, and
    // everything between is the reveal (PROD-4316).
    //
    // Procura pins it to 1 rather than animating it — there the row is the
    // surface, not an affordance hanging off the header, and it arrives with
    // the morph rather than on its own timing.
    final rowT = (procuraT > 0 && t > 0) ? 1.0 : openT;

    return SokoPinnedHeaderBlock(
      key: kFeedPinnedChromeKey,
      // D38 — the filter row belongs to the header, not to the middle of the
      // page: it opens directly under the bar, inside the same paper, on the
      // same rhythm. The row and its gap travel together, so there is no way
      // to pass one without the other.
      // In Procura mode the row is ALWAYS here, not toggled (Zé, 2026-09-03):
      // the chrome is the surface now, so hiding it behind the header's filters
      // button would mean scrolling down inside a search with no way to see or
      // change what you searched for.
      //
      // ⚠️ **But only once [t] has left the band**, and that guard is the whole
      // bug Zé caught on device: this block pins as the LOCATION BAND well
      // before the bar takes over, and an unguarded `procuraT > 0` put the full
      // search chrome into it at that moment — with the inline chrome still on
      // screen below. Two search chromes, which is exactly what D32 forbids and
      // exactly the defect the band→bar hand-over was built to avoid. The bar's
      // own reveal threshold already subtracts a full chrome height from the
      // inline row's trailing edge, so by `t > 0` the inline copy is covered.
      below: rowT == 0
          ? null
          : (
              // **`PageContent`, not `FeedPageContent`** — the filter row is
              // edge-to-edge (Zé, 2026-08-31). It keeps the desktop column cap
              // but NOT the horizontal margin: `SokoTagBar` carries that inside
              // its own scrollable, so chips start on the margin at rest and can
              // scroll to both edges instead of being cut off at it. The bar
              // above keeps `FeedPageContent`; only the scroller differs.
              // **Grows down from under the bar, and collapses back up**
              // (PROD-4316, Zé). `Align(topCenter)` with a `heightFactor` sizes
              // the box to a fraction of the child and pins the child to its
              // top, so the row is revealed downwards; `ClipRect` keeps the
              // part not yet revealed from painting outside it.
              //
              // The same shape `FeedLocationBand` already uses to fold the
              // scallop away as the band becomes the bar — one pattern for
              // "chrome that collapses" in this header, not two.
              widget: ClipRect(
                key: kFeedFilterRowClipKey,
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: rowT,
                  child: PageContent(child: _chromeRow(procuraT)),
                ),
              ),
              // **`kSokoPageMargin`, not `kFeedPageBlockGap`** (Zé, on device,
              // 2026-09-09). This used to borrow the page's between-BLOCKS
              // rhythm (30) — the figure separating the scallop, the ritual
              // cards, the rule and the inline filter row. But the bar and this
              // row are not two page blocks: they are one piece of chrome, and
              // 30 stated a separation that is not the relationship.
              //
              // At 15 the block is evenly spaced — `15 · bar · 15 · row · 15`,
              // the same margin the block already keeps above and below itself
              // — so the two rows read as one unit. Measured: the gap the eye
              // sees is 5 px larger than this number either way, because the
              // header's 30 px chip is centred in a 40 px bar; 30 read as 35,
              // 15 reads as 20.
              // **Scaled by `rowT` too**, or the block would open a full
              // 15 px of empty paper before the row had begun to appear — the
              // gap would pop and then the row would grow out of it. The block
              // lays this out as a `SizedBox` above the widget, so the two have
              // to travel together.
              gap: kSokoPageMargin * rowT,
            ),
      // `FeedPageContent` stays here rather than moving into the block: it is
      // the page's HORIZONTAL margin plus the desktop column, and that is a
      // page-wide decision the header must not make on the page's behalf — the
      // same principle that keeps the block from taking the left and right safe
      // -area insets. The block owns the vertical rhythm and the paper; the feed
      // owns how wide its content is.
      child: FeedPageContent(
        child: FeedLocationBand(
          t: t,
          // **Null until the transition starts.** `Opacity(0)` still hit-tests,
          // so a bar mounted at `t == 0` would put an invisible chip and button
          // over the band, and "is the bar up" would stop being answerable by
          // looking for them.
          //
          // Handed as two halves rather than one assembled bar: the band's
          // delegate MEASURES the leading group to know where the location
          // lands, and it can only measure a child it lays out itself.
          barLeading: t == 0
              ? null
              : FeedPinnedHeaderLeading(onOpenFilters: _toggleFilters),
          barTrailing: t == 0 ? null : const FeedPinnedHeaderTrailing(),
        ),
      ),
    );
  }

  /// The filter row / search chrome, at [procuraT]. **One builder for both
  /// mounted copies** — the inline sliver and the pinned header's `below:` slot
  /// — so the two cannot render different states of the same row.
  Widget _chromeRow(double procuraT, {bool heroCircle = false}) {
    return FeedProcuraRow(
      t: procuraT,
      controller: _searchController,
      focusNode: _searchFocus,
      onProcura: _openSearchOverlay,
      onExit: _exitProcura,
      onFilterSelected: _closeFilters,
      // Only the inline copy carries the search Hero — the chrome is mounted
      // twice (inline + pinned) and two Heroes with one tag would collide.
      heroCircle: heroCircle,
      facets: _restingFacets(),
    );
  }

  /// The facet strips for the selected FEED FILTER, or null where it has none.
  ///
  /// The same two bars the pushed Procura screen mounted, back on the surface
  /// the reader actually browses from. They read the feed filter rather than a
  /// search category, because there is no search open when they are used.
  ///
  /// ⚠️ **The margin goes INSIDE the strip's scrollable**, exactly as
  /// `SokoTagBar` carries its own. The chrome is mounted in `PageContent`,
  /// which supplies the desktop column cap but no horizontal margin, so a strip
  /// with the default `EdgeInsets.zero` starts hard against the left edge —
  /// 15 px to the left of every chip above it (reported by Zé on device). The
  /// pushed screen never showed this: it sat inside a `Padding(15)`, which also
  /// meant its strips could not scroll past the margin at all. Passing it here
  /// gets both halves right: aligned at rest, flush to the edge once scrolled.
  Widget? _restingFacets() => switch (ref.watch(feedFilterProvider)) {
    // `surface` names THIS page, not Discovery's: the same two bars are also
    // mounted on the legacy overlay and the see-more pages, and without it
    // every `filter_applied` from the feed landed in `discover_events` /
    // `discover_places` alongside theirs (PROD-4303 measurement gap).
    FeedFilter.events => const EventFiltersBar(
      padding: EdgeInsets.symmetric(horizontal: kSokoTagBarMargin),
      surface: kFeedEventFacetSurface,
    ),
    FeedFilter.venues => const PlaceFiltersBar(
      padding: EdgeInsets.symmetric(horizontal: kSokoTagBarMargin),
      surface: kFeedPlaceFacetSurface,
    ),
    FeedFilter.zines || FeedFilter.people => null,
  };

  /// What Procura is showing instead of the feed, or null to leave the feed in
  /// place.
  ///
  /// Two ways to leave the feed, and only two:
  ///
  ///  * **`Pessoas`** — its section answers the no-query case itself (suggested
  ///    locals, with follow buttons), so it takes over as soon as the category
  ///    is picked. That is also why `Pessoas` needs no empty state: the one
  ///    chip with no feed behind it is the one chip that always has something
  ///    to show (Zé, 2026-09-03).
  ///  * **A query long enough to search on**, for the other three.
  ///
  /// Everything else — Procura open with nothing typed — returns null, and the
  /// feed the reader was already looking at keeps rendering underneath.
  Widget? _procuraBody(bool procura) {
    // The facet path first: it is the one that is live. A selected facet
    // replaces the feed with the **2-up results grid** the strips have always
    // fed — `discoverySearchResultsProvider` reads the same three providers the
    // chips write, so there is nothing to plumb through.
    final filter = ref.watch(feedFilterProvider);
    if (feedFacetsTakeOver(
      filter: filter,
      timeRange: ref.watch(eventTimeRangeProvider),
      eventFacets: ref.watch(eventFacetFilterProvider),
      placeFacets: ref.watch(placeTypeFacetFilterProvider),
    )) {
      // The query is deliberately the page's (empty in practice — the Procura
      // circle opens the overlay, which owns its own text). Passing it anyway
      // keeps the two halves of this method reading the same field, and
      // `SearchResultsSection` already supports the empty-query search a bare
      // facet produces (`shouldSearchEmptyEvents` / `shouldSearchEmptyPlaces`).
      return SearchResultsSection(
        queryProvider: procuraSearchQueryProvider,
        categoryOverride: searchCategoryForFeedFilter(filter),
      );
    }
    if (!feedProcuraTakesOver(
      procura: procura,
      query: ref.watch(procuraSearchQueryProvider),
    )) {
      return null;
    }
    // Unified-search: grouped results (thumbnail rows + pop expander + guest
    // wall) across every category, narrowed by the toggle chips, replacing the
    // 2-up card grid. `FeedProcuraResults` reads the query/category itself.
    return const FeedProcuraResults();
  }

  Widget _host(
    AsyncValue<FeedHomeState> feed,
    bool procura,
    // Which feed is being composed — the loading state names it. Passed
    // in rather than read here so the whole page has one answer, and so
    // this stays a pure function of what `build` saw.
    FeedFilter filter,
    // PROD-4301 — whether a sendable location exists; `null` while the gate is
    // still resolving. Passed in for the same reason [filter] is: `build`
    // decides whether to subscribe to `feedHomeProvider` off this value, so
    // reading it again here could disagree with what `build` acted on.
    bool? hasLocation,
  ) {
    return ShellSliverHost(
      controller: _controller,
      // PROD-4179 (Zé, on device) — typing in Procura and then scrolling left
      // the keyboard up, covering the results being scrolled toward. A drag
      // now puts it away, and tapping the field brings it back.
      //
      // Unconditional rather than gated on Procura mode: the framework's
      // handler only acts when a descendant actually holds focus, so outside
      // Procura there is nothing to dismiss and this is a no-op. Gating it
      // would add a rebuild path — the host would have to be reconstructed on
      // the mode change — to buy nothing.
      //
      // ⚠️ It is NOT a `FocusNode` swap. Both copies of the chrome stay mounted
      // once laid out (the inline sliver and the pinned header's), so two
      // `TextField`s share `_searchFocus` — and that is fine: tapping the
      // pinned copy after a drag re-focuses it and the typed text survives,
      // asserted in `feed_procura_keyboard_test.dart`. Worth stating because
      // "two fields, one node" reads like the bug and is not.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        // D31 — scrolls away normally, and hands the location band over to
        // the sticky overlay on the way out.
        SliverToBoxAdapter(
          child: FeedPageContent(
            child: FeedTopHeader(researchScrollController: _controller),
          ),
        ),
        // Zero-extent sentinel: reports where the TOP HEADER ends.
        //
        // Same mechanism and the same trap as the one further down — a scroll
        // extent measured during layout, never a painted position, because a
        // culled sliver reports y=0 forever. This one is read by the sticky
        // band's `revealAfter`; the header ends at the scallop, so the band is
        // its last `kFeedLocationBandHeight` px and that subtraction is where
        // the band's own top edge sits.
        SliverLayoutBuilder(
          builder: (context, constraints) {
            _topHeaderScrollExtent = constraints.precedingScrollExtent;
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          },
        ),
        // Figma `7304-23416`: 30 px from the scallop to whatever comes next.
        const SliverToBoxAdapter(child: SizedBox(height: kFeedPageBlockGap)),
        // The ritual cards — Daily Drop and the Weekly Bundle — and **none of
        // them is a feed block.** Each has its own endpoint and its own state
        // machine, so none is composed by `/feed/home` or ever appears in
        // `blocks`. They sit between the header and the filter bar, which is
        // where the legacy page puts them relative to everything else.
        //
        // They are the exact same widgets the legacy Discovery page renders,
        // with the same behaviours — including Daily Drop's own PROD-1979
        // guest treatment, which is NOT the feed's guest policy (D10 forbids
        // the client having one) and belongs to that widget rather than here.
        //
        // `FeedTopCards` owns how many of them are on screen and how wide they
        // are: nothing at zero, full width at one, and at two or more a
        // snapping carousel showing one whole card plus a third of the next,
        // with the peeking card dimmed.
        const SliverToBoxAdapter(
          child: FeedPageContent(
            // `TrailingGap`, not `Padding`: the slot renders nothing at all
            // when neither ritual card has anything to show, and a fixed bottom
            // padding would then leave 60 px of emptiness between the scallop
            // and the filter bar — 30 above a nothing and 30 below it. The gap
            // follows the slot's measured height instead, so the page never has
            // to know which states hide it (PROD-3998).
            child: TrailingGap(gap: kFeedPageBlockGap, child: FeedTopCards()),
          ),
        ),
        // PROD-4081 — the rule between the ritual cards and the filter row
        // (Figma `7598-24580`).
        //
        // **Conditional on the cards, via the provider they both read.** With
        // an empty ritual slot this rule would land directly under the scallop
        // — which is already a divider — so the page would show two in a row
        // with nothing between them. The 30 above it is the slot's own
        // `TrailingGap`, which collapses with the cards; this sliver adds the
        // 30 below.
        if (ref.watch(feedTopSlotHasContentProvider)) ...[
          const SliverToBoxAdapter(
            child: FeedPageContent(child: FeedChromeRule()),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: kFeedPageBlockGap)),
        ],
        // Zero-extent sentinel: the chrome sliver's LEADING edge. Paired with
        // the trailing one below so the chrome's height is MEASURED rather than
        // assumed — Procura mode makes it taller by the facet strips, whose
        // height no caller can compute up front, and an estimate that is wrong
        // by that much puts two search chromes on screen at the hand-over.
        SliverLayoutBuilder(
          builder: (context, constraints) {
            _filterRowScrollStart = constraints.precedingScrollExtent;
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          },
        ),
        // D38 — the bar sits inline at the top, below Daily Drop, and is ALSO
        // reachable from the pinned header's left button once pinned. Same
        // widget, two entry points; the overlay in `build` is the second one.
        SliverToBoxAdapter(
          // **`PageContent`, not `FeedPageContent`** — the row is edge-to-edge
          // (Zé, 2026-08-31). It keeps the desktop column cap but NOT the 15 px
          // horizontal margin: `SokoTagBar` carries that inside its own
          // scrollable, so chips start on the margin at rest and can scroll to
          // both edges instead of being cut off at it.
          // Its OWN tween rather than one hoisted above the page: the header's
          // copy is scoped to the header precisely so a morph does not rebuild
          // the feed's slivers, and hoisting one builder over both would undo
          // that. The two run the same tween, duration and curve from the same
          // frame, and the reveal threshold means they are never both on screen.
          child: PageContent(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: procura ? 1 : 0),
              duration: kFeedProcuraMorph,
              curve: Curves.easeInOut,
              builder: (context, procuraT, _) =>
                  _chromeRow(procuraT, heroCircle: true),
            ),
          ),
        ),
        // Zero-extent sentinel: the inline filter row's TRAILING EDGE.
        //
        // `precedingScrollExtent` is the scroll extent of every sliver before
        // this one — the shell's chrome spacer and refresh control included —
        // recomputed on every layout. So the pinned header's trigger follows
        // whatever is above this line without being told: a reflowed wordmark,
        // a different shell chrome, and the Daily Drop block PROD-4008 inserts
        // just above. Summing known heights instead would silently drift the
        // day someone adds a sliver here.
        //
        // Writing a field from a layout callback is fine; calling `setState`
        // from one is not, and this does not.
        SliverLayoutBuilder(
          builder: (context, constraints) {
            _filterRowScrollEnd = constraints.precedingScrollExtent;
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          },
        ),
        // The 30 below the row, which used to be its own bottom padding.
        //
        // Moved out into a sliver so the sentinel above lands on the ROW's edge
        // instead of 30 px past it. The trigger subtracts a block height from
        // that edge, and doing the same arithmetic with the gap still baked in
        // would mean writing `- kFeedPageBlockGap` at the subtraction site —
        // a second place that has to know how this sliver is padded. Geometry
        // is unchanged: the gap is the same 30, just contributed by a sibling.
        const SliverToBoxAdapter(child: SizedBox(height: kFeedPageBlockGap)),
        // **Holds the page's extent open while the incoming feed is empty.**
        //
        // A full viewport, so the offset the reader was at — at most
        // [_barRevealOffset], which is above the fold by construction — stays
        // inside `maxScrollExtent` and is not clamped away.
        //
        // ⚠️ It sits BEFORE the feed slivers, not after, so it is the thing
        // that collapses when the data lands rather than something the new
        // blocks have to push past. **Which is also why the loading state has
        // to be drawn HERE and not in the `loading:` branch below**: the branch
        // renders a full viewport further down, i.e. off-screen for the whole
        // wait. This box is a viewport tall and the reader is at most at
        // [_barRevealOffset], so its top edge — where the first feed block
        // would have gone — is exactly what they are looking at.
        //
        // It was blank until 2026-09-07 ("the page below should simply be
        // empty while the new feed is loading", Zé, 2026-09-01). That held
        // while the wait was short; the personalised compose can take ~10 s,
        // and ten seconds of nothing is indistinguishable from a broken page.
        //
        // Gated on `feed.isLoading` as well as the target, because the target
        // is cleared by a `ref.listen` — which runs *after* this build — so
        // for one frame after the data lands both would otherwise be mounted.
        if (_filterChangeScrollTarget != null)
          SliverToBoxAdapter(
            child: SizedBox(
              height: MediaQuery.of(context).size.height,
              child: feed.isLoading
                  ? Align(
                      alignment: Alignment.topCenter,
                      child: FeedLoadingState(filter: filter),
                    )
                  : null,
            ),
          ),
        // **The feed stays until a query exists** (Zé, 2026-09-03). Entering
        // Procura changes the chrome and nothing else, which is what makes
        // "the page must not jump" achievable — and it is why the pushed
        // screen's browse grid (`DefaultContentSection`) has no role here: the
        // feed IS the pre-query state.
        if (_procuraBody(procura) case final body?) ...[
          SliverToBoxAdapter(child: FeedPageContent(child: body)),
          // **The blank space that keeps the reader where they were**, and it
          // is DECLARED rather than measured (Zé, 2026-09-04).
          //
          // The first version measured: it let the page collapse, read how far
          // `maxScrollExtent` fell short, grew a reserve and jumped back. Every
          // symptom that produced was the cost of being reactive — the page sat
          // at the top for a frame before the correction landed (a visible
          // flicker), and the correction re-ran on every metrics change, which
          // includes the ones the reader's own finger makes (the results "kept
          // being pulled back up").
          //
          // These two make the collapse impossible instead, with no callbacks
          // and nothing to fight: `SliverFillRemaining` pads the page out to a
          // full viewport when the results are shorter than one and contributes
          // exactly zero when they are not, and the box below adds the offset
          // the reader was holding. The extent is therefore
          // `max(content, viewport) + held`, which puts `maxScrollExtent` at
          // `held` or above **by construction**. Nothing is ever clamped, so
          // nothing has to be put back.
          const SliverFillRemaining(
            hasScrollBody: false,
            child: SizedBox.shrink(),
          ),
          if (_lastFeedOffset > 0)
            SliverToBoxAdapter(child: SizedBox(height: _lastFeedOffset)),
        ] else if (_forcedStateSlivers() case final forced?)
          // Debug scaffold: replaces the feed area wholesale so the state under
          // review does not depend on what the API returned.
          ...forced
        else if (hasLocation == false)
          // PROD-4301 — nothing resolved, so no request was made and there is
          // no response to render. Asking is the only move left, and it is a
          // question rather than an error: `FeedErrorState`'s Retry could
          // never have succeeded here.
          const SliverToBoxAdapter(
            child: FeedPageContent(child: FeedNoLocationState()),
          )
        else if (hasLocation == null)
          // The gate itself is still resolving. Deliberately NOT the ask-state:
          // showing it here would flash "which area do you want to explore?" on
          // every cold start, before the app has finished finding out.
          SliverToBoxAdapter(child: FeedLoadingState(filter: filter))
        else
          ...feed.when(
            data: _dataSlivers,
            // Empty when the reserve above is already drawing it — the two
            // must never both be mounted, or the reader sees the illustration
            // twice, a viewport apart.
            loading: () => [
              if (_filterChangeScrollTarget == null)
                SliverToBoxAdapter(child: FeedLoadingState(filter: filter)),
            ],
            error: (error, _) => [
              SliverToBoxAdapter(
                child: FeedPageContent(child: FeedErrorState(error: error)),
              ),
            ],
          ),
        const SliverToBoxAdapter(child: SizedBox(height: _kBottomNavReserve)),
      ],
    );
  }

  /// Which feed state the admin debug panel is forcing, or
  /// [FeedForcedState.none].
  ///
  /// **The access gate lives here, not at the call sites.** It is read on every
  /// use — a non-admin on a release build gets `none` whatever the provider
  /// holds — and putting it in one accessor means a future caller cannot forget
  /// it. The panel is already mount-gated; this is the second lock.
  FeedForcedState _forcedFeedState() {
    if (!ref.watch(feedDebugAccessProvider)) return FeedForcedState.none;
    return ref.watch(feedForcedStateProvider);
  }

  /// The forced empty/error slivers, or null when nothing is forced.
  ///
  /// These two bypass `feed.when` entirely rather than being faked inside the
  /// `data` branch, and that is the point: a reviewer looking at the error
  /// state should not have to make a request fail, and the empty state should
  /// render whatever the feed happens to hold. Faking them downstream would
  /// make what you see depend on what the API returned, which is exactly the
  /// dependency the toggle exists to remove.
  List<Widget>? _forcedStateSlivers() => switch (_forcedFeedState()) {
    FeedForcedState.empty => const [
      SliverToBoxAdapter(child: FeedPageContent(child: FeedEmptyState())),
    ],
    FeedForcedState.error => [
      SliverToBoxAdapter(
        child: FeedPageContent(
          child: FeedErrorState(
            error: Exception('Forced from the feed debug panel'),
          ),
        ),
      ),
    ],
    // `unknownArea` is a block, so it is injected into the real feed rather
    // than replacing it — see `_dataSlivers`.
    //
    // `noLocation` is absent on purpose: it forces the *gate*, not the render,
    // so it arrives here as an ordinary `hasLocation == false` and is handled
    // by that branch. Rendering it from this switch would show the widget while
    // the request still went out — the exact failure `feed_debug_blocks.dart`
    // warns about.
    FeedForcedState.unknownArea ||
    FeedForcedState.noLocation ||
    FeedForcedState.none => null,
  };

  /// Advance when the page rendered something but left nothing to scroll.
  ///
  /// **The zero-block advance is not enough** (heyl-backend-5, 2026-09-09).
  /// PROD-4290 composes heroes and grids empty and hydrates them only on the
  /// page that serves them, so a first page can legitimately be *chrome-only* —
  /// one banner — with the real content behind a cursor. One banner is
  /// renderable, so `blocks.isEmpty` is false and that guard does not fire; the
  /// page is then shorter than the viewport, so there is no scroll extent, no
  /// scroll notification, and scroll-driven `loadMore` never runs.
  ///
  /// Same strand as the empty case, reached with a non-empty list. Testing
  /// `maxScrollExtent` instead of the block count catches both shapes and any
  /// future one — the honest question is "can the reader reach the next page?",
  /// and scrollability is that question rather than a proxy for it.
  ///
  /// Terminates: `loadMore` refuses a cursor it has already requested and clears
  /// `nextCursor` on a cycle, so `hasMore` goes false even if the backend keeps
  /// answering with short pages.
  void _scheduleAdvanceIfUnscrollable(FeedHomeState state) {
    if (!state.hasMore || state.isLoadingMore || state.loadMoreError != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // `positions.length != 1` means a detail route co-mounted on this
      // controller; reading `.position` then throws in release.
      if (_controller.positions.length != 1) return;
      if (_controller.position.maxScrollExtent > 0) return;
      ref.read(feedHomeProvider.notifier).loadMore();
    });
  }

  List<Widget> _dataSlivers(FeedHomeState state) {
    // Unknown blocks are filtered out HERE, before the builder, so they never
    // occupy a list index. Returning an empty widget from the dispatcher
    // instead would leave a slot behind and shift every key after it — the
    // rendered tree has to be identical to the same feed without the block.
    var blocks = renderableFeedBlocks(
      state.blocks,
      // PROD-4319 — drops `create_cta` for a guest, whose CTAs would both
      // dead-end at a 401. Passed in rather than read inside the filter so
      // it stays a pure function of its inputs.
      isAuthenticated: ref.watch(isAuthenticatedProvider),
    );
    // Debug scaffold — the admin panel can inject the `unknown_area` block,
    // because the backend that emits it (PROD-4290) is not built.
    //
    // Injected BEFORE the empty check on purpose, so forcing it on an
    // out-of-coverage location replaces the neutral empty state with the block
    // — which is exactly the before/after worth looking at.
    //
    // The empty and error states are forced further up, in [build]: they do not
    // belong here because they must not depend on what the API returned. See
    // `_forcedFeedState`.
    if (_forcedFeedState() == FeedForcedState.unknownArea) {
      blocks = [debugUnknownAreaBlock(), ...blocks];
    }
    // PROD-4286 — nothing to draw. Three different causes converge here and
    // the client cannot tell them apart, which is why the state is one neutral
    // notice rather than three specific ones; see `feed_notice_states.dart`.
    //
    // ⚠️ Tested on the RENDERABLE list, not `state.blocks`. A page whose blocks
    // are all types this build has never heard of is non-empty on the wire and
    // empty on screen — that is exactly the old-app case PROD-4290 creates, and
    // testing the wire list would draw a blank page for it.
    //
    // ⚠️ **"Renders nothing" is not "there is nothing"** (codex, 2026-09-08).
    // A page whose blocks this build cannot render still carries a cursor, and
    // `loadMore` is only ever driven by scroll — with no renderable content
    // there is no scrollable extent, so no scroll notification, so the feed
    // would sit on "nothing to show here" with real content one page away.
    //
    // The provider already refuses to make this mistake at the paging level:
    // its ledger counts blocks SEEN, not rendered, precisely so an unknown-only
    // page does not read as end-of-feed. This is the same trap one layer up.
    //
    // So: advance while anything might still be coming, and only claim the feed
    // is empty once paging is genuinely exhausted.
    if (blocks.isEmpty) {
      final canAdvance =
          state.hasMore && !state.isLoadingMore && state.loadMoreError == null;
      if (canAdvance) {
        // Post-frame: `loadMore` writes provider state, which must not happen
        // during a build. The notifier's own guards make a duplicate call a
        // no-op if a scroll fires first.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(feedHomeProvider.notifier).loadMore();
        });
      }
      if (state.hasMore || state.isLoadingMore) {
        return [
          SliverToBoxAdapter(
            child: FeedLoadingState(filter: ref.read(feedFilterProvider)),
          ),
        ];
      }
      return const [
        SliverToBoxAdapter(child: FeedPageContent(child: FeedEmptyState())),
      ];
    }
    // The page rendered something. If it is too short to scroll and there is
    // more behind it, nothing else will ask for the next page.
    _scheduleAdvanceIfUnscrollable(state);

    return [
      // `separated`, so the rule between two blocks is the list's business and
      // not any block's. A block that drew its own trailing rule would draw one
      // after the last block too, and would have to be told whether it is last.
      SliverList.separated(
        itemCount: blocks.length,
        itemBuilder: (context, index) =>
            FeedPageContent(child: buildFeedBlock(blocks[index])),
        // The separator decides per PAIR — a banner needs no rule against it,
        // and only the list can see both neighbours.
        separatorBuilder: (context, index) =>
            FeedBlockSeparator(before: blocks[index], after: blocks[index + 1]),
      ),
      if (state.isLoadingMore)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      if (state.loadMoreError != null)
        SliverToBoxAdapter(
          child: _LoadMoreRetry(
            onRetry: () => ref.read(feedHomeProvider.notifier).retryLoadMore(),
          ),
        ),
    ];
  }
}

class _LoadMoreRetry extends StatelessWidget {
  final VoidCallback onRetry;
  const _LoadMoreRetry({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: TextButton(onPressed: onRetry, child: const Text('Retry')),
      ),
    );
  }
}
