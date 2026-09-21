import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/utils/client_platform.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

class PreferencesApi implements IPreferencesApi {
  final ApiClient _apiClient;

  PreferencesApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<UserPreferences> getPreferences() async {
    // `X-Client-Platform` tells the backend which platform is asking so it can
    // strip `push_notification_opt_in_at` on web (push is mobile-only). The full
    // filter contract is documented on `UserPreferences` in the OpenAPI spec.
    final response = await _dio.get(
      ApiConstants.myPreferences,
      options: Options(headers: {'X-Client-Platform': clientPlatformHeader()}),
    );
    return UserPreferences.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<UserPreferences> updatePreferences(
    UpdatePreferencesRequest request,
  ) async {
    final response = await _dio.patch(
      ApiConstants.myPreferences,
      data: request.toJson(),
    );
    return UserPreferences.fromJson(response.data as Map<String, dynamic>);
  }
}
