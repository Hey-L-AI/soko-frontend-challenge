import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/city_auto_scope_provider.dart';
import '../../../providers/city_scope_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import '../../../shared/utils/search_range.dart';
import '../../lists/models/search_scope.dart';
import '../../moderation/providers/blocked_users_provider.dart';
import 'event_filters_provider.dart';
import 'place_filters_provider.dart';
import 'search_category_provider.dart';

/// Minimum query length before firing a request. Single-character queries
/// return too much noise.
const int kDiscoverySearchMinQueryLength = 2;

/// Maximum results pulled per category. Tuned to match endpoint defaults:
/// lists `limit=50`, events `max_results=20`, places `max_results=10`.
const int kListsSearchLimit = 50;
const int kEventsSearchMaxResults = 20;
const int kPlacesSearchMaxResults = 10;

/// Single result row consumed by `SearchResultsSection`. The four display
/// fields ([imageUrl] / [name] / [subtitle] / [attribution]) are filled via
/// `HighlightedShelfCard`; tap-handling is delegated back to the widget
/// since `BuildContext` and `WidgetRef` aren't available at provider time.
sealed class SearchResultRow {
  const SearchResultRow();

  String? get imageUrl;
  String get name;
  String? get subtitle;
  String get attribution;

  /// Stable key for `Widget.key` so the result list can animate correctly
  /// across re-fetches without churning identity for unchanged rows.
  String get rowKey;

  /// Meilisearch relevance score (0-1) from the source search response.
  /// Null for sources that don't expose a score — `ListSearchResultRow`
  /// always, `EventSearchResultRow` / `PlaceSearchResultRow` when the
  /// backend omits the field (older payloads, Google-fallback places).
  /// Used by the discovery typeahead to sort + filter results.
  double? get relevanceScore;
}

/// List (zine) search result.
class ListSearchResultRow extends SearchResultRow {
  final UserList list;
  const ListSearchResultRow(this.list);

  @override
  String? get imageUrl {
    final cover = list.coverImageUrl;
    if (cover != null && cover.isNotEmpty) return cover;
    final preview = list.previewImages;
    if (preview != null && preview.isNotEmpty) return preview.first;
    return null;
  }

  @override
  String get name => list.name;

  @override
  String? get subtitle {
    final desc = list.description;
    return (desc == null || desc.isEmpty) ? null : desc;
  }

  @override
  String get attribution {
    final handle = list.ownerHandle;
    if (handle != null && handle.isNotEmpty) return '@$handle';
    final fullName = list.ownerName;
    if (fullName != null && fullName.isNotEmpty) return fullName;
    return '';
  }

  @override
  String get rowKey => 'list_${list.id}';

  /// Lists/zines don't expose a Meilisearch score in their API response
  /// (`UserListsListOut`) — the backend ranks internally but doesn't pass
  /// the score through.
  @override
  double? get relevanceScore => null;
}

/// Event search result. Backed by [ItemSuggestion] (`type == 'event'`).
/// Taps push `/events/<id>` (the redesigned full-screen page, PROD-1671).
class EventSearchResultRow extends SearchResultRow {
  final ItemSuggestion event;
  const EventSearchResultRow(this.event);

  @override
  String? get imageUrl => event.imageUrl;

  @override
  String get name => event.name;

  @override
  String? get subtitle {
    // Prefer the venue/location line; fall back to the category. Date stays
    // out of the canonical card chrome — too noisy for a 1-line subtitle.
    final loc = event.location;
    if (loc != null && loc.isNotEmpty) return loc;
    if (event.categories.isNotEmpty) return event.categories.join(', ');
    final cat = event.category;
    return (cat == null || cat.isEmpty) ? null : cat;
  }

  @override
  String get attribution {
    final city = event.city;
    if (city != null && city.isNotEmpty) return city;
    return '';
  }

  @override
  String get rowKey => 'event_${event.id}';

