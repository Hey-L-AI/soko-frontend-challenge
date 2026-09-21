import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/social_proof.dart';
import '../../l10n/generated/l10n.dart';

/// Small pill badge showing save count, designed to overlay on card images.
/// Position with `Positioned(bottom: ..., right: ...)` inside a Stack.
class SocialProofBadge extends StatelessWidget {
  final SocialProof proof;

  /// Badge size factor (scales icon + text). Use smaller values for compact thumbnails.
  final double scale;

  const SocialProofBadge({super.key, required this.proof, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    if (proof.saveCount <= 0) return const SizedBox.shrink();

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 4 * scale, vertical: 2 * scale),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6 * scale),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bookmark, size: 10 * scale, color: Colors.white),
          SizedBox(width: 2 * scale),
          Text(
            '${proof.saveCount}',
            style: TextStyle(
              fontSize: 9 * scale,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Prominent label showing list count, placed in the card content area.
/// e.g., "3 listas com este sítio" / "2 lists with this event"
class SocialProofListsLabel extends StatelessWidget {
  final SocialProof proof;
  final String itemType; // 'event' or 'place'

  const SocialProofListsLabel({
    super.key,
    required this.proof,
    required this.itemType,
  });

  @override
  Widget build(BuildContext context) {
    if (proof.listCount <= 0 || proof.lists.isEmpty)
      return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final l10n = Lt.of(context);

    final text = itemType == 'place'
        ? l10n.detailInListsPlace
        : l10n.detailInListsEvent;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: primaryColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: primaryColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
