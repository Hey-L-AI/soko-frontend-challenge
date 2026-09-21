import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/att_trigger.dart';
import '../../../core/services/klaviyo_service.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/push_permission_service.dart';
import '../../../core/services/unified_analytics_service.dart' as analytics;
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/location_provider.dart';
import '../../../providers/preferences_provider.dart';
import '../../../shared/widgets/auth_header.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../onboarding/providers/login_history_provider.dart';

/// PROD-2073 (PROD-2081): post-auth Soko greeting + permissions gate.
///
/// Shown once after a user's first successful sign-in. Visibility is
/// gated by `needsSokoIntroProvider`, which is `true` until the
/// preferences PATCH below stamps `sms_marketing_opt_in_at` on the
/// server — making the backend the single source of truth.
///
/// Tapping Siga:
///   1. PATCHes preferences (email + SMS marketing + push opt-ins).
///      Server stamps the `*_opt_in_at` timestamps, which flips
///      `needsSokoIntroProvider` to false and stops the router from
///      bouncing back here. On mobile this includes `pn_optin: true`
///      with no token (PROD-2327) so the push timestamp stamps
///      immediately instead of waiting on the ~1-min iOS token.
///   2. Requests push permission (mobile only, if the toggle is on).
///   3. Requests OS location permission (always — Apple 5.1.1).
///   4. Marks location setup complete.
///   5. Routes to `pendingActivationEmail` (register funnel), `returnUrl`
///      (pre-auth deep link), or `/`.
class SokoWelcomeScreen extends ConsumerStatefulWidget {
  const SokoWelcomeScreen({super.key});

  @override
  ConsumerState<SokoWelcomeScreen> createState() => _SokoWelcomeScreenState();
}

