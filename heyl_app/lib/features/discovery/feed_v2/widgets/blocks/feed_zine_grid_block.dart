// PROD-4118 — the `zine_grid` block. Figma `7675-38867`.
//
// A title with an OPTIONAL see-more chevron over a grid of zine covers, 2 to a
// row. One widget, three instances on the Zines page: `grid-featured` (2 items),
// `grid-editor-picks` (4) and `grid-recommended` (4).
//
// **The backend owns the item count, the client owns the column count** (D8), so
// this lays out `ceil(items.length / columns)` rows and a ragged last row is
// expected rather than a defect.
//
// ⚠️ **This is NOT the `venue_grid` empty-block exception, and porting that
// guard would be a bug.** `venue_grid` is *placed* during composition and
// *filled* per caller afterwards, so it can arrive with zero items and
// `renderableFeedBlocks` drops it. Every zine source runs inside composition, so
// an empty zine grid is omitted server-side — confirmed against staging, where a
// guest page omits `grid-featured` and `grid-editor-picks` entirely rather than
// sending them empty. A zero-item guard here would guard a state that cannot
// occur, and would read as deliberate to whoever found it.
//
// ⚠️ **The chevron is conditional here and unconditional on `venue_grid`.**
// `grid-featured` replaces the old Highlighted shelf, which ships no "ver mais"
// by design, and sends `button: null`. Rendering one anyway dead-ends the tap.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/services/unified_analytics_service.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../data/models/feed_impression.dart';
import '../../../../../providers/api_provider.dart';
import '../../../../../shared/widgets/impression_detector.dart';
import '../../../../../shared/widgets/soko_zine_corner_fold.dart';
import '../../../widgets/shelves/highlighted_shelf_card.dart';
import '../../providers/feed_home_provider.dart';
import '../../providers/feed_impression_trackers.dart';
import '../../utils/feed_action_routes.dart';
import '../../utils/feed_item_open.dart';
import '../../utils/feed_zine_cover.dart';
import 'feed_block_atoms.dart';

class FeedZineGridBlock extends ConsumerWidget {
  final FeedBlockZineGrid block;

  const FeedZineGridBlock({super.key, required this.block});

  /// Columns are the CLIENT's decision (D8) — the backend sends a count and has
  /// no idea how wide the viewport is. Two, matching the pair layout the shelf
  /// see-all pages already render zines in (`search_results_view.dart`), which
  /// is why the featured grid's 2 items make one row and the other two grids'
  /// 4 make two.
  static const int columns = 2;

  /// Horizontal gap between cards. The same 10 px `_SearchResultsRow` puts
  /// between its pair — one measurement for the same layout in two places.
  static const double columnGap = 10;

  /// Vertical gap between rows, and between the title and the first row.
  static const double rowGap = 20;

