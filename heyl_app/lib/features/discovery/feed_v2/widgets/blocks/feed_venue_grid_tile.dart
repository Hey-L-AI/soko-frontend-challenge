// PROD-4108 — one cell of the `venue_grid` block. Figma `7675:38682`.
//
// Cover with a save chip, the venue's name, then two icon meta lines: type and
// then neighbourhood.
//
// ⚠️ **This is NOT `NearYouCard`,** despite the ticket saying to reuse it. The
// two were measured against this frame and differ on five counts — cover 4:5
// (not the shelf card's 105×140 = 3:4), a save chip on the cover (the shelf card
// has none), the name in Light rather than Medium, icon-bearing meta lines
// rather than plain text, and both meta lines in `Soko/Ink` rather than a muted
// rose category. Reusing it would put the legacy shelf's look inside the new
// feed.
//
// What it *is* built from is the feed's own vocabulary: [FeedMetaLine] at
// identical metrics to the bundle row's, and the hero card's overlay toggle
// shape at 30 px. So a venue reads the same way on every feed surface, which is
// the reuse that actually mattered.
//
// The full frame is cached at
// `docs/ui/figma-cache/screens/discovery/feed-v2-venue-grid.md`.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../l10n/generated/l10n.dart';
import '../../../../../shared/widgets/clickable.dart';
import '../../../../../shared/widgets/soko_card_image.dart';
import '../../../../../shared/widgets/soko_overlay_toggle.dart';
import '../../../../../shared/widgets/soko_toggle_glyph.dart';
import '../../utils/feed_item_save.dart';
import '../../widgets/blocks/feed_block_atoms.dart';
import '../../../widgets/shelves/_artwork_tile.dart';

class FeedVenueGridTile extends ConsumerWidget {
  final FeedVenueItem venue;

  /// Opens the venue. Null leaves the tile inert.
  ///
  /// **The tile body only** — the save chip is a child and wins the hit test,
  /// so tapping the bookmark saves rather than navigating. Same split as the
  /// bundle row's.
  final VoidCallback? onTap;

  const FeedVenueGridTile({super.key, required this.venue, this.onTap});

  /// Cover aspect (`aspect-[40/50]` on `7675:38686`). **Width-driven** — the
  /// cell width comes from the block's column maths, and the cover's height
  /// follows from it, so the grid reflows on any viewport without a second
  /// source of truth for the tile size.
  static const double coverAspect = 40 / 50;

  /// `rounded-[6px]` on the cover.
  static const double _coverRadius = 6;

  /// Gap under the cover and under the name — both 12 on the frame.
  static const double _stackGap = 12;

  /// Gap between the two meta lines (`7675:38691`, `gap-[8px]`).
  static const double _metaGap = 8;

  /// Icon-to-text gap inside a meta line. 6 on every feed surface — see
  /// [FeedMetaLine], which defaults to it.
  static const double _metaInnerGap = 6;

  /// Save chip: 30 × 30, 10 from the cover's right and bottom edges.
  static const double _chipSize = 30;
  static const double _chipInset = 10;

  /// The chip's ground — `Soko/Ink 30` at 30 % over the photo
  /// (`rgba(121,121,121,0.3)` on the frame), behind a 4 px backdrop blur.
  /// **Constant across saved and unsaved** (D310); the glyph carries the state.
  ///
  /// Deliberately a different token from the hero card's `Soko/Paper 30`: the
  /// hero's chip sits on a large poster and the paper tint reads as a light
  /// scrim, while this one sits on a small thumbnail where the darker ground
  /// keeps the glyph legible over a bright photo.
  static const Color _chipResting = SokoOverlayToggle.frostedInk30;
  static const double _chipBlur = SokoOverlayToggle.defaultBlur;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = isFeedItemSaved(ref, venue);

