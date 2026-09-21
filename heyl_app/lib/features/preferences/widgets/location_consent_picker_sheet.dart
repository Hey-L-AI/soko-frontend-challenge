// PROD-2303 step 7 — modal bottom sheet for picking the consolidated
// location-consent state. Replaces the two side-by-side toggles
// (_LocationSharingHeaderToggle + _LocationConsentToggle) with one row that
// taps to open this sheet.
//
// Design review decisions encoded here (plan: .context/2026-05-30-prod-2303-
// step7-settings-consolidation-plan.md):
//   Q1 — radio set per platform comes from the caller; sheet never branches.
//   Q3 — Approximate never requests OS permission, even if granted before.
//   B2 — Aplicar button disabled + spinner while OS prompt is in flight.
//   B3 — Precise picked + OS denies = auto-downgrade: still PATCH consent=true,
//        pop with `downgradedToApprox` so the caller can show a snackbar.
//   B4 — PATCH failure keeps the sheet open with an inline retry banner.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/location_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../models/location_consent_choice.dart';

/// Result returned via `Navigator.pop`. `null` means the user dismissed
/// without applying.
enum LocationConsentApplyResult {
  /// PATCH succeeded for the chosen radio; row state will reflect the pick.
  applied,

  /// User picked Precise but the OS denied the permission. Backend was
  /// updated with `location_opt_in: true` (the intent), and the UI should
  /// surface a snackbar explaining we're using approximate location.
  downgradedToApprox,
}

class LocationConsentPickerSheet extends ConsumerStatefulWidget {
  const LocationConsentPickerSheet({
    super.key,
    required this.availableChoices,
    required this.initialChoice,
  });

  /// Radios to render. Caller computes via
  /// [availableLocationConsentChoices]; the sheet itself never branches on
  /// platform.
  final List<LocationConsentChoice> availableChoices;

  /// The radio that should be pre-selected when the sheet opens. Derived
  /// from `locationConsentStateProvider` at the call site.
  final LocationConsentChoice initialChoice;

  @override
  ConsumerState<LocationConsentPickerSheet> createState() =>
      _LocationConsentPickerSheetState();
}