class _SokoWelcomeScreenState extends ConsumerState<SokoWelcomeScreen> {
  // Bundled master toggle for SMS + email + push. Defaults ON. Users can
  // cherry-pick channels later in /menu/preferences. _onContinue always
  // PATCHes all three with this value (even `false`) so the server stamps
  // `sms_marketing_opt_in_at` and the Siga gate flips to "done".
  bool _communicationsEnabled = true;
  bool _locationEnabled = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(analytics.unifiedAnalyticsProvider)
          .trackLocationPermission(
            action: analytics.LocationPermissionAction.promptShown,
            isFirstPrompt: true,
          );
    });
  }

  String? _platformString() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return null;
    }
  }

  String _mapToAnalyticsPermissionStatus(LocationPermissionStatus status) {
    switch (status) {
      case LocationPermissionStatus.granted:
        return analytics.PermissionStatus.granted;
      case LocationPermissionStatus.denied:
        return analytics.PermissionStatus.denied;
      case LocationPermissionStatus.deniedForever:
        return analytics.PermissionStatus.restricted;
      case LocationPermissionStatus.serviceDisabled:
      case LocationPermissionStatus.timeout:
      case LocationPermissionStatus.webUnsupported:
      case LocationPermissionStatus.unknownError:
        return analytics.PermissionStatus.denied;
    }
  }

  Future<void> _onContinue() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      // Record marketing prefs first (the consent moment). Sending each
      // channel unconditionally — even `false` — is what makes the
      // server stamp `*_marketing_opt_in_at`, which
      // `needsSokoIntroProvider` uses to skip Siga on other devices.
      //
      // PROD-2179: on web we deliberately omit `pnOptin` from the PATCH
      // (web can never acquire a push token). Leaving `pn_optin` NULL
      // keeps the Siga gate tripped so the user is re-prompted for push
      // when they later log in on iOS/Android.
      //
      // PROD-2327: send `pn_optin: true` in THIS initial PATCH on mobile
      // opt-in. The backend no longer requires `push_notification_token`
      // when `pn_optin=true` — PROD-2213 decoupled token/platform from the
      // consent write, so the push channel stamps `push_notification_opt_in_at`
      // regardless of token presence (the only token-related 422 is
      // token-without-platform). Stamping the timestamp immediately clears
      // the Siga gate (`hasUnrecordedConsent`) so the user can proceed at
      // once. The push token registers asynchronously via `requestAndRegister`
      // below, which then PATCHes `pn_optin: true + token` so Klaviyo can
      // register the device — but navigation no longer waits on that ~1-min
      // iOS token round-trip (the stale-token transient PR #744 guards via
      // `osAuthorisedTokenMissing`).
      //
      // On mobile opt-out (`_communicationsEnabled=false`) we send
      // `pn_optin: false` here so Siga doesn't re-fire, AND we best-effort
      // include any existing Klaviyo token + platform so the backend can
      // revoke that specific device's Klaviyo push subscription. Token is
      // typically null on fresh install (SDK never registered) and that's
      // fine — backend treats bare `pn_optin: false` as a global opt-out.
      String? optOutPushToken;
      String? optOutPushPlatform;
      if (!kIsWeb && !_communicationsEnabled) {
        try {
          optOutPushToken = await ref
              .read(klaviyoServiceProvider)
              .getPushToken();
        } catch (e) {
          debugPrint('[Siga] getPushToken on opt-out threw: $e');
        }
        if (optOutPushToken != null && optOutPushToken.isNotEmpty) {
          switch (defaultTargetPlatform) {
            case TargetPlatform.iOS:
              optOutPushPlatform = 'ios';
            case TargetPlatform.android:
              optOutPushPlatform = 'android';
            default:
              break;
          }
        }
      }

      // PROD-2305 — re-read at call time to keep _onContinue free of
      // a watched copy. A guest who answered pre-auth has their answer
      // in `preferences.locationOptIn` already (migrated in the sign-in
      // path); writing the default-`true` toggle here would silently
      // overwrite a `false`.
      final prefsSnapshot = ref.read(preferencesProvider).preferences;
      final hasMigratedLocationConsent = prefsSnapshot?.locationOptIn != null;

      // PROD-2438 — gate the per-channel PATCH on the backend's
      // `applicability` map. Phone-only users (no email-reachable auth
      // method) must NOT write `email_marketing_opt_in` — the backend
      // strips `email_marketing_opt_in_at` on GET for them so the channel
      // is inapplicable; sending it here would stamp consent on an
      // unreachable channel. Same for email-only (no `phone`) users on
      // SMS. The model defaults all flags to `true` when the backend
      // hasn't shipped the block yet, so behavior is unchanged in
      // back-compat mode.
      final emailApplicable = prefsSnapshot?.emailApplicable ?? true;
      final smsApplicable = prefsSnapshot?.smsApplicable ?? true;
      final pushApplicable = prefsSnapshot?.pushApplicable ?? true;

      // If the PATCH fails, abort before any OS prompts so the user
      // lands back on Siga with the error visible and can retry.
      final patched = await ref
          .read(preferencesProvider.notifier)
          .update(
            emailMarketingOptIn: emailApplicable
                ? _communicationsEnabled
                : null,
            smsMarketingOptIn: smsApplicable ? _communicationsEnabled : null,
            // Push: web is already non-applicable (backend strips the key
            // when `X-Client-Platform: web`, and `applicability.push_notification`
            // is false). The legacy `kIsWeb ? null` guard is preserved as
            // belt-and-braces for old backends that haven't shipped
            // applicability yet.
            pnOptin: (kIsWeb || !pushApplicable)
                ? null
                : _communicationsEnabled,
            pushNotificationToken: optOutPushToken,
            pushNotificationPlatform: optOutPushPlatform,
            // PROD-2285 Phase 1 / PROD-2304 — record location consent
            // server-side. Cross-platform: web answers count cross-device
            // now that PROD-2302 made the backend accept web writes.
            // `_platformString()` returns `ios`/`android`/`web`.
            //
            // PROD-2305 — omit the location fields when the guest cohort
            // already migrated an answer (`preferences.locationOptIn !=
            // null`). The PreferencesNotifier.update() signature treats
            // a `null` argument as "do not change" rather than "set to
            // null", so this preserves the migrated answer instead of
            // clobbering it with the default-true toggle.
            locationOptIn: hasMigratedLocationConsent ? null : _locationEnabled,
            locationOptInSource: hasMigratedLocationConsent ? null : 'siga',
            locationOptInPlatform: hasMigratedLocationConsent
                ? null
                : _platformString(),
          );
      if (!patched) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // The PATCH response is not platform-filtered (the backend strips
      // `push_notification_opt_in_at` only on GET when `X-Client-Platform`
      // is set — see `preferences_api.dart`). Without this reload, web
      // users land back on Siga because the PATCH echo still carries
      // `push_notification_opt_in_at: null`, tripping
      // `hasUnrecordedConsent`. The reload below uses GET, which IS
      // platform-filtered, so the gate clears.
      await ref.read(preferencesProvider.notifier).load();

      // Siga's location card just covered the device-local location ask
      // for this user. Set the per-device flag so `needsLocationAskProvider`
      // doesn't fire the slim screen immediately after Siga.
      final userId = ref.read(authStateProvider).user?.id;
      final isAuthed = ref.read(authStateProvider).isAuthenticated;
      debugPrint(
        '[SIGA-DIAG] soko_welcome _onContinue: about to mark flag — '
        'isAuthenticated=$isAuthed userId=$userId',
      );
      if (userId != null) {
        await markLocationAskShown(ref, scope: 'user', id: userId);
        debugPrint(
          '[SIGA-DIAG] soko_welcome _onContinue: markLocationAskShown '
          'completed for user.$userId',
        );
      } else {
        debugPrint(
          '[SIGA-DIAG] soko_welcome _onContinue: SKIPPED flag write — '
          'userId is null; Page 2 (location-ask) will likely fire next',
        );
      }

      // PROD-2285 Phase 2 — fire iOS ATT here so the user has product
      // context (no-op on Android/web, idempotent on iOS).
      await triggerAttIfNeeded(ref);

      if (!kIsWeb && _communicationsEnabled) {
        // requestAndRegister is mobile-only — the OS push prompt + Klaviyo
        // registration only mean anything on iOS/Android. Consent was
        // already stamped by the initial PATCH above (PROD-2327); this call
        // fires the follow-up `pn_optin: true + push_notification_token`
        // PATCH internally via `_syncPushOptInResult` once the token
        // surfaces, so Klaviyo can register this device. Navigation no
        // longer waits on it.
        //
        // PROD-2285 Phase 2 — defensive timeout. requestAndRegister
        // catches throws internally but a hung Future could block the
        // location prompt forever. 10s is well above the p99 for APNs
        // registration + Klaviyo PATCH.
        try {
          await ref
              .read(pushPermissionServiceProvider.notifier)
              .requestAndRegister(source: 'onboarding')
              .timeout(const Duration(seconds: 10));
        } catch (e) {
          debugPrint('[Siga] push request timed out or failed: $e');
        }
        // The push PATCH above goes through `_preferencesApi` directly,
        // not through `preferencesProvider.notifier`, so the local
        // preferences cache still reflects the pre-push state. Refresh
        // it now so the router's next pass sees the stamped
        // `push_notification_opt_in_at` and DOESN'T bounce the user
        // back to Siga.
        await ref.read(preferencesProvider.notifier).load();
      }

      final analyticsSvc = ref.read(analytics.unifiedAnalyticsProvider);
      if (_locationEnabled) {
        final status = await ref
            .read(locationProvider.notifier)
            .requestPermissionOnly();
        if (status == LocationPermissionStatus.granted) {
          analyticsSvc.trackLocationPermission(
            action: analytics.LocationPermissionAction.allowed,
            permissionStatus: analytics.PermissionStatus.granted,
            isFirstPrompt: true,
          );
        } else {
          analyticsSvc.trackLocationPermission(
            action: analytics.LocationPermissionAction.denied,
            permissionStatus: _mapToAnalyticsPermissionStatus(status),
            isFirstPrompt: true,
          );
          // Don't block the user — fall back to IP location in the background.
          // IP geo may time out under Apple's "Limit IP Address Tracking";
          // the in-chat suggestion card + map badge handle re-prompting later.
          // ignore: unawaited_futures
          ref.read(locationProvider.notifier).setIpApproxLocation();
        }
      } else {
        // User opted out of the precise location prompt. Skip the OS prompt
        // entirely and use IP coarse location so we still surface nearby
        // recommendations. The map badge + chat suggestion card can re-prompt
        // for GPS later if the user wants it.
        analyticsSvc.trackLocationPermission(
          action: analytics.LocationPermissionAction.denied,
          permissionStatus: analytics.PermissionStatus.denied,
          isFirstPrompt: true,
        );
        // ignore: unawaited_futures
        ref.read(locationProvider.notifier).setIpApproxLocation();
      }

      if (!mounted) return;

      // Register funnel: pendingActivationEmail outlives the Soko intro and
      // must route to /auth/activation-pending so the user sees the
      // "check your inbox" step rather than landing in /home before
      // verifying the email.
      final pendingActivationEmail = ref
          .read(authStateProvider)
          .pendingActivationEmail;
      if (pendingActivationEmail != null) {
        context.go(AppRoutes.activationPending, extra: pendingActivationEmail);
        return;
      }
      final returnUrl = ref.read(returnUrlProvider);
      if (returnUrl != null) {
        ref.read(returnUrlProvider.notifier).state = null;
        context.go(returnUrl);
      } else {
        context.go(AppRoutes.home);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final prefsError = ref.watch(preferencesProvider.select((s) => s.error));
    // PROD-2305 — a guest who already answered the pre-auth location
    // ask had their answer migrated to `preferences.location_opt_in` in
    // the sign-in path. Re-asking via Siga would let the default-true
    // toggle silently overwrite a `false` answer when the user taps
    // continue. Hide the card and skip the location fields in the
    // _onContinue PATCH so the migrated answer is preserved.
    final hasMigratedLocationConsent = ref.watch(
      preferencesProvider.select((s) => s.preferences?.locationOptIn != null),
    );
    // PROD-2438 — per-channel applicability for the communications card.
    // Defaults to `true` when prefs aren't loaded yet (which shouldn't
    // happen here — Siga only renders after the BE-only gate has been
    // computed — but the fallback keeps the screen sensible if the
    // assumption breaks).
    final emailApplicable = ref.watch(
      preferencesProvider.select((s) => s.preferences?.emailApplicable ?? true),
    );
    final smsApplicable = ref.watch(
      preferencesProvider.select((s) => s.preferences?.smsApplicable ?? true),
    );
    final pushApplicable = ref.watch(
      preferencesProvider.select((s) => s.preferences?.pushApplicable ?? true),
    );

    return Scaffold(
      backgroundColor: AppColors.sokoPink,
      body: Column(
        children: [
          // AuthHeader handles its own top safe-area inset; place it
          // outside SafeArea so the language pill sits at the screen edge.
          const AuthHeader(),
          Expanded(
            child: PageContent(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 24,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Image.asset(
                      'assets/images/illustrations/soko-seating-and-reading.webp',
                      width: 140,
                      fit: BoxFit.contain,
                      semanticLabel: 'Soko',
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.authSokoIntroHeading,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'SeasonMix',
                        fontSize: 40,
                        fontWeight: FontWeight.w400,
                        height: 1.05,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.authSokoIntroSubtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.35,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _CommunicationsPermissionCard(
                      value: _communicationsEnabled,
                      emailApplicable: emailApplicable,
                      smsApplicable: smsApplicable,
                      pushApplicable: pushApplicable,
                      onChanged: _isLoading
                          ? null
                          : (v) => setState(() => _communicationsEnabled = v),
                    ),
                    if (!hasMigratedLocationConsent) ...[
                      const SizedBox(height: 12),
                      _LocationPermissionCard(
                        value: _locationEnabled,
                        onChanged: _isLoading
                            ? null
                            : (v) => setState(() => _locationEnabled = v),
                      ),
                    ],
                    if (prefsError != null) ...[
                      const SizedBox(height: 16),
                      _SokoErrorBanner(
                        message: l10n.authSokoPreferencesSaveError,
                      ),
                    ],
                    const SizedBox(height: 32),
                    // Siga CTA — canonical SokoCtaButton, yellow variant.
                    // `expand: false` so the button hugs its content per Figma
                    // (small pill in the centre, not full-width).
                    SokoCtaButton(
                      label: l10n.authSokoIntroCta,
                      variant: SokoCtaVariant.yellow,
                      expand: false,
                      loading: _isLoading,
                      onPressed: _isLoading ? null : _onContinue,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bundled communications toggle: covers SMS marketing, email marketing, and
/// push notifications in one switch. Users can cherry-pick individual
/// channels later in /menu/preferences. _onContinue PATCHes all three with
/// this value (true or false), and the recorded `false` is what stamps
/// `*_marketing_opt_in_at` server-side so the Siga gate flips to "done".
class _CommunicationsPermissionCard extends StatelessWidget {
  const _CommunicationsPermissionCard({
    required this.value,
    required this.emailApplicable,
    required this.smsApplicable,
    required this.pushApplicable,
    required this.onChanged,
  });

  final bool value;
  final bool emailApplicable;
  final bool smsApplicable;
  final bool pushApplicable;
  final ValueChanged<bool>? onChanged;

  // PROD-2438 — pick the description copy from the per-channel applicability
  // map the backend exposes on GET /preferences. PROD-2179 web→non-push is
  // subsumed by `pushApplicable` (the backend strips push when
  // `X-Client-Platform: web`). The legacy `kIsWeb` branch survives only as
  // the trailing fallback for the unreachable "neither email nor SMS
  // applicable" case where the screen should never actually render.
  String _description(Lt l10n) {
    if (emailApplicable && smsApplicable && pushApplicable) {
      return l10n.authSokoCommunicationsDesc;
    }
    if (emailApplicable && smsApplicable && !pushApplicable) {
      return l10n.authSokoCommunicationsDescWeb;
    }
    if (emailApplicable && !smsApplicable && pushApplicable) {
      return l10n.authSokoCommunicationsDescPushEmail;
    }
    if (emailApplicable && !smsApplicable && !pushApplicable) {
      return l10n.authSokoCommunicationsDescEmail;
    }
    if (!emailApplicable && smsApplicable && pushApplicable) {
      return l10n.authSokoCommunicationsDescPushSms;
    }
    if (!emailApplicable && smsApplicable && !pushApplicable) {
      return l10n.authSokoCommunicationsDescSms;
    }
    return kIsWeb
        ? l10n.authSokoCommunicationsDescWeb
        : l10n.authSokoCommunicationsDesc;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.notifications_outlined,
            size: 20,
            color: AppColors.sokoInk,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.authSokoCommunicationsLabel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sokoInk,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _description(l10n),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.sokoInkSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.sokoPaper,
            activeTrackColor: AppColors.sokoInk,
          ),
        ],
      ),
    );
  }
}

/// Location toggle card. Defaults ON. Disabling skips the OS GPS prompt
/// and falls back to IP coarse location — the user can re-enable precise
/// location later from settings or in-chat suggestions.
class _LocationPermissionCard extends StatelessWidget {
  const _LocationPermissionCard({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.location_on_outlined,
                size: 20,
                color: AppColors.sokoInk,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.profileSetupLocation,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.sokoInk.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  l10n.profileSetupLocationEssential,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Switch.adaptive(
                value: value,
                onChanged: onChanged,
                activeThumbColor: AppColors.sokoPaper,
                activeTrackColor: AppColors.sokoInk,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.profileSetupLocationDesc,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.sokoInkSecondary,
            ),
          ),
          const SizedBox(height: 10),
          _LocationBenefit(text: l10n.profileSetupLocationBenefit1),
          _LocationBenefit(text: l10n.profileSetupLocationBenefit2),
        ],
      ),
    );
  }
}

class _LocationBenefit extends StatelessWidget {
  const _LocationBenefit({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.check_circle_outline,
              size: 16,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.sokoInkSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the preferences PATCH fails on Continue. Keeps the user on
/// Siga so they can retry without losing their toggle selections.
class _SokoErrorBanner extends StatelessWidget {
  const _SokoErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.sokoInk.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.sokoInk),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, color: AppColors.sokoInk),
            ),
          ),
        ],
      ),
    );
  }
}
