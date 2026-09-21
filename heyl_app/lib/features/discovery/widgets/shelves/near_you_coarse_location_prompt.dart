import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/experiment_service.dart';
import '../../../../core/services/location_service.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/services/unified_analytics_service.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/location_provider.dart';
import 'location_prompt_card.dart';

/// PROD-4083 — whether the actionable "share precise location" prompt should
/// render. True only for the case where the user can actually fix it: **iOS**
/// with the per-app "Precise Location" setting **off** (so no amount of waiting
/// helps), the banner isn't dismissed, and the kill-switch is on. On web/Android
/// there's no per-app precise toggle to prompt here, and a precise-on-but-coarse
/// fix is either warming up or genuinely stuck — neither warrants a prompt.
bool shouldPromptPreciseLocation({
  required bool isIos,
  required bool preciseEnabled,
  required bool dismissed,
  required bool bannerEnabled,
}) => isIos && !preciseEnabled && !dismissed && bannerEnabled;

/// PROD-4083 — mounted under the Near-You shelf when location permission is
/// granted but the current fix is only a coarse GPS reading (`isGpsApproximate`).
///
/// Two jobs, in order, honouring "never nag while we're still acquiring":
///
///  1. **Silently try to upgrade** the coarse fix with one no-prompt read
///     (`refineCoarseFixIfPossible`). Runs on every platform; a warming-up GPS
///     fix upgrades and the shelf unmounts this widget.
///  2. **Only if we can't** — i.e. iOS has "Precise Location" turned **off** (a
///     setting, so waiting will never help and there IS a fix the user can make)
///     — show an actionable "share precise location" prompt whose button fires
///     the iOS temporary-full-accuracy dialog.
///
/// It renders **nothing** while still checking, when precise location is already
/// on (the fix is just warming up or genuinely stuck — no actionable prompt), on
/// web/Android (no per-app precise toggle to flip here), or after dismissal. So
/// the banner never appears mid-acquisition — the shelf holds its loading state
/// during the `awaitingPreciseFix` window, and this widget only mounts after.
class NearYouCoarseLocationPrompt extends ConsumerStatefulWidget {
  const NearYouCoarseLocationPrompt({super.key});

  @override
  ConsumerState<NearYouCoarseLocationPrompt> createState() =>
      _NearYouCoarseLocationPromptState();
}

class _NearYouCoarseLocationPromptState
    extends ConsumerState<NearYouCoarseLocationPrompt> {
  late bool _dismissed;

  /// null = still checking; otherwise the iOS "Precise Location" setting state
  /// (true on web/Android/precise-on — those never prompt here).
  bool? _preciseEnabled;
  bool _isRequesting = false;

  bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _dismissed = ref
        .read(storageServiceProvider)
        .isLocationSuggestionDismissed();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    if (!mounted) return;
    // (1) Best-effort silent upgrade. Harmless no-op when it can't help
    // (iOS reduced-accuracy stays coarse; the guards inside make it idempotent).
    unawaited(ref.read(locationProvider.notifier).refineCoarseFixIfPossible());

    // (2) Only iOS exposes a per-app precise toggle we can prompt to flip;
    // elsewhere treat precise as enabled so the prompt never shows.
    final preciseEnabled =
        !_isIos ||
        await ref.read(locationServiceProvider).isPreciseLocationEnabled();
    if (!mounted) return;
    setState(() => _preciseEnabled = preciseEnabled);
    if (_willShow(preciseEnabled)) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackLocationSuggestion(action: 'precise_impression');
    }
  }

  bool _willShow(bool preciseEnabled) => shouldPromptPreciseLocation(
    isIos: _isIos,
    preciseEnabled: preciseEnabled,
    dismissed: _dismissed,
    bannerEnabled: ref
        .read(experimentServiceProvider)
        .enableLocationSuggestionBanner,
  );

  Future<void> _enablePrecise() async {
    setState(() => _isRequesting = true);
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationSuggestion(action: 'precise_share_tapped');
    // Fires the iOS temporary-full-accuracy dialog, then re-polls. On grant the
    // fix turns precise and the shelf's `isGpsApproximate` gate unmounts us; on
    // denial we stay coarse and keep the banner.
    await ref.read(locationProvider.notifier).requestTemporaryPreciseLocation();
    if (!mounted) return;
    final preciseEnabled = await ref
        .read(locationServiceProvider)
        .isPreciseLocationEnabled();
    if (!mounted) return;
    setState(() {
      _isRequesting = false;
      _preciseEnabled = preciseEnabled;
    });
  }

  void _dismiss() {
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationSuggestion(action: 'precise_dismissed');
    ref.read(storageServiceProvider).saveLocationSuggestionDismissed();
    setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    // Nothing until the async precise-setting check resolves, then only for the
    // actionable iOS-precise-off case.
    final preciseEnabled = _preciseEnabled;
    if (preciseEnabled == null || !_willShow(preciseEnabled)) {
      return const SizedBox.shrink();
    }

    final l10n = Lt.of(context);
    return LocationPromptCard(
      icon: LucideIcons.map_pin,
      title: l10n.locationPreciseBannerTitle,
      body: l10n.locationPreciseBannerBody,
      ctaLabel: l10n.locationPreciseEnableButton,
      ctaIcon: LucideIcons.navigation,
      ctaLoading: _isRequesting,
      onCta: _isRequesting ? null : _enablePrecise,
      dismissLabel: l10n.locationSuggestionDismissButton,
      onDismiss: _dismiss,
    );
  }
}