class _LocationConsentPickerSheetState
    extends ConsumerState<LocationConsentPickerSheet> {
  late LocationConsentChoice _selected;
  bool _isApplying = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialChoice;
  }

  Future<void> _onApply() async {
    if (_isApplying) return;
    setState(() {
      _isApplying = true;
      _errorMessage = null;
    });

    final l10n = Lt.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);

    try {
      // Save consent FIRST so a PATCH failure can't leak side effects.
      // requestPermissionOnly() starts foreground GPS polling immediately on
      // grant, and disableAlwaysShare() is the only path that stops it — we
      // must not touch either until the server has accepted the new intent.
      final consentValue = _selected != LocationConsentChoice.off;
      final ok = await ref
          .read(preferencesProvider.notifier)
          .update(
            locationOptIn: consentValue,
            locationOptInSource: 'settings',
            locationOptInPlatform: currentPlatformConsentTag(),
          );

      if (!mounted) return;

      if (!ok) {
        setState(() {
          _isApplying = false;
          _errorMessage = l10n.locationSheetErrorPatchFailed;
        });
        return;
      }

      // Consent saved. Reconcile the LocationNotifier sharing-mode side of
      // the world to the chosen radio. Without this, a user who previously
      // had Precise (foreground polling active) and picks Approximate or
      // Off would keep streaming GPS PUTs to /me/location even though the
      // row claims something else — the privacy regression that codex
      // flagged when the OS-permission Switch was removed from this screen.
      final locationNotifier = ref.read(locationProvider.notifier);
      final currentSharing = ref.read(locationProvider).sharingMode;
      var downgrade = false;

      switch (_selected) {
        case LocationConsentChoice.precise:
          final currentStatus = ref.read(locationProvider).permissionStatus;
          if (currentStatus != LocationPermissionStatus.granted) {
            // OS prompt is modal on native; the future completes when the
            // user answers. 30s soft-cap so a backgrounded prompt doesn't
            // wedge the sheet (B2). requestPermissionOnly() also calls
            // _startPeriodicUpdates() internally on grant, so we get the
            // foreground polling for free.
            final result = await locationNotifier
                .requestPermissionOnly()
                .timeout(
                  const Duration(seconds: 30),
                  onTimeout: () => LocationPermissionStatus.timeout,
                );
            if (result != LocationPermissionStatus.granted) {
              downgrade = true;
            }
          } else if (currentSharing != LocationSharingMode.always) {
            // Permission already granted but sharing was disabled (user came
            // back from Approximate/Off). Re-enable foreground polling.
            await locationNotifier.enableAlwaysShare();
          }
        case LocationConsentChoice.approximate:
        case LocationConsentChoice.off:
          // Stop foreground GPS polling so the device stops sending
          // device_gps PUTs once the user has selected a non-precise
          // intent. disableAlwaysShare() also clears the cached snapshot
          // and triggers an IP-approx fallback PUT (PROD-2303 step 5/6),
          // which matches Q3 (Approximate respects the row choice — PUT
          // ip_approx only, even when GPS permission is granted).
          if (currentSharing == LocationSharingMode.always) {
            await locationNotifier.disableAlwaysShare();
          }
      }

      if (!mounted) return;

      // Surface the snackbar from here — the row that opens the sheet may
      // be deep in the Settings list and unmounted by the time the user
      // returns. Tying it to the messenger captured before pop keeps it
      // reliable.
      if (downgrade) {
        messenger?.showSnackBar(
          SnackBar(content: Text(l10n.locationSnackbarOsDeniedDowngrade)),
        );
      }
      Navigator.of(context).pop<LocationConsentApplyResult>(
        downgrade
            ? LocationConsentApplyResult.downgradedToApprox
            : LocationConsentApplyResult.applied,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isApplying = false;
        _errorMessage = l10n.locationSheetErrorPatchFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.sokoPaper,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.sokoInk.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.locationSheetTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sokoInk,
                ),
              ),
              const SizedBox(height: 12),
              for (final choice in widget.availableChoices) ...[
                _ChoiceTile(
                  choice: choice,
                  selected: _selected == choice,
                  enabled: !_isApplying,
                  onTap: () => setState(() => _selected = choice),
                ),
                const SizedBox(height: 8),
              ],
              if (_errorMessage != null) ...[
                const SizedBox(height: 4),
                _ErrorBanner(message: _errorMessage!),
                const SizedBox(height: 12),
              ] else
                const SizedBox(height: 8),
              SokoCtaButton(
                label: _isApplying
                    ? l10n.locationSheetApplying
                    : (_errorMessage != null
                          ? l10n.locationSheetErrorRetry
                          : l10n.locationSheetApply),
                onPressed: _onApply,
                loading: _isApplying,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.choice,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final LocationConsentChoice choice;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final (String title, String desc) = switch (choice) {
      LocationConsentChoice.precise => (
        l10n.locationSheetPreciseTitle,
        l10n.locationSheetPreciseDesc,
      ),
      LocationConsentChoice.approximate => (
        l10n.locationSheetApproxTitle,
        l10n.locationSheetApproxDesc,
      ),
      LocationConsentChoice.off => (
        l10n.locationSheetOffTitle,
        l10n.locationSheetOffDesc,
      ),
    };

    final borderColor = selected
        ? AppColors.sokoPink
        : AppColors.sokoInk.withValues(alpha: 0.15);
    final bgColor = selected ? AppColors.sokoLight3 : AppColors.sokoPaper;

    return Opacity(
      opacity: enabled ? 1.0 : 0.6,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Semantics(
          inMutuallyExclusiveGroup: true,
          checked: selected,
          label: '$title. $desc',
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: bgColor,
              border: Border.all(color: borderColor, width: 1.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RadioIndicator(selected: selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.sokoInk,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        desc,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.sokoShade3,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RadioIndicator extends StatelessWidget {
  const _RadioIndicator({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? AppColors.sokoPink
              : AppColors.sokoInk.withValues(alpha: 0.35),
          width: 2,
        ),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.sokoPink,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sokoRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.sokoRed.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Text(
        message,
        style: const TextStyle(fontSize: 13, color: AppColors.sokoInk),
      ),
    );
  }
}
