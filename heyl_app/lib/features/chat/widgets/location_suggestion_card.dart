import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

/// In-chat card that suggests the user share their GPS location.
///
/// Rendered directly in the message list (not as a ChatMessage) so it's
/// ephemeral — disappears when conditions change (e.g., user shares location
/// or dismisses it). Styled like an assistant message bubble for visual
/// consistency.
class LocationSuggestionCard extends StatelessWidget {
  final VoidCallback onShareLocation;
  final VoidCallback onDismiss;

  const LocationSuggestionCard({
    super.key,
    required this.onShareLocation,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    // Soko tokens (PROD-1804) — paint matches the assistant bubble.
    const bubbleColor = AppColors.sokoShade5;
    const textColor = AppColors.sokoInk;
    const textSecondaryColor = AppColors.sokoShade3;
    const primaryColor = AppColors.sokoInk;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Location icon + text
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  LucideIcons.map_pin,
                  size: 18,
                  color: primaryColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.locationSuggestionText,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Action buttons
            Row(
              children: [
                // "Share my location" filled button
                Expanded(
                  child: FilledButton(
                    onPressed: onShareLocation,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sokoPink,
                      foregroundColor: AppColors.sokoInk,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: Text(l10n.locationSuggestionShareButton),
                  ),
                ),
                const SizedBox(width: 8),
                // "Not now" text button
                TextButton(
                  onPressed: onDismiss,
                  style: TextButton.styleFrom(
                    foregroundColor: textSecondaryColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  child: Text(l10n.locationSuggestionDismissButton),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
