import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/utils/auth_gating.dart';
import '../../../../core/utils/event_when_formatter.dart';
import '../../../../data/models/chat_message.dart';
import '../../../../providers/auth_provider.dart';
import '../../../../shared/widgets/search_results_view.dart';
import '../../../lists/utils/zine_cover_recipe.dart';
import '../../providers/place_filters_provider.dart';
import '../../providers/search_category_provider.dart';
import '../../providers/search_query_provider.dart';
import '../../providers/search_results_provider.dart';
import '../shelves/highlighted_shelf_card.dart';
import 'discovery_footer.dart';

/// Search-results state of the Discovery page (Figma
/// `d4BCnyUHe2705J7ecQtaIH` node `6144:5521`). Activates whenever the
/// action bar's search panel is open *and* the debounced
/// [searchQueryProvider] holds a query that meets
/// [kDiscoverySearchMinQueryLength]; otherwise renders nothing so the
/// shelf stack continues to show through.
///
/// Adapts each [SearchResultRow] into a [SearchResultCard] (with a
/// surface-specific tap handler) and hands them to [SearchResultsView].
/// All grid / cell / loading / error / empty / footer rendering lives
/// in the shared view — this widget owns the *data source* and the
/// *routing*, nothing else. The same shared view powers the Lists hub
/// (`/lists`) so any visual change to results lands in one file. Result
/// rows reuse the [HighlightedShelfCard] chrome (same 195 × 304
/// dimensions Em destaque uses); the page closes with
/// [DiscoveryFooter.doneLooking].
class SearchResultsSection extends ConsumerWidget {
  /// PROD-4081 — the surface's query/category state. Null means Discovery's
  /// own (`searchQueryProvider` / `searchCategoryProvider`), which is every
  /// pre-existing caller; the Procura screen passes its forked pair.
  ///
  /// **Nullable rather than defaulted** because a default parameter value must
  /// be a compile-time constant and these providers are top-level `final`, not
  /// `const`. Resolved in [build] instead — same effect, and the fallback stays
  /// visible at the point of use.
  final StateProvider<String>? queryProvider;
  final StateProvider<DiscoverySearchCategory>? categoryProvider;

  /// The category to search, when the surface already knows it and has no
  /// provider holding it. Wins over [categoryProvider].
  ///
  /// The feed's facet strips use this: there the corpus IS the selected feed
  /// filter (`feedFilterProvider`, a `StateProvider<FeedFilter>`), so mirroring
  /// it into a second `StateProvider<DiscoverySearchCategory>` just to satisfy
  /// this widget would add a write-during-build and a state that can disagree
  /// with the chips.
  final DiscoverySearchCategory? categoryOverride;

  const SearchResultsSection({
    super.key,
    this.queryProvider,
    this.categoryProvider,
    this.categoryOverride,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(queryProvider ?? searchQueryProvider).trim();
    final DiscoverySearchCategory category =
        categoryOverride ??
        ref.watch(categoryProvider ?? searchCategoryProvider);
    final shouldSearchEmptyEvents = category == DiscoverySearchCategory.eventos;
    final shouldSearchEmptyPlaces =
        category == DiscoverySearchCategory.sitios &&
        ref.watch(placeTypeFacetFilterProvider).isNotEmpty;
    if (query.length < kDiscoverySearchMinQueryLength &&
        !shouldSearchEmptyEvents &&
        !shouldSearchEmptyPlaces) {
      return const SizedBox.shrink();
    }

    final searchKey = DiscoverySearchKey(category: category, query: query);
    final asyncState = ref.watch(discoverySearchResultsProvider(searchKey));

    // Map domain `SearchResultRow`s → presentation `SearchResultCard`s.
    // Routing is wired here (per surface) so the shared view never has
    // to know about routes / referrers.
    final asyncCards = asyncState.whenData(
      (s) => s.rows
          .map((row) => discoverySearchRowToCard(row, context, ref))
          .toList(),
    );

    // Paging metadata (Events / Places only; Zines + All report hasMore=false).
    final paged = asyncState.valueOrNull;
    final notifier = ref.read(
      discoverySearchResultsProvider(searchKey).notifier,
    );

    // Guest gating (symmetric with the browse feed, PROD-2221): guests across
    // all categories get the first 6 crisp + a blurred sign-in wall, and never
    // paginate. The view ignores the load-more callbacks while clamped.
    final isGuest = !ref.watch(isAuthenticatedProvider);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SearchResultsView(
        resultsAsync: asyncCards,
        query: query,
        hasMore: paged?.hasMore ?? false,
        isLoadingMore: paged?.isLoadingMore ?? false,
        loadMoreError: paged?.loadMoreError,
        onLoadMore: notifier.loadMore,
        onRetryLoadMore: notifier.retryLoadMore,
        isGuest: isGuest,
        onGuestSignIn: () => navigateToLoginPreservingReturn(
          context,
          ref,
          referrer: AuthReferrer.guestGateHome,
        ),
      ),
    );
  }
}

