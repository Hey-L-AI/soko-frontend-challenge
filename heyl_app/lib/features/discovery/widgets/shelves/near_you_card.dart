import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/clickable.dart';
import '../../../../shared/widgets/soko_card_image.dart';
import '_artwork_tile.dart';

/// Compact 3.5-card visualisation used by the "Near you" shelf (PT-PT:
/// "Perto de ti"). 105 × 140 image + 3-line text (name, area, category).
/// Tighter than the canonical card since proximity packs more places into
/// the visible row.
///
/// Spec: `docs/ui/figma-cache/screens/discovery/shelves.md` (variant
/// "Perto de ti").
///
/// **Sizing**: at the design width (≥ [imageWidth]) the card paints at
/// exactly 105 × 140 image + ~75 px text. Below the design width (the
/// 3.5-card layout on narrow phones) the image scales proportionally;
/// the text block keeps its native font sizes. Callers must place the
/// card inside a width-bounded slot — `DiscoveryShelf` handles that when
/// given a `visibleCardsHint`.
class NearYouCard extends StatelessWidget {
  final String? imageUrl;

  /// Texture seed (entity id) + floor colour (venue blue / event green)
  /// for the fallback artwork when [imageUrl] is absent or fails.
  final String seed;
  final SokoEntityKind kind;

  final String name;

  /// Optional second-line slot rendered between [name] and [area]. Used
  /// by the Happening shelf to surface the next event-occurrence date+time
  /// (e.g. "Today, 8 PM" / "Sex, 21h"). Places shelf leaves this null and
  /// keeps the original 3-line layout.
  final String? when;

  /// Middle line — area / neighbourhood / venue name. May wrap to two lines
  /// in the source design (e.g. "Cpo. Martires da Pátria") so we cap at 2.
  final String? area;

  /// Bottom line — venue category or event category.
  final String? category;

  final VoidCallback? onTap;

  /// Image dimensions at the Figma design width.
  static const double imageWidth = 105;
  static const double imageHeight = 140;

  /// Vertical gap between artwork and the first text line. 8 px on the
  /// compact Perto de ti card (Figma `6144:3690`) — tighter than the
  /// 10 px used on Em destaque / canonical cards because the smaller
  /// 14 px name doesn't need the same breathing room.
  static const double imageToTitleGap = 8;

  /// Fixed text-block height reserving room for a 2-line name +
  /// (existing) 2-line area + 1-line category. 8 + 36 + 3.636 +
  /// 33.6 + 3.636 + 16.8 ≈ 102. The title is now 18 px @ height 1.0
  /// (matching `_image_template_card.dart`'s `titleBold` — PROD-1963).
  static const double textBlockHeight = totalHeight - imageHeight;

  /// Extra text-block height for the [when] variant — one 14 px line
  /// (`14 × 1.2 = 16.8`) plus the 3.636 px inter-line gap ≈ 20.5 px.
  static const double _whenLineDelta = 20.5;

  /// Total card height at the design width. Skeletons key off this.
  static const double totalHeight = 242;

  /// Total card height for the 4-line variant used by the Happening shelf
  /// (adds the [when] line between title and area).
  static const double totalHeightWithWhen = totalHeight + _whenLineDelta;

  /// Total height for a card rendered at [width]. Image scales with width;
  /// the text block grows with [textScale] (the OS font-scale factor, clamped
  /// app-wide to 1.3×) so scaled name/when/area/category lines don't overflow
  /// the fixed row height (PROD-2875). Defaults to 1.0 → unchanged at 1× scale.
  static double heightForWidth(double width, [double textScale = 1.0]) =>
      imageHeight * (width / imageWidth) + textBlockHeight * textScale;

  /// Scaled image height for a card rendered at [width] — the cover keeps
  /// its 105×140 aspect while the text block stays a fixed height. Skeletons
  /// / load-more loaders use this so their image placeholder matches the
  /// real cover exactly, instead of guessing a fraction of the row height.
  /// Same value as the `scaledImageHeight` computed inline in [build].
  static double imageHeightForWidth(double width) =>
      imageHeight * (width / imageWidth);

  /// Height-for-width helper for the 4-line variant (with the [when] line).
  /// The [when] line is text too, so it grows with [textScale] as well.
  static double heightForWidthWithWhen(
    double width, [
    double textScale = 1.0,
  ]) => heightForWidth(width, textScale) + _whenLineDelta * textScale;

  /// Muted category color from Figma (`#A88D92`, a desaturated rose).
  static const Color _mutedCategoryColor = Color(0xFFA88D92);

  const NearYouCard({
    super.key,
    required this.imageUrl,
    required this.seed,
    required this.kind,
    required this.name,
    this.when,
    this.area,
    this.category,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;

    return Clickable(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Honour the parent's tight width when bounded —
          // `DiscoveryShelf` wraps each cell in `SizedBox(width: …)`
          // so cards size to whatever the shelf computed. Unbounded
          // width falls back to the design dimension.
          final cardWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : imageWidth;
          final scaledImageHeight = imageHeight * (cardWidth / imageWidth);
          return SizedBox(
            width: cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ArtworkTile(
                  imageUrl: imageUrl,
                  width: cardWidth,
                  height: scaledImageHeight,
                  borderRadius: 6,
                  seed: seed,
                  kind: kind,
                ),
                const SizedBox(height: imageToTitleGap),
                // Name — mirrors the Daily Drop `titleBold` spec exactly
                // (`_image_template_card.dart`): Zalando Sans Medium 18 /
                // line-height 1.0 / letterSpacing -0.36 / Soko Ink.
                // PROD-1963 redesign visual review brought the compact
                // shelf titles up to the same anchor treatment as the
                // pre-shelf image-template sections so the hierarchy
                // reads consistently across Discovery. Up to 2 lines,
                // ellipsised on overflow.
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    height: 1.0,
                    color: inkColor,
                  ).copyWith(letterSpacing: -0.36),
                ),
                // Optional next-occurrence date+time (Happening shelf).
                // Sits between the title and the distance/area line.
                if (when != null && when!.isNotEmpty) ...[
                  const SizedBox(height: 3.636),
                  Text(
                    when!,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: AppTheme.body(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.2,
                      color: inkColor,
                    ),
                  ),
                ],
                if (area != null && area!.isNotEmpty) ...[
                  const SizedBox(height: 3.636),
                  Text(
                    area!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.2,
                      color: inkColor,
                    ),
                  ),
                ],
                if (category != null && category!.isNotEmpty) ...[
                  const SizedBox(height: 3.636),
                  Text(
                    category!,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: AppTheme.body(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.2,
                      color: _mutedCategoryColor,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
