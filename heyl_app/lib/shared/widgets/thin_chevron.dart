// A hairline right chevron (›), the "there is more behind this" affordance.
//
// Hand-painted rather than the `chevron_right` icon-font glyph **because the
// glyph's weight is fixed and too heavy** next to a light display face. At the
// sizes this is used (8x20 beside a 42 px shelf title, 6x15 beside a 32 px
// bundle title) the font glyph reads as a bold arrowhead; a 1.6 px stroke
// reads as a hairline.
//
// Lifted out of `discovery_shelf.dart`, where it lived as a private painter,
// when the server-driven feed's bundle block needed the same affordance
// (PROD-4068). Nothing about it is shelf- or discovery-specific.

import 'package:flutter/material.dart';

/// The chevron as a widget — pair it with [ThinChevron.inTitleRun] to embed it
/// in a text run, or use it directly where a plain glyph is wanted.
class ThinChevron extends StatelessWidget {
  const ThinChevron({
    super.key,
    required this.color,
    this.size = const Size(8, 20),
  });

  final Color color;
  final Size size;

  /// Opacity the affordance is drawn at against the title's ink.
  ///
  /// The chevron is a hint, not a control: at full ink it competes with the
  /// title it belongs to.
  static const double inkAlpha = 0.35;

  /// The chevron as an [InlineSpan], sitting on the text baseline.
  ///
  /// **Baseline-aligned, not centred**: aligning to the middle of the line box
  /// floats it above the text, because the line box is taller than the
  /// lowercase band. Sitting it on the baseline at roughly x-height centres it
  /// on the title's final lowercase letter, which is where the eye expects it.
  ///
  /// [gap] is a leading [WidgetSpan] rather than padding so the whole run
  /// ellipsizes as one — a title long enough to truncate must not drop its
  /// chevron and silently lose the affordance.
  static List<InlineSpan> inTitleRun({
    required String title,
    required Color inkColor,
    Size size = const Size(8, 20),
    double gap = 10,
  }) => [
    TextSpan(text: title),
    WidgetSpan(child: SizedBox(width: gap)),
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: ThinChevron(
        color: inkColor.withValues(alpha: inkAlpha),
        size: size,
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: size, painter: ThinChevronPainter(color: color));
}

/// The painter behind [ThinChevron]. Public so a caller needing the raw glyph
/// inside its own `CustomPaint` (a `WidgetSpan`, a decoration) can reach it.
class ThinChevronPainter extends CustomPainter {
  final Color color;

  const ThinChevronPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * 0.15, size.height * 0.12)
      ..lineTo(size.width * 0.85, size.height * 0.5)
      ..lineTo(size.width * 0.15, size.height * 0.88);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(ThinChevronPainter oldDelegate) =>
      oldDelegate.color != color;
}
