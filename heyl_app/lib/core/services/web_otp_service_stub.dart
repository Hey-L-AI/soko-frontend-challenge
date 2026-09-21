import 'web_otp_service.dart';

/// Creates stub implementation for non-web platforms
WebOtpService createWebOtpService() => _StubWebOtpService();

class _StubWebOtpService implements WebOtpService {
  @override
  bool get isSupported => false;

  @override
  Future<WebOtpResult> requestOtp({
    Duration timeout = const Duration(minutes: 2),
  }) async {
    return const WebOtpResult.failure('WebOTP only supported on web');
  }

  @override
  void cancel() {
    // No-op on non-web platforms
  }
}
