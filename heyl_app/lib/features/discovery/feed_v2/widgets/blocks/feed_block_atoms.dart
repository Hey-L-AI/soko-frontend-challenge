// PROD-4006 — the pieces every feed block shares.
//
// Three of the five v0 blocks draw an icon-and-text meta line, and all five sit
// on the same padded surface and honour the same `blurred` flag. Keeping those
// here rather than in each widget is not only DRY: `blurred` is a **policy**
// decision (D10), and the guarantee that the client applies no guest policy of
// its own is much easier to hold when there is exactly one place that reads the
// flag than when there are five.

import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../shared/widgets/clickable.dart';
import '../../../../../shared/widgets/soko_forward_arrow.dart';

/// Key for the block with this id.
///
/// **Per occurrence, never per type** — `event_hero` appears twice in the v0
/// layout as `hero-lead` and `hero-tail`. This is simultaneously the list key,
/// the paging dedupe key and (from PROD-4003) the impression key, so anything
/// keyed on `type` silently collapses the two.
///
/// Carried over unchanged from PROD-4005's placeholder key so the dispatcher's
/// tests keep asserting on the same thing as the widgets are swapped underneath
/// them.
Key feedBlockKey(String blockId) => ValueKey('feed-block-$blockId');

/// The common surface every block is drawn on: today, the `blurred` treatment.
///
/// It owns **no margin of its own, on either axis.** `FeedPageContent` wraps
/// every sliver on the feed page, so the content column is already established
/// by the time a block builds — the `event_hero` poster is full-width within
/// that column, not bled to the viewport; Figma's 400 px hero frame IS the
/// column. And the space *between* two blocks belongs to `FeedBlockDivider`,
/// the list's separator, which puts `kFeedPageBlockGap` on each side of its
/// rule. A block that also padded itself would push that to 30 + 24 on one side
/// and 30 on the other, and the rule would sit off-centre between them
/// (PROD-3998, 2026-08-27).
///
/// **`blurred` is the backend's decision** (D10). The backend decides which
/// blocks a guest sees and which of them are gated; the client renders the
/// treatment and applies no policy of its own. There is no `isGuest` check
/// here, and there must not be one in any block widget — that would be a
/// second, divergent policy shipped in an app release.
class FeedBlockSurface extends StatelessWidget {
  final FeedBlock block;
  final Widget child;

  const FeedBlockSurface({super.key, required this.block, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!block.blurred) return child;

    // `ImageFiltered` blurs the composited subtree, so the treatment applies
    // uniformly to photos, text and controls rather than needing each block to
    // know which of its parts are sensitive. `IgnorePointer` is the load-
    // bearing half: a blurred control that still responds to taps is a gate
    // that only looks like one.
    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: child,
      ),
    );
  }
}

/// One `icon + text` meta line — "🗓 Qui 13 Ago, 9h", "📍 Casa Capitão".
///
/// **The gap is 6 on every surface.** It was a parameter because the bundle row
/// was read as 20 — its text sits at `x20` in `7304:23671` — but the icon in
/// front of it is 14 wide starting at `x0`, so 20 is the text's *offset*, not
/// the gap. The frame's own auto-layout says `gap-[6px]`, same as the hero
/// (PROD-3998, 2026-08-27). Kept as a parameter for a surface that genuinely
/// differs; nothing overrides it today.
class FeedMetaLine extends StatelessWidget {
  /// The glyph in front of the text — **and the fallback when [leading] is
  /// null**, which is why it stays required even on lines that usually draw
  /// something richer.
  final IconData icon;

  /// Drawn in the icon's place when non-null — a curator's [PersonDot], say.
  ///
  /// It must occupy the icon's footprint ([iconSize]) so the text keeps landing
  /// at the same offset on every line of the same block; `PersonDot`'s default
  /// diameter is 14, which is exactly that.
  final Widget? leading;

  final String text;
  final Color color;
  final double gap;
  final bool expand;

  const FeedMetaLine({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
    this.leading,
    this.gap = 6,
    this.expand = true,
  });

