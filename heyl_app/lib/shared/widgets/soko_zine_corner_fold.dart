// PROD-4118 — the static folded corner on a zine cover. Figma `7686-43803`
// (frame 194 × 242; the fold's own box `7686:43807` is 43 × 35 at x151, y0).
//
// The cover's top-right corner is turned down: you see a slice of the **page
// underneath** in a Soko brand colour, with the back of the folded flap —
// `Soko/Paper` — lying over the rest of the corner box. The two triangles tile
// the box exactly, split by one diagonal from its top-left to its bottom-right.
//
// ⚠️ **Static, not the animated peel.** `ZineCoverPeelOverlay` /
// `ListZineTeasePeel` exist for a different job: an intermittent *hint* that a
// card opens into a page-turn, gated so roughly one card per band animates. On
// the new home feed the fold is **part of the cover** — every zine carries it,
// it never moves, and it is the thing that makes a zine legible as a zine next
// to an event and a venue in the same scroll. Reusing the animated widget here
// would have made a decoration flicker across the page and would have left most
// covers without one.
//
// ⚠️ **The Figma frame's dark navy is illustrative.** Every Soko brand colour is
// a light pastel; the mock's `#055F89` is not one of them. Per Zé the fold's
// colour is a **brand** colour standing in for the first page under the cover —
// see [SokoZineCornerFold.pageColorFor].
//
// **The page is receded twice, and neither half is decoration.** A brand pastel
// painted raw in the corner reads as a bright sticker stuck on the cover rather
// than as something behind it — it out-competes the artwork it is supposed to
// frame. So the colour is mixed toward ink (most of the effect) and a very faint
// ink gradient is laid along the fold line (the rest). Two candidates were built
// and compared on device before settling here; the shadow-only variant kept the
// hue true but went murky over dark covers, and a heavier mix stopped reading as
// the same brand colour at all.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../features/lists/utils/zine_cover_recipe.dart';

/// A turned-down top-right corner, sized as a fraction of the cover's width.
///
/// Drop it into the cover's `Stack` as the last child — it paints only inside
/// its own corner box and is `IgnorePointer`-free by construction (a
/// `CustomPaint` with no gesture surface), so it never steals a tap from the
/// card underneath.
class SokoZineCornerFold extends StatelessWidget {
  /// Colour of the page showing under the turned corner. One of the six Soko
  /// brand colours — see [pageColorFor].
  final Color pageColor;

  /// The flap's own colour: the back of the cover, which is paper.
  final Color flapColor;

  const SokoZineCornerFold({
    super.key,
    required this.pageColor,
    this.flapColor = AppColors.sokoPaper,
  });

  /// How far the brand colour is pulled toward ink.
  ///
  /// **Most of the recede comes from here** (Zé, 2026-09-02, after seeing both
  /// candidates on device): a raw brand pastel in the corner caught the eye
  /// harder than the cover it belonged to. Started at 0.38, which read as a
  /// different and muddier colour rather than as a shaded one — this is the
  /// dialled-back value.
  static const double _mixTowardInk = 0.22;

  /// …and then a little toward white, to take the edge off the saturation so
  /// the result reads as a *shaded page* rather than a seventh brand colour.
  static const double _mixTowardWhite = 0.10;

  /// Opacity of the ink shadow laid along the fold line.
  ///
  /// ⚠️ **Deliberately barely visible.** The mix above does the work; this only
  /// keeps the fold from looking like a flat sticker by hinting that the cover
  /// is casting onto the page. It ran at 0.42 while the two treatments were
  /// being compared as alternatives — at that strength it competes with the
  /// pigment instead of supporting it, and the corner goes murky over a dark
  /// cover photo.
  static const double _shadowAlpha = 0.12;

  /// The page colour actually painted: the brand colour, receded.
  static Color mixedPageColor(Color base) => Color.lerp(
    Color.lerp(base, AppColors.sokoInk, _mixTowardInk)!,
    const Color(0xFFFFFFFF),
    _mixTowardWhite,
  )!;

