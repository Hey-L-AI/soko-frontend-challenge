import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';

/// Full-width banner shown on the expanded map when location sharing is off
/// (IP fallback). Adapts its subtitle and action based on whether the user
/// can still be prompted for permission or has permanently denied it.
class LocationSharingBanner extends StatelessWidget {
  final VoidCallback onTap;

  /// When true, the banner shows "Enable in browser settings" instead of
  /// "Tap to enable", since the system prompt can no longer be triggered.
  final bool isDeniedForever;

  const LocationSharingBanner({
    super.key,
    required this.onTap,
    this.isDeniedForever = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Clickable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.sokoPink,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.location_off,
              size: 20,
              color: AppColors.sokoInk,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.locationSharingBannerTitle,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.sokoInk,
                    ),
                  ),
                  Text(
                    isDeniedForever
                        ? l10n.locationSharingBannerActionSettings
                        : l10n.locationSharingBannerAction,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.sokoInk.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: AppColors.sokoInk,
            ),
          ],
        ),
      ),
    );
  }
}
