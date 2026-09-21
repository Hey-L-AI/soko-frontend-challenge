import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:flutter/foundation.dart';

/// Thin, mockable seam over the `appsflyer_sdk` plugin.
///
/// Every AppsFlyer call the app makes goes through this interface so the
/// destination + service are unit-testable with a mock. This is the ONLY file
/// that references the concrete plugin API — if a plugin upgrade changes a
/// signature, it changes here and nowhere else.
///
/// Verified against the INSTALLED `appsflyer_sdk` 6.18.1 (pub cache source +
/// CHANGELOG.md), not just its README, since the README doesn't document
/// OneLink custom domains or consent.
abstract class AppsflyerClient {
  Future<void> initSdk();
  Future<void> startSdk();
  Future<void> logEvent(String eventName, Map<String, dynamic> values);
  Future<void> setCustomerUserId(String id);

  /// Uniform consent (spec §2a). isSubjectToGdpr is always false for us.
  Future<void> setConsentData({
    required bool isSubjectToGdpr,
    required bool hasConsentForDataUsage,
    required bool hasConsentForAdsPersonalization,
  });

  /// Register the Unified Deep Link callback (spec §4).
  void registerOnDeepLink(void Function(Map<String, dynamic> payload) onLink);
}

/// Real implementation backed by `AppsflyerSdk` from the plugin.
///
/// Plugin symbols confirmed against the installed 6.18.1 source
/// (`~/.pub-cache/hosted/pub.dev/appsflyer_sdk-6.18.1/lib/src/`):
/// - Options class is `AppsFlyerOptions` (not `AppSFlyerOptions`), and its
///   iOS app id field is `appId` (not `afAppId`).
/// - `appInviteOneLink` on `AppsFlyerOptions` only feeds the separate
///   User-Invite-API (`setAppInviteOneLinkID` / `generateInviteLink`) — it is
///   NOT the branded OneLink domain used for Unified Deep Linking. The
///   correct API for spec §4's branded domain is
///   `AppsflyerSdk.setOneLinkCustomDomain` (a list-of-domains setter that
///   "sets custom domain for OneLink aka Branded Domains"), called on the
///   sdk instance after construction.
/// - `setConsentData(AppsFlyerConsent)` was deprecated in 6.16.2
///   ("setConsentData is now deprecated! setConsentDataV2 is the new and
///   recommended way to set manual user consent." — CHANGELOG.md). It is
///   also structurally unable to express our case: `AppsFlyerConsent`'s only
///   public constructors are `forGDPRUser(...)` (hardcodes
///   `isUserSubjectToGDPR: true`) and `nonGDPRUser()` (hardcodes both
///   consent flags to `false`), so there is no way to build
///   `isSubjectToGdpr: false` with independently-set consent flags.
///   `AppsflyerSdk.setConsentDataV2` takes all three as raw named booleans
///   with no such constraint, so it is used here to pass the three values
///   through untouched, per spec §2a.
/// - `onDeepLinking(Function(DeepLinkResult))` is registered on the sdk
///   instance created in [initSdk] (matches the brief).
class RealAppsflyerClient implements AppsflyerClient {
  RealAppsflyerClient({
    required String devKey,
    required String iosAppId,
    required String oneLinkDomain,
  }) : _devKey = devKey,
       _iosAppId = iosAppId,
       _oneLinkDomain = oneLinkDomain;

  final String _devKey;
  final String _iosAppId;
  final String _oneLinkDomain;
  AppsflyerSdk? _sdk;
  void Function(Map<String, dynamic>)? _onLink;

  @override
  void registerOnDeepLink(void Function(Map<String, dynamic>) onLink) {
    // Stored now; wired onto the sdk in initSdk (the sdk doesn't exist yet).
    _onLink = onLink;
  }

  @override
  Future<void> initSdk() async {
    final options = AppsFlyerOptions(
      afDevKey: _devKey,
      appId: _iosAppId,
      showDebug: !kReleaseMode,
      timeToWaitForATTUserAuthorization: 0, // spec §2 — no ATT wait
      manualStart: true,
    );
    final sdk = AppsflyerSdk(options);
    _sdk = sdk;

    // Branded OneLink domain (spec §4) — see class doc: this is
    // setOneLinkCustomDomain, not the AppsFlyerOptions.appInviteOneLink
    // field (that one is for the unrelated User-Invite-API).
    sdk.setOneLinkCustomDomain([_oneLinkDomain]);

    final onLink = _onLink;
    if (onLink != null) {
      sdk.onDeepLinking((result) {
        onLink(result.deepLink?.clickEvent ?? const <String, dynamic>{});
      });
    }

    await sdk.initSdk(
      registerConversionDataCallback: true,
      registerOnDeepLinkingCallback: true,
    );
  }

  @override
  Future<void> startSdk() async => _sdk?.startSDK();

  @override
  Future<void> logEvent(String eventName, Map<String, dynamic> values) async {
    await _sdk?.logEvent(eventName, values);
  }

  @override
  Future<void> setCustomerUserId(String id) async =>
      _sdk?.setCustomerUserId(id);

  @override
  Future<void> setConsentData({
    required bool isSubjectToGdpr,
    required bool hasConsentForDataUsage,
    required bool hasConsentForAdsPersonalization,
  }) async {
    // See class doc: setConsentDataV2 (not the deprecated AppsFlyerConsent
    // object) is the only API that can carry these three values through
    // untouched — pass the arguments straight through, never a
    // hardcoded/placeholder consent object.
    _sdk?.setConsentDataV2(
      isUserSubjectToGDPR: isSubjectToGdpr,
      consentForDataUsage: hasConsentForDataUsage,
      consentForAdsPersonalization: hasConsentForAdsPersonalization,
    );
  }
}
