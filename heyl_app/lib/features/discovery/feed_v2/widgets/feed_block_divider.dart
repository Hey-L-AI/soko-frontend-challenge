// PROD-4005 — the dotted rule between two feed blocks (Figma `7304-23540`).
//
// **Between blocks, never inside one.** One block is one element of the page
// however many cards it draws — the `event_hero` block that carries two items
// is one thing that happens to be two-tall, and a rule through the middle of it
// would claim otherwise. So this is the list's *separator* and nothing else
// places it (Zé, 2026-08-27). The Figma comp draws the rule at only some block
// boundaries; that inconsistency is an artefact of a mockup that mixes blocks
// from several pages, and the rule the page implements is "every boundary".
//
// **Width is the content column, not the viewport.** The frame draws the line
// x0 → x400 inside the 400 px content frame, i.e. exactly as wide as the blocks
// it separates. `FeedPageContent` supplies that column, so this widget takes
// whatever width it is given and must be placed inside one — it must never be
// full-bleed, which would run it under the 15 px page margin.

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../data/models/feed_home.dart';
import '../../../../shared/widgets/soko_dotted_rule.dart';
import 'blocks/feed_people_grid_block.dart';
import 'feed_page_content.dart';

/// Dot geometry, measured off the Figma render rather than taken from the node:
/// the rule's ink sums to exactly `Soko/Shade4` #C1B2B5 at a ~3.5 px pitch of
/// 1 px dots — the same rule the legacy home draws between shelves
/// (`ShelfDivider`) and lists draw between sections (`DottedSectionDivider`).
///
/// Those two build it out of `DottedLine`, which lays one `Container` per dot —
/// ~114 widgets per rule. A feed puts a rule between *every* pair of blocks in
/// a long scrolling list, so this one uses the `CustomPaint` sibling
/// ([SokoDottedRule]) for the identical result at one render object.
const double _kDotRadius = 0.5;
const double _kDotGap = 2.5;

/// The rule plus the [kFeedPageBlockGap] of air the frame puts on each side of
/// it. Measured: every top-level element in `7304-23414` is exactly 30 px from
/// the next, and the rule is one of those elements — so a block boundary that
/// carries a rule is 30 · rule · 30, not 30 in total.
class FeedBlockDivider extends StatelessWidget {
  const FeedBlockDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: kFeedPageBlockGap),
      child: SokoDottedRule(
        color: AppColors.sokoShade4,
        dotRadius: _kDotRadius,
        gap: _kDotGap,
      ),
    );
  }
}

/// The space between two adjacent blocks: the rule, or only the gap.
///
/// **A `banner` is its own separator** (Zé, 2026-08-27). It is a full-bleed
/// coloured slab on a paper page, so it already reads as a break in the feed;
/// a dotted rule laid against its edge separates nothing and doubles the
/// division. So a boundary that touches a banner keeps the frame's 30 and drops
/// the rule — which is also what the comp draws either side of both of its
/// banners.
///
/// A **`feed_complete`** takes it further and gets no separator at all
/// (PROD-4238): the footer it draws opens with its own 120 px and no rule, and
/// anything contributed here would stack on top of that.
///
/// And **two consecutive `people_grid` blocks get neither the rule nor the 30**
/// — just the grid's own row gap, so the pair reads as one uninterrupted grid
/// (Zé, 2026-09-16, PROD-4463). The people feed delivers one grid per page, so
/// that boundary is *pagination showing through*: the reader is looking at one
/// list of 21 people and should not be able to see where it was cut. ⚠️ It is
/// not enough to drop the rule — leaving `kFeedPageBlockGap` would still put a
/// 30 px seam where the rows are 12 apart, which is the same visible boundary
/// by another means.
///
/// ⚠️ **Scoped to `people_grid` adjacency, not to grids generally.** On Sítios
/// two adjacent grids are two *sections*, with their own titles and their own
/// selection reasons, and the rule between them separates things that genuinely
/// are separate. Generalising this would silently restyle a shipped surface
/// nobody asked to change.
///
/// Every other boundary gets the rule. The decision is about the *pair*, not
/// about one block, which is why it lives in the list's separator rather than
/// in any block widget: a block cannot see its neighbours.
class FeedBlockSeparator extends StatelessWidget {
  final FeedBlock before;
  final FeedBlock after;

  const FeedBlockSeparator({
    super.key,
    required this.before,
    required this.after,
  });

  /// Whether [block] already divides the feed by being what it is.
  static bool isOwnSeparator(FeedBlock block) => block is FeedBlockBanner;

  @override
  Widget build(BuildContext context) {
    // PROD-4238 — the footer owns the air above it, so this boundary
    // contributes NOTHING.
    //
    // `DiscoveryFooter` opens with 120 px and deliberately no rule: breaking
    // the inter-block rhythm is how it reads as the page's full stop. The
    // banner branch below is the wrong hook for that — it still contributes
    // the feed's 30, which would make the gap 150 and leave the footer's
    // convention only half-honoured.
    if (after is FeedBlockFeedComplete) return const SizedBox.shrink();
    // The grid's own row gap, read off the block rather than respelled, so the
    // two can never drift apart (PROD-4463). No `FeedPageContent` — there is
    // nothing to line up with the content column.
    if (before is FeedBlockPeopleGrid && after is FeedBlockPeopleGrid) {
      return const SizedBox(height: FeedPeopleGridBlock.rowGap);
    }
    if (isOwnSeparator(before) || isOwnSeparator(after)) {
      // The gap only — no `FeedPageContent`, since there is nothing to line up
      // with the content column.
      return const SizedBox(height: kFeedPageBlockGap);
    }
    return const FeedPageContent(child: FeedBlockDivider());
  }
}

/// PROD-4081 — the SOLID hairline between the ritual cards and the filter row
/// (Figma `7598-24580`).
///
/// **Not [FeedBlockDivider], and the difference is the point.** That one is a
/// dotted `Soko/Shade4` rule separating two *content* blocks; this is a solid
/// `Soko/Ink` line separating the page's *chrome* from the content below it.
/// Sampled off the frame at full-opacity ink, 1 px, spanning the content column
/// — the page supplies the margin, as everywhere else in the feed.
///
/// Carries no gaps of its own: the 30 above it comes from the ritual slot's
/// `TrailingGap` (so it collapses with the cards) and the 30 below it from the
/// filter row's sliver. A rule that padded itself would keep its air on a page
/// that had dropped the cards.
class FeedChromeRule extends StatelessWidget {
  const FeedChromeRule({super.key});

  /// Figma: 1 px. Named so the spacing tests can assert against it rather than
  /// a literal.
  static const double thickness = 1;

  @override
  Widget build(BuildContext context) {
    // **`width: double.infinity` is load-bearing.** A `SizedBox` with only a
    // height shrink-wraps to ZERO width, and `PageContent` centres it — so the
    // rule renders as a 0 px line in the middle of the page and is invisible.
    // It shipped that way for an hour and read as "the divider is missing"; the
    // test that caught it asserts `left == kSokoPageMargin`, which a
    // zero-width rule fails at the page's centre (215 on a 430 viewport).
    return const SizedBox(
      width: double.infinity,
      height: thickness,
      child: ColoredBox(color: AppColors.sokoInk),
    );
  }
}
