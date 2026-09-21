import 'web_otp_service_stub.dart'
    if (dart.library.html) 'web_otp_service_web.dart';

/// Result of WebOTP credential request
class WebOtpResult {
  final bool success;
  final String? code;
  final String? error;

  const WebOtpResult({
    required this.success,
    this.code,
    this.error,
  });

  const WebOtpResult.success(String code)
      : success = true,
        code = code,
        error = null;

  const WebOtpResult.failure(String error)
      : success = false,
        code = null,
        error = error;

  const WebOtpResult.cancelled()
      : success = false,
        code = null,
        error = null;
}

/// Abstract interface for WebOTP functionality
/// WebOTP allows Chrome Android to auto-read OTP from SMS and present it as a browser prompt
abstract class WebOtpService {
  /// Check if WebOTP is supported on the current platform/browser
  bool get isSupported;

  /// Request OTP via WebOTP API
  /// Returns a Future that completes when:
  /// - User receives SMS and browser extracts OTP (success)
  /// - User cancels the prompt (cancelled)
  /// - Timeout occurs (failure)
  /// - API not supported (failure)
  Future<WebOtpResult> requestOtp({
    Duration timeout = const Duration(minutes: 2),
  });

  /// Cancel any pending OTP request
  void cancel();

  /// Factory constructor returns platform-specific implementation
  factory WebOtpService() => createWebOtpService();
}
