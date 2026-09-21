import 'package:flutter/material.dart';

/// Thin dotted rule — the Soko editorial "ticket / coupon" separator.
///
/// Extracted from `discovery/widgets/sections/_editorial_overlay.dart`
/// (PROD-1518, where it was private) so the Daily Drop branded detail
/// header (PROD-3439) and the forthcoming card states (PROD-3438) can
/// draw the same rule instead of each re-deriving the dot geometry.
///
/// Two densities are in use, both measured off Figma rather than guessed:
///
///   - the **card overlay** default ([dotRadius] 0.9, [gap] 2.6 → 4.4 px
///     pitch), matching `stroke-dasharray: 0.07 3.42` on the 399-px card
///     frame, slightly thickened so the dots survive pink-cream covers;
///   - the **detail header** ([dotRadius] 1.0, [gap] 5.0 → 7 px pitch),
///     measured off Figma `7204:22712` (58 dots across the 400-px content
///     column).
class SokoDottedRule extends StatelessWidget {
  final Color color;

  /// Radius of each dot in logical pixels.
  final double dotRadius;

  /// Empty space between dots; pitch is `dotRadius * 2 + gap`.
  final double gap;

  const SokoDottedRule({
    super.key,
    required this.color,
    this.dotRadius = 0.9,
    this.gap = 2.6,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: dotRadius * 2,
      child: CustomPaint(
        painter: _SokoDottedRulePainter(
          color: color,
          dotRadius: dotRadius,
          gap: gap,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SokoDottedRulePainter extends CustomPainter {
  final Color color;
  final double dotRadius;
  final double gap;

  _SokoDottedRulePainter({
    required this.color,
    required this.dotRadius,
    required this.gap,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final step = dotRadius * 2 + gap;
    final cy = size.height / 2;
    for (double cx = dotRadius; cx <= size.width; cx += step) {
      canvas.drawCircle(Offset(cx, cy), dotRadius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SokoDottedRulePainter oldDelegate) =>
      color != oldDelegate.color ||
      dotRadius != oldDelegate.dotRadius ||
      gap != oldDelegate.gap;
}
