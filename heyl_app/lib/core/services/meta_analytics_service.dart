import 'dart:io' show Platform;

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:flutter/foundation.dart';

import 'analytics/meta_destination.dart';

/// Owns the Meta App Events SDK lifecycle.
///
/// Responsibilities:
/// - Call [MetaDestination.markInitialized] once the SDK is ready to log.
/// - On Android: call [activateApp()] immediately in [init()] so
///   guest/pre-signup `app_open` attribution works without an ATT gate.
/// - On iOS: defer [activateApp()] until ATT has resolved. The app root
///   calls [requestTrackingAuthorizationIfNeeded] on cold launch, which
///   drives the native ATT system prompt → setAdvertiserTracking →
///   activateApp sequence.
///
/// All public methods no-op when [enabled] is false so contributors without
/// Meta credentials still build cleanly.
///
/// Note on debug mode: `facebook_app_events ^0.27.2` does not expose a
/// `setIsDebugEnabled` API from Dart. Debug/test-event routing is configured
/// via Meta Events Manager's "Test Events" feature using the device's
/// Ad-Attribution key — no runtime toggle is needed from this service.
class MetaAnalyticsService {
  MetaAnalyticsService({
    FacebookAppEvents? client,
    required MetaDestination destination,
    required this.enabled,
  }) : _client = client ?? FacebookAppEvents(),
       _destination = destination;

  final FacebookAppEvents _client;
  final MetaDestination _destination;
  final bool enabled;
  bool _initialized = false;
  bool _activated = false;

  /// Boots the Meta SDK.
  ///
  /// - On Android: opens the destination gate and fires [activateApp]
  ///   immediately (no ATT on Android).
  /// - On iOS: **keeps the destination gated**. The gate is opened only
  ///   after ATT resolves in [requestTrackingAuthorizationIfNeeded]. This
  ///   ensures that no Meta events (including `setUserId`) leak before the
  ///   user has either granted or explicitly denied tracking. The cost is
  ///   that events fired between cold-launch and the user resolving the
  ///   system dialog are dropped; this is intentional.
  /// - No-ops entirely when [enabled] is false.
  Future<void> init() async {
    if (!enabled) return;
    if (_initialized) return;
    _initialized = true;
    if (_isAndroid) {
      await _activateOnce();
      _destination.markInitialized();
    }
    // iOS: destination stays inert until ATT resolves.
  }

  /// Called from the app root on iOS on cold launch (PROD-2263). Drives:
  ///   1. Check current ATT status.
  ///   2. If already determined (authorized / denied / restricted): set the
  ///      advertiser-tracking flag, open the destination gate, and activate.
  ///   3. If not determined: request the native ATT system dialog directly,
  ///      then on the returned status set tracking, open the gate, and
  ///      activate.
  ///
  /// The ATT system request itself runs even when [enabled] is false — Apple
  /// requires us to ask regardless of whether Meta credentials are present.
  /// Only the Meta-specific side effects (`setAdvertiserTracking`,
  /// `activateApp`, `markInitialized`) are gated on [enabled]. No-ops on
  /// Android and web. Idempotent across calls: once the user has resolved
  /// the dialog, `trackingAuthorizationStatus` returns the cached value and
  /// the system never re-shows the dialog.
  Future<void> requestTrackingAuthorizationIfNeeded() async {
    if (!_isIOS) return;

    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status != TrackingStatus.notDetermined) {
      debugPrint(
        '[MetaAnalyticsService] ATT already determined: status=$status, '
        'metaEnabled=$enabled',
      );
      if (enabled) {
        await _client.setAdvertiserTracking(
          enabled: status == TrackingStatus.authorized,
        );
        // Activate before opening the gate so the replayed buffer lands after
        // app activation, and so a failed activation doesn't latch (see
        // _activateOnce).
        await _activateOnce();
        _destination.markInitialized();
      }
      return;
    }

    final result = await AppTrackingTransparency.requestTrackingAuthorization();
    debugPrint(
      '[MetaAnalyticsService] requestTrackingAuthorization result=$result, '
      'metaEnabled=$enabled',
    );
    if (enabled) {
      await _client.setAdvertiserTracking(
        enabled: result == TrackingStatus.authorized,
      );
      await _activateOnce();
      _destination.markInitialized();
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<void> _activateOnce() async {
    if (_activated) return;
    try {
      await _client.activateApp();
      // Only latch on success — a failed native activation (e.g. SDK not
      // ready yet) must be retried on the next gate-open, not silently
      // swallowed forever.
      _activated = true;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[MetaAnalyticsService] activateApp failed: $e\n$st');
      }
    }
  }

  bool get _isIOS => !kIsWeb && Platform.isIOS;
  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
}
