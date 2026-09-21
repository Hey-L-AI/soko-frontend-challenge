import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/hero_image_warmup.dart';

/// Shared `Hero` tag for the DAILY DROP wordmark shared-element flight: the
/// lockup on the Discovery ready card ([DailyDropReadyCard]) flies up into the
/// drop detail page's branded header ([DailyDropDetailHeader]) on open. Only
/// those two surfaces carry it — they live on different routes, so the tag is
/// unique per route. The status cards (generating / timed-out) also render the
/// wordmark but open a sheet, not the detail, so they deliberately leave it
/// unset.
const String dailyDropWordmarkHeroTag = 'daily-drop-wordmark';

/// The sticker-style **DAILY DROP** lockup: a dark letterform wrapped in a
/// coloured band, wrapped again in a dark rim — scaled to fill its width.
///
/// Built for the branded detail header (PROD-3439) but standalone so the
/// Daily Drop card states (PROD-3438) can reuse it — PROD-3439's brief asks
/// for the wordmark to be shared "where sensible", and FE-1 had not started
/// when this landed.
///
/// ## Why three passes
///
/// Figma builds this from two stacked layers (`7204:22717`), which read as
/// three visual bands. Bottom to top:
///
/// 1. `daily drop (Stroke)` — the glyphs as vectors, filled **and** stroked
///    `#3B0F18` with `stroke-linejoin: round`. A dilated dark silhouette;
///    the round joins are what fuse the serifs and make the letters read as
///    one fat geometric lockup rather than nine separate glyphs.
/// 2. The text run — SeasonMix **Regular**, dark `#3B0F18` fill, with a
///    coloured stroke around it (the per-drop variant colour).
///
/// So the eye sees, outside in: **dark rim → coloured band → dark core.**
/// Flutter has no single-pass stroke+fill `TextStyle`, so we paint the same
/// string three times in one [Stack] — widest stroke first, fill last. Each
/// pass overpaints the middle of the one below, leaving its edge showing as
/// a band.
///
/// Getting this wrong is subtle: a single dark stroke behind a coloured fill
/// (the obvious two-pass version) inverts the design — coloured letters with
/// a dark outline, instead of dark letters with a coloured halo.
///
/// Not localized: "DAILY DROP" is a brand wordmark, not UI copy.
class DailyDropWordmark extends StatelessWidget {
  /// The middle band — the per-drop variant colour. See
  /// `dailyDropWordmarkColor`.
  final Color bandColor;

  /// The letterform core and the outer rim. Figma paints `#3B0F18`, which is
  /// [AppColors.sokoInk]'s Figma token (Soko/Ink).
  final Color inkColor;

  /// When non-null the finished lockup is wrapped in a [Hero] with this tag,
  /// so it flies as a shared element between the surfaces that render it (the
  /// Discovery ready card → the drop detail header). Null → no Hero, the
  /// wordmark just renders in place. See [dailyDropWordmarkHeroTag].
  final String? heroTag;

  const DailyDropWordmark({
    super.key,
    required this.bandColor,
    this.inkColor = AppColors.sokoInk,
    this.heroTag,
  });

  static const String _text = 'DAILY DROP';

  /// Nominal authoring size. [FittedBox] rescales the finished lockup, so
  /// this only fixes the stroke-to-glyph ratios below. Figma authors at
  /// 71.635 px; the round number costs nothing and keeps the ratios honest.
  static const double _baseFontSize = 72;

  /// How far each band reaches past the glyph, as a fraction of the font
  /// size. Not guessed — measured by scanning one pixel row across a stem in
  /// the Figma render (`7204:22712`, wordmark normalised to a 400-px column)
  /// and matching the run lengths: **rim 3 px · band 8 px · core stem 5 px**
  /// at this 72-px size.
  ///
  /// Flutter centres a stroke on the path, so a stroke of width `w` reaches
  /// `w / 2` outside it — hence the doubling at the call sites. The rim's
  /// visible thickness is [_rimOutset] alone, since its stroke starts where
  /// the band's ends.
  static const double _bandOutset = 0.111; // 8 px at 72
  static const double _rimOutset = 0.042; // 3 px at 72

  @override
  Widget build(BuildContext context) {
    // SeasonMix **Regular** — `AppTheme.displayPrimary`'s own w300 default is
    // lighter than the design, and w600 (the heaviest cut bundled) is far too
    // heavy once the dilation is applied. Figma: `Season Mix TRIAL:Regular`,
    // `leading-[0.86]`, `tracking-[-2.149px]` at 71.635 px ⇒ −0.03 em.
    final TextStyle base = AppTheme.displayPrimary(
      fontSize: _baseFontSize,
      fontWeight: FontWeight.w400,
      height: 0.86,
      letterSpacing: _baseFontSize * -0.03,
    );

    // A stroke paints OUTSIDE the text's layout box, which [FittedBox] and
    // the parent both size from — without this pad the rim is clipped and
    // Flutter stripes the overflow. Pad by the widest stroke's reach.
    //
    // Vertically it needs more than that: `height: 0.86` deliberately makes
    // the line box SHORTER than the font's natural ascent + descent, so the
    // glyph ink already sits proud of it before any stroke is added. The
    // extra allowance covers that; it is empty space, so it costs only a
    // slightly taller block, not a visible gap.
    final double bleed = _baseFontSize * (_bandOutset + _rimOutset);
    final double inkOverflow = _baseFontSize * 0.02;

    final Widget lockup = FittedBox(
      fit: BoxFit.fitWidth,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: bleed,
          vertical: bleed + inkOverflow,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            // 1. Outer dark rim — widest, so every later pass sits inside it.
            _pass(
              base,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = _baseFontSize * (_bandOutset + _rimOutset) * 2
                // Round joins are load-bearing, not decoration: they are what
                // fuses the serifs into the fat silhouette Figma exports.
                ..strokeJoin = StrokeJoin.round
                ..color = inkColor,
            ),
            // 2. Coloured band — overpaints the rim's middle, leaving a rim.
            _pass(
              base,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = _baseFontSize * _bandOutset * 2
                ..strokeJoin = StrokeJoin.round
                ..color = bandColor,
            ),
            // 3. The letterform itself, back in ink.
            Text(
              _text,
              textAlign: TextAlign.center,
              style: base.copyWith(color: inkColor),
            ),
          ],
        ),
      ),
    );

    final String? tag = heroTag;
    if (tag == null) return lockup;
    // The lockup is a [FittedBox], so the Hero overlay scales it to fill the
    // interpolated flight rect — the "DAILY DROP" title grows/moves smoothly
    // from the card into the detail header. The per-surface band colour differs
    // (the default flight paints the destination's colour), which reads as the
    // title settling into the detail page's palette.
    //
    // [linearHeroRect] rather than Flutter's default `MaterialRectArcTween`:
    // this move is almost purely vertical, and the arc's separate position and
    // size curves put a visible direction change in the last stretch — the
    // wordmark appeared to snap into place just short of its landing. Set here,
    // inside the widget, so both ends of the flight get it (a rect tween
    // applied to only one end is silently ignored half the time).
    return Hero(tag: tag, createRectTween: linearHeroRect, child: lockup);
  }

  /// One stroked pass. Identical layout to the fill pass — only the paint
  /// differs — so [Stack] centring lines all three up on the same glyphs.
  Widget _pass(TextStyle base, Paint paint) => Text(
    _text,
    textAlign: TextAlign.center,
    style: base.copyWith(foreground: paint),
  );
}