  /// Opens the grid's see-all page.
  ///
  /// ⚠️ On the feed this event carries `block_id` and **no** `shelf_id` — the
  /// xor is a correctness rule, not a preference (PROD-4077).
  void _openSeeMore(BuildContext context, WidgetRef ref, String route) {
    ref
        .read(unifiedAnalyticsProvider)
        .trackDiscoveryShelfSeeMoreClicked(blockId: block.id);
    context.push(route);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = block.title;
    final button = block.button;
    // Two independent reasons the chevron may be absent, and they compose:
    // the block sent no button at all (`grid-featured`), or it sent one whose
    // route this app version does not recognise (rule 2 — hide, never navigate
    // blind). Both land on the same `null` here.
    // `routeTarget`, not `isLive`: since PROD-4238 `isLive` is also true for a
    // `next_slate` action, which carries no route to open. This asks for the
    // destination, so "live" and "where to" cannot disagree.
    final seeAllRoute = button?.routeTarget(isAllowedFeedActionRoute);
    final live = seeAllRoute != null;

    // The run that served THIS block (PROD-4303): the wire block's own run_id
    // when the backend sends one, else the run of the page it arrived on.
    // Captured once here — card callbacks fire where `ref` may be dead.
    final runId =
        block.runId ??
        ref.read(feedHomeProvider).valueOrNull?.runIdForBlock(block.id);

    return FeedBlockSurface(
      block: block,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title.isNotEmpty) ...[
            // `Mobile/H1`, the same token the venue grid's title uses — Season
            // Mix 42, leading 0.9, tracking −0.42. The two grids are the same
            // kind of block and must not drift into different heading scales.
            FeedBlockTitle(
              text: title,
              fontSize: 42,
              height: 0.9,
              letterSpacing: -0.42,
              onSeeAll: live
                  ? () => _openSeeMore(context, ref, seeAllRoute)
                  : null,
              // The backend's own label as the accessible name: the chevron is
              // decorative, so without this the target announces the title
              // rather than what tapping it does. Backend-localized (D7), so no
              // ARB key — the copy travels with the block.
              seeAllSemanticLabel: live ? button?.label : null,
            ),
            const SizedBox(height: rowGap),
          ],
          _grid(context, ref, runId),
        ],
      ),
    );
  }

  /// The cards, in rows of [columns].
  ///
  /// A `Column` of `Row`s rather than a `GridView`, for the same reason the
  /// venue grid is: a handful of items inside an already-scrolling feed, where a
  /// nested scrollable would need `shrinkWrap` plus
  /// `NeverScrollableScrollPhysics` to behave and would build every card anyway.
  ///
  /// A short last row is padded with empty `Expanded` slots rather than left
  /// ragged, so three items give a full row plus one **left-aligned** card at
  /// the same width as its neighbours instead of one stretched across the page.
  Widget _grid(BuildContext context, WidgetRef ref, String? runId) {
    final items = block.items;
    final rowCount = (items.length + columns - 1) ~/ columns;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var row = 0; row < rowCount; row++) ...[
          if (row > 0) const SizedBox(height: rowGap),
          Row(
            // Cards top-align and keep their natural heights: the cover is a
            // fixed aspect at a fixed column width, so the only variation is the
            // text block, which a two-line name is allowed to grow.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var col = 0; col < columns; col++) ...[
                if (col > 0) const SizedBox(width: columnGap),
                Expanded(
                  child: switch (row * columns + col) {
                    final i when i < items.length => _card(
                      context,
                      ref,
                      items[i],
                      i,
                      runId,
                    ),
                    _ => const SizedBox.shrink(),
                  },
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _card(
    BuildContext context,
    WidgetRef ref,
    FeedZineItem zine,
    int index,
    String? runId,
  ) {
    // D83's both-rails treatment, brought to the home feed for the zine blocks
    // (PROD-4118). `ImpressionDetector` fires only after 70 % visible for
    // 300 ms, so a grid scrolled past at speed records nothing — which is what
    // makes it safe for this to touch the suppression rail at all.
    final tracker = ref.watch(
      feedHomeImpressionTrackerProvider((
        blockId: block.id,
        itemType: block.itemType,
        surface: FeedImpressionSurface.zineGrid,
      )),
    );
    // Read HERE, not in onResolved — that callback fires from
    // ImpressionDetector.dispose() where `ref` is dead. keepAlive singleton, so
    // the captured instance outlives the card.
    final sessionTracker = ref.read(discoverySessionTrackerProvider);
    return ImpressionDetector(
      // ⚠️ **The key belongs HERE, on the detector, not only on the tile below
      // it** (PROD-4524). Element reuse happens at the level that sits in the
      // parent's child list, and that is this widget — so keyed one level too
      // low, a rebuild that puts a DIFFERENT item in the same slot reuses
      // `_ImpressionDetectorState`: the running dwell clock, `_episodeQualified`
      // and the post-tap reopen block all carry over, and the closing
      // `exposure_end` is billed to the new occupant while the previous one's
      // is lost outright. `dispose()` also only `forget()`s the CURRENT key, so
      // the pre-swap one leaks in `VisibilityDetector`'s app-global static map.
      //
      // ⚠️ **The new occupant is NOT silent, which is what hides this.**
      // `ImpressionDetector._key` is a getter over `widget.itemId`, so the
      // inner `VisibilityDetector` element is replaced and its detach re-arms
      // the state — the row count looks right and only the attribution is
      // wrong. A regression test asserting "the new item reports nothing"
      // passes with the bug present; assert the CLOSING event instead. Full
      // argument and the measured before/after: `feed_people_grid_block.dart`.
      //
      // The tile keeps its own key where it has one — that guards the tile's
      // state if this wrapper is ever removed. This one is the load-bearing
      // half.
      //
      // Shape: the detector's own `scopeId` plus the item id. `scopeId` already
      // carries this surface's uniqueness argument (the Zines page mounts a
      // grid and a bundle at once; a bundle and its see-all page share a
      // `block_id`), so reusing it keeps the key unique for the same reasons
      // and distinct from the tile's own key below.
      key: ValueKey('${tracker.scopeId}-${zine.id}'),
      // From the tracker, never the bare block id: `VisibilityDetector` keys
      // its bookkeeping in an app-global static map, so two detectors sharing a
      // key silently suppress each other's callbacks rather than erroring. The
      // Zines page mounts a grid and a bundle at once, which is exactly that
      // hazard.
      scopeId: tracker.scopeId,
      itemId: zine.id,
      // Scopes a tap's resolveForItem to THIS card when the same item is also
      // mounted in another block (D82).
      blockId: block.id,
      onImpression: () => tracker.record(zine.id, cardIndex: index),
      // Discovery-session impression at qualification + exposure_end with
      // dwell on episode close (PROD-4257, contract v2).
      onEngagementQualified: (dwellMs) => sessionTracker.impression(
        itemId: zine.id,
        itemType: block.itemType,
        runId: runId,
        blockType: 'zine_grid',
        blockId: block.id,
        surface: FeedImpressionSurface.zineGrid,
        cardIndex: index,
        dwellMs: dwellMs,
      ),
      onResolved: (dwellMs, qualified, endReason) => sessionTracker.exposureEnd(
        dwellMs: dwellMs,
        qualified: qualified,
        endReason: endReason,
        itemId: zine.id,
        itemType: block.itemType,
        runId: runId,
        blockType: 'zine_grid',
        blockId: block.id,
        surface: FeedImpressionSurface.zineGrid,
        cardIndex: index,
      ),
      child: _cardBody(context, ref, zine, index, runId),
    );
  }

  Widget _cardBody(
    BuildContext context,
    WidgetRef ref,
    FeedZineItem zine,
    int index,
    String? runId,
  ) {
    final recipe = zineCoverRecipeFor(zine);
    return HighlightedShelfCard(
      // Item id, not index: a refetch that reorders the grid must not let Flutter
      // reuse one card's element for another zine.
      key: ValueKey('feed-zine-grid-${block.id}-${zine.id}'),
      // ⚠️ `coverRecipe`, never `imageUrl`. The card takes both because search
      // results reuse it for events and venues, which do have a flat URL — but a
      // zine's cover is composed, and handing it a URL renders the wrong picture
      // (or none) for every cover mode except `uploaded_photo`.
      coverRecipe: recipe,
      name: zine.name,
      attribution: _attribution(zine),
      attributionAvatarUrl: zine.curatorAvatarUrl,
      attributionAvatarName: zine.curatorName,
      // ⚠️ **The static fold, not the animated peel** (PROD-4118, Figma
      // `7686-43803`). Setting this suppresses `ZineCoverPeelOverlay` inside the
      // card. On this feed the turned corner is part of the cover — every zine
      // carries one, and it is what makes a zine read as a zine next to an event
      // and a venue in one scroll. The peel is a *hint* gated to roughly one card
      // per band, which on a four-card grid would decorate one card and leave
      // three looking unfinished.
      //
      // `indexInShelf` is deliberately NOT passed: it exists only to steer the
      // peel's gate, and there is no gate here.
      cornerFoldColor: SokoZineCornerFold.pageColorFor(
        zine.id,
        coverColor: recipe.color,
      ),
      indexInShelf: index,
      onTap: () => openFeedItemDetail(
        context,
        ref,
        // The BLOCK's declared type, never the active filter (D34).
        itemType: block.itemType,
        item: zine,
        blockId: block.id,
        // Its own surface class for exposure weighting — a grid tile is not a
        // bundle row, and reusing `bundle_highlight` would make a `GROUP BY
        // surface` quietly wrong in a way nothing would flag.
        surface: FeedImpressionSurface.zineGrid,
        cardIndex: index,
        runId: runId,
      ),
    );
  }

  /// The curator line under the card.
  ///
  /// Empty rather than a placeholder when the backend has no name: the card
  /// renders the line only when it is non-empty, and inventing "Soko" or "—"
  /// here would attribute a zine to someone who did not make it.
  String _attribution(FeedZineItem zine) => zine.curatorName ?? '';
}
