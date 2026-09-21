import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import 'api_client.dart';
import 'search_result_mappers.dart';

/// A single page of search results (PROD-2466). Wraps the mapped [items]
/// with the server's `total` estimate and the `has_more` stop signal.
///
/// `has_more` — NOT `total` — is the pagination terminator: `total` is a
/// Meilisearch estimate that can exceed the rendered count once client-side
/// thinning (e.g. the venue-id filter) runs, so it's display-only.
class PagedSuggestions {
  final List<ItemSuggestion> items;
  final int total;
  final bool hasMore;
  const PagedSuggestions({
    required this.items,
    required this.total,
    required this.hasMore,
  });
}

/// API client for search endpoints (places and events)
class SearchApi {
  final ApiClient _apiClient;

  SearchApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Paginated place search (PROD-2466). Surfaces `total` + `has_more` and
  /// forwards an explicit [offset].
  ///
  /// IMPORTANT (PROD-2466 contract): *sending* `offset` at all — even `0` —
  /// opts the backend into paginated, **local-only** mode: the full-mode
  /// Google fallback is suppressed on every page so the result window walks
  /// a stable, dupe-free order. [searchPlaces] passes `offset: null` to keep
  /// the legacy Google-fill behavior for the non-paginated callers (venue
  /// picker, add-to-list, list suggestions).
  Future<PagedSuggestions> searchPlacesPaged({
    required String query,
    double? latitude,
    double? longitude,
    double radiusMeters = 5000.0,
    int maxResults = 10,
    int? offset,
    String? mode,
    String? country,
    List<String>? facets,
    List<String>? placeTypes,
    CancelToken? cancelToken,
  }) async {
    final requestBody = <String, dynamic>{
      'query': query,
      'max_results': maxResults,
    };

    // Presence-based opt-in: only forward `offset` when the caller actually
    // paginates. Omitting it (bare [searchPlaces]) preserves Google fill.
    if (offset != null) {
      requestBody['offset'] = offset;
    }

    if (latitude != null) {
      requestBody['latitude'] = latitude;
    }
    if (longitude != null) {
      requestBody['longitude'] = longitude;
    }
    if (latitude != null && longitude != null && radiusMeters != 5000.0) {
      requestBody['radius_meters'] = radiusMeters;
    }
    if (mode != null) {
      requestBody['mode'] = mode;
    }
    if (country != null) {
      requestBody['country'] = country;
    }
    if (facets != null && facets.isNotEmpty) {
      requestBody['facets'] = facets;
    }
    if (placeTypes != null && placeTypes.isNotEmpty) {
      requestBody['place_types'] = placeTypes;
    }

    final response = await _dio.post(
      ApiConstants.searchPlaces,
      data: requestBody,
      cancelToken: cancelToken,
    );

    final data = response.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];

    final suggestions = items
        .whereType<Map<String, dynamic>>()
        .map(itemSuggestionFromPlaceResult)
        .whereType<ItemSuggestion>()
        .toList();

