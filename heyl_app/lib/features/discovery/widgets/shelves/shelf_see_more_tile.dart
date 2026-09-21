import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/clickable.dart';

/// Trailing "Ver mais" tile rendered at the end of a Discovery shelf when
/// the shelf has more content than the [kDiscoveryShelfMaxVisibleItems]
/// cap. Tapping it opens the shelf's vertical see-more page.
///
/// Visual (Figma frame `9155`): a rounded soft-pink block matching the
/// neighbouring cards' cover height with a right arrow centered inside,
/// and the "Ver mais" label below where the card names sit. The block
/// takes ~55 % of a card cell's width — the same half-card proportion the
/// paged loader tiles use — so the row's rhythm stays consistent.
class ShelfSeeMoreTile extends StatelessWidget {
  /// Effective card-cell width of the host shelf (viewport-scaled).
  final double cellWidth;

  /// Effective row height of the host shelf.
  final double rowHeight;

  /// Height of the neighbouring cards' image block. Null falls back to
  /// the legacy fraction of [rowHeight] (mirrors the loader tiles).
  final double? imageHeight;

  final VoidCallback onTap;

  const ShelfSeeMoreTile({
    super.key,
    required this.cellWidth,
    required this.rowHeight,
    required this.imageHeight,
    required this.onTap,
  });

  /// Block width as a fraction of the cell width — wider than the paged
  /// loader tiles' half-card peek so the arrow block reads as a real
  /// destination card.
  static const double _innerWidthFraction = 0.72;

  /// Legacy image-block fallback fraction, mirrors the loader tiles.
  static const double _imageHeightFraction = 0.78;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blockColor = isDark ? AppColors.surfaceDark : AppColors.sokoShade5;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final innerWidth = cellWidth * _innerWidthFraction;
    final blockHeight = imageHeight ?? rowHeight * _imageHeightFraction;
    final label = Lt.of(context).discoveryShelfSeeMore;

    return Clickable(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: label,
        child: SizedBox(
          width: innerWidth,
          height: rowHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: innerWidth,
                height: blockHeight,
                decoration: BoxDecoration(
                  color: blockColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  // Figma icon: thin right arrow with a wide chevron head
                  // (33×37 frame). Drawn (not a PNG) because the export
                  // clips the chevron tips at the canvas edge.
                  child: CustomPaint(
                    size: const Size(33, 37),
                    painter: _SeeMoreArrowPainter(color: inkColor),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Same type ramp as the card names beside it (Zalando Sans
              // Medium 18 / lh 1.0 / tracking -2%). Two lines so a narrow
              // phone tile wraps "Ver mais" / "See more" onto the second
              // line instead of ellipsising to "Ver m…".
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.body(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                  color: inkColor,
                ).copyWith(letterSpacing: -0.36),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thin right arrow with a wide chevron head, matching the Figma
/// see-more icon (33×37): a horizontal shaft through the middle and a
/// full-height chevron whose tip lands on the right edge.
class _SeeMoreArrowPainter extends CustomPainter {
  final Color color;

  const _SeeMoreArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final midY = size.height / 2;
    // Inset so the round caps stay inside the canvas.
    const inset = 1.0;
    final tipX = size.width - inset;
    // Chevron head: spans the full height, ~40% of the width deep.
    final headStartX = size.width * 0.58;

    // Shaft.
    canvas.drawLine(Offset(inset, midY), Offset(tipX, midY), paint);
    // Chevron head.
    final head = Path()
      ..moveTo(headStartX, inset)
      ..lineTo(tipX, midY)
      ..lineTo(headStartX, size.height - inset);
    canvas.drawPath(head, paint);
  }

  @override
  bool shouldRepaint(_SeeMoreArrowPainter oldDelegate) =>
      oldDelegate.color != color;
}
