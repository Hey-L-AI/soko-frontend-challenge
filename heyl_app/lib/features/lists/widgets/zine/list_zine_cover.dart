import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../shared/widgets/cached_image.dart';
import '../../utils/zine_cover_recipe.dart';

/// Client-side renderer for a list "zine cover". Lays out a deterministic
/// composition from a [ZineCoverRecipe] — no network calls, no list
/// model dependency. The widget is sized by its parent (use it inside a
/// container with bounded width and height).
///
/// Z-stack (bottom → top, matches the Figma layer order for
/// node 3621-2409):
///   1. Background — solid `recipe.color` OR [CachedImage] when
///      `recipe.hasPhoto` (with the solid colour as a fallback when
///      the photo errors).
///   2. Colour stripe — full-width bottom band in `recipe.color`,
///      rendered only in photo mode so the title is readable.
///   3. Title — `AutoSizeText`, uppercase, [SeasonMix] weight 300,
///      tinted to `recipe.textColor`. Up to 4 lines, auto-fits between
///      [_titleMaxFontSize] and the supplied [titleMinFontSize], then
///      ellipsises.
///   4. Soko logo — top-center, tinted to `recipe.textColor`.
///   5. Texture — full-bleed overlay, on top of everything (gives the
///      screen-printed zine feel).
///
/// See `docs/features/PROD-1908-zine-cover-renderer.md` for the design
/// decisions behind the layout proportions and the texture choice.
class ListZineCover extends StatelessWidget {
  /// Resolved recipe — produced by [ZineCoverRecipe.fromFields] or
  /// constructed directly in tests.
  final ZineCoverRecipe recipe;

  /// List title. Rendered uppercase. Empty string is allowed and
  /// renders an empty title block.
  final String title;

  /// When `false`, the title and (in photo mode) the bottom colour
  /// stripe are skipped. List-card thumbnails set this so the card's
  /// own title label below the image isn't redundant — the colour
  /// stripe also disappears since it exists only to host the title.
  final bool showTitle;

  /// When `false`, the Soko logo glyph is skipped. Thumbnail surfaces
  /// pass false because a Soko logo on every list card reads as noisy.
  /// The full-screen zine cover keeps the default `true`.
  final bool showLogo;

  const ListZineCover({
    super.key,
    required this.recipe,
    required this.title,
    this.showTitle = true,
    this.showLogo = true,
  });

  // ───────── layout proportions (eyeballed against Figma 3621-2409;
  // tweak in implementation if a designer flags them) ─────────

  /// Title-stripe height as a fraction of cover height (photo mode only).
  static const double _stripeHeightFrac = 0.20;

  /// Logo size as a fraction of cover width.
  static const double _logoWidthFrac = 0.10;

  /// Logo top padding as a fraction of cover height.
  static const double _logoTopFrac = 0.08;

  /// Title horizontal padding as a fraction of cover width.
  static const double _titleHPadFrac = 0.08;

  /// Title bottom padding (in solid mode) as a fraction of cover height.
  /// Photo mode centers the title in the colour stripe instead.
  static const double _titleBottomFrac = 0.08;

  /// Title starting font size as a fraction of cover **width** (CSS
  /// `vw` analogue). Scaling by width means the title looks
  /// proportionally identical at every surface — hero zine, shelf
  /// card, list-hub thumbnail — regardless of aspect ratio. On a
  /// 350-wide hero this gives ~52 px (close to the previous absolute
  /// 54 px); on a 160-wide shelf card it gives ~24 px.
  static const double _titleMaxFontSizeFrac = 0.15;

  /// Title minimum font size as a fraction of cover width. The
  /// AutoSizeText auto-fit algorithm shrinks within `[min, max]` for
  /// long titles, then ellipsises when even `min` doesn't fit. Keeping
  /// this proportional means a long title shrinks by the *same visual
  /// amount* on every surface — the user's complaint about size
  /// inconsistency across Discovery vs. zine mode goes away.
  ///
  /// PROD-1805: dropped from 0.10 → 0.06 so a 72-char title (the
  /// frontend cap) fits in 4 lines without ellipsising — both in
  /// solid mode (width is the binding constraint at ~25 px on a
  /// 350-wide hero) and in photo mode (the 20%-of-height stripe is
  /// the binding constraint at ~21 px on a 350×450 hero). Pairs with
  /// the bump from `maxLines: 2` → `4`.
  static const double _titleMinFontSizeFrac = 0.06;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        final Color bg = recipe.color.flutterColor;
        final Color textColor = recipe.textColor.flutterColor;
        final bool hasPhoto = recipe.hasPhoto;
        final double stripeH = h * _stripeHeightFrac;

