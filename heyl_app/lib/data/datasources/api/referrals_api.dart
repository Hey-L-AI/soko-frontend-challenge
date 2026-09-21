import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/api_responses.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Referrals API
class ReferralsApi implements IReferralsApi {
  final ApiClient _apiClient;

  ReferralsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<PendingSearchResponse> getPendingSearch(String slug) async {
    final response = await _dio.get(
      ApiConstants.pendingSearch(slug),
      options: Options(
        sendTimeout: ApiConstants.defaultTimeout,
        receiveTimeout: ApiConstants.defaultTimeout,
      ),
    );

    return PendingSearchResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
