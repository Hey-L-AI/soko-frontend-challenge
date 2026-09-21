import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Which mark sits inside the ring.
enum MemoryGlyphKind { plus, minus, arrowDown, arrowUp }

/// The circled +, −, and ▾ marks from the memory design.
///
/// Drawn rather than bundled: the Figma exports are 26x26 PNGs at 1x, which
/// blur at 2x/3x and cannot be tinted. The shapes are pure geometry, so the
/// measured proportions below reproduce them exactly and stay crisp at any
/// size. Every ratio is measured off those exports (`Icon.png`, 26x26):
///
/// * ring is FULL-BLEED — it touches the box edge, unlike Lucide's inset
///   `circle_plus`, whose ring sits 2/24 in from the edge;
/// * ring stroke ~1.2 px on 26 => 0.046 of the box;
/// * the mark spans x8..x17 => 10 px on 26 => 0.385 of the box, centred;
/// * mark stroke ~1.5 px on 26 => 0.058 of the box;
/// * colour is `#3B0F18` at FULL opacity — Soko/Ink, not a faded hairline.
///
/// Replace with the SVGs if the icons are ever re-exported as vectors.
class MemoryGlyph extends StatelessWidget {
  final MemoryGlyphKind kind;
  final double size;
  final Color color;

  const MemoryGlyph({
    super.key,
    required this.kind,
    this.size = 26,
    this.color = AppColors.sokoInk,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _MemoryGlyphPainter(kind: kind, color: color),
    ),
  );
}

class _MemoryGlyphPainter extends CustomPainter {
  final MemoryGlyphKind kind;
  final Color color;

  const _MemoryGlyphPainter({required this.kind, required this.color});

  // Ratios of the box, measured off the 26x26 Figma exports by summing alpha
  // coverage rather than counting solid pixels — the marks are thin enough
  // that eyeballing the raster over-reads every dimension.
  static const double _ringStroke = 1.0 / 26; // 1.00 px of coverage
  static const double _markStroke = 1.0 / 26; // two rows at 50% => 1.0 px
  // The bar measures 10.75 px END TO END, caps included. With round caps the
  // drawn extent is (2 * half) + stroke, so the geometric half-length is
  // (10.75 - 1.0) / 2 = 4.875.
  static const double _markHalf = 4.875 / 26;
  static const double _headHalf = 4.5 / 26; // arrowhead half-width
  static const double _headRise = 4 / 26; // arrowhead height

  @override
  void paint(Canvas canvas, Size size) {
    final d = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);
    final ringStroke = d * _ringStroke;
    final markStroke = d * _markStroke;
    final half = d * _markHalf;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringStroke
      ..color = color
      ..isAntiAlias = true;
    // Full-bleed: inset by half the stroke so the ring's OUTER edge lands on
    // the box edge, which is where the export draws it.
    canvas.drawCircle(c, (d - ringStroke) / 2, ring);

    final mark = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = markStroke
      // Round, not butt: the design's marks have rounded ends. The 1 px raster
      // export cannot show it, but it is visible at the 31 px this renders at.
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..isAntiAlias = true;

    switch (kind) {
      case MemoryGlyphKind.minus:
        canvas.drawLine(c - Offset(half, 0), c + Offset(half, 0), mark);
      case MemoryGlyphKind.plus:
        canvas.drawLine(c - Offset(half, 0), c + Offset(half, 0), mark);
        canvas.drawLine(c - Offset(0, half), c + Offset(0, half), mark);
      case MemoryGlyphKind.arrowDown:
      case MemoryGlyphKind.arrowUp:
        // The arrow is the same stem as the plus's vertical, with a chevron at
        // the pointing end. `arrowUp` is the mirror, so the collapse/expand
        // toggle flips rather than rotating a glyph drawn for one direction.
        final s = kind == MemoryGlyphKind.arrowDown ? 1.0 : -1.0;
        canvas.drawLine(c - Offset(0, half * s), c + Offset(0, half * s), mark);
        final tip = c + Offset(0, half * s);
        final hw = d * _headHalf;
        final hr = d * _headRise;
        canvas.drawLine(tip, tip + Offset(-hw, -hr * s), mark);
        canvas.drawLine(tip, tip + Offset(hw, -hr * s), mark);
    }
  }

  @override
  bool shouldRepaint(covariant _MemoryGlyphPainter old) =>
      old.kind != kind || old.color != color;
}
