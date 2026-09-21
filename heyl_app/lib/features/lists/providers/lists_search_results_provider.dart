import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/saved_item.dart';
import '../../../data/models/saved_search_item.dart';
import '../../../data/models/user_list.dart';
import '../../../providers/api_provider.dart';
import '../../discovery/providers/search_category_provider.dart';
import 'lists_search_providers.dart';
import 'yours_following_mode_provider.dart';

/// Sealed result of a `/lists` hub search — one variant per category
/// pill (Zines / Eventos / Sítios). Carries enough state for the
/// results body to render the right grid without consulting the
/// category provider again.
sealed class ListsSearchResults {
  const ListsSearchResults();
  bool get isEmpty;
}

/// Owner's lists matching the query. Searched server-side via
/// `listMyLists(q:...)` — same surface that powered the Zines tab pre-
/// PROD-1934.
class ListsSearchResultsZines extends ListsSearchResults {
  final List<UserList> lists;
  const ListsSearchResultsZines(this.lists);
  @override
  bool get isEmpty => lists.isEmpty;
}

/// Saved events matching the query — server-side via
/// `searchSavedItems(item_type=event)`. Owner-scoped, no location
/// filter, no date filter.
class ListsSearchResultsEvents extends ListsSearchResults {
  final List<SavedSearchItem> events;
  const ListsSearchResultsEvents(this.events);
  @override
  bool get isEmpty => events.isEmpty;
}

/// Saved places matching the query — server-side via
/// `searchSavedItems(item_type=place)`. Owner-scoped.
class ListsSearchResultsPlaces extends ListsSearchResults {
  final List<SavedSearchItem> places;
  const ListsSearchResultsPlaces(this.places);
  @override
  bool get isEmpty => places.isEmpty;
}

/// Sentinel for "query too short" — single-character queries return too
/// much noise. The body renders the default state when this is returned.
class ListsSearchResultsIdle extends ListsSearchResults {
  const ListsSearchResultsIdle();
  @override
  bool get isEmpty => true;
}

/// PROD-2026 — combined results for the "All" tab. Carries the three
/// per-category result lists so the body can render them as stacked
/// sections (Zines first, then Eventos, then Sítios) inside a single
/// scroll view. Empty when every section is empty.
class ListsSearchResultsAll extends ListsSearchResults {
  final List<UserList> lists;
  final List<SavedSearchItem> events;
  final List<SavedSearchItem> places;
  const ListsSearchResultsAll({
    required this.lists,
    required this.events,
    required this.places,
  });
  @override
  bool get isEmpty => lists.isEmpty && events.isEmpty && places.isEmpty;
}

/// Search-results provider for the `/lists` hub, keyed by
/// [YoursFollowingMode] (PROD-2128). Switches on
/// [listsSearchCategoryProvider]:
///
/// - **Zines**
///   - mode=yours → `listMyLists(q=…, scope=worldwide)`. Owner-only,
///     global. Unchanged from pre-PROD-1934.
///   - mode=following → `listFollowedLists(q=…)`. Server-filters the
///     followed-lists set by query.
/// - **Eventos** / **Sítios** → `searchSavedItems(q=…, item_type=…)`
///   (PROD-1934). Single server-side call per category; the BE matches
///   `q` against the same field set as Zines (event title, venue
///   name / city / address / type, event categories / vibes / tags,
///   the user's `tip`). No location / date filter — that's intentional
///   for v1 and surfaced to the user via the "results aren't filtered
///   by location or date" notice above the grid. PROD-2128 — under
///   mode=following we pass `scope=following` so the BE unions items
///   across all followed lists.
///
/// Returns [ListsSearchResultsIdle] when the trimmed query is shorter
/// than [kListsSearchMinQueryLength]. The body uses this to skip
/// rendering the results grid + footer.
final listsSearchResultsProvider =
    FutureProvider.family<ListsSearchResults, YoursFollowingMode>((
      ref,
      mode,
    ) async {
      final query = ref.watch(listsSearchQueryProvider).trim();
      if (query.length < kListsSearchMinQueryLength) {
        return const ListsSearchResultsIdle();
      }

      final category = ref.watch(listsSearchCategoryProvider);
      final listsApi = ref.read(listsApiProvider);
      final isFollowing = mode == YoursFollowingMode.following;
      final savedScope = isFollowing ? 'following' : null;

      Future<UserListsResponse> zinesQuery() {
        if (isFollowing) {
          return listsApi.listFollowedLists(q: query);
        }
        // `listMyLists` defaults `include_collaborative=true` server-side
        // (no FE knob today). Unchanged behaviour from pre-PROD-1934 —
        // Zines tab has always returned owned + collaborative lists.
        return listsApi.listMyLists(q: query, scope: 'worldwide');
      }

      switch (category) {
        case DiscoverySearchCategory.zines:
        // Leitores is Discovery-only (people rows) — the `/yours` hub
        // never offers the tab, so this branch is unreachable there;
        // fall back to the zines result defensively.
        case DiscoverySearchCategory.leitores:
          final response = await zinesQuery();
          return ListsSearchResultsZines(response.items);

        case DiscoverySearchCategory.eventos:
          final response = await listsApi.searchSavedItems(
            q: query,
            itemType: SavedItemType.event,
            scope: savedScope,
          );
          return ListsSearchResultsEvents(response.items);

        case DiscoverySearchCategory.sitios:
          final response = await listsApi.searchSavedItems(
            q: query,
            itemType: SavedItemType.place,
            scope: savedScope,
          );
          return ListsSearchResultsPlaces(response.items);

        case DiscoverySearchCategory.all:
          // PROD-2026 — fan out the three per-category searches in parallel
          // and bundle them into a single [ListsSearchResultsAll]. Body
          // renders the result as three stacked sections so the user can
          // scan all matches without flipping tabs.
          final results = await Future.wait<dynamic>([
            zinesQuery(),
            listsApi.searchSavedItems(
              q: query,
              itemType: SavedItemType.event,
              scope: savedScope,
            ),
            listsApi.searchSavedItems(
              q: query,
              itemType: SavedItemType.place,
              scope: savedScope,
            ),
          ]);
          final listsResp = results[0] as UserListsResponse;
          final eventsResp = results[1] as SavedSearchItemsResponse;
          final placesResp = results[2] as SavedSearchItemsResponse;
          return ListsSearchResultsAll(
            lists: listsResp.items,
            events: eventsResp.items,
            places: placesResp.items,
          );
      }
    });
