import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/interfaces/api_interfaces.dart';
import '../../data/models/user_preferences.dart';
import '../../providers/api_provider.dart';
import '../../providers/preferences_provider.dart';
import '../notifications/fcm_token_service.dart';
import 'klaviyo_service.dart';
import 'push_permission_state.dart';
import 'unified_analytics_service.dart';

const _kCardDismissedKey = 'push_card_dismissed_v1';

/// Persisted count of return-reprompt attempts whose OS dialog failed to
/// present (see [PushPermissionService.maybeRepromptOnReturn]). A dialog
/// that presents resolves `notDetermined` and never qualifies again, so a
/// non-zero value here means the sdk_failure race is recurring — we retry
/// up to [_kReturnRepromptMaxAttempts] across returns, then stop nagging.
const _kReturnRepromptAttemptsKey = 'push_return_reprompt_attempts_v1';
const _kReturnRepromptMaxAttempts = 3;

/// State emitted by [PushPermissionService]. Wrapping the permission
/// state and the dismissal flag together lets the UI react to both
/// via a single `ref.watch`.
class PushUiState {
  final PushPermissionState permission;
  final bool cardDismissed;
  const PushUiState({required this.permission, required this.cardDismissed});

  PushUiState copyWith({PushPermissionState? permission, bool? cardDismissed}) {
    return PushUiState(
      permission: permission ?? this.permission,
      cardDismissed: cardDismissed ?? this.cardDismissed,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PushUiState &&
      other.permission == permission &&
      other.cardDismissed == cardDismissed;

  @override
  int get hashCode => Object.hash(permission, cardDismissed);
}

/// Single source of truth for "should the user see a push prompt
/// somewhere in the UI right now?". Owns the in-flight mutex so
/// concurrent registration attempts (auth restore + lifecycle resume
/// + user tap) share one Klaviyo call.
class PushPermissionService extends Notifier<PushUiState> {
  Completer<PushRegResult>? _inFlight;
  bool _disposed = false;
  String? _lastAuthUserId;
  bool _backendSyncAllowed = false;

  /// Tracks the last analytic emission per source so the
  /// `lifecycle_resume` self-heal path doesn't re-emit `sdk_failure`
  /// on every app foreground when a user is persistently stuck in
  /// `osAuthorisedTokenMissing`. We emit only on transitions.
  final Map<String, PushRegResult> _lastEmitted = {};

  /// PROD-2178: backend writes a Klaviyo outbox row on each `pn_optin`
  /// PATCH using `idempotency_key = (user_id, action, timestamp_second)`.
  /// Two PATCHes with the same payload in the same second collide and
  /// surface as 500. The service has two paths that legitimately fire
  /// the same value back-to-back — `_syncPushOptInResult(result)`
  /// followed by `_syncPushOptIn(next)` from the `refresh()` after
  /// `requestAndRegister` / `_registerIfAuthorized` — so we dedup here.
  /// Cache is updated only on PATCH success; failures preserve retry
  /// capability by leaving the cache unchanged.
  bool? _lastSyncedOptIn;
  String? _lastSyncedToken;

  @override
  PushUiState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
    });
    Future.microtask(refresh);
    return const PushUiState(
      permission: PushPermissionState.loading(),
      cardDismissed: false,
    );
  }

  KlaviyoService get _klaviyo => ref.read(klaviyoServiceProvider);
  IPreferencesApi get _preferencesApi => ref.read(preferencesApiProvider);

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  /// Recompute state from OS + Klaviyo. Idempotent.
  ///
  /// [syncBackend] is false for pre-Siga auth changes: those should update
  /// local UI state without recording push consent before the user reaches
  /// the Siga consent surface.
  Future<void> refresh({bool syncBackend = true}) async {
    final prefs = await SharedPreferences.getInstance();
    // Race-safe: if the user already dismissed in-memory (e.g. during
    // the very first build()'s microtask-scheduled refresh), preserve
    // that. The disk write may not have landed yet, but the in-memory
    // state captures the intent — and dismiss is one-way.
    final dismissed =
        (prefs.getBool(_kCardDismissedKey) ?? false) || state.cardDismissed;

    if (!_klaviyo.isEnabled || !_isMobile) {
      state = state.copyWith(
        permission: deriveState(
          sdkEnabled: _klaviyo.isEnabled,
          isMobile: _isMobile,
          authStatus: AuthorizationStatus.notDetermined,
          tokenPresent: false,
        ),
        cardDismissed: dismissed,
      );
      return;
    }

    AuthorizationStatus authStatus;
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      authStatus = settings.authorizationStatus;
    } catch (e) {
      debugPrint('[PushPermissionService] getNotificationSettings failed: $e');
      authStatus = AuthorizationStatus.notDetermined;
    }

    final tokenPresent = await _klaviyo.verifyTokenPresence();

    var next = deriveState(
      sdkEnabled: true,
      isMobile: true,
      authStatus: authStatus,
      tokenPresent: tokenPresent,
    );

    // Self-heal: if OS allows but Klaviyo has no token, silently retry
    // registration once. The mutex prevents recursion if a user-tap or
    // auth-change call is already in flight.
    if (next is PushPermissionReady &&
        next.sub == ReadySubState.osAuthorisedTokenMissing &&
        _inFlight == null) {
      await _registerIfAuthorized(source: 'lifecycle_resume');
      final afterToken = await _klaviyo.verifyTokenPresence();
      next = deriveState(
        sdkEnabled: true,
        isMobile: true,
        authStatus: authStatus,
        tokenPresent: afterToken,
      );
    }

    if (_disposed) return;
    if (syncBackend && _backendSyncAllowed) {
      await _syncPushOptIn(next);
    }
    if (_disposed) return;
    state = PushUiState(permission: next, cardDismissed: dismissed);
  }

  /// Called by auth_provider when the cached/refreshed user changes.
  ///
  /// Only attempts registration when the OS is already in an allowed
  /// state — calling _registerIfAuthorized unconditionally would
  /// produce a permissionDenied result for notDetermined users, which
  /// would falsely emit a 'denied' analytic without a real prompt.
  Future<void> onAuthChanged({
    required String userId,
    required bool shouldRegisterIfAuthorized,
  }) async {
    // PROD-2244 — reset per-session dedup caches so analytics + Klaviyo
    // consent fire again for the newly-logged-in user. Both caches were
    // added for intra-session reasons that don't carry across users:
    //
    //   * `_lastEmitted` is the lifecycle_resume flood guard
    //     (`_emitRegistrationOutcome`'s transition gate) — meant to
    //     suppress repeated `sdk_failure` emissions for a single user
    //     stuck in `osAuthorisedTokenMissing`. After a re-login as
    //     User B with the OS still authorized, the cached `registered`
    //     result for `auth_change` would suppress User B's
    //     `push_permission(action=granted)` event entirely.
    //
    //   * `_lastSyncedOptIn` / `_lastSyncedToken` exist to dodge
    //     PROD-2178's same-second `idempotency_key = (user_id, action,
    //     ts)` collision on the BE Klaviyo outbox. The key already
    //     includes `user_id` server-side, so per-device dedup across
    //     users blocks legitimate writes — the symptom is no
    //     `pn_optin=true` PATCH for User B, so Klaviyo never learns
    //     User B granted consent and won't send them push.
    //
    // Clearing here (vs. in `AuthNotifier.logout`) keeps the cache
    // lifecycle owned by the service that owns the caches. It is still
    // identity-aware: cached-user restore and the follow-up `getMe()` for
    // the same user must preserve the PROD-2178 same-payload dedup.
    final identityChanged = _lastAuthUserId != userId;
    _lastAuthUserId = userId;
    _backendSyncAllowed = shouldRegisterIfAuthorized;
    if (identityChanged) {
      _lastEmitted.clear();
      _lastSyncedOptIn = null;
      _lastSyncedToken = null;
    }

    if (!_klaviyo.isEnabled || !_isMobile) {
      await refresh(syncBackend: shouldRegisterIfAuthorized);
      return;
    }
    if (shouldRegisterIfAuthorized) {
      try {
        final settings = await FirebaseMessaging.instance
            .getNotificationSettings();
        final allowed =
            settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
        if (allowed) {
          await _registerIfAuthorized(source: 'auth_change');
        }
      } catch (e) {
        debugPrint('[PushPermissionService] onAuthChanged precheck failed: $e');
      }
    }
    await refresh(syncBackend: shouldRegisterIfAuthorized);
  }

  /// User-tap path (chat card or settings row). Fires OS prompt if
  /// needed, then registers.
  Future<PushRegResult> requestAndRegister({required String source}) async {
    if (_inFlight != null) return _inFlight!.future;
    _backendSyncAllowed = true;
    final completer = Completer<PushRegResult>();
    _inFlight = completer;
    // iOS displays privacy prompts out-of-process and temporarily marks the
    // app inactive; requesting notification permission while inactive — e.g.
    // immediately after Siga's ATT prompt, or during a resume transition —
    // can silently fail to present, leaving the OS `notDetermined`. That race
    // is the leading cause of the `sdk_failure` cohort. Wait for the app to be
    // foreground-active before firing, so the dialog reliably shows.
    await _waitForForegroundActive();
    // PROD-3210: measure "asked" DIRECTLY — before this, "never asked"
    // (34% of users) could only be inferred from the absence of
    // push_permission. Fires only when the OS prompt will actually show
    // (notDetermined); an already-granted/denied user re-tapping does not
    // count as being asked again.
    final platform = _platformLabel;
    if (platform != null) {
      try {
        final settings = await FirebaseMessaging.instance
            .getNotificationSettings();
        if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
          ref
              .read(unifiedAnalyticsProvider)
              .trackPushPromptShown(source: source, platform: platform);
        }
      } catch (_) {
        // Settings unavailable — skip the prompt beacon, never block the ask.
      }
    }
    PushRegResult result;
    try {
      result = await _klaviyo.requestPushPermissionAndRegister();
    } catch (e) {
      result = PushRegResult.failed;
    }
    _emitRegistrationOutcome(source: source, result: result);
    await _syncPushOptInResult(result);
    completer.complete(result);
    _inFlight = null;
    unawaited(refresh());
    return result;
  }

  /// Mark the card permanently dismissed. Refreshes state so any
  /// `ref.watch` consumer rebuilds.
  Future<void> dismissCard() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCardDismissedKey, true);
    state = state.copyWith(cardDismissed: true);
  }

  /// Re-present the OS notification dialog when an eligible user returns to
  /// the app. Targets the two recoverable cohorts behind our missing-push
  /// numbers — users who dropped out before the onboarding push step
  /// ("never asked") and users whose prompt failed to present
  /// ("sdk_failure"). Both derive to [ReadySubState.osNotDetermined], and on
  /// iOS that state only persists if the dialog was never shown, so
  /// auto-firing is self-limiting: one real presentation resolves it forever.
  ///
  /// A dialog that genuinely fails to present (the persistent sdk_failure
  /// race) is not written off after a single try — we bump a bounded counter
  /// and retry on a later return, up to [_kReturnRepromptMaxAttempts], then
  /// stop. `denied` users are a different state ([ReadySubState.osDenied])
  /// and are excluded automatically — the OS won't re-present to them anyway.
  ///
  /// Called from app resume and cold-start (see `app.dart`); idempotent and
  /// safe to fire on every return.
  Future<void> maybeRepromptOnReturn() async {
    if (!_klaviyo.isEnabled || !_isMobile) return;
    if (_inFlight != null) return; // a prompt is already running

    // Siga owns the prompt while the consent gate is unrecorded — never race
    // it. `null` means preferences haven't loaded yet (cold start): load them
    // and re-read so we don't prompt out of order, then require an explicit
    // `false` before continuing.
    var needsSiga = ref.read(needsSokoIntroProvider);
    if (needsSiga == null) {
      await ref.read(preferencesProvider.notifier).load();
      if (_disposed) return;
      needsSiga = ref.read(needsSokoIntroProvider);
    }
    if (needsSiga != false) return;

    final prefs = await SharedPreferences.getInstance();
    final attempts = prefs.getInt(_kReturnRepromptAttemptsKey) ?? 0;

    // Refresh so the decision reflects the live OS status.
    await refresh();
    if (_disposed) return;
    if (!shouldReprompt(
      permission: state.permission,
      attemptCount: attempts,
      needsSiga: false,
    )) {
      return;
    }

    await requestAndRegister(source: 'return_reprompt');
    if (_disposed) return;

    // Did the dialog actually present? If the OS is no longer `notDetermined`
    // the user answered (or it resolved) and the state guard alone stops
    // future attempts. If it's still `notDetermined`, the dialog never
    // presented — bump the bounded counter so we retry on a later return.
    if (await _isOsNotDetermined()) {
      if (_disposed) return;
      await prefs.setInt(_kReturnRepromptAttemptsKey, attempts + 1);
    }
  }

  /// Waits until the app is foreground-active (or a short cap elapses) before
  /// an OS permission prompt. A `null` lifecycle state, or a binding that
  /// isn't initialized (web / unit tests), means "proceed" — never block or
  /// throw on those paths.
  Future<void> _waitForForegroundActive() async {
    const step = Duration(milliseconds: 100);
    for (var i = 0; i < 20; i++) {
      final AppLifecycleState? lifecycle;
      try {
        lifecycle = WidgetsBinding.instance.lifecycleState;
      } catch (_) {
        return; // binding not initialized — nothing to wait for
      }
      if (lifecycle == null || lifecycle == AppLifecycleState.resumed) return;
      await Future<void>.delayed(step);
      if (_disposed) return;
    }
  }

  Future<bool> _isOsNotDetermined() async {
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.notDetermined;
    } catch (_) {
      return false;
    }
  }

  Future<PushRegResult> _registerIfAuthorized({required String source}) async {
    if (_inFlight != null) return _inFlight!.future;
    final completer = Completer<PushRegResult>();
    _inFlight = completer;
    PushRegResult result;
    try {
      result = await _klaviyo.registerForPushIfAlreadyAuthorized();
    } catch (e) {
      result = PushRegResult.failed;
    }
    _emitRegistrationOutcome(source: source, result: result);
    await _syncPushOptInResult(result);
    completer.complete(result);
    _inFlight = null;
    return result;
  }

  // ---------- Analytics helpers ----------

  /// Returns null on non-mobile platforms (web). When null, no
  /// push_permission analytic should be emitted — the spec is mobile
  /// only and platform labels must not be falsified.
  String? get _platformLabel {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return null;
    }
  }

  void _emitRegistrationOutcome({
    required String source,
    required PushRegResult result,
  }) {
    final platform = _platformLabel;
    if (platform == null) return; // not iOS/Android — feature is OOB
    // Transition-gate: only emit when the result for this source
    // changes. Otherwise lifecycle_resume self-heal would flood
    // sdk_failure every foreground for users stuck in
    // osAuthorisedTokenMissing.
    if (_lastEmitted[source] == result) return;
    _lastEmitted[source] = result;
    final analytics = ref.read(unifiedAnalyticsProvider);
    // Map PushRegResult to the analytics 'action' contract. The key
    // correctness rule: OS-granted-but-Klaviyo-failed (registeredTokenUnknown)
    // is the bad state we're trying to surface — emit 'sdk_failure',
    // NOT 'granted'.
    final action = switch (result) {
      PushRegResult.registered => 'granted',
      PushRegResult.permissionDenied => 'denied',
      PushRegResult.registeredTokenUnknown ||
      PushRegResult.sdkDisabled ||
      PushRegResult.sdkInitFailed ||
      PushRegResult.failed => 'sdk_failure',
    };
    analytics.trackPushPermission(
      action: action,
      source: source,
      platform: platform,
      registrationResult: result.name,
    );
  }

  Future<void> _syncPushOptIn(PushPermissionState permission) async {
    if (permission is! PushPermissionReady) return;
    // Don't treat "OS-authorized but Klaviyo token not yet surfaced" as an
    // opt-out. On iOS getPushToken() returns null transiently right after
    // launch/resume (the Klaviyo SDK re-surfaces the token async), deriving
    // osAuthorisedTokenMissing — a non-`verified` Ready state. Mapping that to
    // `pn_optin=false` made every app resume (app.dart's
    // didChangeAppLifecycleState → refresh) PATCH a false opt-out for users who
    // actually granted, and the backend then revoked their token
    // (revoked_reason=opt_out). Mirror how `_syncPushOptInResult` already skips
    // the equivalent `registeredTokenUnknown` — let the next refresh re-check
    // once the token lands and PATCH the authoritative state then.
    if (permission.sub == ReadySubState.osAuthorisedTokenMissing) return;
    await _syncPushOptInValue(permission.sub == ReadySubState.verified);
  }

  /// Test seam for the refresh-path opt-in sync. Production reaches
  /// `_syncPushOptIn` only from `refresh()`, which derives state via
  /// `FirebaseMessaging.instance.getNotificationSettings()` — an
  /// un-injectable plugin singleton that throws under `flutter test`. This
  /// exposes the mapping so the `osAuthorisedTokenMissing` regression
  /// (never PATCH a false opt-out for a token that just hasn't surfaced) can
  /// be asserted directly.
  @visibleForTesting
  Future<void> syncPushOptInForTesting(PushPermissionState permission) =>
      _syncPushOptIn(permission);

  Future<void> _syncPushOptInResult(PushRegResult result) async {
    // PROD-2178: `registeredTokenUnknown` means OS authorized but Klaviyo
    // hasn't surfaced the token yet — the user said "yes", we just can't
    // satisfy the backend's `pn_optin=true requires push_notification_token`
    // contract this turn. Skip and let the next lifecycle re-check (which
    // calls `_syncPushOptIn`) PATCH once the token lands. Similarly, SDK
    // init failures and SDK-disabled (web stub) have no signal to record.
    switch (result) {
      case PushRegResult.registered:
        await _syncPushOptInValue(true);
      case PushRegResult.permissionDenied:
      case PushRegResult.failed:
        await _syncPushOptInValue(false);
      case PushRegResult.registeredTokenUnknown:
      case PushRegResult.sdkInitFailed:
      case PushRegResult.sdkDisabled:
        // skip — no authoritative state to PATCH
        return;
    }
  }

  /// Best-effort token read. When [shouldPollForToken] is true (opt-in
  /// paths), retries a few times with short backoff so the Klaviyo SDK's
  /// async token write can land. When false (opt-out paths), the token
  /// is optional, so a single attempt is enough. Defensive try/catch:
  /// never let a Klaviyo SDK throw block the in-flight Completer chain
  /// in [requestAndRegister].
  Future<String?> _tryGetTokenWithPoll({
    required bool shouldPollForToken,
  }) async {
    Future<String?> readOnce() async {
      try {
        return await _klaviyo.getPushToken();
      } catch (e) {
        debugPrint('[PushPermissionService] getPushToken threw: $e');
        return null;
      }
    }

    var token = await readOnce();
    if (!shouldPollForToken || (token != null && token.isNotEmpty)) {
      return token;
    }

    // ~3s total at 100ms cadence. Tight enough not to delay the Siga
    // continue flow visibly; loose enough that APNs/FCM round-trip
    // post-registration completes on devices that recycle the OS prompt.
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_disposed) return null;
      token = await readOnce();
      if (token != null && token.isNotEmpty) return token;
    }
    return token;
  }

  Future<void> _syncPushOptInValue(bool optedIn) async {
    if (_disposed) return;
    // PROD-2178: backend requires `push_notification_token` AND
    // `push_notification_platform` when `pn_optin=true` (returns 422
    // otherwise) — Klaviyo's bulk-jobs payload rejects bare-string
    // tokens. On opt-out the token + platform are optional but we
    // include them when we have them so the backend can remove that
    // token from the Klaviyo subscription.
    //
    // On opt-in we MUST get a token before the PATCH. The Klaviyo SDK
    // writes the token to local state asynchronously after
    // `registerForPushNotifications` resolves — on a freshly-granted
    // device the prompt's user-interaction delay gives this plenty of
    // time, but on a re-authorized device (e.g. delete-account →
    // re-signup on the same install, where the OS prompt is skipped)
    // the SDK can return `registered` before the token write lands.
    // We poll for up to ~3s before giving up so a single missed token
    // doesn't leave the backend permanently in `pn_optin = null`.
    String? token = await _tryGetTokenWithPoll(shouldPollForToken: optedIn);
    if (_disposed) return;
    if (optedIn && (token == null || token.isEmpty)) {
      // After polling the SDK still has no token. PATCHing `pn_optin=true`
      // without one would 422 — so abandon the PATCH and surface the
      // failure loudly. The user's `*_at` will stay NULL and the Siga
      // gate will fire again next launch, prompting another attempt.
      debugPrint(
        '[PushPermissionService] token never surfaced after poll — pn_optin: true PATCH abandoned',
      );
      return;
    }
    // Dedup against the last successful PATCH — `requestAndRegister`
    // and `_registerIfAuthorized` both fire `_syncPushOptInResult`
    // followed by `refresh()`'s `_syncPushOptIn(next)`, which would
    // send the same payload twice and trip the backend's per-second
    // idempotency_key uniqueness constraint (500).
    if (_lastSyncedOptIn == optedIn && _lastSyncedToken == token) {
      debugPrint(
        '[PushPermissionService] dedup: pn_optin=$optedIn already synced',
      );
      return;
    }
    // This service is gated to `_isMobile` (iOS/Android) so the platform
    // is always one of those two. Bundled with the token so Klaviyo can
    // route the push correctly (server derives `vendor` from this:
    // ios → apns, android → fcm).
    final platform = token == null ? null : _platformString();
    try {
      await _preferencesApi.updatePreferences(
        UpdatePreferencesRequest(
          pnOptin: optedIn,
          pushNotificationToken: token,
          pushNotificationPlatform: platform,
        ),
      );
      // Only update the dedup cache after a successful PATCH so the
      // next call can retry if this one threw mid-flight.
      _lastSyncedOptIn = optedIn;
      _lastSyncedToken = token;
      // PROD-2511 — kick the FCM-token registration now that auth and
      // permission are confirmed. Piggybacks on the Klaviyo PATCH's
      // auth gating; the call dedups internally.
      unawaited(ref.read(fcmTokenServiceProvider).refresh());
    } catch (e) {
      debugPrint('[PushPermissionService] pn_optin backend sync failed: $e');
    }
  }

  /// Returns `ios` / `android` for the only two platforms this service
  /// runs on. Returns `null` for anything else (defensive — `_isMobile`
  /// already gates this code path, so non-iOS/Android is unreachable).
  String? _platformString() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return null;
    }
  }

  // ---------- Pure helpers (testable without Riverpod) ----------

  @visibleForTesting
  static PushPermissionState deriveState({
    required bool sdkEnabled,
    required bool isMobile,
    required AuthorizationStatus authStatus,
    required bool tokenPresent,
  }) {
    if (!isMobile) {
      return const PushPermissionState.unavailable(
        UnavailableReason.notSupportedPlatform,
      );
    }
    if (!sdkEnabled) {
      return const PushPermissionState.unavailable(
        UnavailableReason.klaviyoDisabled,
      );
    }
    switch (authStatus) {
      case AuthorizationStatus.authorized:
        return tokenPresent
            ? const PushPermissionState.ready(ReadySubState.verified)
            : const PushPermissionState.ready(
                ReadySubState.osAuthorisedTokenMissing,
              );
      case AuthorizationStatus.provisional:
        return tokenPresent
            ? const PushPermissionState.ready(
                ReadySubState.verified,
                quality: AuthQuality.provisional,
              )
            : const PushPermissionState.ready(
                ReadySubState.osAuthorisedTokenMissing,
                quality: AuthQuality.provisional,
              );
      case AuthorizationStatus.denied:
        return const PushPermissionState.ready(ReadySubState.osDenied);
      case AuthorizationStatus.notDetermined:
        return const PushPermissionState.ready(ReadySubState.osNotDetermined);
    }
  }

  static bool shouldShowCard(PushUiState ui) {
    if (ui.cardDismissed) return false;
    final permission = ui.permission;
    if (permission is! PushPermissionReady) return false;
    return permission.sub == ReadySubState.osNotDetermined ||
        permission.sub == ReadySubState.osDenied;
  }

  /// Pure decision for the return-reprompt (see [maybeRepromptOnReturn]).
  /// Fires only when the OS permission is genuinely undetermined — i.e. the
  /// system dialog was never presented — the Siga gate is clear, and we're
  /// under the bounded retry cap. `osDenied`/`verified`/`osAuthorisedTokenMissing`
  /// all fall through to false.
  @visibleForTesting
  static bool shouldReprompt({
    required PushPermissionState permission,
    required int attemptCount,
    required bool needsSiga,
    int maxAttempts = _kReturnRepromptMaxAttempts,
  }) {
    if (needsSiga) return false;
    if (attemptCount >= maxAttempts) return false;
    if (permission is! PushPermissionReady) return false;
    return permission.sub == ReadySubState.osNotDetermined;
  }
}

final pushPermissionServiceProvider =
    NotifierProvider<PushPermissionService, PushUiState>(
      PushPermissionService.new,
    );
