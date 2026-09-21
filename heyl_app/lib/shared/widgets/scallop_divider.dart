import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Reusable scalloped horizontal divider, tiled from a single-scallop SVG.
///
/// The widget computes how many whole tiles fit in the available width
/// (`floor(width / tileWidth)`) so no scallop is ever cropped, and
/// centres the tiled row so leftover space is split evenly on both
/// sides. Use anywhere we want a wavy section break — Discovery,
/// list-detail, profile, etc.
///
/// Defaults render the canonical Soko Ink scallop from Figma `3932:1986`
/// (`d4BCnyUHe2705J7ecQtaIH`); pass a different [tileAsset] /
/// [tileWidth] / [tileHeight] to render a different motif.
class ScallopDivider extends StatelessWidget {
  /// Path to a single-tile SVG. Defaults to the Soko-Ink scalloped tile
  /// (one scallop peak, 18.19 × 9 px).
  final String tileAsset;

  /// Native width of one tile in logical px. Must match the SVG's viewBox
  /// width, otherwise tiles overlap or leave seams.
  final double tileWidth;

  /// Native height of one tile in logical px. Must match the SVG's viewBox
  /// height; the rendered widget reserves exactly this height.
  final double tileHeight;

  /// The canonical tile's height, and the default for [tileHeight].
  ///
  /// Public so a caller that has to state its own height in advance can say
  /// *this* number rather than spell `9` and drift from it — the feed's
  /// location band does, since a pinned overlay has to know how tall it is
  /// before it is laid out.
  static const double defaultTileHeight = 9.0;

  /// Optional ColorFilter applied to every tile (e.g. for tinted variants).
  /// Null leaves the SVG's authored colour untouched.
  final ColorFilter? colorFilter;

  /// Lay tiles to the FULL box width, clipping the two end tiles, instead of
  /// fitting whole tiles and centring the leftover.
  ///
  /// The default floors to whole tiles (`floor(width / tileWidth)`), so the
  /// rule can sit up to one tile — 18 px — narrower than its box, split
  /// between the two ends. That is right for a free-standing section break,
  /// and wrong wherever the rule has to land on a page margin the text next to
  /// it also lands on: the wave reads as inset compared to everything above
  /// and below it.
  ///
  /// Set true to `ceil` instead and clip. This is how Figma draws it — the
  /// scallop in `7304-23416` is a 709 px vector clipped to a 400 px frame.
  final bool fillWidth;

  /// Flip the row vertically.
  ///
  /// **Orientation of the canonical asset, verified against the rendered
  /// SVG:** the flat edge is on the BOTTOM and each tile rises to a point
  /// at the top — spikes pointing UP. (An earlier version of this comment
  /// claimed the opposite; the path in
  /// `section_divider_tile.svg` runs `M0 7.65 → peak at y −0.34 → 18.19
  /// 7.65 → V8.52 → H0`, i.e. a tent standing on a 0.87 px baseline.)
  ///
  /// Set true to flip it: the flat edge moves to the top and the points
  /// hang down. That is the orientation Figma uses for the Discovery feed's
  /// top header (`7304-23416`), where the rule closes the header off from
  /// above.
  final bool inverted;

  const ScallopDivider({
    super.key,
    this.tileAsset = 'assets/images/icons/discovery/section_divider_tile.svg',
    this.tileWidth = 18.19,
    this.tileHeight = defaultTileHeight,
    this.colorFilter,
    this.inverted = false,
    this.fillWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: tileHeight,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Floor → whole tiles only, no cropping. Leftover space is
          // centred by the parent [Center] (not by the Row's
          // `mainAxisAlignment`). [fillWidth] ceils instead and clips, so the
          // rule ends exactly on its box.
          final exact = constraints.maxWidth / tileWidth;
          final count = (fillWidth ? exact.ceil() : exact.floor()).clamp(
            1,
            4096,
          );
          // Use `MainAxisSize.min` + a `Center` wrapper rather than
          // `MainAxisSize.max + MainAxisAlignment.center`. The latter
          // makes the Row claim `constraints.maxWidth` and centre its
          // children inside, which leaves the children's total width
          // (`count * tileWidth`) compared against the Row's allocated
          // width (`maxWidth`) — and that comparison is in IEEE-754
          // float64. When `count = floor(maxWidth / tileWidth)`,
          // `count * tileWidth` re-computed in float can land a few ULPs
          // ABOVE `maxWidth` (typical magnitude: 1e-6 px), producing
          // Flutter's "RIGHT OVERFLOWED BY 0.00000320 PIXELS" debug
          // indicator. `MainAxisSize.min` sizes the Row to its
          // children's actual painted width, so the overflow comparison
          // is the Row's width vs itself — guaranteed equal. The
          // `Center` wrapper handles horizontal centring inside the
          // unbounded outer SizedBox. PROD-2216 follow-up.
          final tiles = Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(
              count,
              (_) => SvgPicture.asset(
                tileAsset,
                width: tileWidth,
                height: tileHeight,
                colorFilter: colorFilter,
              ),
            ),
          );
          if (!fillWidth) return Center(child: tiles);
          // `OverflowBox` hands the Row unbounded width, so a ceil'd run that
          // is wider than the box is not an overflow — a bare `Center` would
          // paint the same pixels but log "RIGHT OVERFLOWED BY n PIXELS" in
          // debug. `ClipRect` then trims the two end tiles symmetrically.
          return ClipRect(
            child: OverflowBox(
              minWidth: 0,
              maxWidth: double.infinity,
              alignment: Alignment.center,
              child: tiles,
            ),
          );
        },
      ),
    );
    return inverted ? Transform.flip(flipY: true, child: row) : row;
  }
}