  static const double iconSize = 14;
  static const double fontSize = 14;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTheme.body(
        fontSize: fontSize,
        fontWeight: FontWeight.w300,
        color: color,
        // `Mobile/B2 Reg` is leading 1, and pinning it is load-bearing rather
        // than cosmetic: the bundle row is a FIXED 80 px box, and an unpinned
        // 14 px font renders a ~19 px line box, which overflows it by 4 px.
        height: 1,
      ),
    );

    return Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        leading ?? Icon(icon, size: iconSize, color: color),
        SizedBox(width: gap),
        // **Always `Flexible`, including under `MainAxisSize.min`.** The label
        // is the only child that can give ground, so without this the row has
        // nothing to shrink and `TextOverflow.ellipsis` never gets a chance:
        // the text lays out at its full intrinsic width and the row overflows
        // its parent instead. That shipped, and showed up on the live feed as
        // "RIGHT OVERFLOWED BY 89 PIXELS" on bundle rows with a long category.
        //
        // `Flexible`, never `Expanded`: `Flexible` is loose, so under
        // `MainAxisSize.min` the row still hugs a short label. `Expanded` is
        // tight — it would force the label to fill, which turns every hugging
        // row into a full-width one and breaks the "date · category" pairing.
        //
        // The caller still has to bound this row's width (both current
        // `expand: false` sites wrap it in a `Flexible` of their own). A row
        // handed unbounded width will now assert on the flex child rather than
        // silently overflow, which is the better failure.
        Flexible(child: label),
      ],
    );
  }
}

/// The "·" that separates the hero's category and price chips.
class FeedMetaSeparator extends StatelessWidget {
  final Color color;

  const FeedMetaSeparator({super.key, required this.color});

  @override
  Widget build(BuildContext context) => Text(
    '•',
    style: AppTheme.body(
      fontSize: FeedMetaLine.fontSize,
      fontWeight: FontWeight.w300,
      color: color,
      // Same pinned line box as [FeedMetaLine]'s label, and for the same
      // reason: the frame gives this glyph a 14 px box (`7304:23674`), and
      // unpinned it renders ~19 and makes the row it sits in taller than the
      // two meta lines it separates.
      height: 1,
    ),
  );
}

/// A block's title, in the display face.
///
/// Used by `bundle` (**`Mobile/H2`** — Season Mix 32, leading 1, tracking **0**),
/// `feed_end` (`Mobile/H3` at 26, centred) and `venue_grid` (**`Mobile/H1`** —
/// 42, leading **0.9**, tracking −0.42). All are backend-localized strings —
/// render them as received.
///
/// [letterSpacing] exists because `Mobile/H2`'s tracking is 0 while
/// `AppTheme.displayPrimary` derives −2 % from the size — that is `Mobile/H1`'s
/// tracking, not every display token's. Left null it keeps the derived value.
class FeedBlockTitle extends StatelessWidget {
  final String text;
  final double fontSize;
  final TextAlign align;
  final Color color;
  final double? letterSpacing;

  /// Line height. `Mobile/H2` and `Mobile/H3` are leading 1; `Mobile/H1` — the
  /// venue grid's title — is **0.9**, so this is a token difference rather than
  /// a tweak. Defaults to 1 so the two existing callers are unchanged.
  final double height;

  /// When set, the title becomes a tap target and grows a trailing hairline
  /// chevron — the "there is more behind this" affordance (PROD-4068, D87).
  ///
  /// **The arrow is pinned to the right edge**, not carried in the title's
  /// text run (Zé, 2026-08-28). It sits in a box the same width as the
  /// `CircleIconButton` each bundle row puts at that edge, so the affordance
  /// and the save buttons below it share one vertical axis. The title takes
  /// the remaining width and ellipsizes into it.
  ///
  /// The whole row is the tap target — title, arrow, and the gap between them.
  final VoidCallback? onSeeAll;

  /// Accessible name for [onSeeAll]. The chevron is decorative, so without
  /// this the target announces the title and not what tapping it does.
  final String? seeAllSemanticLabel;

  const FeedBlockTitle({
    super.key,
    required this.text,
    // `Mobile/H2`. Both callers pass their own size (bundle 32, `feed_end` 26),
    // so this is only what a third one would inherit — it was 28, which is
    // neither token and which nothing had used since the bundle moved to 32.
    this.fontSize = 32,
    this.align = TextAlign.start,
    this.color = AppColors.sokoInk,
    this.letterSpacing,
    this.height = 1,
    this.onSeeAll,
    this.seeAllSemanticLabel,
  });

  /// Minimum gap between the title's last letter and the arrow's box.
  static const double _seeAllGap = 8;

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.displayPrimary(
      fontSize: fontSize,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );

    if (onSeeAll == null) {
      return Text(text, textAlign: align, style: style);
    }

    return Semantics(
      button: true,
      label: seeAllSemanticLabel,
      child: Clickable(
        onTap: onSeeAll,
        child: Row(
          children: [
            // `Expanded`, so a long title ellipsizes into the space left by
            // the arrow rather than pushing it off the edge.
            Expanded(
              child: Text(
                text,
                textAlign: align,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: _seeAllGap),
            SokoForwardArrow(
              color: color.withValues(alpha: SokoForwardArrow.inkAlpha),
            ),
          ],
        ),
      ),
    );
  }
}
