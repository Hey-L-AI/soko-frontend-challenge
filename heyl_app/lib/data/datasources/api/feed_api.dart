import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// API client for the Discovery feed endpoints (PROD-1515 / PROD-1553 /
/// PROD-1554 / PROD-1963 / PROD-1999).
class FeedApi implements IFeedApi {
  final ApiClient _apiClient;

  FeedApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<FeedHomeOut> getHomeFeed({
    FeedFilter filter = FeedFilter.events,
    String? cityId,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? adminBoundaryId,
    String? cursor,
  }) async {
    final response = await _dio.get(
      ApiConstants.homeFeed,
      queryParameters: {
        'filter': filter.wire,
        if (cityId != null) 'city_id': cityId,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        // `radius_km`, NOT `radius_m`. The unified SearchLocation group is
        // kilometres across all five Discovery endpoints (`SearchLocationRadiusKm`
        // in the spec, `DEFAULT_RADIUS_KM = 100.0` server-side) and `lists_api`
        // already sends `radius_km`. A metres variant on this one endpoint
        // would be gratuitous divergence.
        if (radiusKm != null) 'radius_km': radiusKm,
        if (adminBoundaryId != null) 'admin_boundary_id': adminBoundaryId,
        if (cursor != null) 'cursor': cursor,
      },
    );
    return FeedHomeOut.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<NearYouEventsFeedResponse> getNearYouEventsFeed({
    required double latitude,
    required double longitude,
    int limit = 20,
    int offset = 0,
    String? seed,
    DateTime? snapshotAt,
    bool? personalize,
  }) async {
    final response = await _dio.get(
      ApiConstants.nearYouEventsFeed,
      queryParameters: {
        'latitude': latitude,
        'longitude': longitude,
        'limit': limit,
        'offset': offset,
        if (seed != null) 'seed': seed,
        if (snapshotAt != null)
          'snapshot_at': snapshotAt.toUtc().toIso8601String(),
        if (personalize != null) 'personalize': personalize,
      },
    );
    return NearYouEventsFeedResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<NearYouPlacesFeedResponse> getNearYouPlacesFeed({
    required double latitude,
    required double longitude,
    int limit = 20,
    int offset = 0,
    String? seed,
    DateTime? snapshotAt,
    bool? personalize,
  }) async {
    final response = await _dio.get(
      ApiConstants.nearYouPlacesFeed,
      queryParameters: {
        'latitude': latitude,
        'longitude': longitude,
        'limit': limit,
        'offset': offset,
        if (seed != null) 'seed': seed,
        if (snapshotAt != null)
          'snapshot_at': snapshotAt.toUtc().toIso8601String(),
        if (personalize != null) 'personalize': personalize,
      },
    );
    return NearYouPlacesFeedResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<DiscoveryForYouResponse> getDiscoveryForYou({
    String objective = 'for_you',
    String entityTypes = 'both',
    double? latitude,
    double? longitude,
    int numResults = 15,
    int offset = 0,
  }) async {
    final response = await _dio.post(
      ApiConstants.discovery,
      data: {
        'objective': objective,
        'entity_types': entityTypes,
        'num_results': numResults,
        'offset': offset,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      },
    );
    return DiscoveryForYouResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<HighlightedFeedResponse> getHighlightedFeed({
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
  }) async {
    final response = await _dio.get(
      ApiConstants.highlightedFeed,
      queryParameters: {
        if (cityId != null) 'city_id': cityId,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (locationSource != null) 'location_source': locationSource,
      },
    );
    return HighlightedFeedResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<VenuesWithEventsFeedResponse> getVenuesWithEventsFeed({
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
    int limit = 10,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.venuesWithEventsFeed,
      queryParameters: {
        if (cityId != null) 'city_id': cityId,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (locationSource != null) 'location_source': locationSource,
        'limit': limit,
        'offset': offset,
      },
    );
    return VenuesWithEventsFeedResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}
