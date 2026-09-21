import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/entity_ref.dart';
import 'api_client.dart';

/// API client for the user activity history endpoint (Discovery Page,
/// PROD-1521 / PROD-1514). Server-side hydration drops deleted/inactive
/// entities silently so the response can be shorter than `limit`; an empty
/// list is returned as `{items: []}` with HTTP 200 (never 404).
class UserActivityApi {
  final ApiClient _apiClient;

  UserActivityApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Recent activity for the authenticated user, deduped by entity and
  /// ordered most-recent-first. Backend caps `limit` at 20.
  Future<ActivityListResponse> getMyActivity({int limit = 6}) async {
    final response = await _dio.get(
      ApiConstants.myActivity,
      queryParameters: {'limit': limit},
    );
    return ActivityListResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
