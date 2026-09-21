import 'package:flutter/foundation.dart';
import 'package:smart_auth/smart_auth.dart';

/// Thin wrapper over the Android SMS Retriever API (`smart_auth`) for silent
/// OTP auto-read (PROD-3323).
///
/// Android-only by construction: every method short-circuits to a no-op / null
/// on web and non-Android platforms so callers stay platform-agnostic. iOS keeps
/// using QuickType (the `oneTimeCode` autofill hint on the OTP field) and web
/// keeps using WebOTP — neither touches this service.
///
/// Platform detection uses [defaultTargetPlatform] (web-safe) rather than
/// `dart:io`'s `Platform`, which does not compile for web.
class SmsRetrieverService {
  SmsRetrieverService({SmartAuth? smartAuth})
    : _smartAuth = smartAuth ?? SmartAuth.instance;

  final SmartAuth _smartAuth;

  /// Codes are always 6 digits (see [SokoFormOtpInput]); match exactly so the
  /// extractor never grabs a stray number from the SMS body.
  static const _codeMatcher = r'\d{6}';

  /// Logged once per session so the hash surfaces even in release logs without
  /// spamming a line per OTP start.
  static bool _signatureLogged = false;

  /// True only where the Retriever API exists.
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The app-signing hash the SMS must end with for the Retriever to match.
  /// Differs between debug and Play-signed release builds, so it is computed at
  /// runtime and sent per-request rather than hardcoded. Returns null off
  /// Android or on failure.
  Future<String?> getAppSignature() async {
    if (!isSupported) return null;
    final result = await _smartAuth.getAppSignature();
    final hash = result.hasData ? result.data : null;
    // Retriever fails silently on a hash mismatch, so the computed hash must be
    // diagnosable from logs — including release builds, whose hash differs from
    // debug and can't otherwise be recovered (PROD-3323). The hash is not
    // secret. Logged unconditionally but only once per session.
    if (!_signatureLogged) {
      _signatureLogged = true;
      debugPrint('[SmsRetriever] app signature hash: $hash');
    }
    return hash;
  }

  /// Starts the Retriever listener and completes with the 6-digit code once the
  /// matching SMS arrives (or null on timeout / no match / off-Android). The
  /// native side auto-expires after ~5 min; callers should also [cancel] on
  /// dispose.
  Future<String?> listenForCode() async {
    if (!isSupported) return null;
    final result = await _smartAuth.getSmsWithRetrieverApi(
      matcher: _codeMatcher,
    );
    if (!result.hasData) return null;
    final code = result.data?.code;
    if (kDebugMode) {
      debugPrint(
        '[SmsRetriever] retrieved code: ${code == null ? 'none' : 'ok'}',
      );
    }
    return code;
  }

  /// Removes the native Retriever listener. Safe to call unconditionally.
  Future<void> cancel() async {
    if (!isSupported) return;
    await _smartAuth.removeSmsRetrieverApiListener();
  }
}
