/// Result of attempting to register the device with Klaviyo for push.
///
/// Returned by every entry point on `KlaviyoService` so callers know
/// what actually happened (the prior `Future<void>` shape swallowed
/// every failure mode into debug logs).
enum PushRegResult {
  /// OS permission granted AND `KlaviyoSDK.getPushToken()` returned a
  /// non-null token after registration.
  registered,

  /// OS permission granted, `registerForPushNotifications()` returned
  /// without throwing, but `getPushToken()` returned null. Likely the
  /// FCM token hasn't arrived yet — safe to retry on next lifecycle.
  registeredTokenUnknown,

  /// OS returned `denied` (iOS) or user declined the runtime prompt
  /// (Android 13+). No registration was attempted.
  permissionDenied,

  /// The Klaviyo SDK is off for this build — either the build is
  /// non-production (PROD-3112: `EnvironmentConfig.analyticsEnvironment !=
  /// 'prod'`, the expected state in dev and staging) or
  /// `KLAVIYO_PUBLIC_API_KEY` is empty. Klaviyo SDK no-ops; this is a
  /// build-config issue, not a user-recoverable one.
  sdkDisabled,

  /// `KlaviyoSDK().initialize()` threw. Treat as transient.
  sdkInitFailed,

  /// Any other exception path (uncaught error during registration).
  failed,
}

enum UnavailableReason { klaviyoDisabled, notSupportedPlatform }

/// Sub-state inside [PushPermissionReady]. Driven by the combination
/// of OS auth status and Klaviyo token presence (verified via
/// `KlaviyoSDK.getPushToken()`).
enum ReadySubState {
  /// OS authorized (incl. provisional) AND Klaviyo has a token.
  /// Card hidden, drawer "On" (or "Quiet" for provisional).
  verified,

  /// OS authorized but `getPushToken()` returned null. Background
  /// retry — do not show the card, drawer shows "Retrying…".
  osAuthorisedTokenMissing,

  /// OS has not been prompted yet. Card shows prompt copy.
  osNotDetermined,

  /// User tapped Don't Allow or revoked in Settings. Card shows
  /// Settings-deep-link copy.
  osDenied,
}

/// Whether the user is using iOS provisional (quiet) notifications.
/// Only meaningful when sub is [ReadySubState.verified].
enum AuthQuality { full, provisional }

sealed class PushPermissionState {
  const PushPermissionState();

  const factory PushPermissionState.loading() = PushPermissionLoading;

  const factory PushPermissionState.unavailable(UnavailableReason reason) =
      PushPermissionUnavailable;

  const factory PushPermissionState.ready(
    ReadySubState sub, {
    AuthQuality? quality,
  }) = PushPermissionReady;

  bool get isVerified =>
      this is PushPermissionReady &&
      (this as PushPermissionReady).sub == ReadySubState.verified;
}

final class PushPermissionLoading extends PushPermissionState {
  const PushPermissionLoading();
}

final class PushPermissionUnavailable extends PushPermissionState {
  final UnavailableReason reason;
  const PushPermissionUnavailable(this.reason);
}

final class PushPermissionReady extends PushPermissionState {
  final ReadySubState sub;
  final AuthQuality quality;
  const PushPermissionReady(this.sub, {AuthQuality? quality})
    : quality = quality ?? AuthQuality.full;
}
