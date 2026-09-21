import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/storage_service.dart';
import '../../../../core/services/location_service.dart';
import '../../../../core/services/unified_analytics_service.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/location_provider.dart';
import '../../../../shared/utils/bottom_sheet_utils.dart';
import '../../../../shared/widgets/browser_instructions_sheet.dart';
import 'location_prompt_card.dart';

/// A low-pressure prompt shown below Near You when Discovery has a city but
/// cannot calculate exact distances from the user's position. It shares the
/// existing seven-day dismissal cooldown and analytics with the chat prompt so
/// people who say "Not now" are not asked again elsewhere in the app.
class NearYouLocationCta extends ConsumerStatefulWidget {
  const NearYouLocationCta({super.key});

  @override
  ConsumerState<NearYouLocationCta> createState() => _NearYouLocationCtaState();
}

class _NearYouLocationCtaState extends ConsumerState<NearYouLocationCta> {
  late bool _dismissed;
  bool _isRequesting = false;

  @override
  void initState() {
    super.initState();
    _dismissed = ref
        .read(storageServiceProvider)
        .isLocationSuggestionDismissed();
    if (!_dismissed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(unifiedAnalyticsProvider)
              .trackLocationSuggestion(action: 'impression');
        }
      });
    }
  }

  Future<void> _enableLocation() async {
    final notifier = ref.read(locationProvider.notifier);
    final locationState = ref.read(locationProvider);
    setState(() => _isRequesting = true);
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationSuggestion(action: 'share_tapped');
    if (locationState.permissionStatus ==
        LocationPermissionStatus.deniedForever) {
      if (kIsWeb) {
        if (mounted) {
          showBottomSheetWithHiddenNav<void>(
            context: context,
            ref: ref,
            useRootNavigator: true,
            builder: (_) => BrowserInstructionsSheet(
              onCheckAgain: () {
                Navigator.pop(context);
                notifier.requestPermissionOnly();
              },
            ),
          );
        }
      } else {
        notifier.openSettings();
      }
    } else {
      await notifier.requestPermissionOnly();
    }
    if (mounted) setState(() => _isRequesting = false);
  }

  void _dismiss() {
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationSuggestion(action: 'dismissed');
    ref.read(storageServiceProvider).saveLocationSuggestionDismissed();
    setState(() => _dismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    return LocationPromptCard(
      icon: LucideIcons.map_pin,
      title: l10n.locationSharingBannerTitle,
      body: l10n.locationSuggestionText,
      ctaLabel: l10n.locationEnableBadge,
      ctaIcon: LucideIcons.navigation,
      ctaLoading: _isRequesting,
      onCta: _isRequesting ? null : _enableLocation,
      dismissLabel: l10n.locationSuggestionDismissButton,
      onDismiss: _dismiss,
    );
  }
}