    return PagedSuggestions(
      items: suggestions,
      total: data['total'] as int? ?? suggestions.length,
      hasMore: data['has_more'] as bool? ?? false,
    );
  }

  /// Search for places (local database first, Google Maps fallback).
  ///
  /// Returns a list of [ItemSuggestion] that can be directly added to a list.
  /// - Local results have venueId for Mode 1 save (DB reference)
  /// - Google results have googlePlaceId for Mode 2 save (external data)
  ///
  /// Non-paginated: passes `offset: null` so the backend keeps the Google
  /// fallback (see [searchPlacesPaged] for the pagination contract).
  Future<List<ItemSuggestion>> searchPlaces({
    required String query,
    double? latitude,
    double? longitude,
    double radiusMeters = 5000.0,
    int maxResults = 10,
    String? mode,
    String? country,
    List<String>? facets,
    List<String>? placeTypes,
    CancelToken? cancelToken,
  }) async {
    final paged = await searchPlacesPaged(
      query: query,
      latitude: latitude,
      longitude: longitude,
      radiusMeters: radiusMeters,
      maxResults: maxResults,
      offset: null,
      mode: mode,
      country: country,
      facets: facets,
      placeTypes: placeTypes,
      cancelToken: cancelToken,
    );
    return paged.items;
  }

  /// Fetch the event category facet catalog (PROD-2369). Facets are the
  /// product-facing filter chips; the backend owns the taxonomy and maps each
  /// facet id to canonical `events.categories[]` values. Guest-safe.
  ///
  /// Labels are NOT localized server-side: [CategoryFacet.label] is an English
  /// fallback only. The frontend localizes via [CategoryFacet.labelKey] through
  /// its own ARB (see `EventFiltersBar`). The endpoint takes no `locale` param.
  Future<List<CategoryFacet>> getCategoryFacets({
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.eventCategoryFacets,
      cancelToken: cancelToken,
    );

    final data = response.data as Map<String, dynamic>;
    final facets = data['facets'] as List<dynamic>? ?? const [];
    return facets
        .whereType<Map<String, dynamic>>()
        .map(CategoryFacet.fromJson)
        .toList();
  }

  /// Fetch the place type facet catalog (PROD-2369). Facets are the
  /// product-facing Discovery Places filter chips; the backend owns the root
  /// venue type taxonomy and expands selected facet ids server-side.
  Future<List<PlaceTypeFacet>> getPlaceTypeFacets({
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.placeTypeFacets,
      cancelToken: cancelToken,
    );

    final data = response.data as Map<String, dynamic>;
    final facets = data['facets'] as List<dynamic>? ?? const [];
    return facets
        .whereType<Map<String, dynamic>>()
        .map(PlaceTypeFacet.fromJson)
        .toList();
  }

  /// Search local database for events.
  ///
  /// Returns a list of [ItemSuggestion] that can be directly added to a list.
  /// Events are returned with Mode 1 data (eventId for DB reference).
  ///
  /// [facets] are product-facing facet ids (e.g. `["music","arts_culture"]`,
  /// from [getCategoryFacets]); the backend expands them to canonical
  /// categories server-side (PROD-2369). This is the preferred filter path for
  /// the webapp. [categories] sends canonical labels directly — kept for
  /// non-webapp/back-compat callers; the two are mutually exclusive in
  /// practice. An unknown facet id makes the backend respond `422`.
  ///
  /// When [latitude] and [longitude] are both provided, the backend applies a
  /// hard `_geoRadius` filter (events outside [radiusMeters] are excluded).
  /// [country] (ISO-3166 alpha-2) applies a hard country filter; it works
  /// alone (no coords required).
  ///
  /// BE validators that the request layer guards against:
  ///   * lat XOR lon → 422. We gate the pair together — either both go or
  ///     neither do.
  ///   * `radius_meters` is non-nullable BE-side. We only forward it when
  ///     both coords are present; omit otherwise so the BE 20km default
  ///     kicks in server-side.
  ///   * `country` must match `^[A-Z]{2}$`. We uppercase non-empty values
  ///     and drop empty strings.
  Future<PagedSuggestions> searchEventsPaged({
    String? query,
    int maxResults = 20,
    int? offset,
    String? mode,
    List<String>? facets,
    List<String>? categories,
    String? startDate,
    String? endDate,
    double? latitude,
    double? longitude,
    double? radiusMeters,
    String? country,
    CancelToken? cancelToken,
  }) async {
    final requestBody = <String, dynamic>{'max_results': maxResults};

    // Presence-based opt-in (PROD-2466): only paginated callers send
    // `offset`; the bare [searchEvents] omits it.
    if (offset != null) {
      requestBody['offset'] = offset;
    }

    if (query != null) {
      requestBody['query'] = query;
    }
    if (mode != null) {
      requestBody['mode'] = mode;
    }
    if (facets != null && facets.isNotEmpty) {
      requestBody['facets'] = facets;
    }
    if (categories != null && categories.isNotEmpty) {
      requestBody['categories'] = categories;
    }
    if (startDate != null && startDate.isNotEmpty) {
      requestBody['start_date'] = startDate;
    }
    if (endDate != null && endDate.isNotEmpty) {
      requestBody['end_date'] = endDate;
    }

    // BE 422s on lat-XOR-lon; gate the pair together. Orphan radius is
    // also dropped — it's meaningless without a centroid.
    final hasCoords = latitude != null && longitude != null;
    if (hasCoords) {
      requestBody['latitude'] = latitude;
      requestBody['longitude'] = longitude;
      if (radiusMeters != null) {
        requestBody['radius_meters'] = radiusMeters;
      }
    }
    if (country != null && country.isNotEmpty) {
      requestBody['country'] = country.toUpperCase();
    }

    final response = await _dio.post(
      ApiConstants.searchEvents,
      data: requestBody,
      cancelToken: cancelToken,
    );

    final data = response.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? [];

    final suggestions = items
        .whereType<Map<String, dynamic>>()
        .map(itemSuggestionFromEventResult)
        .whereType<ItemSuggestion>()
        .toList();

    return PagedSuggestions(
      items: suggestions,
      total: data['total'] as int? ?? suggestions.length,
      hasMore: data['has_more'] as bool? ?? false,
    );
  }

  /// Search local database for events (non-paginated). Thin wrapper over
  /// [searchEventsPaged] with `offset: null`; returns just the mapped items
  /// for callers that don't page (add-to-list sheet, etc.).
  Future<List<ItemSuggestion>> searchEvents({
    String? query,
    int maxResults = 20,
    String? mode,
    List<String>? facets,
    List<String>? categories,
    String? startDate,
    String? endDate,
    double? latitude,
    double? longitude,
    double? radiusMeters,
    String? country,
    CancelToken? cancelToken,
  }) async {
    final paged = await searchEventsPaged(
      query: query,
      maxResults: maxResults,
      offset: null,
      mode: mode,
      facets: facets,
      categories: categories,
      startDate: startDate,
      endDate: endDate,
      latitude: latitude,
      longitude: longitude,
      radiusMeters: radiusMeters,
      country: country,
      cancelToken: cancelToken,
    );
    return paged.items;
  }
}
