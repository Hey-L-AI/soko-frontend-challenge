import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Auth Methods API
class AuthMethodsApi implements IAuthMethodsApi {
  final ApiClient _apiClient;

  AuthMethodsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<AuthMethodsListResponse> listAuthMethods() async {
    final response = await _dio.get(ApiConstants.myAuthMethods);
    return AuthMethodsListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<RemoveAuthMethodResponse> removeAuthMethod(String methodId) async {
    final response = await _dio.delete(ApiConstants.myAuthMethod(methodId));
    return RemoveAuthMethodResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<OTPStartResponse> startAddPhone(
    String phone, {
    String channel = 'sms',
    String? appHash,
  }) async {
    final response = await _dio.post(
      ApiConstants.myAuthPhoneStart,
      data: {
        'phone': phone,
        'channel': channel,
        if (appHash != null) 'app_hash': appHash,
      },
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );
    return OTPStartResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<dynamic> verifyAddPhone(String phone, String code) async {
    final response = await _dio.post(
      ApiConstants.myAuthPhoneVerify,
      data: {'phone': phone, 'code': code},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    final data = response.data as Map<String, dynamic>;

    // Check if merge is required
    if (data['merge_required'] == true) {
      return VerifyWithMergeResponse.fromJson(data);
    }

    return AddAuthMethodResponse.fromJson(data);
  }

  @override
  Future<OTPStartResponse> startAddEmail(String email) async {
    final response = await _dio.post(
      ApiConstants.myAuthEmailStart,
      data: {'email': email},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );
    return OTPStartResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<dynamic> verifyAddEmail(String email, String code) async {
    final response = await _dio.post(
      ApiConstants.myAuthEmailVerify,
      data: {'email': email, 'code': code},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    final data = response.data as Map<String, dynamic>;

    // Check if merge is required
    if (data['merge_required'] == true) {
      return VerifyWithMergeResponse.fromJson(data);
    }

    return AddAuthMethodResponse.fromJson(data);
  }

  @override
  Future<MergeConfirmResponse> confirmMerge(MergeConfirmRequest request) async {
    final response = await _dio.post(
      ApiConstants.myAuthMerge,
      data: request.toJson(),
    );
    return MergeConfirmResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<ProfileUpdateResponse> updateProfile(
    ProfileUpdateRequest request,
  ) async {
    final response = await _dio.patch(
      ApiConstants.myProfile,
      data: request.toJson(),
    );
    return ProfileUpdateResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<HandleAvailabilityResponse> checkHandleAvailability(
    String handle,
  ) async {
    final response = await _dio.get(ApiConstants.handleAvailable(handle));
    return HandleAvailabilityResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<void> updateWhatsappPreference(String whatsappPhone) async {
    await _dio.put(
      ApiConstants.myWhatsappPreference,
      data: {'whatsapp_phone': whatsappPhone},
    );
    // Response is {whatsapp_phone, message} - no need to parse
    // The caller refreshes the user profile after this succeeds
  }
}
