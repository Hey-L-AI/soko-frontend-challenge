import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../data/models/recurrence_phase.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/clickable.dart';
import '../../../../shared/widgets/recurrence_phase_chip.dart';
import '../../../../shared/widgets/soko_tag.dart';
import '../../../lists/utils/zine_cover_recipe.dart';
import '../../../lists/widgets/zine/list_zine_cover.dart';
import '../../../lists/widgets/zine/zine_cover_peel_overlay.dart';
import '../../../../shared/widgets/soko_zine_corner_fold.dart';
import '../../../../shared/widgets/person_dot.dart';
import '_artwork_tile.dart';

/// Em destaque card — forked from [CanonicalShelfCard] for the larger
/// 195 × 242 image specced in Figma `d4BCnyUHe2705J7ecQtaIH` node
/// `6144:5096`. Text-block typography matches the canonical (Zalando Sans
/// Medium 18 / Light 14 name + subtitle + Light 14 attribution at 30% Ink).
///
/// **Sizing**: at the design width (≥ [imageWidth]) the card paints at
/// exactly 195 × 242 image + 62 px text. On narrower viewports (e.g.
/// iPhone SE, where two cards plus the 10 px gap don't fit inside the
/// 32 px content padding) the card scales the image down proportionally
/// so two-card rows no longer overflow. Callers must place the card
/// inside a width-bounded slot (`Expanded`/`Flexible`/`SizedBox`); inside
/// an unbounded slot the card stays at the design width.
class HighlightedShelfCard extends StatelessWidget {
  /// PROD-1908 — recipe-driven cover for list cards. Mutually exclusive
  /// with [imageUrl]; the search-results row reuses this card for
  /// events/venues which pass a raw URL instead.
  final ZineCoverRecipe? coverRecipe;

  /// Raw image URL for non-list callers (search results showing events
  /// or venues). Mutually exclusive with [coverRecipe].
  final String? imageUrl;

  final String name;
  final String? subtitle;
  final String attribution;

  /// Curator "bolinha" before the attribution line — photo when set, else an
  /// initial dot in the person's seeded colour ([attributionAvatarName] /
  /// [attributionAvatarSeed]); nothing when neither is provided.
  final String? attributionAvatarUrl;
  final String? attributionAvatarName;
  final String? attributionAvatarSeed;
  final VoidCallback? onTap;

  /// 0-based position of this card within its row/grid — drives the
  /// [ZineCoverPeelOverlay] gate so the first or second card in a
  /// search-result grid always gets the peel hint. Null = no
  /// first-impression guarantee (falls back to the ~25% probability
  /// gate by name hash).
  ///
  /// Ignored when [cornerFoldColor] is set: the static fold is on every card,
  /// so there is no "which card gets the hint" question to answer.
  final int? indexInShelf;

  /// PROD-4118 — when set (and [coverRecipe] is non-null), the cover gets the
  /// **static** turned corner ([SokoZineCornerFold]) in this colour instead of
  /// the animated peel, and this is the colour of the page showing underneath.
  ///
  /// Opt-in rather than the default because the two treatments answer different
  /// questions. On the new home feed the fold is **part of the cover** — every
  /// zine has one, and it is what makes a zine read as a zine beside an event
  /// and a venue in one scroll. On search results and the shelves the peel is a
  /// **hint** that this card opens into a page-turn, deliberately intermittent.
  /// Flipping the default would silently restyle every one of those surfaces.
  final Color? cornerFoldColor;

  /// PROD-3124 — when set (`'event'` / anything else = venue), a type tag
  /// pill ("Evento" / "Sítio", same accents as the chat cards' [CardTagRow])
  /// renders inset in the image's top-right corner. Null (every caller except
  /// the Map results grid today) → no tag.
  final String? itemType;

  /// PROD-3379 — when set, a recurrence-phase chip ("Primeiros dias" / "Últimos dias")
  /// renders in the image's top-right badge stack, **below** the [itemType]
  /// pill (right-aligned Column), so a wide chip drops to its own line instead
  /// of colliding with the type pill. Event cards only in practice — venues
  /// never carry a phase. Null (every caller except the Map results
  /// carousel/grid today) → no chip.
  final RecurrencePhase? recurrencePhase;

  /// Card image dimensions at the Figma design width (`6144:5096`).
  /// Cards may render smaller if their parent constrains them below this.
  static const double imageWidth = 195;
  static const double imageHeight = 242;

  /// Vertical gap between the artwork and the first text line. Figma
  /// `6144:5149` specs 10 px (was 2 px in earlier cuts).
  static const double imageToTitleGap = 10;

  /// Card aspect ratio (image + 3-line text block) at the design width.
  /// Used by skeleton placeholders so a loading row reserves the same
  /// real estate as a hydrated row.
  static const double aspectRatio = imageWidth / totalHeight;

  /// Total card height at the design width: image + 10 px gap + name
  /// (up to 2 lines) + subtitle (up to 2 lines) + attribution.
  /// Skeletons key off this; rendered cards use the value scaled to
  /// the constrained width.
  ///
  /// Math: 242 (image) + 10 (gap) + 36 (name 2 × 18 px @ lh 1.0) + 2
  /// + ~34 (subtitle 2 × 14 × 1.2) + 2 + ~17 (attribution) ≈ 343.
  static const double totalHeight = 343;

  /// The subtitle's slot inside the text block: a 2 px gap + up to 2 lines at
  /// 14 px / 1.2 line-height. [build] omits both when [subtitle] is null or
  /// empty, so a caller that never supplies one reserves this for nothing.
  static const double subtitleBlockHeight = 2 + 2 * 14 * 1.2;

