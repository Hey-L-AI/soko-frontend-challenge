import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/utils/auth_gating.dart';
import '../../../../data/models/entity_ref.dart';
import '../../../../providers/detail_seed_provider.dart';
import '../../../../core/utils/event_when_formatter.dart';
import '../../../../providers/auth_provider.dart';
import '../../../../providers/resolved_search_location_provider.dart';
import '../../../../shared/widgets/search_results_view.dart';
import '../../../lists/utils/zine_cover_recipe.dart';
import '../../providers/happening_shelf_provider.dart';
import '../../providers/near_you_context_provider.dart';
import '../../providers/near_you_places_shelf_provider.dart';
import '../../providers/search_category_provider.dart';
import '../../providers/trending_shelf_provider.dart';
import '../feed_scroll_controller_scope.dart';
import '../shelves/near_you_places_shelf.dart' show nearYouDistanceLabel;

/// PROD-2221 — default-content section rendered inside Discovery's
/// search panel when the overlay is open and the user hasn't typed
/// anything yet. Replaces the legacy "shelves + Daily Drop" stack with
/// a single vertical 2-up grid of the feed that matches the active
/// category chip:
///
///   - `zines`   → "Most followed" (trending list shelf)
///   - `eventos` → "A acontecer" (happening events feed)
///   - `sitios`  → "Perto de ti" (near-you places feed)
///   - `all`     → defensive fallback to zines; the chip itself is
///                 removed on Discovery (PROD-2221) so this branch is
///                 unreachable, but the switch stays exhaustive for
///                 the compiler.
///
/// Behavior layered on the base grid:
///
///   * **Distance sort (PROD-2221)** — events and places are sorted
///     by `distanceKm` ascending before being mapped to cards, so the
///     closest item always sits first regardless of how the BE
///     ordered the page.
///   * **Empty state (PROD-2221 follow-up)** — if the provider
///     settles at `items: []` with no error, the section renders
///     [SizedBox.shrink()] instead of "Sem resultados para ''". The
///     misleading typed-search empty copy doesn't fit the
///     default-content path; the chips themselves are the only label
///     the user needs.
///   * **Guest-mode clamp (PROD-2221 follow-up)** — unauthenticated
///     viewers see the first 6 cards crisp; the rest are blurred,
///     pointer-blocked, and a centered [GuestBlurCtaCard] sits above
///     with a sign-in CTA wired to
///     `navigateToLoginPreservingReturn`. `loadMore()` is short-
///     circuited for guests — paging deeper just builds more cards
///     they can't see.
///
/// Infinite scroll piggybacks on the Discovery feed's
/// [ScrollController] from [FeedScrollControllerScope]: when the scrollable
/// comes within [_kLoadMoreThreshold]px of the bottom and the active
/// provider has `hasMore == true`, `loadMore()` fires once — the
/// provider's own `isLoadingMore` flag dedupes.
class DefaultContentSection extends ConsumerStatefulWidget {
  /// PROD-4081 — the surface's category state. Null means Discovery's own
  /// [searchCategoryProvider]; the Procura screen passes its forked one.
  /// Nullable rather than defaulted because the provider is top-level `final`,
  /// not `const`, so it cannot be a default parameter value.
  ///
  /// Read through `_DefaultContentSectionState._categoryProvider` — this state
  /// touches the provider from four places (mount, load-more, a tab-flip
  /// listener and `build`), and resolving the fallback once is what keeps them
  /// from drifting apart.
  final StateProvider<DiscoverySearchCategory>? categoryProvider;

  const DefaultContentSection({super.key, this.categoryProvider});

  @override
  ConsumerState<DefaultContentSection> createState() =>
      _DefaultContentSectionState();
}

/// Distance from the bottom of the outer scrollable at which we trigger
/// `loadMore()`. Bumped from the original 600 to 800 so the next page
/// starts fetching a bit before the user reaches the end and the bottom
/// spinner is already on screen when it does.
const double _kLoadMoreThreshold = 800;

class _DefaultContentSectionState extends ConsumerState<DefaultContentSection> {
  ScrollController? _attachedController;

  /// The category state this instance reads — the host's if it passed one,
  /// Discovery's otherwise. See [DefaultContentSection.categoryProvider].
  StateProvider<DiscoverySearchCategory> get _categoryProvider =>
      widget.categoryProvider ?? searchCategoryProvider;

