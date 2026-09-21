import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Locales API
class LocalesApi implements ILocalesApi {
  final ApiClient _apiClient;

  LocalesApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<LocaleListResponse> listLocales() async {
    final response = await _dio.get(ApiConstants.locales);
    return LocaleListResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
