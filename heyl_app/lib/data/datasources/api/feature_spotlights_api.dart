import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/feature_spotlight.dart';
import '../interfaces/feature_spotlights_api.dart';
import 'api_client.dart';

/// Real HTTP implementation of [IFeatureSpotlightsApi] (PROD-2808).
///
/// Tolerates 404 responses so the webapp can ship ahead of the backend
/// endpoints landing (PROD-2809). A 404 is treated as [FeatureSpotlightsState.empty]
/// on GET and as a no-op on POST — the local cache continues to drive
/// dismissal state until the endpoint is live.
class FeatureSpotlightsApi implements IFeatureSpotlightsApi {
  FeatureSpotlightsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<FeatureSpotlightsState> fetchState() async {
    try {
      final response = await _apiClient.dio.get(ApiConstants.featureSpotlights);
      final data = response.data;
      if (data is! Map<String, dynamic>) return FeatureSpotlightsState.empty;
      return FeatureSpotlightsState.fromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return FeatureSpotlightsState.empty;
      rethrow;
    }
  }

  @override
  Future<void> markSeen(
    String featureId, {
    FeatureSpotlightSeenReason? reason,
  }) async {
    try {
      await _apiClient.dio.post(
        ApiConstants.featureSpotlightSeen(featureId),
        data: {if (reason != null) 'reason': reason.wire},
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return;
      rethrow;
    }
  }
}