  @override
  double? get relevanceScore => event.relevanceScore;
}

/// Place (venue) search result.
class PlaceSearchResultRow extends SearchResultRow {
  final ItemSuggestion place;
  const PlaceSearchResultRow(this.place);

  @override
  String? get imageUrl => place.imageUrl;

  @override
  String get name => place.name;

  @override
  String? get subtitle {
    final cat = place.category;
    if (cat != null && cat.isNotEmpty) return _humanise(cat);
    final types = place.types;
    if (types != null && types.isNotEmpty) return _humanise(types.first);
    return null;
  }

  @override
  String get attribution {
    final city = place.city;
    if (city != null && city.isNotEmpty) return city;
    final address = place.address;
    if (address == null || address.isEmpty) return '';
    final firstSegment = address.split(',').first.trim();
    return firstSegment;
  }

  @override
  String get rowKey {
    final venueId = place.venueId;
    if (venueId != null) return 'venue_$venueId';
    final googleId = place.googlePlaceId;
    if (googleId != null) return 'google_$googleId';
    return 'place_${place.id}';
  }

  @override
  double? get relevanceScore => place.relevanceScore;
}

String _humanise(String slug) {
  if (slug.isEmpty) return slug;
  final words = slug.replaceAll('_', ' ').split(' ');
  if (words.isEmpty) return slug;
  final first = words.first;
  final cap = first.isEmpty
      ? first
      : '${first[0].toUpperCase()}${first.substring(1)}';
  return [cap, ...words.skip(1)].join(' ');
}

/// Family key — `(category, query)`. Equality + hash are required because
/// `FutureProvider.family` uses the argument as a cache key.
class DiscoverySearchKey {
  final DiscoverySearchCategory category;
  final String query;

  const DiscoverySearchKey({required this.category, required this.query});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DiscoverySearchKey &&
          other.category == category &&
          other.query == query);

  @override
  int get hashCode => Object.hash(category, query);
}

/// One mapped page of discovery rows plus the server `has_more` stop signal.
typedef _SearchPage = ({List<SearchResultRow> rows, bool hasMore});

/// Paged state for the Discovery search-results surface (PROD-2466 /
/// PROD-2368). Events and Places paginate via `offset`/`has_more`; Zines and
/// the "All" fan-out load a single page and pin [hasMore] to `false`.
@immutable
class DiscoverySearchState {
  /// Rows accumulated across every page fetched so far, deduped by `rowKey`.
  final List<SearchResultRow> rows;

  /// Offset to request for the NEXT page. Advances by the per-category page
  /// size (`max_results`) — the PROD-2466 contract walks the server-side
  /// result window, so client-side thinning never shifts the offset.
  final int nextOffset;

  /// Server `has_more` from the last page — the loop terminator. `total` is
  /// a display-only estimate and is intentionally not stored.
  final bool hasMore;

  /// `true` while a `loadMore` fetch is in flight; the outer `AsyncValue`
  /// stays `AsyncData` so the grid never collapses to skeletons mid-scroll.
  final bool isLoadingMore;

  /// Last `loadMore` failure. Auto-fire is blocked while non-null; cleared
  /// only by `retryLoadMore`.
  final Object? loadMoreError;

  const DiscoverySearchState({
    required this.rows,
    required this.nextOffset,
    required this.hasMore,
    required this.isLoadingMore,
    required this.loadMoreError,
  });

  const DiscoverySearchState.empty()
    : rows = const [],
      nextOffset = 0,
      hasMore = false,
      isLoadingMore = false,
      loadMoreError = null;