    return Clickable(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cover(context, ref, saved),
          const SizedBox(height: _stackGap),
          Text(
            venue.name,
            // Two lines, not one: the frame ships "Jardim do Torel" and
            // "Leitaria do Paço" wrapped, so a single ellipsized line would
            // truncate names the design shows in full.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            // `Mobile/B1 Reg` — Zalando Sans Light 18, leading 1, tracking
            // −0.36. The same token the bundle row's title uses, via the same
            // helper, so the two cannot drift.
            style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
          ),
          const SizedBox(height: _stackGap),
          _meta(),
        ],
      ),
    );
  }

  /// Type over neighbourhood, each an icon + label.
  ///
  /// ⚠️ **Type leads**, which is the reverse of the order this tile shipped
  /// with. The bundle row split its single `neighbourhood · type` line into two
  /// on 2026-09-08 (Zé) with the type on line 1, and the tile was flipped in
  /// the same change: the two surfaces show the same two facts about the same
  /// entity, so reading them in opposite orders is the drift, not the
  /// consistency. Keep them in step.
  ///
  /// Both lines are omitted individually rather than as a pair: `neighborhood`
  /// is 92–99 % covered and `type` is 95 %+, so a venue missing one still shows
  /// the other instead of an empty block.
  Widget _meta() {
    final type = venue.type;
    final hasType = type != null && type.isNotEmpty;
    final neighborhood = venue.neighborhood;
    final hasNeighborhood = neighborhood != null && neighborhood.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasType)
          FeedMetaLine(
            icon: LucideIcons.move_right,
            // Backend-localized label for the PRIMARY type (ADR-043) — what the
            // venue *is*, not what it also contains. Render as received; it is
            // not a slug.
            text: type,
            color: AppColors.sokoInk,
            gap: _metaInnerGap,
          ),
        if (hasType && hasNeighborhood) const SizedBox(height: _metaGap),
        if (hasNeighborhood)
          FeedMetaLine(
            icon: LucideIcons.map_pin,
            text: neighborhood,
            color: AppColors.sokoInk,
            gap: _metaInnerGap,
          ),
      ],
    );
  }

  Widget _cover(BuildContext context, WidgetRef ref, bool saved) {
    // `LayoutBuilder`, not `AspectRatio` alone: `ArtworkTile` wants concrete
    // dimensions (it hands them to `SokoCardImage`, which sizes the textured
    // fallback from them), and `double.infinity` would reach the fallback
    // painter as an unbounded box. The cell width comes from the block's column
    // maths, so reading it here keeps the tile's own size derived rather than
    // duplicated.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = width / coverAspect;
        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // `ArtworkTile` rather than a bare `CachedImage`: it already owns
              // the deterministic textured fallback for a venue with no photo,
              // keyed off the entity id — the same floor the shelf card and the
              // map cards paint. A plain image would leave a grey box.
              ArtworkTile(
                imageUrl: venue.imageUrl,
                width: width,
                height: height,
                borderRadius: _coverRadius,
                seed: venue.id,
                kind: SokoEntityKind.venue,
              ),
              Positioned(
                right: _chipInset,
                bottom: _chipInset,
                child: _saveChip(context, ref, saved),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The bookmark, on the cover — the shared card-overlay toggle (D310).
  ///
  /// It used to flip the circle to opaque `Soko/Paper` with an ink bookmark
  /// when saved. That is the pre-D310 treatment the hero card was moved off,
  /// and this tile was simply missed: the ground is held constant now and the
  /// glyph carries the state on its own.
  Widget _saveChip(BuildContext context, WidgetRef ref, bool saved) {
    return SokoOverlayToggle(
      selected: saved,
      size: _chipSize,
      ground: _chipResting,
      blurSigma: _chipBlur,
      semanticLabel: Lt.of(context).feedHeroSaveA11y,
      onTap: () => openFeedItemSave(context, ref, venue),
      glyph: (active, color) => SokoToggleGlyph.bookmarkChip(
        active: active,
        fillColor: color,
        lineColor: color,
      ),
    );
  }
}
