import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/att_trigger.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/services/unified_analytics_service.dart' as analytics;
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/location_provider.dart';
import '../../../providers/preferences_provider.dart';
import '../../../shared/widgets/auth_header.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../onboarding/providers/login_history_provider.dart';
import '../helpers/guest_session_starter.dart';

/// Cross-device location prompt. Shown when the user has already completed
/// Siga on some device (server-side consent recorded) but has not yet
/// granted/declined location on this one. Visibility is gated by
/// `needsLocationAskProvider`. Skips the full Siga greeting since the user
/// already knows Soko.
class SokoLocationAskScreen extends ConsumerStatefulWidget {
  const SokoLocationAskScreen({super.key});

  @override
  ConsumerState<SokoLocationAskScreen> createState() =>
      _SokoLocationAskScreenState();
}

class _SokoLocationAskScreenState extends ConsumerState<SokoLocationAskScreen> {
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
            isFirstPrompt: false,
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
      // Branch on identity. Authed users PATCH the server; guests have
      // no /me/preferences so they only write the local guest-consent
      // key — the sign-in migration helper will promote it to the
      // backend the next time the guest authenticates. Both branches
      // mark the per-device "asked" flag so the gate doesn't re-fire.
      final identity = ref.read(currentLocationAskIdentityProvider);
      if (identity == null) {
        // Identity hasn't resolved (e.g. visitor id still loading). Abort
        // gracefully — the gate will keep showing the screen on the next
        // pass.
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      if (identity.scope == 'user') {
        // PROD-2285 Phase 1 / PROD-2304 — server-write FIRST. If PATCH
        // fails, abort before any OS prompts so the user lands back on the
        // ask screen with the error visible and can retry.
        final patched = await ref
            .read(preferencesProvider.notifier)
            .update(
              locationOptIn: _locationEnabled,
              locationOptInSource: 'location_ask',
              locationOptInPlatform: _platformString(),
            );
        if (!patched) {
          if (mounted) setState(() => _isLoading = false);
          return;
        }
        // PATCH responses aren't platform-filtered — the backend strips
        // `push_notification_opt_in_at` only on GET with `X-Client-Platform`.
        // Without this reload, a web user landing here from any prior
        // PATCH would have a stale `hasUnrecordedConsent=true` and get
        // bounced to full Siga instead of progressing past the location ask.
        await ref.read(preferencesProvider.notifier).load();
      } else {
        // Guest path — write the local key the sign-in migration helper
        // reads (see `migrateGuestLocationConsentIfNeeded`). Same key
        // format as the legacy guest sheet, so the migration contract
        // is preserved across the surface change.
        final prefs = ref.read(sharedPreferencesProvider);
        await prefs.setBool(
          guestLocationOptInKey(identity.id),
          _locationEnabled,
        );
      }

      // Mark this surface as "shown for this identity on this device" so
      // `needsLocationAskProvider` stops firing.
      await markLocationAskShown(ref, scope: identity.scope, id: identity.id);

      // PROD-2285 Phase 2 — fire iOS ATT here too. The slim-prompt flow
      // is the only entry into the app for a user who completed Siga on
      // another device (or for a guest who tapped Continue as guest), so
      // ATT must still fire (no-op on Android/web).
      await triggerAttIfNeeded(ref);

      final analyticsSvc = ref.read(analytics.unifiedAnalyticsProvider);
      if (_locationEnabled) {
        final status = await ref
            .read(locationProvider.notifier)
            .requestPermissionOnly();
        if (status == LocationPermissionStatus.granted) {
          analyticsSvc.trackLocationPermission(
            action: analytics.LocationPermissionAction.allowed,
            permissionStatus: analytics.PermissionStatus.granted,
            isFirstPrompt: false,
          );
        } else {
          analyticsSvc.trackLocationPermission(
            action: analytics.LocationPermissionAction.denied,
            permissionStatus: _mapToAnalyticsPermissionStatus(status),
            isFirstPrompt: false,
          );
          // ignore: unawaited_futures
          ref.read(locationProvider.notifier).setIpApproxLocation();
        }
      } else {
        analyticsSvc.trackLocationPermission(
          action: analytics.LocationPermissionAction.denied,
          permissionStatus: analytics.PermissionStatus.denied,
          isFirstPrompt: false,
        );
        // ignore: unawaited_futures
        ref.read(locationProvider.notifier).setIpApproxLocation();
      }

      if (!mounted) return;

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

    return Scaffold(
      backgroundColor: AppColors.sokoPink,
      body: Column(
        children: [
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
                      width: 220,
                      fit: BoxFit.contain,
                      semanticLabel: 'Soko',
                    ),
                    const SizedBox(height: 24),
                    Text(
                      l10n.authLocationAskHeading,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'SeasonMix',
                        fontSize: 32,
                        fontWeight: FontWeight.w400,
                        height: 1.1,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.authLocationAskSubtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.35,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _LocationPermissionCard(
                      value: _locationEnabled,
                      onChanged: _isLoading
                          ? null
                          : (v) => setState(() => _locationEnabled = v),
                    ),
                    const SizedBox(height: 32),
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
        ],
      ),
    );
  }
}