/// Adapter — Discovery's domain rows → presentation cards. The `onTap`
/// preserves the pre-refactor routing (Discovery's `referrer='/'` for
/// list pushes; routed full-screen detail pages for events / venues).
/// Public so the shelf see-more pages (filtered mode) reuse the exact
/// same row→card adaptation and routing as the Discovery search grid.
SearchResultCard discoverySearchRowToCard(
  SearchResultRow row,
  BuildContext context,
  WidgetRef ref,
) {
  return switch (row) {
    ListSearchResultRow(:final list) => SearchResultCard(
      rowKey: row.rowKey,
      coverRecipe: ZineCoverRecipe.fromUserList(list),
      name: row.name,
      subtitle: row.subtitle,
      attribution: row.attribution,
      attributionAvatarUrl: list.ownerAvatarUrl,
      attributionAvatarName: list.ownerName ?? list.ownerHandle,
      attributionAvatarSeed: list.ownerId,
      onTap: () => context.push(
        '/lists/${list.urlIdentifier}',
        extra: const {'referrer': '/'},
      ),
    ),
    EventSearchResultRow(:final event) => SearchResultCard(
      rowKey: row.rowKey,
      imageUrl: row.imageUrl,
      name: row.name,
      // Prepend the "A acontecer"-style day+time to the subtitle so the
      // event search rows surface the same temporal signal the Happening
      // shelf already shows on its cards. Format follows
      // `core/utils/event_when_formatter.dart`. Falls back to the row's
      // existing subtitle (venue / category) when the BE doesn't give us
      // a parseable date.
      subtitle: _composeEventSubtitle(event, row.subtitle, context),
      attribution: row.attribution,
      // Routed full-screen event detail page (PROD-1671). Discovery
      // is admin-gated by the same flag the new page uses, so this
      // swap can't strand a non-admin viewer.
      onTap: () => context.push('/events/${event.eventId ?? event.id}'),
    ),
    PlaceSearchResultRow(:final place) => SearchResultCard(
      rowKey: row.rowKey,
      imageUrl: row.imageUrl,
      name: row.name,
      subtitle: row.subtitle,
      attribution: row.attribution,
      // Routed full-screen venue detail page (PROD-1670). Same
      // admin-gating story as the event case above.
      //
      // `place.venueId!` is safe because `_searchPlaces` already filtered
      // out null-venueId results (PROD-2194). The `place.id` fallback
      // we used to have here was unsafe — for Google-source results it
      // resolved to the Google Place ID, which the venue-detail endpoint
      // rejects with 422 uuid_parsing.
      onTap: () => context.push('/venues/${place.venueId!}'),
    ),
  };
}

/// Compose the event search row subtitle: `"<when> · <existing>"` when the
/// BE provides a parseable next occurrence, otherwise the existing
/// subtitle (venue / category) unchanged. Mirrors the day+time format the
/// Happening shelf shows on each card.
///
/// Source-of-truth note: `event.date` is the BE's English-only display
/// string (per OpenAPI `EventSearchResult.date`). The structured datetime
/// is `event.occurrences.first.startAt`, parsed by `SearchApi.searchEvents`
/// from `start_at`. Events whose schedule isn't yet known surface with an
/// empty `occurrences` list and fall back to the venue line here.
String? _composeEventSubtitle(
  ItemSuggestion event,
  String? existing,
  BuildContext context,
) {
  if (event.occurrences.isEmpty) return existing;
  final next = event.occurrences.first;
  final when = formatEventWhen(
    context: context,
    startsAt: next.startAt,
    timeKnown: next.timeKnown,
  );
  if (existing == null || existing.isEmpty) return when;
  return '$when · $existing';
}