  @override
  void initState() {
    super.initState();
    // PROD-2743 — refetch the Zines grid when this section first mounts on the
    // zines tab (e.g. tabbing in from Eventos, which renders a different
    // section). [trendingShelfProvider] is `keepAlive()`d so it would
    // otherwise show its last-city cache without re-fetching; the
    // search-results-backed tabs (events/places) re-create on tab-in and so
    // already reload. This brings the zines tab to parity. The notifier's
    // `_epoch` guard collapses this with the constructor's initial fetch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshZinesIfActive(ref.read(_categoryProvider));
    });
  }

  /// Re-fetch the Zines default grid when zines is the active category. No-op
  /// for events/places — those tabs reload via their own section/provider
  /// lifecycle. Called on mount (initState) and on in-section category flips
  /// (the `ref.listen` in [build]).
  ///
  /// PROD-3269 — the mount / tab-flip paths are stale-gated
  /// ([TrendingShelfNotifier.refreshIfStale]): within the grid's TTL and
  /// for unchanged coords they reuse the kept-alive data instead of
  /// re-firing the expensive `/lists/public` query on every overlay
  /// open. [force] is for the coord-change listener, where the refetch
  /// is the whole point (PROD-2743).
  void _refreshZinesIfActive(
    DiscoverySearchCategory category, {
    bool force = false,
  }) {
    if (category == DiscoverySearchCategory.zines ||
        category == DiscoverySearchCategory.all) {
      final notifier = ref.read(trendingShelfProvider.notifier);
      force ? notifier.refresh() : notifier.refreshIfStale();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = FeedScrollControllerScope.maybeOf(context);
    if (controller == _attachedController) return;
    _attachedController?.removeListener(_onScroll);
    _attachedController = controller;
    _attachedController?.addListener(_onScroll);
  }

  @override
  void dispose() {
    _attachedController?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final controller = _attachedController;
    // PROD-3058 — the shell's shared ScrollController can have >1 attached
    // position while a detail route (/venues, /events, /lists — all flat under
    // DiscoveryShell) is mounted on top of Discovery: both scrollables bind to
    // the same controller, and the controller re-broadcasts each position's
    // ticks to this listener. `controller.position` (== `_positions.single`)
    // then throws `StateError: Too many elements` in release (the debug asserts
    // that guard it are stripped). Only act when exactly one scrollable is
    // attached — mirrors the defensive `positions`-based reads in
    // scroll_memory_observer.dart / discovery_map_button.dart. Skipping the
    // load-more tick while a detail route is active is correct: this pager only
    // applies when Discovery is the single live scrollable, and
    // SearchResultsView's own bottom sentinel still fires onLoadMore when
    // Discovery is genuinely scrolled to its end.
    if (controller == null || controller.positions.length != 1) return;
    // Guests can't see beyond the first 6 cards, so fetching more
    // pages is wasted bandwidth.
    if (!ref.read(isAuthenticatedProvider)) return;
    final pos = controller.position;
    final remaining = pos.maxScrollExtent - pos.pixels;
    if (remaining > _kLoadMoreThreshold) return;
    // Fire-and-forget — each notifier's own `isLoadingMore` guards
    // against re-entrant calls while a page is in flight.
    final category = ref.read(_categoryProvider);
    switch (category) {
      case DiscoverySearchCategory.zines:
      case DiscoverySearchCategory.all:
        ref.read(trendingShelfProvider.notifier).loadMore();
      case DiscoverySearchCategory.eventos:
        ref.read(happeningShelfProvider.notifier).loadMore();
      case DiscoverySearchCategory.sitios:
        ref.read(nearYouPlacesShelfProvider.notifier).loadMore();
      case DiscoverySearchCategory.leitores:
        // Leitores renders via ReadersSearchSection — nothing to page here.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // PROD-2743 — when the user flips between filter tabs without this section
    // unmounting (zines ↔ sítios both render here), refetch the zines grid as
    // it becomes active so it reflects the current city. initState covers the
    // mount-from-events case; this covers in-section flips.
    ref.listen(_categoryProvider, (prev, next) {
      if (prev != next) _refreshZinesIfActive(next);
    });
    // PROD-2743 — refetch the zines grid when the RESOLVED picker coords change
    // while the user is sitting on this tab (e.g. auto Lisbon → explicit Rio).
    // The widget is the reliable observer here: it's mounted on the active tab,
    // so this `listen` always fires on a settled coord change, sidestepping the
    // edge-cases the provider-internal listener missed. `select(valueOrNull)`
    // ignores AsyncLoading ticks (they retain the previous value) and fires
    // only on a real coord change. Calling `refresh()` (not recreating the
    // notifier) is dispose-safe.
    ref.listen(
      resolvedSearchLocationProvider.select((c) => c.valueOrNull?.center),
      (prev, next) {
        if (prev == next) return;
        // Forced: a settled coord change must refetch regardless of the
        // PROD-3269 TTL — the cached grid belongs to the old city.
        _refreshZinesIfActive(ref.read(_categoryProvider), force: true);
      },
    );
    final category = ref.watch(_categoryProvider);
    final asyncCards = switch (category) {
      // Leitores never reaches this section (`_DiscoveryBody` routes it
      // to ReadersSearchSection); grouped with the zines fallback so the
      // switch stays exhaustive.
      DiscoverySearchCategory.zines ||
      DiscoverySearchCategory.all ||
      DiscoverySearchCategory.leitores => _trendingCards(context, ref),
      DiscoverySearchCategory.eventos => _happeningCards(context, ref),
      DiscoverySearchCategory.sitios => _nearYouPlacesCards(context, ref),
    };
    final isGuest = !ref.watch(isAuthenticatedProvider);
    final pagination = _paginationFor(category);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: _Body(
        asyncCards: asyncCards,
        hasMore: pagination.hasMore,
        isLoadingMore: pagination.isLoadingMore,
        onLoadMore: pagination.onLoadMore,
        isGuest: isGuest,
        onGuestSignIn: () => navigateToLoginPreservingReturn(
          context,
          ref,
          referrer: AuthReferrer.guestGateHome,
        ),
      ),
    );
  }

  /// Pagination flags + load-more trigger for the active category's shelf
  /// provider, threaded into [SearchResultsView] so the same auto-infinite-
  /// scroll spinner the typed-search surface ([SearchResultsSection]) shows
  /// now also sits below the zines and places default grids. Mirrors the
  /// category switch in [_onScroll] — both the outer scroll listener and the
  /// view's bottom sentinel call the same `loadMore`, which self-guards
  /// against re-entrancy.
  ///
  /// `eventos` is effectively unreachable here: `_DiscoveryBody` routes the
  /// events chip to [SearchResultsSection] (which owns its own footer), so
  /// `DefaultContentSection` only ever renders the `zines` / `sitios`
  /// branches. The case stays only to keep the switch exhaustive.
  ({bool hasMore, bool isLoadingMore, VoidCallback onLoadMore}) _paginationFor(
    DiscoverySearchCategory category,
  ) {
    switch (category) {
      case DiscoverySearchCategory.zines:
      case DiscoverySearchCategory.all:
      // Leitores never reaches this section — grouped with the zines
      // fallback so the switch stays exhaustive.
      case DiscoverySearchCategory.leitores:
        final s = ref.watch(trendingShelfProvider);
        return (
          hasMore: s.hasMore,
          isLoadingMore: s.isLoadingMore,
          onLoadMore: ref.read(trendingShelfProvider.notifier).loadMore,
        );
      case DiscoverySearchCategory.eventos:
        final s = ref.watch(happeningShelfProvider);
        return (
          hasMore: s.hasMore,
          isLoadingMore: s.isLoadingMore,
          onLoadMore: ref.read(happeningShelfProvider.notifier).loadMore,
        );
      case DiscoverySearchCategory.sitios:
        final s = ref.watch(nearYouPlacesShelfProvider);
        return (
          hasMore: s.hasMore,
          isLoadingMore: s.isLoadingMore,
          onLoadMore: ref.read(nearYouPlacesShelfProvider.notifier).loadMore,
        );
    }
  }
}

