import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';

/// Small tappable pill badge prompting the user to enable GPS location.
/// Shown on the compact chat map when the location is IP-based fallback.
class EnableLocationBadge extends StatelessWidget {
  final VoidCallback onTap;

  const EnableLocationBadge({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Clickable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.sokoPink,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.my_location,
              size: 12,
              color: AppColors.sokoInk,
            ),
            const SizedBox(width: 4),
            Text(
              l10n.locationEnableBadge,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.chevron_right,
              size: 12,
              color: AppColors.sokoInk,
            ),
          ],
        ),
      ),
    );
  }
}
