// PROD-4068 — the "there is more behind this" arrow, pointing right.
//
// **The back button's glyph, mirrored** (`kSokoArrowGlyph` via
// `Transform.scale(scaleX: -1)`), rather than a second drawing. The two arrows
// on a see-all round trip — the chevron that opens the page and the back arrow
// that leaves it — are then visibly the same object, and swapping the art
// cannot leave them disagreeing.
//
// Replaces the hairline `ThinChevron` on the feed's bundle affordance (Zé,
// 2026-08-28). `ThinChevron` stays: the legacy Discovery shelves still embed it
// in their title text run, which is a different layout and a different weight.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'soko_back_button.dart';

class SokoForwardArrow extends StatelessWidget {
  const SokoForwardArrow({
    super.key,
    required this.color,
    this.boxSize = defaultBoxSize,
  });

  /// Ink the glyph is tinted with. Callers pass it already faded — the
  /// affordance is a hint, not a control, and at full ink it competes with the
  /// title it belongs to.
  final Color color;

  /// Side of the square hit target the glyph is centred in.
  ///
  /// Defaults to 40 to match `CircleIconButton`, which is what the rows
  /// beneath a bundle title put at the same right edge — so the arrow and the
  /// save buttons share a vertical axis rather than being off by a few pixels.
  final double boxSize;

  static const double defaultBoxSize = 40;

  /// Glyph box. 22×17 is the chrome header's back-arrow size, kept identical so
  /// the outbound and inbound arrows of a see-all round trip are the same
  /// weight.
  static const double _glyphWidth = 22;
  static const double _glyphHeight = 17;

  /// Opacity the affordance is drawn at against the title's ink.
  static const double inkAlpha = 0.35;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: boxSize,
    height: boxSize,
    child: Center(
      child: Transform.scale(
        scaleX: -1,
        child: SvgPicture.asset(
          kSokoArrowGlyph,
          width: _glyphWidth,
          height: _glyphHeight,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        ),
      ),
    ),
  );
}