  /// The fold's width as a fraction of the cover's width — `43 / 194` from the
  /// frame. Expressed as a ratio rather than a fixed 43 px because the same
  /// cover renders at 194 in a grid cell and at 64 in a bundle row, and a fixed
  /// corner would swamp the small one.
  static const double widthFraction = 43 / 194;

  /// The fold's own aspect ratio, `35 / 43` from the frame. Kept separate from
  /// the cover's aspect so the corner stays the same *shape* on a 4:5 grid card
  /// and on a taller row thumbnail.
  static const double heightPerWidth = 35 / 43;

  /// Radius on the flap's bottom-left corner, as a fraction of the fold's
  /// width — `6 / 43`, the `C2.68629 34.9453 0 32.259 0 28.9453` arc in the
  /// frame's export. Fractional so it scales with everything else.
  static const double cornerRadiusFraction = 6 / 43;

  /// How far the flap's apex sits **above** the fold box, as a fraction of its
  /// width — `2.05469 / 43`, the `V-2.05469` in the frame's export.
  ///
  /// Small but not cosmetic: it is what sets the diagonal's slope (37 over 43,
  /// not 35 over 43) and it gives the flap a few pixels of width at the card's
  /// very top edge instead of tapering to a point there. Dropping it leaves the
  /// top-left of the fold visibly emptier than the frame.
  static const double apexOvershootFraction = 2.05469 / 43;

  /// The Soko colour standing in for the first page under [listId]'s cover.
  ///
  /// ⚠️ **Deterministic from the id, not the real first page.** The true colour
  /// is the first item's derived palette colour (`zineItemColorProvider`,
  /// PROD-4072), which needs that item's id and image — neither of which the
  /// feed payload carries. Zé's call (2026-09-02) was to derive one from the
  /// zine id meanwhile: stable across devices and sessions, always on-brand,
  /// and never a neutral.
  ///
  /// **[coverColor] is excluded, not merely preferred against.** A solid
  /// `background_color` cover in the same brand colour would make the fold
  /// vanish — the page underneath would be indistinguishable from the cover
  /// over it, which reads as a rendering bug rather than a design. Stepping to
  /// the next colour in the palette guarantees the fold is always visible while
  /// keeping the choice deterministic.
  static Color pageColorFor(String listId, {ZineCoverColor? coverColor}) {
    final index = stableHash(listId) % kZineColors.length;
    var pick = kZineColors[index];
    if (coverColor != null && pick == coverColor) {
      pick = kZineColors[(index + 1) % kZineColors.length];
    }
    return pick.flutterColor;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Width-driven, so the corner is the same proportion of every cover it
      // sits on. An unbounded width would make the fold meaningless, so fall
      // back to the frame's own 43.
      final coverWidth = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : 194.0;
      final foldWidth = coverWidth * widthFraction;
      return Align(
        alignment: Alignment.topRight,
        child: SizedBox(
          width: foldWidth,
          height: foldWidth * heightPerWidth,
          child: CustomPaint(
            painter: _CornerFoldPainter(
              // Both at once, and in this order: the pigment recedes the
              // colour, the shadow then hints at depth on top of it.
              pageColor: mixedPageColor(pageColor),
              flapColor: flapColor,
              radiusFraction: cornerRadiusFraction,
              apexOvershootFraction: apexOvershootFraction,
              shadowAlpha: _shadowAlpha,
            ),
          ),
        ),
      );
    },
  );
}

