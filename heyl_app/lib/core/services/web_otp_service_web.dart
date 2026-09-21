@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

import 'web_otp_service.dart';

/// Creates web implementation
WebOtpService createWebOtpService() => _WebOtpService();

/// Check if OTPCredential is available in the browser
@JS('window.OTPCredential')
external JSObject? get _otpCredentialClass;

class _WebOtpService implements WebOtpService {
  web.AbortController? _abortController;

  @override
  bool get isSupported {
    // Check if OTPCredential is available in the browser
    // This is available in Chrome 84+ on Android
    try {
      return _otpCredentialClass != null;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<WebOtpResult> requestOtp({
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (!isSupported) {
      return const WebOtpResult.failure('WebOTP not supported in this browser');
    }

    try {
      // Create AbortController for cancellation
      _abortController = web.AbortController();

      // Create the options object for navigator.credentials.get()
      final options = _CredentialRequestOptions(
        otp: _OTPOptions(transport: ['sms'].jsify() as JSArray<JSString>),
        signal: _abortController!.signal,
      );

      // Call navigator.credentials.get(options)
      final credential = await web.window.navigator.credentials
          .get(options as web.CredentialRequestOptions)
          .toDart
          .timeout(timeout, onTimeout: () {
        cancel();
        throw TimeoutException('OTP request timed out');
      });

      if (credential == null) {
        return const WebOtpResult.cancelled();
      }

      // Extract the OTP code from the credential
      // OTPCredential has a 'code' property
      final otpCredential = credential as _OTPCredential;
      final code = otpCredential.code;
      if (code.isEmpty) {
        return const WebOtpResult.failure('No OTP code in credential');
      }

      return WebOtpResult.success(code);
    } on TimeoutException {
      return const WebOtpResult.failure('OTP request timed out');
    } catch (e) {
      final errorString = e.toString();
      // DOMException with name "AbortError" means user cancelled
      if (errorString.contains('AbortError') ||
          errorString.contains('aborted')) {
        return const WebOtpResult.cancelled();
      }
      return WebOtpResult.failure('WebOTP error: $e');
    } finally {
      _abortController = null;
    }
  }

  @override
  void cancel() {
    _abortController?.abort();
    _abortController = null;
  }
}

/// OTPCredential interface (returned by navigator.credentials.get for OTP)
extension type _OTPCredential._(JSObject _) implements JSObject {
  external String get code;
}

/// OTP options for credentials.get()
extension type _OTPOptions._(JSObject _) implements JSObject {
  external factory _OTPOptions({
    required JSArray<JSString> transport,
  });
}

/// Credential request options with OTP support
extension type _CredentialRequestOptions._(JSObject _) implements JSObject {
  external factory _CredentialRequestOptions({
    _OTPOptions? otp,
    web.AbortSignal? signal,
  });
}
