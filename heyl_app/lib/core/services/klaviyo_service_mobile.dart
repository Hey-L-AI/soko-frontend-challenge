import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:klaviyo_flutter_sdk/klaviyo_flutter_sdk.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../config/environment.dart';
import 'push_permission_state.dart';

class KlaviyoService {
  static bool _initialized = false;
  static bool _disabledLogged = false;
  static bool _profileSynced = false;
  static StreamSubscription<Map<String, dynamic>>? _pushEventSubscription;

  final KlaviyoSDK _sdk = KlaviyoSDK();

  /// PROD-3112: `false` in every non-production build, so a dev or staging
  /// device can never link itself to a real production Klaviyo profile. When
  /// this is `false` the service behaves exactly like the web stub — nothing
  /// initialises and every call below no-ops.
  bool get isEnabled => EnvironmentConfig.klaviyoEnabled;

  Future<void> initialize() async {
    if (_initialized) return;
    if (!isEnabled) {
      if (!_disabledLogged) {
        final env = EnvironmentConfig.analyticsEnvironment;
        final reason = env != 'prod'
            ? 'non-production environment ($env)'
            : 'KLAVIYO_PUBLIC_API_KEY is empty';
        debugPrint('[Klaviyo] Disabled: $reason');
        _disabledLogged = true;
      }
      return;
    }

    try {
      await _sdk.initialize(apiKey: EnvironmentConfig.klaviyoPublicApiKey);
      _initialized = true;
      _listenForPushEvents();
      debugPrint('[Klaviyo] Initialized');
    } catch (e) {
      debugPrint('[Klaviyo] Initialization failed: $e');
    }
  }

  /// Links the device's Klaviyo SDK install to the Soko user via `external_id`
  /// only. Backend (PROD-2178) owns every other profile field. We still need
  /// this on mobile so the device push token attaches to the correct profile.
  Future<void> identify(String userId) async {
    await initialize();
    if (!_initialized) return;
    try {
      await _sdk.setProfile(KlaviyoProfile(externalId: userId));
      _profileSynced = true;
      debugPrint('[Klaviyo] Identified: $userId');
    } catch (e) {
      debugPrint('[Klaviyo] identify failed: $e');
    }
  }

  Future<PushRegResult> requestPushPermissionAndRegister() async {
    if (!isEnabled) return PushRegResult.sdkDisabled;
    try {
      await initialize();
    } catch (e) {
      debugPrint('[Klaviyo] init failed: $e');
      return PushRegResult.sdkInitFailed;
    }
    if (!_initialized) return PushRegResult.sdkInitFailed;

    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      final isAllowed =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!isAllowed) return PushRegResult.permissionDenied;

      await _sdk.registerForPushNotifications();
      final token = await _sdk.getPushToken();
      return token != null && token.isNotEmpty
          ? PushRegResult.registered
          : PushRegResult.registeredTokenUnknown;
    } catch (e) {
      debugPrint('[Klaviyo] Push registration failed: $e');
      return PushRegResult.failed;
    }
  }

  /// Current OS push-notification authorization state. Returns `true` when
  /// the user has granted permission (including provisional on iOS); `false`
  /// for `denied`, `notDetermined`, and when the SDK is disabled.
  Future<bool> get isPushAuthorized async {
    if (!isEnabled) return false;
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('[Klaviyo] Reading push permission failed: $e');
      return false;
    }
  }

  /// Opens the OS app-settings page where the user can grant or revoke
  /// notification permission. iOS / Android only — the caller is expected
  /// to refresh `isPushAuthorized` on `AppLifecycleState.resumed`.
  Future<void> openNotificationSettings() async {
    try {
      await ph.openAppSettings();
    } catch (e) {
      debugPrint('[Klaviyo] Opening notification settings failed: $e');
    }
  }

  Future<PushRegResult> registerForPushIfAlreadyAuthorized() async {
    if (!isEnabled) return PushRegResult.sdkDisabled;
    try {
      await initialize();
    } catch (e) {
      debugPrint('[Klaviyo] init failed: $e');
      return PushRegResult.sdkInitFailed;
    }
    if (!_initialized) return PushRegResult.sdkInitFailed;

    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      final isAllowed =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!isAllowed) return PushRegResult.permissionDenied;

      await _sdk.registerForPushNotifications();
      final token = await _sdk.getPushToken();
      return token != null && token.isNotEmpty
          ? PushRegResult.registered
          : PushRegResult.registeredTokenUnknown;
    } catch (e) {
      debugPrint('[Klaviyo] Re-registration failed: $e');
      return PushRegResult.failed;
    }
  }

  /// Cheap check: does Klaviyo currently know a push token for this
  /// install? Does NOT trigger registration. Returns false if the SDK
  /// is disabled or uninitialised.
  Future<bool> verifyTokenPresence() async {
    if (!isEnabled || !_initialized) return false;
    try {
      final token = await _sdk.getPushToken();
      return token != null && token.isNotEmpty;
    } catch (e) {
      debugPrint('[Klaviyo] verifyTokenPresence threw: $e');
      return false;
    }
  }

  /// Returns the current Klaviyo push token for this install, or `null`
  /// if there is none / the SDK is disabled. Sent to the backend in
  /// `PATCH /preferences { pn_optin, push_notification_token }` so the
  /// backend can write Klaviyo's `subscriptions.push.tokens[0]`.
  /// Required when opting in (else 422); included on opt-out when
  /// available so the backend can remove the token from Klaviyo.
  Future<String?> getPushToken() async {
    if (!isEnabled || !_initialized) return null;
    try {
      final token = await _sdk.getPushToken();
      if (token == null || token.isEmpty) return null;
      return token;
    } catch (e) {
      debugPrint('[Klaviyo] getPushToken threw: $e');
      return null;
    }
  }

  Future<void> handleUniversalTrackingLink(Uri uri) async {
    if (!_initialized || !isEnabled) return;

    try {
      _sdk.handleUniversalTrackingLink(uri.toString());
    } catch (e) {
      debugPrint('[Klaviyo] Tracking link handling failed: $e');
    }
  }

  Future<void> resetProfile() async {
    await initialize();
    if (!_initialized) return;

    try {
      await _sdk.resetProfile();
      _profileSynced = false;
      debugPrint('[Klaviyo] Profile reset');
    } catch (e) {
      debugPrint('[Klaviyo] Profile reset failed: $e');
    }
  }

  Future<void> trackEvent(
    String eventName, {
    Map<String, dynamic>? properties,
  }) async {
    await initialize();
    if (!_initialized) return;

    try {
      await _sdk.createEvent(
        KlaviyoEvent.custom(metric: eventName, properties: properties),
      );
    } catch (e) {
      debugPrint('[Klaviyo] Event tracking failed for $eventName: $e');
    }
  }

  void _listenForPushEvents() {
    _pushEventSubscription ??= _sdk.onPushNotification.listen((event) {
      if (kDebugMode) {
        debugPrint('[Klaviyo] Push event: $event');
      }
    });
  }
}
