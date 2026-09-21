import 'dart:io' show Platform;

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';
import 'package:tiktok_business_sdk/tiktok_business_sdk.dart';

import 'analytics/tiktok_destination.dart';

/// Owns the TikTok Business SDK lifecycle on mobile (PROD-2919).
///
/// Mirrors [MetaAnalyticsService]: init immediately on Android; on iOS
/// defer the actual SDK boot until ATT resolves, and only then open the
/// destination gate so buffered ops replay against a live SDK.
///
/// The TikTok pub package (`tiktok_business_sdk` 0.0.1) doesn't expose a
/// separate `activate()`/`startTrack()` step — `initTiktokBusinessSdk` is
/// both init and activation. So on iOS we skip the init call at cold
/// launch and defer it to [requestTrackingAuthorizationIfNeeded]. Guests
/// signing up before ATT get their `sign_up` replayed via
/// [TikTokDestination]'s pre-init buffer.
///
/// All public methods no-op when [enabled] is false so contributors
/// without TikTok credentials still build cleanly.
class TikTokAnalyticsService {
  TikTokAnalyticsService({
    TiktokBusinessSdk? client,
    required TikTokDestination destination,
    required this.enabled,
    required this.appId,
    required this.ttAppId,
    required this.accessToken,
  }) : _client = client ?? TiktokBusinessSdk(),
       _destination = destination;

  final TiktokBusinessSdk _client;
  final TikTokDestination _destination;
  final bool enabled;
  final String appId;
  final String ttAppId;
  final String accessToken;

  bool _initialized = false;
  bool _sdkBooted = false;

  /// Boot the TikTok SDK.
  ///
  /// - Android: call [initTiktokBusinessSdk] immediately and open the
  ///   destination gate.
  /// - iOS: no-op. The SDK boots after the ATT prompt resolves in
  ///   [requestTrackingAuthorizationIfNeeded] so no events fire pre-consent.
  /// - Web: no-op (that path uses `TikTokWebDestination`).
  /// - No-ops entirely when [enabled] is false or credentials are missing.
  Future<void> init() async {
    if (!enabled) return;
    if (!_credentialsPresent) return;
    if (_initialized) return;
    _initialized = true;
    if (_isAndroid) {
      await _bootSdkOnce();
      _destination.markInitialized();
    }
    // iOS: gate stays closed. Buffered ops flush after ATT resolves.
  }

  /// iOS ATT trigger (PROD-2263-style). Follows Meta's shape exactly so a
  /// single call site in [triggerAttIfNeeded] handles both SDKs.
  ///
  ///   1. If ATT already resolved → boot SDK and open gate.
  ///   2. Else → request ATT prompt, then boot + open gate.
  ///
  /// The system ATT dialog itself is driven by Meta's request in the same
  /// site; here we only apply the outcome. Calling
  /// `requestTrackingAuthorization` twice is safe (Apple caches the
  /// resolution), but we only need one dialog so if Meta ran first we just
  /// read the cached status.
  ///
  /// TikTok SDK reads `ATTrackingManager.trackingAuthorizationStatus`
  /// itself at event-emit time — no explicit setAdvertiserTracking-style
  /// call needed.
  Future<void> requestTrackingAuthorizationIfNeeded() async {
    if (!_isIOS) return;

    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status != TrackingStatus.notDetermined) {
      if (enabled && _credentialsPresent) {
        await _bootSdkOnce();
        _destination.markInitialized();
      }
      return;
    }

    final result = await AppTrackingTransparency.requestTrackingAuthorization();
    debugPrint(
      '[TikTokAnalyticsService] requestTrackingAuthorization result=$result, '
      'tiktokEnabled=$enabled',
    );
    if (enabled && _credentialsPresent) {
      await _bootSdkOnce();
      _destination.markInitialized();
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  bool get _credentialsPresent =>
      appId.isNotEmpty && ttAppId.isNotEmpty && accessToken.isNotEmpty;

  Future<void> _bootSdkOnce() async {
    if (_sdkBooted) return;
    try {
      await _client.initTiktokBusinessSdk(
        accessToken: accessToken,
        appId: appId,
        ttAppId: ttAppId,
        openDebug: kDebugMode,
        enableAutoIapTrack: false,
      );
      _sdkBooted = true;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[TikTokAnalyticsService] init failed: $e\n$st');
      }
    }
  }

  bool get _isIOS => !kIsWeb && Platform.isIOS;
  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
}
