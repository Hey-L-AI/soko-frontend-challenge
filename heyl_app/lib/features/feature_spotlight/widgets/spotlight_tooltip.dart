import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/soko_cta_button.dart';

/// Coachmark card used by every feature spotlight (PROD-2808).
///
/// Mirrors the onboarding voice: Soko Paper card with Soko Ink text, a
/// single primary CTA (`SokoCtaButton`), and a dismiss link. The Soko
/// hand pointer is NOT rendered here — it lives in a separate
/// `OverlayEntry` positioned relative to the target's actual rect (see
/// `spotlight_hand_overlay.dart`) so it correctly points at the button
/// regardless of where `showcaseview` places this card.
class SpotlightTooltip extends StatelessWidget {
  const SpotlightTooltip({
    super.key,
    required this.title,
    required this.body,
    required this.ctaLabel,
    required this.dismissLabel,
    required this.onCtaTapped,
    required this.onDismissed,
    this.illustrationAsset,
    this.content,
    this.showDismissLink = true,
    this.cardKey,
  });

  final String title;
  final String body;
  final String ctaLabel;
  final String dismissLabel;
  final VoidCallback onCtaTapped;
  final VoidCallback onDismissed;
  final String? illustrationAsset;

  /// Optional custom widget rendered between the body and the primary CTA —
  /// e.g. the mutual-follow Soko card on the profile spotlight. Null for the
  /// text-only spotlights.
  final Widget? content;

  /// Whether to render the small dismiss link below the primary CTA.
  /// Set to `false` for pure-acknowledgment spotlights whose primary CTA
  /// already means "dismiss" (e.g. message-feedback teaching a gesture)
  /// so the tooltip doesn't render two buttons with the same label.
  final bool showDismissLink;

  /// Attached to the visible card [Container] so the Soko hand overlay can
  /// resolve the card's actual on-screen rect and place itself on the side
  /// opposite wherever `showcaseview` (which may auto-flip past a screen
  /// edge) actually landed the card. See `spotlight_hand_overlay.dart`.
  final GlobalKey? cardKey;

  static const double _maxWidth = 340.0;
  static const double _horizontalMargin = 16.0;

  @override
  Widget build(BuildContext context) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final effectiveMax = (viewportWidth - _horizontalMargin * 2).clamp(
      240.0,
      _maxWidth,
    );

    return Center(
      child: Container(
        key: cardKey,
        constraints: BoxConstraints(maxWidth: effectiveMax),
        decoration: BoxDecoration(
          color: AppColors.sokoPaper,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: AppColors.sokoInk.withValues(alpha: 0.15),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (illustrationAsset != null) ...[
              Center(
                child: Image.asset(
                  illustrationAsset!,
                  height: 64,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              title,
              style: AppTheme.display(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: AppTheme.body(fontSize: 14, color: AppColors.sokoInk),
            ),
            if (content != null) ...[const SizedBox(height: 14), content!],
            const SizedBox(height: 16),
            SokoCtaButton(
              label: ctaLabel,
              onPressed: onCtaTapped,
              expand: true,
            ),
            if (showDismissLink) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: onDismissed,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.sokoInkSecondary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    dismissLabel,
                    style: AppTheme.body(
                      fontSize: 13,
                      color: AppColors.sokoInkSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
