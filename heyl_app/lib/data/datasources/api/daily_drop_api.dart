import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/daily_drop.dart';
import 'api_client.dart';

/// Status returned by `POST /api/v1/app/recommendations/daily/request`.
///
/// - `ctaProfiling` (PROD-1969 / PROD-1988): user is inside the new-user
///   profiling window — BE will not generate a drop; FE renders the
///   profiling CTA card instead of polling.
/// - `unsupportedCity` (PROD-2036): resolved city is outside the
///   supported launch markets — no task enqueued; FE renders the
///   explanatory CTA and must NOT poll.
enum DailyDropRequestStatus {
  ready,
  generating,
  ctaProfiling,
  unsupportedCity,
  unknown,
}

DailyDropRequestStatus _parseDailyDropRequestStatus(String? raw) {
  switch (raw) {
    case 'ready':
      return DailyDropRequestStatus.ready;
    case 'generating':
      return DailyDropRequestStatus.generating;
    case 'cta_profiling':
      return DailyDropRequestStatus.ctaProfiling;
    case 'unsupported_city':
      return DailyDropRequestStatus.unsupportedCity;
    default:
      return DailyDropRequestStatus.unknown;
  }
}

/// API client for the Daily Drop (recommendations) endpoints.
class DailyDropApi {
  final ApiClient _apiClient;

  DailyDropApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Request generation of today's daily drop.
  ///
  /// Returns the typed [DailyDropRequestStatus] from the BE response.
  /// Returns 202 when generation is enqueued, 200 when already exists or
  /// when the user is in the profiling window / unsupported city.
  ///
  /// Optional structured location signals (PROD-2045) are applied by the
  /// BE in priority order: `cityId` → `latitude`+`longitude`. When
  /// `cityId` is supplied, `latitude`/`longitude` are ignored — pass one
  /// OR the other, not both.
  Future<DailyDropRequestStatus> requestDailyDrop({
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
  }) async {
    final body = <String, dynamic>{
      if (cityId != null) 'city_id': cityId,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (locationSource != null) 'location_source': locationSource,
    };
    final response = await _dio.post(
      ApiConstants.dailyDropRequest,
      data: body.isEmpty ? null : body,
    );
    final data = response.data as Map<String, dynamic>;
    return _parseDailyDropRequestStatus(data['status'] as String?);
  }

  /// Get today's daily drop recommendation.
  ///
  /// Optional structured location signals (PROD-2045) follow the same
  /// priority order as [requestDailyDrop].
  Future<DailyDrop> getDailyDrop({
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
  }) async {
    final response = await _dio.get(
      ApiConstants.dailyDrop,
      queryParameters: {
        if (cityId != null) 'city_id': cityId,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (locationSource != null) 'location_source': locationSource,
      },
    );
    final data = response.data as Map<String, dynamic>;
    debugPrint('[DailyDrop] Raw API response: $data');
    debugPrint('[DailyDrop] poster_image_url: ${data['poster_image_url']}');
    debugPrint('[DailyDrop] poster_status: ${data['poster_status']}');
    debugPrint('[DailyDrop] recommendation_id: ${data['recommendation_id']}');
    debugPrint('[DailyDrop] status: ${data['status']}');
    final drop = DailyDrop.fromJson(data);
    debugPrint(
      '[DailyDrop] Parsed → posterImageUrl: ${drop.posterImageUrl}, posterStatus: ${drop.posterStatus}, isPosterReady: ${drop.isPosterReady}, isUnsupportedCity: ${drop.isUnsupportedCity}',
    );
    return drop;
  }

  /// Load one daily recommendation by id.
  ///
  /// Wraps `GET /api/v1/app/recommendations/{recommendation_id}`
  /// (PROD-2781). The response mirrors [getDailyDrop], so it parses into
  /// the same [DailyDrop] model. Used by PROD-3232 to resolve the
  /// personalized rationale ("why Soko picked this") for a drop reached
  /// via the Daily Drop card when the in-memory today's-drop state does
  /// not hold this id (historic drop / cold push deep-link).
  ///
  /// User-scoped and restricted to `recommendation_mode='daily'`: a
  /// forged or weekly-bundle id returns 404 (the caller treats any error
  /// as "no rationale" and renders nothing).
  Future<DailyDrop> getRecommendationById(String recommendationId) async {
    final response = await _dio.get(
      ApiConstants.recommendationById(recommendationId),
    );
    final data = response.data as Map<String, dynamic>;
    return DailyDrop.fromJson(data);
  }
}
