import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Location API
class LocationApi implements ILocationApi {
  final ApiClient _apiClient;

  LocationApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<LocationUpdateResponse> updateLocation(
    LocationUpdateRequest request,
  ) async {
    final response = await _dio.put(
      ApiConstants.myLocation,
      data: request.toJson(),
    );

    return LocationUpdateResponse.fromJson(
        response.data as Map<String, dynamic>);
  }

  @override
  Future<LocationUpdateResponse> updateTaggedLocation(
    String tag,
    LocationUpdateRequest request,
  ) async {
    // BE's `UserLocationTaggedCreate` requires `tag` (Literal "home" |
    // "work" | "current") in the body, even though it's also the path
    // param. Merge it in here — `LocationUpdateRequest.toJson()` is
    // shared with the untagged endpoint where the field doesn't exist.
    final response = await _dio.put(
      ApiConstants.myLocationTagged(tag),
      data: {
        ...request.toJson(),
        'tag': tag,
      },
    );

    return LocationUpdateResponse.fromJson(
        response.data as Map<String, dynamic>);
  }

  @override
  Future<LocationSnapshot?> getLocation() async {
    try {
      final response = await _dio.get(ApiConstants.myLocation);

      if (response.data == null) {
        return null;
      }

      return LocationSnapshot.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      // Location may not exist yet
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> createShareLink({
    int expiresInHours = 24,
  }) async {
    final response = await _dio.post(
      ApiConstants.locationShareLink,
      data: {
        'expires_in_hours': expiresInHours,
      },
    );

    return response.data as Map<String, dynamic>;
  }
}
