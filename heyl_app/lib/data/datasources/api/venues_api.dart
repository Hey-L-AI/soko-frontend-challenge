import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';
import 'resolve_url_failure.dart';

/// Real implementation of Venues API
class VenuesApi implements IVenuesApi {
  final ApiClient _apiClient;

  VenuesApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<VenueListResponse> listVenues({
    String? city,
    int limit = 100,
    String? cursor,
  }) async {
    final queryParams = <String, dynamic>{'limit': limit};

    if (city != null && city.isNotEmpty) {
      queryParams['city'] = city;
    }
    if (cursor != null) {
      queryParams['cursor'] = cursor;
    }

    final response = await _dio.get(
      ApiConstants.venues,
      queryParameters: queryParams,
    );

    return VenueListResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<ResolveUrlResult> resolveVenueFromUrl(String url) async {
    try {
      final response = await _dio.post(
        ApiConstants.venuesResolveUrl,
        data: {'url': url},
      );
      final data = response.data as Map<String, dynamic>;
      // 202 → the URL was a shared Google Maps *list*; the backend started an
      // async import job instead of resolving a single venue. Hand the job off
      // to the import poller rather than parsing a venue (backend PROD-3903).
      if (response.statusCode == 202) {
        return ResolveUrlListImport(ImportJobCreatedResponse.fromJson(data));
      }
      return ResolveUrlPlace(_itemSuggestionFromVenueJson(data));
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  @override
  Future<ItemSuggestion> resolvePlaceId(String googlePlaceId) async {
    try {
      final response = await _dio.post(
        ApiConstants.venuesResolvePlaceId,
        data: {'google_place_id': googlePlaceId},
      );
      // 200 (DB hit) and 201 (created from Google) both return ResolveVenueOut.
      return _itemSuggestionFromVenueJson(
        response.data as Map<String, dynamic>,
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  /// Map a `ResolveVenueOut` JSON response (see backend PROD-1382) into an
  /// `ItemSuggestion` shaped like text-search place results, so the existing
  /// row widget renders it without modification. The `created` boolean on the
  /// response is ignored here — the UI doesn't distinguish.
  ItemSuggestion _itemSuggestionFromVenueJson(Map<String, dynamic> json) {
    final venueId = json['id'] as String;
    // `name` is nullable in the backend schema; fall back to an empty string
    // rather than crashing — the row widget handles empty names gracefully.
    final name = (json['name'] as String?) ?? '';
    return ItemSuggestion(
      id: venueId,
      name: name,
      type: 'place',
      venueId: venueId,
      imageUrl: json['image_url'] as String?,
      description: json['description'] as String?,
      address: json['address'] as String?,
      city: json['city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      rating: (json['rating'] as num?)?.toDouble(),
      ratingCount: json['rating_count'] as int?,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
      types: (json['types'] as List<dynamic>?)?.cast<String>(),
      googlePlaceId: json['google_place_id'] as String?,
      googleMapsUrl: json['google_maps_url'] as String?,
      website: json['website'] as String?,
      phone: json['phone'] as String?,
      openingHours: json['opening_hours'] as Map<String, dynamic>?,
    );
  }

  ResolveUrlFailure _mapDioError(DioException e) {
    // Network-level: no response received
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.connectionError) {
      return const ResolveUrlNetworkError();
    }

    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const ResolveUrlInvalid();
      case 404:
        return const ResolveUrlNotFound();
      case 422:
        return const ResolveUrlUnrecognized();
      case 429:
        return const ResolveUrlRateLimited();
      case 502:
        // Short-link expansion timed out / upstream unreachable — treat as a
        // transient network failure from the user's perspective.
        return const ResolveUrlNetworkError();
      default:
        return ResolveUrlUnknown(statusCode: status);
    }
  }
}
