import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';

/// Dialog for choosing location sharing mode
class LocationSharingDialog extends StatelessWidget {
  final VoidCallback onShareOnce;
  final VoidCallback onShareAlways;

  const LocationSharingDialog({
    super.key,
    required this.onShareOnce,
    required this.onShareAlways,
  });

  static Future<void> show({
    required BuildContext context,
    required VoidCallback onShareOnce,
    required VoidCallback onShareAlways,
  }) {
    return showDialog(
      context: context,
      builder: (context) => LocationSharingDialog(
        onShareOnce: onShareOnce,
        onShareAlways: onShareAlways,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Dialog(
      backgroundColor: AppColors.sokoPaper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Close button
            Align(
              alignment: Alignment.topRight,
              child: Clickable(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    color: AppColors.sokoShade5,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    size: 18,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ),

            // Icon
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.sokoShade5,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.location_on,
                size: 32,
                color: AppColors.sokoInk,
              ),
            ),

            const SizedBox(height: 16),

            // Title
            Text(
              l10n.mapWidgetShareTitle,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),

            const SizedBox(height: 8),

            // Subtitle
            Text(
              l10n.mapWidgetShareSubtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.sokoShade3,
              ),
            ),

            const SizedBox(height: 24),

            // Share Always button (primary)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  onShareAlways();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sokoPink,
                  foregroundColor: AppColors.sokoInk,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  l10n.mapWidgetShareAlways,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Share Once button (secondary)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(context);
                  onShareOnce();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sokoInk,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: AppColors.sokoShade5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  l10n.mapWidgetShareOnce,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
