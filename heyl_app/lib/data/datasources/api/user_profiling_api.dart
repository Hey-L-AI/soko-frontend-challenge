import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of the V6 questionnaire API. The backend surface is
/// now named user profiling, while the wire fields/i18n keys are unchanged.
class UserProfilingApi implements IUserProfilingApi {
  final ApiClient _apiClient;

  UserProfilingApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<UserProfilingQuestions> getQuestions() async {
    final response = await _dio.get(ApiConstants.userProfilingQuestions);
    return UserProfilingQuestions.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<UserProfilingSubmitResponse> submit(
    UserProfilingSubmitRequest request,
  ) async {
    final response = await _dio.post(
      ApiConstants.userProfilingSubmit,
      data: request.toJson(),
    );
    return UserProfilingSubmitResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}