  DiscoverySearchState copyWith({
    List<SearchResultRow>? rows,
    int? nextOffset,
    bool? hasMore,
    bool? isLoadingMore,
    Object? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return DiscoverySearchState(
      rows: rows ?? this.rows,
      nextOffset: nextOffset ?? this.nextOffset,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

/// Discovery search results — paginated (PROD-2466). One family entry per
/// `(category, query)`. Every filter that changes the result set (facets,
/// time range, geo scope, blocks) is `watch`ed in [build] so a filter change
/// rebuilds the entry from page 0; [loadMore] `read`s the same providers
/// (unchanged since the last build) to fetch the next window.
///
/// Only Events and Places paginate. Zines and the "All" fan-out load a single
/// page with `hasMore == false`, so [loadMore] is a no-op for them.
class DiscoverySearchResults
    extends
        AutoDisposeFamilyAsyncNotifier<
          DiscoverySearchState,
          DiscoverySearchKey
        > {
  CancelToken? _cancelToken;

  @override
  Future<DiscoverySearchState> build(DiscoverySearchKey key) async {
    final query = key.query.trim();

    // Register rebuild dependencies: any filter that changes the result set
    // must reset pagination to page 0. The actual values are `read` inside
    // the fetch helpers (which also run from `loadMore`, where `watch` is
    // not allowed).
    ref.watch(eventTimeRangeProvider);
    ref.watch(eventFacetFilterProvider);
    ref.watch(placeTypeFacetFilterProvider);
    ref.watch(cityScopeProvider);
    ref.watch(cityAutoScopeProvider);
    // Decision 13 — Discovery search follows U (the neighbourhood area) too,
    // so results anchor on the same place the pill/shelves show.
    ref.watch(autoFollowUserScopeProvider);
    // Blocked-author filtering only applies to list (zine) results — only
    // those categories read it in `_searchLists`. Watching it for events /
    // places would needlessly rebuild them on block changes (and couples them
    // to the `blockedUserIdsProvider` "initialize in main" override).
    if (key.category == DiscoverySearchCategory.zines ||
        key.category == DiscoverySearchCategory.all) {
      ref.watch(blockedUserIdsProvider);
    }

    final selectedPlaceFacets = key.category == DiscoverySearchCategory.sitios
        ? ref.read(placeTypeFacetFilterProvider)
        : const <String>{};
    final shouldSearchEmptyEvents =
        key.category == DiscoverySearchCategory.eventos;
    final shouldSearchEmptyPlaces =
        key.category == DiscoverySearchCategory.sitios &&
        selectedPlaceFacets.isNotEmpty;
    if (query.length < kDiscoverySearchMinQueryLength &&
        !shouldSearchEmptyEvents &&
        !shouldSearchEmptyPlaces) {
      return const DiscoverySearchState.empty();
    }

    final cancelToken = CancelToken();
    ref.onDispose(() {
      if (!cancelToken.isCancelled) cancelToken.cancel();
    });
    _cancelToken = cancelToken;

    switch (key.category) {
      case DiscoverySearchCategory.zines:
        return _flat(await _searchLists(ref, query, cancelToken));
      case DiscoverySearchCategory.all:
        // PROD-2026 — Discovery's "All" pill fans out the three per-category
        // searches in parallel and concatenates the rows in Zines → Events →
        // Places order. Stays flat (no pagination) per the PROD-2368 scope.
        final results = await Future.wait([
          _searchLists(ref, query, cancelToken),
          _fetchEventsPage(ref, query, 0, cancelToken).then((p) => p.rows),
          _fetchPlacesPage(ref, query, 0, cancelToken).then((p) => p.rows),
        ]);
        return _flat([...results[0], ...results[1], ...results[2]]);
      case DiscoverySearchCategory.eventos:
        final page = await _fetchEventsPage(ref, query, 0, cancelToken);
        return DiscoverySearchState(
          rows: page.rows,
          nextOffset: kEventsSearchMaxResults,
          hasMore: page.hasMore,
          isLoadingMore: false,
          loadMoreError: null,
        );
      case DiscoverySearchCategory.sitios:
        final page = await _fetchPlacesPage(ref, query, 0, cancelToken);
        return DiscoverySearchState(
          rows: page.rows,
          nextOffset: kPlacesSearchMaxResults,
          hasMore: page.hasMore,
          isLoadingMore: false,
          loadMoreError: null,
        );
      case DiscoverySearchCategory.leitores:
        // Leitores never renders through this grid provider —
        // `_DiscoveryBody` routes it to `ReadersSearchSection` (people
        // rows via `peopleSearchProvider`). The typeahead's keep-alive
        // loop still instantiates this key, so return empty instead of
        // firing a pointless search.
        return const DiscoverySearchState.empty();
    }
  }

  /// Single-page (non-paginated) state for Zines / All.
  static DiscoverySearchState _flat(List<SearchResultRow> rows) =>
      DiscoverySearchState(
        rows: rows,
        nextOffset: rows.length,
        hasMore: false,
        isLoadingMore: false,
        loadMoreError: null,
      );

  /// Fetch + append the next page. No-op unless the current state has more
  /// pages, isn't already loading, and isn't sitting on an unretried error.
  /// Only Events / Places ever have `hasMore == true`.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null ||
        !current.hasMore ||
        current.isLoadingMore ||
        current.loadMoreError != null) {
      return;
    }
    final key = arg;
    final cancelToken = _cancelToken ?? CancelToken();

    state = AsyncData(current.copyWith(isLoadingMore: true));
    try {
      final query = key.query.trim();
      final isEvents = key.category == DiscoverySearchCategory.eventos;
      final page = isEvents
          ? await _fetchEventsPage(ref, query, current.nextOffset, cancelToken)
          : await _fetchPlacesPage(ref, query, current.nextOffset, cancelToken);
      final pageSize = isEvents
          ? kEventsSearchMaxResults
          : kPlacesSearchMaxResults;
      state = AsyncData(
        current.copyWith(
          rows: _appendDedup(current.rows, page.rows),
          nextOffset: current.nextOffset + pageSize,
          hasMore: page.hasMore,
          isLoadingMore: false,
          clearLoadMoreError: true,
        ),
      );
    } catch (error) {
      // A cancelled request means the family is being torn down (new query /
      // filter); drop silently rather than surfacing a load-more error.
      if (error is DioException && CancelToken.isCancel(error)) return;
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: error),
      );
    }
  }