        // PROD-2300 gate: each chrome element ANDs the widget arg
        // (call-site intent: e.g. cards suppress title because the card
        // already shows the name below) with the per-list curator
        // `recipe.show*` flag (PROD-2297). Either gate hiding wins.
        // `from_profiling` lists have `recipe.show*=false` from the BE
        // backfill, so the legacy `plain` kill-switch (retired in
        // PROD-2300) is no longer needed.
        final bool effectiveShowTitle = showTitle && recipe.showTitle;
        final bool effectiveShowLogo = showLogo && recipe.showLogo;
        final bool effectiveShowTexture = recipe.showTexture;

        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 1. Background — solid colour, with a photo overlaid in
              //    photo modes. The solid colour sits underneath so a
              //    photo load failure (CachedImage errorBuilder) still
              //    shows a coherent cover.
              Container(color: bg),
              if (hasPhoto)
                Positioned.fill(
                  child: CachedImage(
                    imageUrl: recipe.photoUrl!,
                    fit: BoxFit.cover,
                    // This cover is a Hero-flight destination (Library thumb →
                    // cover). Paint the warmed bytes instantly so the flown
                    // poster lands seamlessly instead of re-fading.
                    instant: true,
                    // Suppress the default broken-image fallback so the
                    // solid colour underneath is the photo's failure UI.
                    errorWidget: const SizedBox.expand(),
                  ),
                ),

              // 2. Bottom colour stripe — photo mode only AND only when
              //    a title will be drawn (stripe exists to host the
              //    title). Sized so the title sits inside it.
              if (hasPhoto && effectiveShowTitle)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: stripeH,
                  child: Container(color: bg),
                ),

              // 3. Title — in solid mode anchored to the bottom of the
              //    cover with its own bottom padding; in photo mode
              //    sized to the stripe so it auto-fits inside.
              if (effectiveShowTitle)
                Positioned(
                  left: w * _titleHPadFrac,
                  right: w * _titleHPadFrac,
                  bottom: hasPhoto ? 0 : h * _titleBottomFrac,
                  height: hasPhoto ? stripeH : null,
                  child: () {
                    // Width-proportional font range — same visual scale
                    // across all cover sizes / aspect ratios.
                    // AutoSizeText asserts that
                    //   `min/step % 1 == 0` AND `max/step % 1 == 0`
                    // (see auto_size_text-3.0.0/lib/src/auto_size_text.dart),
                    // so we MUST round to whole pixels — fractional sizes
                    // crash the widget and render a red Flutter error
                    // widget on top of the cover. The lower clamps keep
                    // values >= 1 (the package also asserts maxFontSize
                    // > 0); negligible in practice since covers are
                    // never narrower than ~80 px.
                    final maxFs = (w * _titleMaxFontSizeFrac)
                        .floorToDouble()
                        .clamp(2.0, 200.0);
                    final minFs = (w * _titleMinFontSizeFrac)
                        .floorToDouble()
                        .clamp(1.0, maxFs);
                    return _TitleText(
                      text: title,
                      color: textColor,
                      maxFontSize: maxFs,
                      minFontSize: minFs,
                    );
                  }(),
                ),

              // 4. Soko logo — top-center, tinted to text colour.
              if (effectiveShowLogo)
                Positioned(
                  top: h * _logoTopFrac,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: SvgPicture.asset(
                      'assets/images/logos/soko-icon-paper.svg',
                      width: w * _logoWidthFrac,
                      colorFilter: ColorFilter.mode(textColor, BlendMode.srcIn),
                    ),
                  ),
                ),

              // 5. Texture — full-bleed, on top of everything (matches
              //    Figma layer order; gives the printed-zine feel).
              //    IgnorePointer so the texture doesn't absorb taps if
              //    a parent wires hit zones underneath. Skipped when
              //    the curator has set `cover_show_texture=false`
              //    (PROD-2297) — e.g. on `from_profiling` lists whose
              //    curated photo cover should render clean.
              if (effectiveShowTexture)
                IgnorePointer(
                  child: Image.asset(
                    recipe.textureAssetPath,
                    fit: BoxFit.cover,
                    width: w,
                    height: h,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TitleText extends StatelessWidget {
  final String text;
  final Color color;
  final double maxFontSize;
  final double minFontSize;

  const _TitleText({
    required this.text,
    required this.color,
    required this.maxFontSize,
    required this.minFontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AutoSizeText(
        text.toUpperCase(),
        // PROD-1805: up to 4 lines (was 2) so a worst-case 72-char
        // title — the frontend input cap — can render without
        // ellipsising. AutoSizeText still tries the largest font
        // first and only adds lines when text doesn't fit, so short
        // titles stay 1 line at max size; only the longest titles
        // actually reach 4 lines (and at a noticeably bigger font
        // size than the previous 2-line config compressed them to).
        maxLines: 4,
        minFontSize: minFontSize,
        stepGranularity: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'SeasonMix',
          fontWeight: FontWeight.w400,
          fontSize: maxFontSize,
          color: color,
          height: 1.05,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
}
