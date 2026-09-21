import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../core/utils/event_when_formatter.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import '../../../shared/widgets/search_results_view.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../lists/utils/zine_cover_recipe.dart';
import '../providers/city_guides_shelf_provider.dart';
import '../providers/editor_picks_shelf_provider.dart';
import '../providers/happening_shelf_provider.dart';
import '../providers/most_followed_shelf_provider.dart';
import '../providers/near_you_context_provider.dart';
import '../providers/near_you_places_shelf_provider.dart';
import '../providers/paged_shelf_state.dart';
import '../providers/event_filters_provider.dart';
import '../providers/place_filters_provider.dart';
import '../providers/recommended_shelf_provider.dart';
import '../providers/search_category_provider.dart';
import '../providers/search_results_provider.dart';
import '../providers/spaces_shelf_provider.dart';
import '../utils/attribution_prefix.dart';
import '../widgets/sections/discovery_footer.dart';
import '../widgets/sections/search_results_section.dart';
import '../widgets/event_filters_bar.dart';
import '../widgets/place_filters_bar.dart';
import '../widgets/shelves/near_you_places_shelf.dart';

/// The Discovery shelves that own a vertical see-more page. [slug] is the
/// URL path segment (`/shelves/<slug>`); [analyticsId] matches the
/// `shelf_id` the home shelf dispatches so tile taps and card clicks join
/// to the same shelf in dashboards.
enum SeeMoreShelf {
  happening('happening', 'happening'),
  nearYouPlaces('near-you', 'near_you_places'),
  trending('trending', 'trending'),
  editorPicks('editor-picks', 'editor_picks'),
  recommended('recommended', 'recommended'),
  spaces('spaces', 'spaces'),
  cityGuides('city-guides', 'city_guides');

  const SeeMoreShelf(this.slug, this.analyticsId);

  final String slug;
  final String analyticsId;

  /// Route path for this shelf's see-more page.
  String get routePath => '/shelves/$slug';

  static SeeMoreShelf? fromSlug(String slug) {
    for (final shelf in values) {
      if (shelf.slug == slug) return shelf;
    }
    return null;
  }
}

/// Everything the see-more page needs from a shelf's provider, adapted to
/// the shared [SearchResultsView] contract.
typedef _ShelfData = ({
  String title,
  AsyncValue<List<SearchResultCard>> cards,
  bool hasMore,
  bool isLoadingMore,
  Object? loadMoreError,
  VoidCallback onLoadMore,
  VoidCallback? onRetryLoadMore,
});

/// Vertical see-more page for a Discovery shelf (the "Ver mais" tile's
/// destination): the shelf's title with a back arrow on top, and the
/// shelf's full feed as the standard 2-up grid — no search bar, no filter
/// chips. Shares the shelf's provider, so the first page is already warm
/// when the user arrives from the homepage and anything loaded here stays
/// cached when they go back (the home shelf caps its row at
/// [kDiscoveryShelfMaxVisibleItems] regardless).
///
/// Pagination piggybacks on [SearchResultsView]'s bottom sentinel;
/// guests get the shared 6-crisp-cards clamp with the sign-in CTA.
class ShelfSeeMoreScreen extends ConsumerWidget {
  final SeeMoreShelf shelf;