  /// Clear the stored `loadMore` error and try the next page again.
  Future<void> retryLoadMore() async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(clearLoadMoreError: true));
    await loadMore();
  }

  static List<SearchResultRow> _appendDedup(
    List<SearchResultRow> existing,
    List<SearchResultRow> incoming,
  ) {
    final seen = existing.map((r) => r.rowKey).toSet();
    final out = List<SearchResultRow>.of(existing);
    for (final row in incoming) {
      if (seen.add(row.rowKey)) out.add(row);
    }
    return out;
  }
}

/// Paginated discovery search results, keyed by `(category, query)`.
/// Cancellation: when the family key changes (new query/category) the old
/// entry auto-disposes; `ref.onDispose` cancels the in-flight Dio request.
final discoverySearchResultsProvider = AsyncNotifierProvider.autoDispose
    .family<DiscoverySearchResults, DiscoverySearchState, DiscoverySearchKey>(
      DiscoverySearchResults.new,
    );

Future<List<SearchResultRow>> _searchLists(
  Ref ref,
  String query,
  CancelToken cancelToken,
) async {
  final api = ref.read(listsApiProvider);
  final geo = _resolveDiscoveryGeo(ref);
  // `read` here — the notifier's `build` already `watch`es
  // `blockedUserIdsProvider` so the family entry invalidates when blocks
  // change. (This helper also runs from `loadMore`, where `watch` is not
  // allowed.) Otherwise a result cached under `(category, query)` would
  // survive a block in the same session.
  final blockedIds = ref.read(blockedUserIdsProvider);
  final response = await api.listPublicLists(
    q: query,
    latitude: geo.latitude,
    longitude: geo.longitude,
    // Lists endpoint uses `radius_km`, not metres. Convert when present.
    radiusKm: geo.radiusMeters == null ? null : geo.radiusMeters! / 1000,
    locationSource: geo.latitude == null ? null : 'picker',
    limit: kListsSearchLimit,
    cancelToken: cancelToken,
  );
  return filterByBlockedAuthors(
    response.items,
    blockedIds,
  ).map<SearchResultRow>((l) => ListSearchResultRow(l)).toList();
}

