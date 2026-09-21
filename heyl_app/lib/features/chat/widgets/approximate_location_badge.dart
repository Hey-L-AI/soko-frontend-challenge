import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';

/// Small pill badge indicating approximate GPS location (poor accuracy).
///
/// Display-only by default — the CTA role for "location is off entirely" is
/// handled by [LocationSharingBanner]. When [onTap] is supplied the badge
/// becomes a CTA in its own right and grows a chevron so the affordance matches
/// the behaviour; the host decides whether a coarse fix is actually fixable on
/// this platform (see `MapboxMapWidget._handleApproximateTap`). Passing null
/// keeps the historic inert pill, which is the correct rendering on web, where
/// browsers expose no location-accuracy setting at all.
class ApproximateLocationBadge extends StatelessWidget {
  const ApproximateLocationBadge({super.key, this.onTap});

  /// When non-null the badge is tappable and shows a chevron.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.near_me_disabled,
            size: 12,
            color: AppColors.sokoShade3,
          ),
          const SizedBox(width: 4),
          Text(
            l10n.locationApproximate,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.sokoShade3,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            const Icon(
              Icons.chevron_right,
              size: 12,
              color: AppColors.sokoShade3,
            ),
          ],
        ],
      ),
    );

    final tap = onTap;
    if (tap == null) return pill;
    return Clickable(onTap: tap, child: pill);
  }
}
