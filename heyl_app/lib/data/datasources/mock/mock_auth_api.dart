import 'dart:convert';

import '../../models/attribution_data.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'mock_data.dart';

/// Mock implementation of Auth API
class MockAuthApi implements IAuthApi {
  String? _storedPhone;
  String? _storedCode;
  String? _storedEmail;
  UserProfile? _currentUser;
  String? _accessToken;

  /// PROD-1979 — stub guest mint. Returns a fake JWT-looking token with
  /// `sub="guest:<visitor_id>"` so the FE's `isGuestJwt` check passes.
  @override
  Future<GuestSessionResponse> createGuestSession({String? visitorId}) async {
    await _simulateDelay();
    final vid = visitorId ?? 'mock-visitor-id';
    // Construct a syntactically valid JWT-looking string with a payload
    // the FE can decode (sub starts with "guest:").
    const header =
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'; // {"alg":"HS256","typ":"JWT"}
    final payload = base64Url
        .encode(utf8.encode('{"sub":"guest:$vid","role":"guest"}'))
        .replaceAll('=', '');
    const signature = 'mock-signature';
    return GuestSessionResponse(
      accessToken: '$header.$payload.$signature',
      tokenType: 'bearer',
      expiresIn: 86400,
      expiresAt: DateTime.now().add(const Duration(hours: 24)),
      visitorId: vid,
    );
  }

  /// Start phone login - simulates sending OTP
  @override
  Future<PhoneStartResponse> startPhoneLogin(
    String phone, {
    String channel = 'sms',
    String? appHash,
  }) async {
    await _simulateDelay();

    // Store phone and generate a mock code
    _storedPhone = phone;
    _storedCode = '123456'; // Fixed code for development

    return PhoneStartResponse(
      status: PhoneStartResponse.statusSent,
      channel: channel,
      smsFallbackAvailable: true,
    );
  }

  /// Verify OTP and login
  @override
  Future<LoginResponse> verifyOtp(
    String phone,
    String code, {
    AttributionData? attribution,
    String? returnTo,
    String? claimIntent,
  }) async {
    await _simulateDelay(milliseconds: 800);

    // For mock, accept any 6-digit code or the stored code
    if (code.length != 6) {
      throw Exception('Invalid code format');
    }

    // Validate against stored phone and code
    if (_storedPhone != null && phone != _storedPhone) {
      throw Exception('Phone number mismatch');
    }
    // Accept the stored code or any 6-digit code in dev mode
    if (_storedCode != null && code != _storedCode && code != '123456') {
      // For mock, we're lenient - accept any 6-digit code
    }

    // Log in with mock user
    // Generate a mock UUID based on phone (in production, backend generates the UUID)
    final mockUuid =
        'mock-${phone.hashCode.abs().toRadixString(16).padLeft(8, '0')}-0000-0000-0000-000000000000';
    _currentUser = MockData.mockUser.copyWith(
      id: mockUuid,
      userId: mockUuid, // userId is now UUID (same as id)
      displayIdentifier: phone, // Phone number for display
    );
    _accessToken = 'mock_token_${DateTime.now().millisecondsSinceEpoch}';

    return LoginResponse(
      user: _currentUser!.toJson(),
      accessToken: _accessToken!,
      tokenType: 'bearer',
    );
  }

  // ========== Passwordless Email-OTP Login (Mock, PROD-3595) ==========

