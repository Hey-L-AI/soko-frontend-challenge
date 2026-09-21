import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Account API
class AccountApi implements IAccountApi {
  final ApiClient _apiClient;

  AccountApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<MessageResponse> deleteAccount(DeleteAccountRequest request) async {
    final response = await _dio.delete(
      ApiConstants.account,
      data: request.toJson(),
    );

    return MessageResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<SupportInfo> getSupportInfo() async {
    final response = await _dio.get(ApiConstants.support);
    return SupportInfo.fromJson(response.data as Map<String, dynamic>);
  }
}
