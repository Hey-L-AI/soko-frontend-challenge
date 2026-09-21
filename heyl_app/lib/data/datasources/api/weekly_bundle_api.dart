import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/weekly_bundle.dart';
import 'api_client.dart';

/// API client for the Weekly Bundle (recommendations) endpoints.
class WeeklyBundleApi {
  final ApiClient _apiClient;

  WeeklyBundleApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Get this week's bundle.
  ///
  /// Optional structured location signals (PROD-2045) are applied by the
  /// BE in priority order: `cityId` → `latitude`+`longitude`. When
  /// `cityId` is supplied, `latitude`/`longitude` are ignored.
  Future<WeeklyBundle> getWeeklyBundle({
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
  }) async {
    final response = await _dio.get(
      ApiConstants.weeklyBundle,
      queryParameters: {
        if (cityId != null) 'city_id': cityId,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (locationSource != null) 'location_source': locationSource,
      },
    );
    final data = response.data as Map<String, dynamic>;
    debugPrint(
      '[WeeklyBundle] status: ${data['status']}, pages: ${(data['page_image_urls'] as List?)?.length}, items: ${(data['items'] as List?)?.length}',
    );
    return WeeklyBundle.fromJson(data);
  }
}