/// Builds the fold's two paths for a given box.
///
/// Exposed so tests can ask `Path.contains(offset)` directly. Reading the
/// rendered pixels would be the obvious alternative and does not work here:
/// `RenderRepaintBoundary.toImage` needs a real surface, so in a plain widget
/// test it never completes and the suite reports "0 tests ran" rather than
/// failing anywhere near this file.
@visibleForTesting
class SokoZineFoldPaths {
  /// The turned-down flap: below the diagonal, bottom-left corner rounded.
  static Path flap(
    Size size, {
    double radiusFraction = SokoZineCornerFold.cornerRadiusFraction,
    double apexOvershootFraction = SokoZineCornerFold.apexOvershootFraction,
  }) {
    final w = size.width;
    final h = size.height;
    final r = w * radiusFraction;
    final apexY = -w * apexOvershootFraction;
    return Path()
      ..moveTo(w, h)
      ..lineTo(r, h)
      // ⚠️ **A quadratic bezier through the true corner, not `arcToPoint`.**
      // `arcToPoint` needs a sweep direction, and with `clockwise: false` it
      // takes the long way round — which bites a chunk out of the flap near its
      // left edge and reads as the top-left being "clipped weirdly" while the
      // bottom-left never looks round at all. The control point *is* the corner
      // the radius cuts, so this form has no direction to get wrong.
      ..quadraticBezierTo(0, h, 0, h - r)
      ..lineTo(0, apexY)
      ..close();
  }

  /// The page under the cover: everything above the diagonal.
  static Path page(
    Size size, {
    double apexOvershootFraction = SokoZineCornerFold.apexOvershootFraction,
  }) {
    final w = size.width;
    final h = size.height;
    final apexY = -w * apexOvershootFraction;
    return Path()
      ..moveTo(0, apexY)
      ..lineTo(w, apexY)
      ..lineTo(w, h)
      ..close();
  }
}

class _CornerFoldPainter extends CustomPainter {
  final Color pageColor;
  final Color flapColor;
  final double radiusFraction;
  final double apexOvershootFraction;

  /// Ink laid along the fold line, fading out toward the corner. Zero disables
  /// the shadow entirely (the `mixed` variant carries its depth in the colour).
  final double shadowAlpha;

  const _CornerFoldPainter({
    required this.pageColor,
    required this.flapColor,
    required this.radiusFraction,
    required this.apexOvershootFraction,
    required this.shadowAlpha,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final apexY = -w * apexOvershootFraction;

    final pagePath = SokoZineFoldPaths.page(
      size,
      apexOvershootFraction: apexOvershootFraction,
    );

    // The page under the cover. Painted across the whole box first, so the
    // flap's rounded corner reveals page colour rather than whatever sits
    // behind the fold.
    canvas.drawPath(pagePath, Paint()..color = pageColor);

    // The cover's shadow ON that page: darkest right at the fold line, gone by
    // the corner. Clipped to the page triangle, so it never darkens the flap —
    // the flap is the lit side.
    if (shadowAlpha > 0) {
      // Perpendicular to the diagonal, so the falloff follows the fold rather
      // than the box. The diagonal runs (0, apexY) → (w, h); its normal points
      // up and to the right.
      final dy = h - apexY;
      final len = math.sqrt(dy * dy + w * w);
      final normal = Offset(dy / len, -w / len);
      final mid = Offset(w / 2, (apexY + h) / 2);
      // Perpendicular distance from the diagonal to the far corner — the full
      // depth the gradient has to cover.
      final reach = w * dy / len;
      canvas.save();
      canvas.clipPath(pagePath);
      canvas.drawPath(
        pagePath,
        Paint()
          ..shader = ui.Gradient.linear(mid, mid + normal * reach, [
            AppColors.sokoInk.withValues(alpha: shadowAlpha),
            AppColors.sokoInk.withValues(alpha: 0),
          ]),
      );
      canvas.restore();
    }

    canvas.drawPath(
      SokoZineFoldPaths.flap(
        size,
        radiusFraction: radiusFraction,
        apexOvershootFraction: apexOvershootFraction,
      ),
      Paint()..color = flapColor,
    );
  }

  @override
  bool shouldRepaint(_CornerFoldPainter old) =>
      old.pageColor != pageColor ||
      old.flapColor != flapColor ||
      old.radiusFraction != radiusFraction ||
      old.apexOvershootFraction != apexOvershootFraction ||
      old.shadowAlpha != shadowAlpha;
}
