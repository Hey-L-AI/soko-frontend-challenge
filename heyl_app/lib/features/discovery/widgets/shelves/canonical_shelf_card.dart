import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/clickable.dart';
import '../../../../shared/widgets/expert_badge.dart';
import '../../../../shared/widgets/person_dot.dart';
import '../../../../shared/widgets/soko_card_image.dart';
import '../../../lists/utils/zine_cover_recipe.dart';
import '../../../lists/widgets/system_list_badge.dart';
import '../../../lists/widgets/zine/list_zine_cover.dart';
import '../../../lists/widgets/zine/zine_cover_peel_overlay.dart';
import '_artwork_tile.dart';

/// Canonical 2.5-card visualisation used by the Yours, Editor Picks, and
/// Recommended shelves. 160.418 by 213 image + a 3-line text stack (name,
/// optional subtitle, attribution).
///
/// Spec: `docs/ui/figma-cache/screens/discovery/shelves.md`. Per the
/// fork-on-doubt rule documented there, individual shelves still own their
/// own shelf widget — they just compose this chrome rather than each
/// re-declaring an identical card layout. When per-shelf divergence lands
/// (e.g. an Editor Picks badge, a Verificados check), each shelf forks the
/// card into its own file and stops calling this helper.
///
/// **Sizing**: at the design width (≥ [imageWidth]) the card paints at
/// exactly 160.418 × 213 image + 62 px text. Below the design width
/// (e.g. 2.5-card layout on narrow phones) the image scales
/// proportionally; the text block keeps its native font sizes. Callers
/// must place the card inside a width-bounded slot
/// (`SizedBox(width: …)`) — `DiscoveryShelf` handles that when given a
/// `visibleCardsHint`.
class CanonicalShelfCard extends StatelessWidget {
  /// PROD-1908 — recipe-driven cover for list cards. Solid colour +
  /// texture for background_color mode, or the photo when the recipe
  /// carries a `photoUrl` (uploaded / legacy item-image URL). Title +
  /// logo are suppressed since the shelf card surface shows them
  /// separately. Mutually exclusive with [imageUrl] — list callers
  /// pass `coverRecipe`, non-list callers (Spaces shelf rendering
  /// venues) pass `imageUrl`.
  final ZineCoverRecipe? coverRecipe;

  /// Raw image URL for non-list shelf cards (e.g. Spaces shelf venues).
  /// Mutually exclusive with [coverRecipe].
  final String? imageUrl;

  /// Texture seed + floor colour for the non-list ([imageUrl]) branch —
  /// pass the entity id and its kind. Ignored when [coverRecipe] drives a
  /// list cover.
  final String? seed;
  final SokoEntityKind kind;

  final String name;

  /// Middle line — list category, description, or null to drop the line
  /// (the "Mais seguidas" 2-line variant is rendered by a different card).
  final String? subtitle;

  /// Bottom line at 30% Ink opacity (e.g. `Edt. por ti`, `Edt. {curator}`).
  final String attribution;

  /// When true, render a compact Expert badge after [attribution] (backend
  /// `owner.is_expert`, PROD-3336). Only the callers that pass a list owner
  /// (e.g. the Trending shelf) set this; other shelves leave it false.
  final bool ownerIsExpert;

  /// Curator avatar rendered before the attribution line (14 px round),
  /// mirroring the list-page header's curator cluster. When null/empty the
  /// card falls back to an initial-letter dot in the curator's seeded colour
  /// (see [attributionAvatarName] / [attributionAvatarSeed]); with neither,
  /// the attribution renders text-only.
  final String? attributionAvatarUrl;

  /// Curator display name — drives the initial in the no-photo fallback dot.
  final String? attributionAvatarName;

  /// Stable per-person seed (owner user id) for the fallback dot's colour,
  /// matching the tint the same person gets on every avatar surface.
  final String? attributionAvatarSeed;

  final VoidCallback? onTap;

  /// When true, overlay a "Auto" pill on the artwork (top-left) to signal
  /// that this list is system-managed. PROD-1741 / PROD-1953. Set by the
  /// Yours shelf for any list with a non-null `system_kind`. Pair with
  /// [systemKind] so the badge can pick the right leading icon.
  final bool isSystemList;

  /// Backend `system_kind` for this list, forwarded to [SystemListBadge]
  /// to drive the per-kind icon (IG glyph / bookmark / book / cog).
  /// Null when [isSystemList] is false.
  final String? systemKind;

  /// 0-based position of this card within its shelf row. Used by the
  /// tease-peel gate to guarantee that the first OR second card in any
  /// shelf renders the corner-peel hint (so users see the affordance
  /// without scrolling) and to fall back to the ~25% probability gate
  /// for slots beyond that. Null disables the index-aware gate and
  /// reverts to pure-hash gating — used by call sites that don't know
  /// or care about position (e.g. detail-screen "appears-in" rows
  /// where there's no first-impression value).
  final int? indexInShelf;

  /// Card image dimensions at the Figma design width.
  static const double imageWidth = 160.418;
  static const double imageHeight = 213;

  /// Vertical gap between artwork and the first text line. Figma
  /// `6144:5149` (matches Em destaque) — was 2 px in earlier cuts.
  static const double imageToTitleGap = 10;

  /// Fixed text-block height reserving room for a 2-line name + 2-line
  /// subtitle + 1-line attribution: 10 (gap) + 36 (name 2 × 18 px lh
  /// 1.0) + 2 + ~34 (subtitle 2 × 14 × 1.2) + 2 + ~17 (attribution)
  /// ≈ 101.
  static const double textBlockHeight = totalHeight - imageHeight;

