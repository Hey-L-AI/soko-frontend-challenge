import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';

/// Tappable bordered "Add photo" button shown by [ListZineHeroSlot] when
/// the item has no displayable photo. Rendered as the topmost child of the
/// hero `Stack` so taps inside its bounds are absorbed (do NOT bubble to
/// the prev/next tap-zones below); taps that land on the dim hero bg
/// outside the button still navigate the zine.
///
/// **Today** the button is purely aspirational — the BE doesn't yet
/// support user-uploaded photos. Tapping it shows a "coming soon"
/// SnackBar via [onTap]. Future tickets ([PROD-1729] uploads,
/// [PROD-1730] moderation) will swap the SnackBar for a real picker.
class ListZineHeroPlaceholder extends StatelessWidget {
  /// Called when the user taps the bordered button. Callers wire this to
  /// show a transient "coming soon" SnackBar. When null, the button
  /// renders as a no-op (no visual disabled state — kept simple while the
  /// affordance is aspirational).
  final VoidCallback? onTap;

  const ListZineHeroPlaceholder({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Semantics(
      label: l10n.listZineAddPhotoHint,
      button: true,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          // Soft splash matching the bordered surface so the tap feedback
          // reads as part of the button, not the hero bg.
          splashColor: AppColors.sokoInk.withValues(alpha: 0.06),
          highlightColor: AppColors.sokoInk.withValues(alpha: 0.04),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.sokoPaper.withValues(alpha: 0.6),
              border: Border.all(
                color: AppColors.sokoInk.withValues(alpha: 0.18),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.image_plus,
                  size: 28,
                  color: AppColors.sokoInk.withValues(alpha: 0.6),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.listZineAddPhotoHint,
                  style: AppTheme.mobileB2Reg(
                    color: AppColors.sokoInk.withValues(alpha: 0.7),
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
