import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/interfaces/api_interfaces.dart';
import '../../data/models/user_preferences.dart';
import '../../providers/api_provider.dart';
import '../../providers/auth_provider.dart';
import '../services/experiment_service.dart';

typedef FcmTokenFetcher = Future<String?> Function();
typedef FcmTokenRefreshStream = Stream<String> Function();

/// PROD-2511 — registers the FCM registration token with the backend
/// so the HeyL notifications pipeline (gates → template → inbox →
/// Celery → FCM `messaging.send()`) can deliver pushes on both iOS
/// and Android.
///
/// Separate from the Klaviyo marketing path managed by
/// [PushPermissionService]. Klaviyo's iOS SDK surfaces the raw APNs
/// device token (~64 hex chars) and the backend tags it
/// `vendor='apns'` — fine for Klaviyo's bulk-jobs push, useless for
/// FCM `messaging.send()`. Firebase's APNs ↔ FCM exchange yields the
/// ~150-char FCM token registered here.
///
/// Three trigger paths, all funneled through [_registerToken]'s dedup:
///   1. [initialise] — initial fetch on app startup (after auth
///      transitions to true via [isAuthenticatedProvider] listener).
///   2. `FirebaseMessaging.onTokenRefresh` — natural rotation events.
///   3. [refresh] — explicit kick from
///      [PushPermissionService._syncPushOptInValue] after the Klaviyo
///      PATCH lands, so a freshly-granted user gets the FCM token
///      registered in the same lifecycle as the APNs one.
class FcmTokenService {
  FcmTokenService(
    this._ref, {
    FcmTokenFetcher? tokenFetcher,
    FcmTokenRefreshStream? refreshStream,
  }) : _tokenFetcher =
           tokenFetcher ?? (() => FirebaseMessaging.instance.getToken()),
       _refreshStream =
           refreshStream ?? (() => FirebaseMessaging.instance.onTokenRefresh);

  final Ref _ref;
  final FcmTokenFetcher _tokenFetcher;
  final FcmTokenRefreshStream _refreshStream;

  bool _initialised = false;
  StreamSubscription<String>? _refreshSub;
  ProviderSubscription<bool>? _authSub;

  /// Dedup against the last successful PATCH so onTokenRefresh +
  /// auth-listener + explicit `refresh()` don't all PATCH the same
  /// string. Cleared on dispose; otherwise persists across the
  /// service's lifetime, which mirrors the device-token lifetime.
  String? _lastPatchedToken;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  IPreferencesApi get _preferencesApi => _ref.read(preferencesApiProvider);

  /// Idempotent. Subscribes to onTokenRefresh and listens for the
  /// auth-transition so a cold-start authed user gets registered as
  /// soon as the access token is available.
  Future<void> initialise() async {
    if (_initialised || !_isMobile) return;
    _initialised = true;

    _refreshSub = _refreshStream().listen(
      _registerToken,
      onError: (Object e) {
        debugPrint('[FcmTokenService] onTokenRefresh error: $e');
      },
    );

    // fireImmediately covers the cold-start case where auth resolves
    // to true before this listener attaches. Subsequent prev→next
    // transitions (login mid-session) re-fire too.
    //
    // PROD-2511 — on logout (true → false) clear ``_lastPatchedToken`` so
    // the next login PATCHes the FCM token even when the same install-
    // scoped token comes back from Firebase. Without this, switching
    // accounts on the same device leaves the new user without an FCM row
    // (Firebase keeps the token bound to the app install, not the user,
    // so ``getToken()`` returns the same string the prior user already
    // PATCHed and the dedup short-circuits before reaching the backend).
    _authSub = _ref.listen<bool>(isAuthenticatedProvider, (prev, next) {
      if (next && prev != true) {
        unawaited(refresh());
      } else if (prev == true && !next) {
        _lastPatchedToken = null;
      }
    }, fireImmediately: true);
  }

  /// Public re-fetch + register. Safe to call repeatedly — dedup
  /// against [_lastPatchedToken] keeps the backend quiet, and the
  /// auth gate inside [_registerToken] prevents pre-auth 401s.
  Future<void> refresh() async {
    if (!_isMobile) return;
    String? token;
    try {
      token = await _tokenFetcher();
    } catch (e) {
      // iOS getToken throws transiently right after launch if the APNs
      // ↔ FCM exchange hasn't completed. onTokenRefresh will fire when
      // it does; nothing to do here.
      debugPrint('[FcmTokenService] getToken threw: $e');
      return;
    }
    if (token == null || token.isEmpty) return;
    await _registerToken(token);
  }

  Future<void> _registerToken(String token) async {
    if (token.isEmpty || token == _lastPatchedToken) return;
    // PROD-2511 — kill-switch gate. If the engine is disabled via the
    // PostHog flag, never PATCH a token. The app.dart init is already
    // gated on the same flag; this catches mid-session flips and
    // onTokenRefresh fires that race the listener.
    if (!_ref.read(experimentServiceProvider).notificationsEngineEnabled) {
      return;
    }
    // Gate on auth — /preferences PATCH 401s pre-auth. The
    // isAuthenticatedProvider listener in [initialise] re-kicks us on
    // the false→true transition, so skipping here is safe.
    if (!_ref.read(isAuthenticatedProvider)) return;
    try {
      await _preferencesApi.updatePreferences(
        UpdatePreferencesRequest(
          fcmToken: token,
          pushNotificationPlatform: defaultTargetPlatform == TargetPlatform.iOS
              ? 'ios'
              : 'android',
        ),
      );
      _lastPatchedToken = token;
    } catch (e) {
      debugPrint('[FcmTokenService] updatePreferences(fcm) failed: $e');
    }
  }

  void dispose() {
    _refreshSub?.cancel();
    _authSub?.close();
    _refreshSub = null;
    _authSub = null;
    _initialised = false;
    _lastPatchedToken = null;
  }

  @visibleForTesting
  String? get lastPatchedTokenForTesting => _lastPatchedToken;
}

final fcmTokenServiceProvider = Provider<FcmTokenService>((ref) {
  final service = FcmTokenService(ref);
  ref.onDispose(service.dispose);
  return service;
});