Future<_SearchPage> _fetchEventsPage(
  Ref ref,
  String query,
  int offset,
  CancelToken cancelToken,
) async {
  final api = ref.read(searchApiProvider);
  final geo = _resolveDiscoveryGeo(ref);
  final timeRange = ref.read(eventTimeRangeProvider);
  final selectedFacets = ref.read(eventFacetFilterProvider);
  final dateRange = eventDateRangeFor(timeRange, DateTime.now());
  final page = await api.searchEventsPaged(
    query: query,
    // `full` is the browse/filter mode: it honors facet/category expansion
    // and returns a paginated result set. (Fast is a title-lookup that returns
    // a short set with `has_more: false` — it breaks the guest gate, infinite
    // scroll, and facet filtering, so events stays on full.)
    mode: 'full',
    maxResults: kEventsSearchMaxResults,
    offset: offset,
    // Backend-owned taxonomy (PROD-2369): send facet ids; the backend expands
    // them to canonical `events.categories[]` server-side. The order is
    // sorted for a stable family cache key across re-selections.
    facets: (selectedFacets.toList()..sort()),
    startDate: dateRange?.startDate,
    endDate: dateRange?.endDate,
    latitude: geo.latitude,
    longitude: geo.longitude,
    radiusMeters: geo.radiusMeters,
    country: geo.country,
    cancelToken: cancelToken,
  );
  return (
    rows: page.items
        .map<SearchResultRow>((e) => EventSearchResultRow(e))
        .toList(),
    hasMore: page.hasMore,
  );
}

