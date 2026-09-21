import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/attribution_data.dart';
import 'api_client.dart';

/// API client for attribution tracking endpoints
class AttributionApi {
  final ApiClient _apiClient;

  AttributionApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Record an attribution touchpoint
  /// This endpoint does not require authentication (anonymous tracking)
  Future<TouchpointResponse> recordTouchpoint(AttributionData data) async {
    if (kDebugMode) {
      debugPrint('[AttributionApi] recordTouchpoint - visitorId: ${data.visitorId}, '
          'platform: ${data.platform}, utmSource: ${data.utmSource}');
    }

    final response = await _dio.post(
      ApiConstants.attributionTouchpoint,
      data: data.toJson(),
      options: Options(
        sendTimeout: ApiConstants.defaultTimeout,
        receiveTimeout: ApiConstants.defaultTimeout,
      ),
    );

    return TouchpointResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