  /// Total card height at the design width. Skeletons key off this.
  static const double totalHeight = 314;

  /// Vertical chrome reserved by the 2-line subtitle slot in the card's
  /// text block: 2 px leading gap + ~34 px for two lines of 14 px text at
  /// `height: 1.2`. Pulled out so shelves whose data does not render a
  /// subtitle can shrink the row height by this amount (PROD-1961) and
  /// avoid the empty bottom-of-cell gap that otherwise sits between the
  /// attribution and the next shelf's dotted divider.
  static const double subtitleSlotHeight = 36;

  /// Total card height when the card renders **without** a subtitle line.
  /// Used by shelves whose card data has empty/null descriptions so the
  /// row shrinks to its actual content height.
  static const double totalHeightNoSubtitle = totalHeight - subtitleSlotHeight;

  /// Total height for a card rendered at [width]. The image scales with width;
  /// the text block grows with [textScale] (the OS font-scale factor, clamped
  /// app-wide to 1.3×) so the scaled name/subtitle/attribution don't overflow
  /// the fixed row height (PROD-2875). Defaults to 1.0 → unchanged at 1× scale.
  static double heightForWidth(double width, [double textScale = 1.0]) =>
      imageHeight * (width / imageWidth) + textBlockHeight * textScale;

  /// Scaled image height for a card rendered at [width] — the cover keeps
  /// its 160.418×213 aspect while the text block stays a fixed height.
  /// Skeletons / load-more loaders use this so their image placeholder
  /// matches the real cover exactly, instead of guessing a fraction of the
  /// (text-inflated) row height. Same value as the `scaledImageHeight`
  /// computed inline in [build].
  static double imageHeightForWidth(double width) =>
      imageHeight * (width / imageWidth);

  /// [heightForWidth] variant for cards rendered without a subtitle line.
  static double heightForWidthNoSubtitle(
    double width, [
    double textScale = 1.0,
  ]) =>
      imageHeight * (width / imageWidth) +
      (textBlockHeight - subtitleSlotHeight) * textScale;

  const CanonicalShelfCard({
    super.key,
    this.coverRecipe,
    this.imageUrl,
    this.seed,
    this.kind = SokoEntityKind.neutral,
    required this.name,
    required this.attribution,
    this.ownerIsExpert = false,
    this.attributionAvatarUrl,
    this.attributionAvatarName,
    this.attributionAvatarSeed,
    this.subtitle,
    this.onTap,
    this.isSystemList = false,
    this.systemKind,
    this.indexInShelf,
  }) : assert(
         (coverRecipe == null) != (imageUrl == null) ||
             (coverRecipe == null && imageUrl == null),
         'Provide either coverRecipe (lists) or imageUrl (non-lists), not both',
       );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final attributionColor = inkColor.withValues(alpha: 0.3);

    return Clickable(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Honour the parent's tight width when bounded — `DiscoveryShelf`
          // wraps each cell in `SizedBox(width: …)` so the cards size
          // themselves to whatever the shelf computed (with or without
          // a `visibleCardsHint`). Unbounded width falls back to the
          // design dimension.
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
                Stack(
                  children: [
                    if (coverRecipe != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(
                          width: cardWidth,
                          height: scaledImageHeight,
                          child: ListZineCover(
                            recipe: coverRecipe!,
                            title: name,
                          ),
                        ),
                      )
                    else
                      ArtworkTile(
                        imageUrl: imageUrl,
                        width: cardWidth,
                        height: scaledImageHeight,
                        seed: seed ?? '',
                        kind: kind,
                      ),
                    // Corner-peel hint. Renders nothing for non-list
                    // cards or when the cover is still loading; otherwise
                    // gates on the index-aware probability rule. Clipped
                    // to the cover's rounded radius so it stays inside
                    // the card surface.
                    Positioned.fill(
                      child: ZineCoverPeelOverlay(
                        coverRecipe: coverRecipe,
                        name: name,
                        indexInShelf: indexInShelf,
                        alwaysPeel: true,
                        clipRadius: BorderRadius.circular(5),
                      ),
                    ),
                    if (isSystemList)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: SystemListBadge(
                          label: Lt.of(context).systemListBadgeAuto,
                          tooltip: Lt.of(context).systemListBadgeTooltip,
                          systemKind: systemKind,
                          onImage: true,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: imageToTitleGap),
                // Name — Zalando Sans Medium 18 / lh 1.0 / tracking
                // -0.36 (-2%). Up to 2 lines, ellipsised on overflow.
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    height: 1.0,
                    color: inkColor,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(
                      fontSize: 14,
                      fontWeight: FontWeight.w300,
                      height: 1.2,
                      color: inkColor,
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if ((attributionAvatarUrl?.isNotEmpty ?? false) ||
                        (attributionAvatarName?.isNotEmpty ?? false)) ...[
                      PersonDot(
                        url: attributionAvatarUrl,
                        name: attributionAvatarName,
                        seed: attributionAvatarSeed,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        attribution,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                        style: AppTheme.body(
                          fontSize: 14,
                          fontWeight: FontWeight.w300,
                          height: 1.2,
                          color: attributionColor,
                        ),
                      ),
                    ),
                    if (ownerIsExpert) ...[
                      const SizedBox(width: 4),
                      const ExpertBadge(compact: true),
                    ],
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