  @override
  Future<EmailLoginStartResponse> startEmailLogin(String email) async {
    await _simulateDelay();

    _storedEmail = email;
    _storedCode = '123456'; // Fixed code for development

    return const EmailLoginStartResponse(
      status: EmailLoginStartResponse.statusSent,
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
    await _simulateDelay(milliseconds: 800);

    if (code.length != 6) {
      throw Exception('Invalid code format');
    }
    if (_storedEmail != null && email != _storedEmail) {
      throw Exception('Email mismatch');
    }

    // Find-or-create by email — mirror the real endpoint's auto-create.
    final mockUuid =
        'mock-${email.hashCode.abs().toRadixString(16).padLeft(8, '0')}-0000-0000-0000-000000000002';
    _currentUser = MockData.mockUser.copyWith(
      id: mockUuid,
      userId: mockUuid,
      displayIdentifier: email,
    );
    _accessToken = 'mock_token_${DateTime.now().millisecondsSinceEpoch}';

    return LoginResponse(
      user: _currentUser!.toJson(),
      accessToken: _accessToken!,
      tokenType: 'bearer',
    );
  }

  /// Get current user
  Future<UserProfile> getMe() async {
    await _simulateDelay(milliseconds: 200);

    if (_currentUser == null) {
      throw Exception('Not authenticated');
    }

    return _currentUser!;
  }

  @override
  Future<MessageResponse> logout() async {
    await _simulateDelay(milliseconds: 200);

    _currentUser = null;
    _accessToken = null;
    _storedPhone = null;
    _storedCode = null;
    _storedEmail = null;

    return const MessageResponse(message: 'Logged out successfully');
  }

  // ========== Email/Password Authentication (Mock) ==========

  @override
  Future<RegisterResponse> register({
    required String email,
    required String password,
    String? fullName,
    AttributionData? attribution,
  }) async {
    await _simulateDelay(milliseconds: 800);

    // Mock registration - always succeeds
    // Generate a mock UUID based on email (in production, backend generates the UUID)
    final mockUuid =
        'mock-${email.hashCode.abs().toRadixString(16).padLeft(8, '0')}-0000-0000-0000-000000000001';
    _currentUser = MockData.mockUser.copyWith(
      id: mockUuid,
      userId: mockUuid, // userId is now UUID (same as id)
      displayIdentifier: email, // Email for display
      fullName: fullName ?? MockData.mockUser.fullName,
    );
    _accessToken = 'mock_token_${DateTime.now().millisecondsSinceEpoch}';

    return RegisterResponse(
      user: _currentUser!.toJson(),
      accessToken: _accessToken!,
      tokenType: 'bearer',
    );
  }

  @override
  Future<LoginResponse> loginWithEmail({
    required String email,
    required String password,
    AttributionData? attribution,
  }) async {
    await _simulateDelay(milliseconds: 800);

    // Mock login - always succeeds
    // Generate a mock UUID based on email (in production, backend generates the UUID)
    final mockUuid =
        'mock-${email.hashCode.abs().toRadixString(16).padLeft(8, '0')}-0000-0000-0000-000000000001';
    _currentUser = MockData.mockUser.copyWith(
      id: mockUuid,
      userId: mockUuid, // userId is now UUID (same as id)
      displayIdentifier: email, // Email for display
    );
    _accessToken = 'mock_token_${DateTime.now().millisecondsSinceEpoch}';

    return LoginResponse(
      user: _currentUser!.toJson(),
      accessToken: _accessToken!,
      tokenType: 'bearer',
    );
  }

  @override
  Future<ActivationResponse> activateAccount(String token) async {
    await _simulateDelay(milliseconds: 500);

    // Mock activation - always succeeds
    return const ActivationResponse(
      message: 'Account activated successfully',
      email: 'test@example.com',
    );
  }

  @override
  Future<ResendActivationResponse> resendActivation(String email) async {
    await _simulateDelay(milliseconds: 500);

    return ResendActivationResponse(
      message: 'Activation email sent',
      email: email,
    );
  }

  @override
  Future<ForgotPasswordResponse> forgotPassword(
    String email, {
    String? origin,
  }) async {
    await _simulateDelay(milliseconds: 500);

    return const ForgotPasswordResponse(
      message:
          'If this email is registered, you will receive password reset instructions',
    );
  }

  @override
  Future<ResetPasswordResponse> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    await _simulateDelay(milliseconds: 500);

    return const ResetPasswordResponse(message: 'Password reset successfully');
  }

  // ========== OAuth Authentication (Mock) ==========

  @override
  Future<LoginResponse> loginWithApple({
    required String identityToken,
    required String authorizationCode,
    String? email,
    String? fullName,
    String? nonce,
    AttributionData? attribution,
  }) async {
    await _simulateDelay(milliseconds: 800);

    // Mock Apple login - always succeeds
    final mockEmail = email ?? 'apple_user@privaterelay.appleid.com';
    final mockUuid =
        'mock-apple-${mockEmail.hashCode.abs().toRadixString(16).padLeft(8, '0')}-0000-0000-000000000001';
    _currentUser = MockData.mockUser.copyWith(
      id: mockUuid,
      userId: mockUuid,
      displayIdentifier: mockEmail,
      fullName: fullName ?? MockData.mockUser.fullName,
    );
    _accessToken = 'mock_token_${DateTime.now().millisecondsSinceEpoch}';

    return LoginResponse(
      user: _currentUser!.toJson(),
      accessToken: _accessToken!,
      tokenType: 'bearer',
    );
  }

  @override
  Future<LoginResponse> loginWithGoogle({
    required String idToken,
    String? nonce,
    AttributionData? attribution,
  }) async {
    await _simulateDelay(milliseconds: 800);

    const mockEmail = 'google_user@gmail.com';
    final mockUuid =
        'mock-google-${mockEmail.hashCode.abs().toRadixString(16).padLeft(8, '0')}-0000-0000-000000000001';
    _currentUser = MockData.mockUser.copyWith(
      id: mockUuid,
      userId: mockUuid,
      displayIdentifier: mockEmail,
    );
    _accessToken = 'mock_token_${DateTime.now().millisecondsSinceEpoch}';

    return LoginResponse(
      user: _currentUser!.toJson(),
      accessToken: _accessToken!,
      tokenType: 'bearer',
    );
  }

  /// Check if authenticated
  bool get isAuthenticated => _accessToken != null && _currentUser != null;

  /// Get current access token
  String? get accessToken => _accessToken;

  /// Set authentication state (for restoring from storage)
  void setAuthState(UserProfile user, String token) {
    _currentUser = user;
    _accessToken = token;
  }

  Future<void> _simulateDelay({int milliseconds = 500}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
