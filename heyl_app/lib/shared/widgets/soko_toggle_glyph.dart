import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_colors.dart';

/// A two-state SVG glyph for Soko's card-overlay toggles (like/dislike thumbs,
/// save bookmark):
///
/// - **inactive** — the [outlineAsset] stroked in [lineColor] (Soko Ink), hollow
///   interior.
/// - **active** — the [fillAsset] filled solid in [fillColor] (Soko Ink).
///
/// Both assets share a viewBox (as the `detail/thumb-up*` and `detail/bookmark*`
/// pairs do), so the glyph keeps the same footprint across states.
class SokoToggleGlyph extends StatelessWidget {
  /// The canonical asset paths, published so the handful of surfaces that
  /// cannot use this widget still resolve to the same files.
  ///
  /// Three call sites legitimately hand-roll their own rendering and are NOT
  /// bugs to be migrated: the detail row cross-fades the two states with
  /// `AnimatedOpacity` (this widget swaps instantly), the search row passes
  /// `colorFilter: null` when liked so the fill keeps its own colour, and
  /// `BtSqIco` takes an asset *path* rather than a widget. They reference these
  /// constants so swapping a glyph is still a one-file change.
  static const thumbUpOutline = 'assets/images/icons/detail/thumb-up.svg';
  static const thumbUpFill = 'assets/images/icons/detail/thumb-up-fill.svg';
  static const bookmarkChipOutline = 'assets/images/icons/detail/bookmark.svg';
  static const bookmarkChipFill =
      'assets/images/icons/detail/bookmark-filled.svg';
  static const bookmarkActionOutline =
      'assets/images/icons/detail/bookmark-line.svg';
  static const bookmarkActionFill =
      'assets/images/icons/detail/bookmark-fill.svg';

  const SokoToggleGlyph({
    super.key,
    required this.outlineAsset,
    required this.fillAsset,
    required this.active,
    required this.height,
    this.fillColor = AppColors.sokoInk,
    this.lineColor = AppColors.sokoInk,
  });

  /// The 👍 pair, used for like **and** dislike (dislike rotates it 180°, it is
  /// not a second asset). Every like/dislike surface in the app routes through
  /// here — the detail action row, chat and onboarding cards, search rows, and
  /// the Discovery feed's hero card — so swapping the glyph is a one-line change
  /// in this file rather than a grep across eight call sites.
  const SokoToggleGlyph.thumbUp({
    super.key,
    required this.active,
    required this.height,
    this.fillColor = AppColors.sokoInk,
    this.lineColor = AppColors.sokoInk,
  }) : outlineAsset = thumbUpOutline,
       fillAsset = thumbUpFill;

  /// The bookmark pair sized for a **circular chip** (~14 px): card overlays,
  /// feed rows, the detail page's round save button.
  ///
  /// Deliberately distinct from [SokoToggleGlyph.bookmarkAction] — the two pairs
  /// are drawn on different viewBoxes for their different sizes, and swapping
  /// one for the other changes the stroke weight at render size.
  const SokoToggleGlyph.bookmarkChip({
    super.key,
    required this.active,
    this.height = 14,
    this.fillColor = AppColors.sokoInk,
    this.lineColor = AppColors.sokoInk,
  }) : outlineAsset = bookmarkChipOutline,
       fillAsset = bookmarkChipFill;

  /// The bookmark pair sized for the **labelled detail action** (~24 px).
  const SokoToggleGlyph.bookmarkAction({
    super.key,
    required this.active,
    this.height = 24,
    this.fillColor = AppColors.sokoInk,
    this.lineColor = AppColors.sokoInk,
  }) : outlineAsset = bookmarkActionOutline,
       fillAsset = bookmarkActionFill;

  /// Stroke-only ("line") glyph, e.g. `detail/thumb-up.svg`.
  final String outlineAsset;

  /// Filled glyph on the same viewBox, e.g. `detail/thumb-up-fill.svg`.
  final String fillAsset;

  final bool active;

  /// On-screen height; width follows the shared viewBox aspect.
  final double height;

  final Color fillColor;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      active ? fillAsset : outlineAsset,
      height: height,
      colorFilter: ColorFilter.mode(
        active ? fillColor : lineColor,
        BlendMode.srcIn,
      ),
    );
  }
}