/// Renders the default-content states by delegating to the shared
/// [SearchResultsView] — including the guest clamp (now owned by the view,
/// shared with the typed-search surface). The empty case is overridden to
/// [SizedBox.shrink] so an empty filter renders nothing rather than the
/// misleading typed-search "Sem resultados para ''" copy.
class _Body extends StatelessWidget {
  final AsyncValue<List<SearchResultCard>> asyncCards;
  final bool hasMore;
  final bool isLoadingMore;
  final VoidCallback onLoadMore;
  final bool isGuest;
  final VoidCallback onGuestSignIn;
  const _Body({
    required this.asyncCards,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadMore,
    required this.isGuest,
    required this.onGuestSignIn,
  });

  @override
  Widget build(BuildContext context) {
    return SearchResultsView(
      resultsAsync: asyncCards,
      query: '',
      hasMore: hasMore,
      isLoadingMore: isLoadingMore,
      onLoadMore: onLoadMore,
      isGuest: isGuest,
      onGuestSignIn: onGuestSignIn,
      emptyState: const SizedBox.shrink(),
    );
  }
}

AsyncValue<List<SearchResultCard>> _trendingCards(
  BuildContext context,
  WidgetRef ref,
) {
  final state = ref.watch(trendingShelfProvider);
  if (state.isInitialLoading) return const AsyncValue.loading();
  if (state.error != null) {
    return AsyncValue.error(state.error!, StackTrace.empty);
  }
  return AsyncValue.data(
    state.items.map((list) {
      final ownerName = list.ownerName ?? list.ownerHandle ?? 'Soko';
      return SearchResultCard(
        rowKey: 'list_${list.id}',
        coverRecipe: ZineCoverRecipe.fromUserList(list),
        name: list.name,
        subtitle: (list.description == null || list.description!.isEmpty)
            ? null
            : list.description,
        attribution: list.ownerHandle != null && list.ownerHandle!.isNotEmpty
            ? '@${list.ownerHandle}'
            : ownerName,
        attributionAvatarUrl: list.ownerAvatarUrl,
        attributionAvatarName: ownerName,
        attributionAvatarSeed: list.ownerId,
        onTap: () => context.push(
          '/lists/${list.urlIdentifier}',
          extra: const {'referrer': '/'},
        ),
      );
    }).toList(),
  );
}