  /// Total height for a card rendered at [width]. The image scales with
  /// width, the text block (gap + name + subtitle + attribution) stays fixed.
  ///
  /// Pass `hasSubtitle: false` when the caller never supplies a [subtitle] —
  /// the card then doesn't build one, and reserving [subtitleBlockHeight] for
  /// it is ~36 px of dead space under every card. (The Map page's results grid
  /// is the one such caller, and it's the one place the waste is *visible*: its
  /// drawer snaps to exactly one card row, so the slack lands as a gap between
  /// the cards and the filter buttons rather than as scroll padding.)
  static double heightForWidth(double width, {bool hasSubtitle = true}) =>
      imageHeight * (width / imageWidth) +
      (totalHeight - imageHeight) -
      (hasSubtitle ? 0 : subtitleBlockHeight);

  const HighlightedShelfCard({
    super.key,
    this.coverRecipe,
    this.imageUrl,
    required this.name,
    required this.attribution,
    this.attributionAvatarUrl,
    this.attributionAvatarName,
    this.attributionAvatarSeed,
    this.subtitle,
    this.onTap,
    this.indexInShelf,
    this.cornerFoldColor,
    this.itemType,
    this.recurrencePhase,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final attributionColor = inkColor.withValues(alpha: 0.3);
    final hasAttributionAvatar =
        (attributionAvatarUrl?.isNotEmpty ?? false) ||
        (attributionAvatarName?.isNotEmpty ?? false);
    final showAttribution = attribution.isNotEmpty || hasAttributionAvatar;

    return Clickable(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Honour the parent's tight width when bounded (the shelf
          // scaffold always wraps cells in `SizedBox(width: …)`). Fall
          // back to the design width only in the unbounded case
          // (theoretical — every current call site wraps the card).
          // The image height scales proportionally; the text block
          // keeps its native font metrics so 1-line lines stay
          // readable at every size.
          final cardWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : imageWidth;
          final scaledImageHeight = imageHeight * (cardWidth / imageWidth);
          // The cover artwork (zine recipe or event/venue photo), optionally
          // wrapped in a shared-element `Hero` (PROD-4160-followup). Extracted
          // so the fold/peel overlays stay OUTSIDE the Hero — only the cover
          // flies.
          final Widget coverArt = coverRecipe != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox(
                    width: cardWidth,
                    height: scaledImageHeight,
                    child: ListZineCover(recipe: coverRecipe!, title: name),
                  ),
                )
              : ArtworkTile(
                  imageUrl: imageUrl,
                  width: cardWidth,
                  height: scaledImageHeight,
                );
          final Widget cover = coverArt;
          return SizedBox(
            width: cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  children: [
                    cover,
                    // The corner treatment — one of two, never both.
                    //
                    // **Static fold** when the host asked for one
                    // (`cornerFoldColor`, PROD-4118): part of the cover, on
                    // every card, never moving. **Animated peel** otherwise:
                    // an intermittent hint that the card opens into a
                    // page-turn, gated to roughly one card per band.
                    //
                    // ⚠️ Mutually exclusive on purpose. Both drawn would put a
                    // moving flap under a fixed one in the same corner; and the
                    // peel's own gate means most cards would show only the
                    // static one anyway, so the page would look inconsistent
                    // rather than richer.
                    if (coverRecipe != null && cornerFoldColor != null)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: SokoZineCornerFold(
                            pageColor: cornerFoldColor!,
                          ),
                        ),
                      )
                    else
                      // Corner-peel hint on list-cover search results.
                      // Renders nothing for event/venue cards (no
                      // coverRecipe) or until the cover photo loads.
                      Positioned.fill(
                        child: ZineCoverPeelOverlay(
                          coverRecipe: coverRecipe,
                          name: name,
                          indexInShelf: indexInShelf,
                          alwaysPeel: true,
                          clipRadius: BorderRadius.circular(5),
                        ),
                      ),
                    // Top-right badge stack (PROD-3124 type tag + PROD-3379
                    // recurrence chip). Both inset in the image's top-right
                    // corner, right-aligned in a Column so a wide recurrence
                    // chip ("Primeiros dias") drops to its own line under the
                    // type pill instead of colliding with it.
                    if (itemType != null || recurrencePhase != null)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // PROD-3124 — type tag ("Evento" / "Sítio"). Same
                            // pill as the chat cards (CardTagRow) but with the
                            // accents deliberately SWAPPED (Zé 2026-07-15):
                            // events wear the venue accent and vice versa here.
                            if (itemType != null)
                              SokoTag(
                                background: itemType == 'event'
                                    ? AppColors.sokoVenueAccent
                                    : AppColors.sokoEventAccent,
                                child: Text(
                                  itemType == 'event'
                                      ? Lt.of(context).eventDetailTagTypeEvent
                                      : Lt.of(context).venueDetailTagTypeVenue,
                                  style: SokoTag.textStyle,
                                ),
                              ),
                            // PROD-3379 — recurrence-phase chip ("Primeiros
                            // dias" / "Últimos dias") stacked under the type pill.
                            if (recurrencePhase != null) ...[
                              if (itemType != null) const SizedBox(height: 4),
                              RecurrencePhaseChip(
                                phase: recurrencePhase!,
                                compact: true,
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: imageToTitleGap),
                // Name — up to 2 lines, ellipsised on overflow (Figma
                // `6144:5149`). Wider Em destaque cards usually fit a
                // single line; smaller scaled cards on narrow phones
                // benefit from the 2-line headroom.
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
                if (showAttribution) ...[
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasAttributionAvatar) ...[
                        PersonDot(
                          url: attributionAvatarUrl,
                          name: attributionAvatarName,
                          seed: attributionAvatarSeed,
                        ),
                        const SizedBox(width: 5),
                      ],
                      if (attribution.isNotEmpty)
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
                    ],
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
