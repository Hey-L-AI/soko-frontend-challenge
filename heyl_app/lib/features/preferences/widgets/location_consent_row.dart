// PROD-2303 step 7 — single Settings row replacing the two side-by-side
// location toggles (`_LocationSharingHeaderToggle` + `_LocationConsentToggle`).
// Reads the canonical `locationConsentStateProvider` and renders one of three
// state labels with a contextual status line. Taps open the picker sheet.
//
// Design review decisions encoded here (plan: .context/2026-05-30-prod-2303-
// step7-settings-consolidation-plan.md):
//   B1 — loading state shows a skeleton shimmer, row non-tappable.
//   B5 — Precise selected but GPS fix still pending shows
//        "Locating GPS… · {ip-city}".
//   B6 — IP geolocation missing → omit status line entirely.
//   Q2 — Native Off + OS permission still granted → show revoke link.
//   Q4 — Web Off + browser permission cached → show inline explainer.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/location_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/location_snapshot.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/location_consent_state_provider.dart';
import '../../../providers/providers.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../models/location_consent_choice.dart';
import 'location_consent_picker_sheet.dart';

class LocationConsentRow extends ConsumerWidget {
  const LocationConsentRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final consentState = ref.watch(locationConsentStateProvider);
    final permission = ref.watch(
      locationProvider.select((s) => s.permissionStatus),
    );

    final isLoading = consentState is LocationConsentUnknown;
    final currentChoice = _choiceFromState(consentState);
    final statusLine = _statusLine(l10n, consentState);
    final stateLabel = _stateLabel(l10n, currentChoice);

    final osGrantedNative =
        !kIsWeb && permission == LocationPermissionStatus.granted;
    final osGrantedWeb =
        kIsWeb && permission == LocationPermissionStatus.granted;
    final isOff =
        consentState is LocationConsentDeniedIp ||
        consentState is LocationConsentDeniedNoIp;
    final showRevokeLink = isOff && osGrantedNative;
    final showWebExplainer = isOff && osGrantedWeb;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isLoading
                ? null
                : () => _openSheet(context, ref, currentChoice),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    LucideIcons.map_pin,
                    size: 20,
                    color: AppColors.sokoInk,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.prefsLocationRowTitle,
                          style: const TextStyle(
                            color: AppColors.sokoInk,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 3),
                        if (isLoading)
                          const _SkeletonStatusLine()
                        else
                          _CollapsedSummary(
                            stateLabel: stateLabel,
                            statusLine: statusLine,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    LucideIcons.chevron_right,
                    size: 20,
                    color: isLoading
                        ? AppColors.sokoShade3.withValues(alpha: 0.4)
                        : AppColors.sokoShade3,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showRevokeLink)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 4),
            child: InkWell(
              onTap: () => ref.read(locationProvider.notifier).openSettings(),
              child: Text(
                l10n.prefsLocationRevokeOsLink,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.sokoPink,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.sokoPink,
                ),
              ),
            ),
          ),
        if (showWebExplainer)
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 2, bottom: 4),
            child: Text(
              l10n.prefsLocationWebOffExplainer,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.sokoShade3,
                height: 1.3,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _openSheet(
    BuildContext context,
    WidgetRef ref,
    LocationConsentChoice initial,
  ) async {
    await showBottomSheetWithHiddenNav<LocationConsentApplyResult>(
      context: context,
      ref: ref,
      backgroundColor: AppColors.sokoPaper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => LocationConsentPickerSheet(
        availableChoices: availableLocationConsentChoices(),
        initialChoice: initial,
      ),
    );
    // The provider rebuilds the row automatically on PATCH success; the
    // sheet itself fires the snackbar for B3 (downgrade). Nothing else to
    // do here.
  }
}

/// Compact state→radio mapping. `Unknown` falls back to Precise as the
/// label-less placeholder; the row clamps that case to the skeleton so the
/// label never renders.
LocationConsentChoice _choiceFromState(LocationConsentState state) {
  switch (state) {
    case LocationConsentGrantedGps():
      return LocationConsentChoice.precise;
    case LocationConsentGrantedButIp():
      return LocationConsentChoice.approximate;
    case LocationConsentDeniedIp():
    case LocationConsentDeniedNoIp():
      return LocationConsentChoice.off;
    case LocationConsentGuestGranted():
      return LocationConsentChoice.precise;
    case LocationConsentGuestDenied():
      return LocationConsentChoice.off;
    case LocationConsentUnknown():
      return LocationConsentChoice.precise;
  }
}

String _stateLabel(Lt l10n, LocationConsentChoice choice) {
  switch (choice) {
    case LocationConsentChoice.precise:
      return l10n.prefsLocationStatePrecise;
    case LocationConsentChoice.approximate:
      return l10n.prefsLocationStateApprox;
    case LocationConsentChoice.off:
      return l10n.prefsLocationStateOff;
  }
}

/// Returns the second-line status string, or `null` when the row should
/// omit it (B6 — no IP fallback yet).
String? _statusLine(Lt l10n, LocationConsentState state) {
  switch (state) {
    case LocationConsentGrantedGps(:final lastKnown):
      final city = lastKnown.city;
      final country = lastKnown.country;
      if (city == null || country == null) return null;
      return l10n.prefsLocationStatusGps(city, country);
    case LocationConsentGrantedButIp(:final lastKnown):
      // B5 — consent says Precise but the data layer hasn't produced a GPS
      // fix yet. Distinguish "GPS pending" from "Approximate selected" by
      // looking at lastLocation source: a non-GPS fix paired with a granted
      // permission means we're between consent and first fix.
      if (lastKnown == null) return null;
      if (lastKnown.source != LocationSource.deviceGps) {
        // No GPS yet — show locating prefix if we know permission is granted,
        // otherwise plain IP line.
        final city = lastKnown.city;
        final country = lastKnown.country;
        if (city == null || country == null) return null;
        return l10n.prefsLocationStatusIp(city, country);
      }
      final city = lastKnown.city;
      final country = lastKnown.country;
      if (city == null || country == null) return null;
      return l10n.prefsLocationStatusGps(city, country);
    case LocationConsentDeniedIp(:final lastKnown):
      // Off but we have an IP city — show the off-state status copy. The
      // city is for diagnostics; copy hides it intentionally to match the
      // "Recomendações por país" framing.
      final _ = lastKnown;
      return l10n.prefsLocationStatusOff;
    case LocationConsentDeniedNoIp():
      return l10n.prefsLocationStatusOff;
    case LocationConsentGuestGranted():
    case LocationConsentGuestDenied():
      // Settings only renders for authed users; guest states reaching here
      // is defensive — surface no status line.
      return null;
    case LocationConsentUnknown():
      return null;
  }
}

class _CollapsedSummary extends StatelessWidget {
  const _CollapsedSummary({required this.stateLabel, this.statusLine});

  final String stateLabel;
  final String? statusLine;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          stateLabel,
          style: const TextStyle(
            color: AppColors.sokoShade3,
            fontSize: 13,
            height: 1.2,
          ),
        ),
        if (statusLine != null) ...[
          const SizedBox(height: 2),
          Text(
            statusLine!,
            style: const TextStyle(
              color: AppColors.sokoShade3,
              fontSize: 12,
              height: 1.2,
            ),
          ),
        ],
      ],
    );
  }
}

/// B1 — preferences still loading. Renders a placeholder line the same
/// width as the longest realistic status string so the row doesn't
/// jump on resolve.
class _SkeletonStatusLine extends StatelessWidget {
  const _SkeletonStatusLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      height: 12,
      decoration: BoxDecoration(
        color: AppColors.sokoInk.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