/// Maps a relative [EventTimeRange] to a concrete inclusive `start`/`end`
/// date window (formatted `YYYY-MM-DD`) anchored on [now], or `null` for
/// [EventTimeRange.anytime] (no date scoping). [now] is injected so the
/// mapping — especially the weekend window when "today" is already on the
/// weekend — is deterministically testable.
@visibleForTesting
({String startDate, String endDate})? eventDateRangeFor(
  EventTimeRange range,
  DateTime now,
) {
  final today = DateTime(now.year, now.month, now.day);
  switch (range) {
    case EventTimeRange.anytime:
      return null;
    case EventTimeRange.today:
      return (startDate: _formatDate(today), endDate: _formatDate(today));
    case EventTimeRange.tomorrow:
      final tomorrow = today.add(const Duration(days: 1));
      return (startDate: _formatDate(tomorrow), endDate: _formatDate(tomorrow));
    case EventTimeRange.thisWeek:
      final daysUntilSunday = DateTime.sunday - today.weekday;
      final sunday = today.add(Duration(days: daysUntilSunday));
      return (startDate: _formatDate(today), endDate: _formatDate(sunday));
    case EventTimeRange.weekend:
      final daysUntilSaturday = DateTime.saturday - today.weekday;
      final saturday = daysUntilSaturday >= 0
          ? today.add(Duration(days: daysUntilSaturday))
          : today;
      final sunday = saturday.weekday == DateTime.sunday
          ? saturday
          : saturday.add(const Duration(days: 1));
      return (startDate: _formatDate(saturday), endDate: _formatDate(sunday));
    case EventTimeRange.thisMonth:
      final nextMonth = today.month == DateTime.december
          ? DateTime(today.year + 1, DateTime.january)
          : DateTime(today.year, today.month + 1);
      final monthEnd = nextMonth.subtract(const Duration(days: 1));
      return (startDate: _formatDate(today), endDate: _formatDate(monthEnd));
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

Future<_SearchPage> _fetchPlacesPage(
  Ref ref,
  String query,
  int offset,
  CancelToken cancelToken,
) async {
  final api = ref.read(searchApiProvider);
  final geo = _resolveDiscoveryGeo(ref);
  final selectedFacets = ref.read(placeTypeFacetFilterProvider);
  final sortedFacets = selectedFacets.toList()..sort();
  final page = await api.searchPlacesPaged(
    query: query,
    latitude: geo.latitude,
    longitude: geo.longitude,
    radiusMeters: geo.radiusMeters ?? SearchRange.city.radiusMeters,
    // `full` unconditionally — matches events. Full honors type/facet filtering
    // and paginates; `offset` still suppresses the Google fallback so the paged
    // window stays local + stable. (Fast was a title-lookup that skipped type
    // filtering and returned 0 for a bare query — bad for browse.)
    mode: 'full',
    // PROD-2466: sending `offset` opts into paginated, local-only mode — the
    // Google fallback is suppressed on every page (intended; keeps the paged
    // window stable + dupe-free).
    offset: offset,
    country: geo.country,
    facets: sortedFacets.isEmpty ? null : sortedFacets,
    maxResults: kPlacesSearchMaxResults,
    cancelToken: cancelToken,
  );
  // PROD-2194: `/places/search` may still return Google-fallback results
  // (`venue_id: null`) with no pushable detail route, so we drop them. In
  // paginated mode Google is suppressed server-side, so this is largely a
  // no-op here, but kept for safety against transitional payloads.
  return (
    rows: page.items
        .where((p) => p.venueId != null)
        .map<SearchResultRow>((p) => PlaceSearchResultRow(p))
        .toList(),
    hasMore: page.hasMore,
  );
}

/// Geo bundle resolved from the active Discovery scope. Reads the
/// Discovery-specific scope providers and skips the device-GPS fallback
/// (Discovery operates at city granularity by design).
class _GeoParams {
  final String? country;
  final double? latitude;
  final double? longitude;
  final double? radiusMeters;

  const _GeoParams({
    this.country,
    this.latitude,
    this.longitude,
    this.radiusMeters,
  });
}

// `read` (not `watch`): the notifier's `build` `watch`es both
// `cityScopeProvider` and `cityAutoScopeProvider`, so the family entry already
// rebuilds when the explicit scope changes OR the async auto-scope resolves
// (the PROD-2196 cold-load race). This helper also runs from `loadMore`, where
// `watch` is not allowed — hence `read` here. Applies uniformly to events +
// places + lists since all three resolve through this helper.
_GeoParams _resolveDiscoveryGeo(Ref ref) {
  final override = ref.read(cityScopeProvider);
  // Decision 13 — prefer the precise-fix neighbourhood area (C follows U) over
  // the profile/IP city cascade, matching resolvedSearchLocationProvider.
  final followUser = ref.read(autoFollowUserScopeProvider).valueOrNull;
  final auto = followUser ?? ref.read(cityAutoScopeProvider).valueOrNull;
  final scope = override ?? auto;
  if (scope == null) return const _GeoParams();
  return switch (scope) {
    SearchScopeCountry(:final iso2) => _GeoParams(country: iso2),
    SearchScopeCountryCity(:final iso2, :final city) => _GeoParams(
      country: iso2,
      latitude: city.latitude,
      longitude: city.longitude,
      radiusMeters: SearchRange.city.radiusMeters,
    ),
    // Map-picker area scope (PROD-3109): center + shape-aware radius, no
    // country. Radius mode today; boundary_id containment is a later backend
    // flip that doesn't change this translation.
    SearchScopeArea(:final centerLat, :final centerLng, :final radiusMeters) =>
      _GeoParams(
        latitude: centerLat,
        longitude: centerLng,
        radiusMeters: radiusMeters,
      ),
  };
}