  const ShelfSeeMoreScreen({super.key, required this.shelf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final isGuest = !ref.watch(isAuthenticatedProvider);
    // Filter chips — the temporal/typed shelves only. Same Discovery-wide
    // filter state as the "Descobre a cidade" strips; while any filter is
    // active the grid swaps from the feed continuation to the same
    // filtered search the overlay shows (the feed endpoints accept no
    // category/date params).
    final Widget? filtersBar = switch (shelf) {
      SeeMoreShelf.happening => const EventFiltersBar(
        padding: EdgeInsets.symmetric(horizontal: 16),
      ),
      SeeMoreShelf.nearYouPlaces => const PlaceFiltersBar(
        padding: EdgeInsets.symmetric(horizontal: 16),
      ),
      _ => null,
    };
    final filtersActive = switch (shelf) {
      SeeMoreShelf.happening =>
        ref.watch(eventFacetFilterProvider).isNotEmpty ||
            ref.watch(eventTimeRangeProvider) != EventTimeRange.anytime,
      SeeMoreShelf.nearYouPlaces =>
        ref.watch(placeTypeFacetFilterProvider).isNotEmpty,
      _ => false,
    };
    final data = filtersActive
        ? _filteredSearchData(context, ref)
        : _dataFor(context, ref);

    return ColoredBox(
      color: isDark ? AppColors.surfaceDark : AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                // Top matches the large-title page rhythm (Library sits at
                // safe-area + 27). Kept in sync with FeedBundleSeeAllScreen's
                // twin header — change both together.
                padding: const EdgeInsets.fromLTRB(4, 27, 4, 8),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Title centered on the page; symmetric horizontal
                    // insets keep it truly centered despite the back
                    // button occupying the left edge.
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 52),
                      child: Text(
                        data.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.displayPrimary(
                          fontSize: 32,
                          fontWeight: FontWeight.w300,
                          color: inkColor,
                          height: 0.95,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SokoBackButton(color: inkColor),
                    ),
                  ],
                ),
              ),
              if (filtersBar != null)
                Padding(
                  // Horizontal insets live inside the bar's scroll view so
                  // the chips clip at the column edge but can still scroll
                  // flush past it.
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: filtersBar,
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: SearchResultsView(
                    resultsAsync: data.cards,
                    query: '',
                    hasMore: data.hasMore,
                    isLoadingMore: data.isLoadingMore,
                    loadMoreError: data.loadMoreError,
                    onLoadMore: data.onLoadMore,
                    onRetryLoadMore: data.onRetryLoadMore,
                    isGuest: isGuest,
                    onGuestSignIn: () => navigateToLoginPreservingReturn(
                      context,
                      ref,
                      referrer: AuthReferrer.guestGateHome,
                    ),
                    // An empty continuation page still gets the "done
                    // looking" full-stop instead of the typed-search
                    // "no results" copy; the filtered (search-backed)
                    // mode keeps the search grid's own empty state.
                    emptyState: filtersActive
                        ? null
                        : const DiscoveryFooter.doneLooking(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _ShelfData _dataFor(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    switch (shelf) {
      case SeeMoreShelf.happening:
        return _happeningData(context, ref, l10n);
      case SeeMoreShelf.nearYouPlaces:
        return _nearYouPlacesData(context, ref, l10n);
      case SeeMoreShelf.trending:
        return _trendingData(context, ref, l10n);
      case SeeMoreShelf.editorPicks:
        return _listShelfData(
          context,
          ref,
          l10n,
          title: l10n.discoveryShelfEditorPicksTitle,
          async: ref.watch(editorPicksShelfProvider),
          loadMore: () =>
              ref.read(editorPicksShelfProvider.notifier).loadMore(),
          retryLoadMore: () =>
              ref.read(editorPicksShelfProvider.notifier).retryLoadMore(),
        );
      case SeeMoreShelf.recommended:
        return _listShelfData(
          context,
          ref,
          l10n,
          title: l10n.discoveryShelfRecommendedTitle,
          async: ref.watch(recommendedShelfProvider),
          loadMore: () =>
              ref.read(recommendedShelfProvider.notifier).loadMore(),
          retryLoadMore: () =>
              ref.read(recommendedShelfProvider.notifier).retryLoadMore(),
        );
      case SeeMoreShelf.spaces:
        return _spacesData(context, ref, l10n);
      case SeeMoreShelf.cityGuides:
        return _listShelfData(
          context,
          ref,
          l10n,
          title: l10n.discoveryShelfCityGuidesTitle,
          async: ref.watch(cityGuidesShelfProvider),
          loadMore: () => ref.read(cityGuidesShelfProvider.notifier).loadMore(),
          retryLoadMore: () =>
              ref.read(cityGuidesShelfProvider.notifier).retryLoadMore(),
        );
    }
  }

  /// Shared adapter for the three `PagedShelfState` list shelves (Editor
  /// Picks / Recommended / City Guides). Card chrome mirrors the home
  /// shelf's [CanonicalShelfCard] content 1:1 (name, description,
  /// "Edt." attribution).
  _ShelfData _listShelfData(
    BuildContext context,
    WidgetRef ref,
    Lt l10n, {
    required String title,
    required AsyncValue<PagedShelfState> async,
    required VoidCallback loadMore,
    required VoidCallback retryLoadMore,
  }) {
    final analytics = ref.read(unifiedAnalyticsProvider);
    final paged = async.valueOrNull;
    final AsyncValue<List<SearchResultCard>> cards;
    if (async.hasError && paged == null) {
      cards = AsyncValue.error(async.error!, StackTrace.empty);
    } else if (paged == null) {
      cards = const AsyncValue.loading();
    } else {
      cards = AsyncValue.data([
        for (final (index, list) in paged.items.indexed)
          SearchResultCard(
            rowKey: 'list_${list.id}',
            coverRecipe: ZineCoverRecipe.fromUserList(list),
            name: list.name,
            subtitle: (list.description == null || list.description!.isEmpty)
                ? null
                : list.description,
            attribution: (list.ownerName != null && list.ownerName!.isNotEmpty)
                ? '${attributionPrefixFor(l10n, list.ownerHandle)}${list.ownerName}'
                : l10n.discoveryShelfYoursAttribution,
            attributionAvatarUrl: list.ownerAvatarUrl,
            attributionAvatarName: list.ownerName ?? list.ownerHandle,
            attributionAvatarSeed: list.ownerId,
            onTap: () {
              analytics.trackDiscoveryShelfCardClicked(
                shelfId: shelf.analyticsId,
                cardIndex: index,
                itemId: list.id,
                itemType: 'list',
              );
              context.push(
                '/lists/${list.urlIdentifier}',
                extra: const {'referrer': '/'},
              );
            },
          ),
      ]);
    }
    return (
      title: title,
      cards: cards,
      hasMore: paged?.hasMore ?? false,
      isLoadingMore: paged?.isLoadingMore ?? false,
      loadMoreError: paged?.loadMoreError,
      onLoadMore: loadMore,
      onRetryLoadMore: retryLoadMore,
    );
  }

  /// Filtered mode for the Happening / Near-you pages: any active filter
  /// routes through the exact same paged search the "Descobre a cidade"
  /// grids use (`discoverySearchResultsProvider` with an empty query
  /// reads the shared facet/time-range providers), with the shared
  /// row→card adapter so routing and chrome stay identical.
  _ShelfData _filteredSearchData(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final category = shelf == SeeMoreShelf.happening
        ? DiscoverySearchCategory.eventos
        : DiscoverySearchCategory.sitios;
    final key = DiscoverySearchKey(category: category, query: '');
    final asyncState = ref.watch(discoverySearchResultsProvider(key));
    final notifier = ref.read(discoverySearchResultsProvider(key).notifier);
    final paged = asyncState.valueOrNull;
    final title = shelf == SeeMoreShelf.happening
        ? l10n.discoveryShelfHappeningTitle
        : nearYouPlacesTitle(
            l10n: l10n,
            shelfContext: ref.watch(nearYouContextProvider).valueOrNull,
            searchLocation: ref
                .watch(resolvedSearchLocationProvider)
                .valueOrNull,
          );
    return (
      title: title,
      cards: asyncState.whenData(
        (s) => s.rows
            .map((row) => discoverySearchRowToCard(row, context, ref))
            .toList(),
      ),
      hasMore: paged?.hasMore ?? false,
      isLoadingMore: paged?.isLoadingMore ?? false,
      loadMoreError: paged?.loadMoreError,
      onLoadMore: notifier.loadMore,
      onRetryLoadMore: notifier.retryLoadMore,
    );
  }

  _ShelfData _happeningData(BuildContext context, WidgetRef ref, Lt l10n) {
    final analytics = ref.read(unifiedAnalyticsProvider);
    final state = ref.watch(happeningShelfProvider);
    final shelfContext = ref.watch(nearYouContextProvider).valueOrNull;
    final notifier = ref.read(happeningShelfProvider.notifier);
    final AsyncValue<List<SearchResultCard>> cards;
    if (state.isInitialLoading) {
      cards = const AsyncValue.loading();
    } else if (state.error != null && state.items.isEmpty) {
      cards = AsyncValue.error(state.error!, StackTrace.empty);
    } else {
      // Keep the feed's ranking — this page is the continuation of the
      // shelf, so the order must match what the user was scrolling.
      cards = AsyncValue.data([
        for (final (index, item) in state.items.indexed)
          SearchResultCard(
            rowKey: 'event_${item.id}',
            imageUrl: item.imageUrl,
            name: item.title,
            subtitle: _joinLine(
              formatEventWhen(
                context: context,
                startsAt: item.startsAt,
                timeKnown: item.timeKnown,
              ),
              item.primaryCategory,
            ),
            attribution:
                nearYouDistanceLabel(shelfContext, item.distanceKm) ?? '',
            onTap: () {
              analytics.trackDiscoveryShelfCardClicked(
                shelfId: shelf.analyticsId,
                cardIndex: index,
                itemId: item.id,
                itemType: 'event',
              );
              context.push('/events/${item.id}');
            },
          ),
      ]);
    }
    return (
      title: l10n.discoveryShelfHappeningTitle,
      cards: cards,
      hasMore: state.hasMore,
      isLoadingMore: state.isLoadingMore,
      loadMoreError: null,
      onLoadMore: notifier.loadMore,
      onRetryLoadMore: null,
    );
  }

  _ShelfData _nearYouPlacesData(BuildContext context, WidgetRef ref, Lt l10n) {
    final analytics = ref.read(unifiedAnalyticsProvider);
    final state = ref.watch(nearYouPlacesShelfProvider);
    final notifier = ref.read(nearYouPlacesShelfProvider.notifier);
    final shelfContext = ref.watch(nearYouContextProvider).valueOrNull;
    // Same dynamic title as the home shelf ("Perto de ti" / "Perto de
    // Estrela" / ...), so the page reads as that shelf's continuation.
    final title = nearYouPlacesTitle(
      l10n: l10n,
      shelfContext: shelfContext,
      searchLocation: ref.watch(resolvedSearchLocationProvider).valueOrNull,
    );
    final AsyncValue<List<SearchResultCard>> cards;
    if (state.isInitialLoading) {
      cards = const AsyncValue.loading();
    } else if (state.error != null && state.items.isEmpty) {
      cards = AsyncValue.error(state.error!, StackTrace.empty);
    } else {
      cards = AsyncValue.data([
        for (final (index, item) in state.items.indexed)
          SearchResultCard(
            rowKey: 'venue_${item.id}',
            imageUrl: item.imageUrl,
            name: item.title,
            subtitle: item.primaryTag,
            attribution:
                nearYouDistanceLabel(shelfContext, item.distanceKm) ?? '',
            onTap: () {
              analytics.trackDiscoveryShelfCardClicked(
                shelfId: shelf.analyticsId,
                cardIndex: index,
                itemId: item.id,
                itemType: 'venue',
              );
              context.push('/venues/${item.id}');
            },
          ),
      ]);
    }
    return (
      title: title,
      cards: cards,
      hasMore: state.hasMore,
      isLoadingMore: state.isLoadingMore,
      loadMoreError: null,
      onLoadMore: notifier.loadMore,
      onRetryLoadMore: null,
    );
  }

  _ShelfData _spacesData(BuildContext context, WidgetRef ref, Lt l10n) {
    final analytics = ref.read(unifiedAnalyticsProvider);
    final state = ref.watch(spacesShelfProvider);
    final notifier = ref.read(spacesShelfProvider.notifier);
    final AsyncValue<List<SearchResultCard>> cards;
    if (state.isInitialLoading) {
      cards = const AsyncValue.loading();
    } else if (state.error != null && state.items.isEmpty) {
      cards = AsyncValue.error(state.error!, StackTrace.empty);
    } else {
      cards = AsyncValue.data([
        for (final (index, item) in state.items.indexed)
          SearchResultCard(
            rowKey: 'venue_${item.id}',
            imageUrl: item.imageUrl,
            name: item.title,
            subtitle: item.primaryTag,
            attribution: item.eventCount15d > 0
                ? l10n.discoveryShelfSpacesEventCount(item.eventCount15d)
                : '',
            onTap: () {
              analytics.trackDiscoveryShelfCardClicked(
                shelfId: shelf.analyticsId,
                cardIndex: index,
                itemId: item.id,
                itemType: 'venue',
              );
              context.push('/venues/${item.id}');
            },
          ),
      ]);
    }
    return (
      title: l10n.discoveryShelfSpacesTitle,
      cards: cards,
      hasMore: state.hasMore,
      isLoadingMore: state.isLoadingMore,
      loadMoreError: null,
      onLoadMore: notifier.loadMore,
      onRetryLoadMore: null,
    );
  }

  _ShelfData _trendingData(BuildContext context, WidgetRef ref, Lt l10n) {
    final analytics = ref.read(unifiedAnalyticsProvider);
    final state = ref.watch(mostFollowedShelfProvider);
    final AsyncValue<List<SearchResultCard>> cards;
    if (state.isInitialLoading) {
      cards = const AsyncValue.loading();
    } else if (state.error != null && state.items.isEmpty) {
      cards = AsyncValue.error(state.error!, StackTrace.empty);
    } else {
      cards = AsyncValue.data([
        for (final (index, list) in state.items.indexed)
          SearchResultCard(
            rowKey: 'list_${list.id}',
            coverRecipe: ZineCoverRecipe.fromUserList(list),
            name: list.name,
            subtitle: (list.description == null || list.description!.isEmpty)
                ? null
                : list.description,
            attribution:
                '${attributionPrefixFor(l10n, list.ownerHandle)}'
                '${list.ownerName ?? list.ownerHandle ?? 'Soko'}',
            attributionAvatarUrl: list.ownerAvatarUrl,
            attributionAvatarName: list.ownerName ?? list.ownerHandle,
            attributionAvatarSeed: list.ownerId,
            onTap: () {
              analytics.trackDiscoveryShelfCardClicked(
                shelfId: shelf.analyticsId,
                cardIndex: index,
                itemId: list.id,
                itemType: 'list',
              );
              context.push(
                '/lists/${list.urlIdentifier}',
                extra: const {'referrer': '/'},
              );
            },
          ),
      ]);
    }
    // PROD-2416 — Most followed is a fixed top-50 window; the page shows
    // the full window with no pagination.
    return (
      title: l10n.discoveryShelfTrendingTitle,
      cards: cards,
      hasMore: false,
      isLoadingMore: false,
      loadMoreError: null,
      onLoadMore: () {},
      onRetryLoadMore: null,
    );
  }
}

/// "when · category" with the category dropped when absent.
String _joinLine(String when, String? category) {
  if (category == null || category.isEmpty) return when;
  return '$when · $category';
}
