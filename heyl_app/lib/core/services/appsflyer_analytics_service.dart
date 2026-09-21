import 'dart:io' show Platform;

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';

import 'analytics/appsflyer_client.dart';
import 'analytics/appsflyer_consent.dart';
import 'analytics/appsflyer_destination.dart';

/// Owns the AppsFlyer SDK lifecycle (spec §2).
///
/// Cold-launch: init, set provisional consent from the CURRENT ATT status
/// (normally notDetermined -> false), then startSDK() ONCE with NO ATT wait so
/// the install is sent immediately (no memory-cache loss). The deferred ATT
/// prompt later calls [updateConsentOnAttResolved]; that update is NOT
/// retroactive (AF does not backfill the IDFA onto the already-sent install).
///
/// SKAdNetwork is left ENABLED (the SDK default) so AppsFlyer receives Apple's
/// SKAN postbacks — paired with the `NSAdvertisingAttributionReportEndpoint`
/// postback-copy key in Info.plist. (SKAN was previously disabled until Growth
/// owned the conversion-value config; re-enabled once they did.)
///
/// No-ops entirely when [enabled] is false.
class AppsflyerAnalyticsService {
  AppsflyerAnalyticsService({
    required AppsflyerClient client,
    required AppsflyerDestination destination,
    required this.enabled,
    bool? isIOS,
    Future<TrackingStatus> Function()? attStatus,
  }) : _client = client,
       _destination = destination,
       _isIOS = isIOS ?? (!kIsWeb && Platform.isIOS),
       _attStatus =
           attStatus ??
           (() => AppTrackingTransparency.trackingAuthorizationStatus);

  final AppsflyerClient _client;
  final AppsflyerDestination _destination;
  final bool enabled;
  final bool _isIOS;
  final Future<TrackingStatus> Function() _attStatus;
  bool _started = false;

  /// [onDeepLink] is the UDL handler (Task 13). It MUST be registered before
  /// `startSDK()` — AppsFlyer requires the deep-link callback set at init time
  /// — so it's wired here, not later in app.dart.
  Future<void> init({
    String? knownUserId,
    void Function(Map<String, dynamic> payload)? onDeepLink,
  }) async {
    if (!enabled) return;
    if (_started) return; // idempotent — startSDK fires once
    _started = true;

    // Register UDL BEFORE initSdk/startSdk (spec §4). The client stores it and
    // applies it to the sdk instance created in initSdk.
    if (onDeepLink != null) {
      _client.registerOnDeepLink(onDeepLink);
    }

    // SKAdNetwork is left ENABLED (the SDK default) so AppsFlyer receives
    // Apple's SKAN postbacks. initSdk() constructs the underlying AppsflyerSdk;
    // startSdk() (below) registers the SKAN session under manualStart.
    await _client.initSdk();

    if (knownUserId != null && knownUserId.isNotEmpty) {
      await _client.setCustomerUserId(knownUserId);
    }

    final status = _isIOS ? await _attStatus() : null;
    final consent = appsflyerConsentFor(status, isIOS: _isIOS);
    await _client.setConsentData(
      isSubjectToGdpr: consent.isSubjectToGdpr,
      hasConsentForDataUsage: consent.hasConsentForDataUsage,
      hasConsentForAdsPersonalization: consent.hasConsentForAdsPersonalization,
    );

    await _client.startSdk();
    _destination.markStarted();
  }

  /// Called from [triggerAttIfNeeded] after the deferred ATT prompt resolves.
  /// Re-sends consent with the resolved status. NOT retroactive (spec §2).
  Future<void> updateConsentOnAttResolved(TrackingStatus status) async {
    if (!enabled || !_isIOS) return;
    final consent = appsflyerConsentFor(status, isIOS: true);
    await _client.setConsentData(
      isSubjectToGdpr: consent.isSubjectToGdpr,
      hasConsentForDataUsage: consent.hasConsentForDataUsage,
      hasConsentForAdsPersonalization: consent.hasConsentForAdsPersonalization,
    );
  }
}
