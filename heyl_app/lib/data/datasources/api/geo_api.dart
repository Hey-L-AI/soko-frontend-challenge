import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import 'api_client.dart';

/// API client for the location-scope picker (PROD-1397 v2).
///
/// Three endpoints under `/api/v1/app/geo/*`:
/// - `listCountries()` — full country list with localized names + coverage hint.
/// - `searchCities(...)` — city autocomplete scoped to one country; backend
///   routes to local DB or Google Places Autocomplete per country.
/// - `resolveCity(...)` — resolves a Google-sourced picker pick to lat/lon.
///   Skipped for local-sourced picks (they already carry coordinates).
class GeoApi {
  final ApiClient _apiClient;

  GeoApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// List all 249 ISO-3166-1 countries with localized names.
  ///
  /// Cache the result per picker session — the list is static (only
  /// [GeoCountry.hasLocalCoverage] flips as PROD-1400 seeds more rows).
  Future<List<GeoCountry>> listCountries({
    required String locale,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.geoCountries,
      queryParameters: {'locale': locale},
      cancelToken: cancelToken,
    );
    final data = response.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];
    return items
        .map((e) => GeoCountry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Autocomplete cities inside a single country.
  ///
  /// [countryCode] — ISO-3166-1 alpha-2, uppercased by the backend.
  /// [q] — prefix, 2-100 characters.
  /// [sessionToken] — UUID owned by the frontend; reuse within a single
  /// picker session + the subsequent resolveCity call so Google bundles
  /// the Autocomplete Session billing.
  Future<GeoCitySearchResponse> searchCities({
    required String countryCode,
    required String q,
    required String sessionToken,
    required String locale,
    int limit = 10,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.geoCities,
      queryParameters: {
        'country_code': countryCode,
        'q': q,
        'session_token': sessionToken,
        'locale': locale,
        'limit': limit,
      },
      cancelToken: cancelToken,
    );
    return GeoCitySearchResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Resolve a picked city to coordinates. UUID ids short-circuit on the
  /// backend (local DB lookup, no Google); Google `place_id`s trigger a
  /// Place Details call — billed as part of the [sessionToken] session.
  ///
  /// Skip this call entirely when the picker returned `source: "local"` —
  /// [GeoCity.latitude] / [GeoCity.longitude] are already populated.
  Future<GeoCity> resolveCity({
    required String cityId,
    required String sessionToken,
    required String locale,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.geoCityById(cityId),
      queryParameters: {'session_token': sessionToken, 'locale': locale},
      cancelToken: cancelToken,
    );
    return GeoCity.fromJson(response.data as Map<String, dynamic>);
  }

  /// Resolve a tapped map coordinate to its containing neighborhood boundary
  /// (PROD-3109). Returns null when no boundary contains the point (ocean,
  /// gap, or outside covered countries — the backend answers `200` with
  /// `boundary: null`, never 404).
  Future<GeoBoundary?> resolveBoundaryAt({
    required double lat,
    required double lng,
    String locale = 'en',
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.geoBoundaryAt,
      queryParameters: {'lat': lat, 'lng': lng, 'locale': locale},
      cancelToken: cancelToken,
    );
    final data = response.data as Map<String, dynamic>;
    final boundary = data['boundary'];
    if (boundary == null) return null;
    return GeoBoundary.fromJson(boundary as Map<String, dynamic>);
  }

  /// Fetch the child neighbourhoods (freguesias, admin_level 8) contained by a
  /// city-level boundary, for the picker's tap-to-drill layer
  /// (`GET /geo/boundary/{id}/children`). Empty for a leaf boundary (a freguesia
  /// has no children) or a country with no finer tier (e.g. MX). The endpoint
  /// omits `country_code`/`parent`, so [countryCode] and [parentName] are
  /// injected into each child before parsing — otherwise the boundary loses its
  /// country (breaks list-suggestions filtering) and its "Child, City" label.
  Future<List<GeoBoundary>> boundaryChildren({
    required String id,
    required String countryCode,
    String? parentName,
    String locale = 'en',
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.geoBoundaryChildren(id),
      queryParameters: {'locale': locale},
      cancelToken: cancelToken,
    );
    final data = response.data as Map<String, dynamic>;
    final children = (data['children'] as List<dynamic>?) ?? const [];
    return children
        .whereType<Map<String, dynamic>>()
        .map(
          (c) => GeoBoundary.fromJson({
            ...c,
            if (c['country_code'] == null) 'country_code': countryCode,
            if (parentName != null && c['parent'] == null)
              'parent': {'name': parentName},
          }),
        )
        .toList();
  }

  /// Typed area autocomplete (Phase 2). Predictions carry no coordinates —
  /// resolve on select via [resolveArea]. [countryCode]/[nearLat]/[nearLng] are
  /// ranking-bias hints only. [sessionToken] is a frontend UUID reused for a
  /// search + its resolve (Google session billing later).
  Future<List<AreaPrediction>> searchAreas({
    required String q,
    required String sessionToken,
    required String locale,
    String? countryCode,
    double? nearLat,
    double? nearLng,
    int limit = 8,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.geoAreas,
      queryParameters: {
        'q': q,
        'session_token': sessionToken,
        'locale': locale,
        'limit': limit,
        if (countryCode != null) 'country_code': countryCode,
        if (nearLat != null) 'near_lat': nearLat,
        if (nearLng != null) 'near_lng': nearLng,
      },
      cancelToken: cancelToken,
    );
    return AreaSearchResponse.fromJson(
      response.data as Map<String, dynamic>,
    ).results;
  }

  /// Deeper submitted map search. The backend searches local geography and
  /// venues first, then may use Google as a quality-gated fallback.
  Future<DeepAreaSearchResponse> deepSearch({
    required String q,
    required String locale,
    String? countryCode,
    double? nearLat,
    double? nearLng,
    int limit = 12,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post(
      ApiConstants.geoSearch,
      data: {
        'q': q,
        'locale': locale,
        'limit': limit,
        if (countryCode != null) 'country_code': countryCode,
        if (nearLat != null) 'near_lat': nearLat,
        if (nearLng != null) 'near_lng': nearLng,
      },
      cancelToken: cancelToken,
    );
    return DeepAreaSearchResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Resolve a picked area prediction to coordinates + optional geometry.
  /// Returns null when the backend answers `{area: null}` (unresolvable id).
  Future<ResolvedArea?> resolveArea({
    required String id,
    required String sessionToken,
    required String locale,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get(
      ApiConstants.geoAreaById(id),
      queryParameters: {'session_token': sessionToken, 'locale': locale},
      cancelToken: cancelToken,
    );
    final data = response.data as Map<String, dynamic>;
    final area = data['area'];
    if (area == null) return null;
    return ResolvedArea.fromJson(area as Map<String, dynamic>);
  }
}
