import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/social/user_search_item.dart';
import 'api_client.dart';

/// People discovery — search + suggestions ("Locals near you")
/// (backend PROD-2777 / PROD-2821). Admin-gated pilot.
class PeopleApi {
  final ApiClient _apiClient;

  PeopleApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Search users by handle (prefix) or name (substring). Requires >= 2 chars.
  Future<UserSearchListResponse> search(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.userSearch,
      queryParameters: {'q': query, 'limit': limit, 'offset': offset},
    );
    return UserSearchListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Suggested users to follow — "Locals suggested" + friends-of-friends.
  ///
  /// The optional [cityId] / [latitude] / [longitude] scope the *locals* tier
  /// to the Discovery picker city (PROD-3748), mirroring the feed endpoints'
  /// `SearchLocation*` params. Omitting them preserves the viewer-relative
  /// ranking. [locationSource] is analytics-only and never affects ranking.
  Future<UserSearchListResponse> suggested({
    int limit = 20,
    int offset = 0,
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
  }) async {
    final response = await _dio.get(
      ApiConstants.suggestedUsers,
      queryParameters: {
        'limit': limit,
        'offset': offset,
        if (cityId != null) 'city_id': cityId,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (locationSource != null) 'location_source': locationSource,
      },
    );
    return UserSearchListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Contact discovery — send SHA-256 hashes of the device's E.164 contact
  /// numbers, get back the Soko users among them. Raw numbers never leave the
  /// device (mobile-only; PROD-2821).
  Future<UserSearchListResponse> matchContacts(List<String> phoneHashes) async {
    final response = await _dio.post(
      ApiConstants.contactsMatch,
      data: {'phone_hashes': phoneHashes},
    );
    return UserSearchListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}
