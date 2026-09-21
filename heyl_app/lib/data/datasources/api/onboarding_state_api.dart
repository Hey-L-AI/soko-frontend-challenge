import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/onboarding_state_models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';
import 'interceptors/retry_interceptor.dart';

/// Real implementation of the resumable chat-onboarding state API
/// (PROD-3882 / BE-1): `GET`/`PUT /api/v1/app/onboarding/state`.
class OnboardingStateApi implements IOnboardingStateApi {
  final ApiClient _apiClient;

  OnboardingStateApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<OnboardingStateDto> getState() async {
    final response = await _dio.get(
      ApiConstants.onboardingState,
      // GET is already retried by RetryInterceptor; the longer timeout gives a
      // cold-started backend room to answer the resume load.
      options: Options(receiveTimeout: ApiConstants.onboardingStateTimeout),
    );
    return OnboardingStateDto.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<OnboardingStateDto> putState(OnboardingStatePutDto request) async {
    final response = await _dio.put(
      ApiConstants.onboardingState,
      data: request.toJson(),
      // The state PUT is an idempotent full-state upsert (server forward-replays
      // the same answers to the same state), so it opts into retry — otherwise a
      // single transient blip surfaces the generic error mid-step. Longer timeout
      // survives a cold-started backend.
      options: Options(
        receiveTimeout: ApiConstants.onboardingStateTimeout,
        sendTimeout: ApiConstants.onboardingStateTimeout,
        extra: const {RetryInterceptor.idempotentRetryKey: true},
      ),
    );
    return OnboardingStateDto.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<OnboardingStateDto> resetState() async {
    final response = await _dio.post(ApiConstants.onboardingReset);
    return OnboardingStateDto.fromJson(response.data as Map<String, dynamic>);
  }
}