AsyncValue<List<SearchResultCard>> _happeningCards(
  BuildContext context,
  WidgetRef ref,
) {
  final state = ref.watch(happeningShelfProvider);
  final shelfContext = ref.watch(nearYouContextProvider).valueOrNull;
  if (state.isInitialLoading) return const AsyncValue.loading();
  if (state.error != null) {
    return AsyncValue.error(state.error!, StackTrace.empty);
  }
  // PROD-2221 — sort by distance ascending. The BE proximity ranking
  // factors in time-bucketing too; client-side sort enforces strict
  // distance ordering for the default-content view.
  final sorted = [...state.items]
    ..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  return AsyncValue.data(
    sorted.map((item) {
      // Mirror the search-grid + Happening-shelf "when" line —
      // `formatEventWhen` is the same shared formatter the Happening
      // shelf uses on each card. Prepended to the category so the row
      // reads "Sex, 21h · Art" / "Tomorrow, 9 AM · Art".
      final when = formatEventWhen(
        context: context,
        startsAt: item.startsAt,
        timeKnown: item.timeKnown,
      );
      final category = item.primaryCategory;
      final subtitle = category == null || category.isEmpty
          ? when
          : '$when · $category';
      return SearchResultCard(
        rowKey: 'event_${item.id}',
        imageUrl: item.imageUrl,
        name: item.title,
        subtitle: subtitle,
        attribution: nearYouDistanceLabel(shelfContext, item.distanceKm) ?? '',
        onTap: () {
          // PROD-4XXX: seed the detail shell from the card we already have.
          ref.cacheDetailSeed(
            DetailSeed(
              kind: EntityKind.event,
              id: item.id,
              imageUrl: item.imageUrl,
              title: item.title,
              category: item.primaryCategory,
              startAtIso: item.startsAt.toIso8601String(),
            ),
          );
          context.push('/events/${item.id}');
        },
      );
    }).toList(),
  );
}

AsyncValue<List<SearchResultCard>> _nearYouPlacesCards(
  BuildContext context,
  WidgetRef ref,
) {
  final state = ref.watch(nearYouPlacesShelfProvider);
  final shelfContext = ref.watch(nearYouContextProvider).valueOrNull;
  if (state.isInitialLoading) return const AsyncValue.loading();
  if (state.error != null) {
    return AsyncValue.error(state.error!, StackTrace.empty);
  }
  // PROD-2221 — sort by distance ascending. Same rationale as events.
  final sorted = [...state.items]
    ..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  return AsyncValue.data(
    sorted.map((item) {
      return SearchResultCard(
        rowKey: 'venue_${item.id}',
        imageUrl: item.imageUrl,
        name: item.title,
        subtitle: item.primaryTag,
        attribution: nearYouDistanceLabel(shelfContext, item.distanceKm) ?? '',
        onTap: () {
          // PROD-4XXX: seed the detail shell from the card we already have.
          ref.cacheDetailSeed(
            DetailSeed(
              kind: EntityKind.venue,
              id: item.id,
              imageUrl: item.imageUrl,
              title: item.title,
              category: item.primaryTag,
            ),
          );
          context.push('/venues/${item.id}');
        },
      );
    }).toList(),
  );
}
