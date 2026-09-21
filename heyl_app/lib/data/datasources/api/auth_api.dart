import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/attribution_data.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Auth API
class AuthApi implements IAuthApi {
  final ApiClient _apiClient;

  AuthApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  // ========== Phone OTP Authentication ==========

  @override
  Future<PhoneStartResponse> startPhoneLogin(
    String phone, {
    String channel = 'sms',
    String? appHash,
  }) async {
    if (kDebugMode) {
      debugPrint(
        '[AuthApi] startPhoneLogin - phone: $phone, channel: $channel',
      );
    }
    final response = await _dio.post(
      ApiConstants.authPhoneStart,
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

    return PhoneStartResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<LoginResponse> verifyOtp(
    String phone,
    String code, {
    AttributionData? attribution,
    String? returnTo,
    String? claimIntent,
  }) async {
    if (kDebugMode) {
      debugPrint(
        '[AuthApi] verifyOtp - phone: $phone, code: $code, attribution: ${attribution?.visitorId}',
      );
    }

    final data = <String, dynamic>{'phone': phone, 'code': code};

    // PROD-4040 T2.4: Business Connect return-state so the backend can validate
    // + echo business_return_to on the LoginResponse.
    if (returnTo != null && returnTo.isNotEmpty) data['return_to'] = returnTo;
    if (claimIntent != null && claimIntent.isNotEmpty) {
      data['claim_intent'] = claimIntent;
    }

    // Add attribution fields if present
    if (attribution != null) {
      data['visitor_id'] = attribution.visitorId;
      data['platform'] = attribution.platform;
      if (attribution.utmSource != null)
        data['utm_source'] = attribution.utmSource;
      if (attribution.utmMedium != null)
        data['utm_medium'] = attribution.utmMedium;
      if (attribution.utmCampaign != null)
        data['utm_campaign'] = attribution.utmCampaign;
      if (attribution.referralClickId != null)
        data['referral_click_id'] = attribution.referralClickId;
    }

    final response = await _dio.post(
      ApiConstants.authPhoneVerify,
      data: data,
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return LoginResponse.fromJson(response.data as Map<String, dynamic>);
  }

  // ========== Passwordless Email-OTP Login (PROD-3595) ==========

  @override
  Future<EmailLoginStartResponse> startEmailLogin(String email) async {
    if (kDebugMode) {
      debugPrint('[AuthApi] startEmailLogin - email: $email');
    }
    final response = await _dio.post(
      ApiConstants.authEmailLoginStart,
      data: {'email': email},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return EmailLoginStartResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<LoginResponse> verifyEmailLogin(
    String email,
    String code, {
    AttributionData? attribution,
    String? returnTo,
    String? claimIntent,
  }) async {
    if (kDebugMode) {
      debugPrint(
        '[AuthApi] verifyEmailLogin - email: $email, code: $code, attribution: ${attribution?.visitorId}',
      );
    }

    final data = <String, dynamic>{'email': email, 'code': code};

    // PROD-4040 T2.4: Business Connect return-state so the backend can validate
    // + echo business_return_to on the LoginResponse (symmetric to verifyOtp).
    if (returnTo != null && returnTo.isNotEmpty) data['return_to'] = returnTo;
    if (claimIntent != null && claimIntent.isNotEmpty) {
      data['claim_intent'] = claimIntent;
    }

    // Add attribution fields if present
    if (attribution != null) {
      data['visitor_id'] = attribution.visitorId;
      data['platform'] = attribution.platform;
      if (attribution.utmSource != null)
        data['utm_source'] = attribution.utmSource;
      if (attribution.utmMedium != null)
        data['utm_medium'] = attribution.utmMedium;
      if (attribution.utmCampaign != null)
        data['utm_campaign'] = attribution.utmCampaign;
      if (attribution.referralClickId != null)
        data['referral_click_id'] = attribution.referralClickId;
    }

    final response = await _dio.post(
      ApiConstants.authEmailLoginVerify,
      data: data,
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return LoginResponse.fromJson(response.data as Map<String, dynamic>);
  }

  // ========== Email/Password Authentication ==========

  @override
  Future<RegisterResponse> register({
    required String email,
    required String password,
    String? fullName,
    AttributionData? attribution,
  }) async {
    final data = <String, dynamic>{
      'email': email,
      'password': password,
      if (fullName != null && fullName.isNotEmpty) 'full_name': fullName,
    };

    // Add attribution fields if present
    if (attribution != null) {
      data['visitor_id'] = attribution.visitorId;
      data['platform'] = attribution.platform;
      if (attribution.utmSource != null)
        data['utm_source'] = attribution.utmSource;
      if (attribution.utmMedium != null)
        data['utm_medium'] = attribution.utmMedium;
      if (attribution.utmCampaign != null)
        data['utm_campaign'] = attribution.utmCampaign;
      if (attribution.referralClickId != null)
        data['referral_click_id'] = attribution.referralClickId;
    }

    final response = await _dio.post(
      ApiConstants.authRegister,
      data: data,
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return RegisterResponse.fromJson(response.data as Map<String, dynamic>);
  }

  // ========== Guest Session (PROD-1979) ==========

  @override
  Future<GuestSessionResponse> createGuestSession({String? visitorId}) async {
    if (kDebugMode) {
      debugPrint('[AuthApi] createGuestSession - visitorId: $visitorId');
    }
    final response = await _dio.post(
      ApiConstants.authGuest,
      data: {if (visitorId != null) 'visitor_id': visitorId},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );
    return GuestSessionResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<LoginResponse> loginWithEmail({
    required String email,
    required String password,
    AttributionData? attribution,
  }) async {
    final data = <String, dynamic>{'email': email, 'password': password};

    // Add attribution fields if present
    if (attribution != null) {
      data['visitor_id'] = attribution.visitorId;
      data['platform'] = attribution.platform;
      if (attribution.utmSource != null)
        data['utm_source'] = attribution.utmSource;
      if (attribution.utmMedium != null)
        data['utm_medium'] = attribution.utmMedium;
      if (attribution.utmCampaign != null)
        data['utm_campaign'] = attribution.utmCampaign;
      if (attribution.referralClickId != null)
        data['referral_click_id'] = attribution.referralClickId;
    }

    final response = await _dio.post(
      ApiConstants.authLogin,
      data: data,
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return LoginResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<ActivationResponse> activateAccount(String token) async {
    final response = await _dio.get(
      ApiConstants.authActivate,
      queryParameters: {'token': token},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return ActivationResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<ResendActivationResponse> resendActivation(String email) async {
    final response = await _dio.post(
      ApiConstants.authResendActivation,
      data: {'email': email},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return ResendActivationResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<ForgotPasswordResponse> forgotPassword(
    String email, {
    String? origin,
  }) async {
    final response = await _dio.post(
      ApiConstants.authForgotPassword,
      data: {'email': email, if (origin != null) 'origin': origin},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return ForgotPasswordResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<ResetPasswordResponse> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    final response = await _dio.post(
      ApiConstants.authResetPassword,
      data: {'token': token, 'new_password': newPassword},
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return ResetPasswordResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  // ========== OAuth Authentication ==========

  @override
  Future<LoginResponse> loginWithApple({
    required String identityToken,
    required String authorizationCode,
    String? email,
    String? fullName,
    String? nonce,
    AttributionData? attribution,
  }) async {
    final data = <String, dynamic>{
      'identity_token': identityToken,
      'authorization_code': authorizationCode,
      if (email != null) 'email': email,
      if (fullName != null && fullName.isNotEmpty) 'full_name': fullName,
      if (nonce != null) 'nonce': nonce,
    };

    // Add attribution fields if present
    if (attribution != null) {
      data['visitor_id'] = attribution.visitorId;
      data['platform'] = attribution.platform;
      if (attribution.utmSource != null)
        data['utm_source'] = attribution.utmSource;
      if (attribution.utmMedium != null)
        data['utm_medium'] = attribution.utmMedium;
      if (attribution.utmCampaign != null)
        data['utm_campaign'] = attribution.utmCampaign;
      if (attribution.referralClickId != null)
        data['referral_click_id'] = attribution.referralClickId;
    }

    final response = await _dio.post(
      ApiConstants.authAppleToken,
      data: data,
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return LoginResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<LoginResponse> loginWithGoogle({
    required String idToken,
    String? nonce,
    AttributionData? attribution,
  }) async {
    final data = <String, dynamic>{
      'id_token': idToken,
      if (nonce != null) 'nonce': nonce,
    };

    // Add attribution fields if present
    if (attribution != null) {
      data['visitor_id'] = attribution.visitorId;
      data['platform'] = attribution.platform;
      if (attribution.utmSource != null)
        data['utm_source'] = attribution.utmSource;
      if (attribution.utmMedium != null)
        data['utm_medium'] = attribution.utmMedium;
      if (attribution.utmCampaign != null)
        data['utm_campaign'] = attribution.utmCampaign;
      if (attribution.referralClickId != null)
        data['referral_click_id'] = attribution.referralClickId;
    }

    final response = await _dio.post(
      ApiConstants.authGoogleToken,
      data: data,
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );

    return LoginResponse.fromJson(response.data as Map<String, dynamic>);
  }

  // ========== Common ==========

  @override
  Future<UserProfile> getMe() async {
    final response = await _dio.get(
      ApiConstants.authMe,
      options: Options(
        sendTimeout: ApiConstants.authTimeout,
        receiveTimeout: ApiConstants.authTimeout,
      ),
    );
    return UserProfile.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<MessageResponse> logout() async {
    final response = await _dio.post(ApiConstants.authLogout);
    return MessageResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
