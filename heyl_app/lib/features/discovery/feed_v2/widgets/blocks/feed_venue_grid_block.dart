// PROD-4108 — the `venue_grid` block ("Perto de ti"). Figma `7675:38682`.
//
// A title with a see-more chevron over a grid of venue tiles, 3 to a row.
//
// **The backend owns the item count, the client owns the column count** (D8).
// So this widget never assumes six: it lays out `ceil(items.length / columns)`
// rows and a ragged last row is expected rather than a defect. Per-caller
// seen-suppression and a thin corpus both shorten the list, and two readers in
// one city legitimately get different grids of different lengths.
//
// ⚠️ **An empty grid never reaches this widget** — `renderableFeedBlocks` drops
// a zero-item `venue_grid` before the list builder. That filter is the client's
// half of a rule the backend cannot enforce: it places the block during
// composition, before the per-caller near-you query runs, and its cursor digest
// is taken over that composition. See the dispatcher for the whole story.
//
// **The block is not bundle-shaped** (D137). No `total_count`, no full result
// set, no highlight window — its "ver mais" leaves the feed contract entirely
// for the app's existing `/shelves/near-you` page, so the affordance is
// unconditional rather than gated on a count. D78/D87 govern bundles, not this.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/services/unified_analytics_service.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../data/models/feed_impression.dart';
import '../../../../../providers/api_provider.dart';
import '../../../../../shared/widgets/impression_detector.dart';
import '../../providers/feed_home_provider.dart';
import '../../providers/feed_impression_trackers.dart';
import '../../utils/feed_action_routes.dart';
import '../../utils/feed_item_open.dart';
import 'feed_block_atoms.dart';
import 'feed_venue_grid_tile.dart';

class FeedVenueGridBlock extends ConsumerWidget {
  final FeedBlockVenueGrid block;

  const FeedVenueGridBlock({super.key, required this.block});

  /// Columns are the CLIENT's decision (D8) — the backend sends a count and has
  /// no idea how wide the viewport is. Three matches the frame's `3 × 125 + 2 ×
  /// 12 = 399` at the design width.
  static const int columns = 3;

  /// Horizontal gap between tiles (`7675:38684`, `gap-[12px]`).
  static const double columnGap = 12;

  /// Vertical gap between rows — the root frame's own `gap-[20px]`, which also
  /// separates the title from the first row.
  static const double rowGap = 20;

  /// Opens the legacy near-you shelf page.
  ///
  /// **The same destination and the same event as the legacy shelf's own tile**
  /// (D137). Reusing the page is only safe because the backend sources this
  /// grid from the query that page uses, so tapping through shows more of the
  /// same thing rather than a differently-composed list.
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
    // Rule 2 in its ordinary form: a button whose route this app version does
    // not recognise hides the affordance rather than navigating blind. In
    // practice `/shelves/near-you` is allowlisted, so the chevron is
    // unconditional — but the gate stays because the alternative is trusting a
    // server-supplied route.
    // `routeTarget`, not `isLive`: since PROD-4238 `isLive` is also true for a
    // `next_slate` action, which carries no route to open. This asks for the
    // destination, so "live" and "where to" cannot disagree.
    final seeAllRoute = button?.routeTarget(isAllowedFeedActionRoute);
    final live = seeAllRoute != null;

    // The run that served THIS block (PROD-4303): the wire block's own run_id
    // when the backend sends one, else the run of the page it arrived on.
    // Captured once here — tile callbacks fire where `ref` may be dead.
    final runId =
        block.runId ??
        ref.read(feedHomeProvider).valueOrNull?.runIdForBlock(block.id);

    return FeedBlockSurface(
      block: block,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title.isNotEmpty) ...[
            // `Mobile/H1` (`7675:38683`) — Season Mix 42, leading 0.9, tracking
            // −0.42. Larger than the bundle's `Mobile/H2` 32, and a different
            // token rather than the same one scaled up.
            FeedBlockTitle(
              text: title,
              fontSize: 42,
              height: 0.9,
              letterSpacing: -0.42,
              onSeeAll: live
                  ? () => _openSeeMore(context, ref, seeAllRoute)
                  : null,
              // The backend's label ("Ver mais") as the accessible name: the
              // chevron is decorative, so without this the target announces the
              // title and not what tapping it does. Backend-localized (D7), so
              // no ARB key — the copy travels with the block.
              seeAllSemanticLabel: live ? button?.label : null,
            ),
            const SizedBox(height: rowGap),
          ],
          _grid(context, ref, runId),
        ],
      ),
    );
  }

  /// The tiles, in rows of [columns].
  ///
  /// A `Column` of `Row`s rather than a `GridView`: the grid is a handful of
  /// items inside an already-scrolling feed, so a scrollable would need
  /// `shrinkWrap` plus `NeverScrollableScrollPhysics` to behave — more moving
  /// parts than the layout warrants, and it would build all tiles anyway.
  ///
  /// The last row is padded with empty `Expanded` slots rather than left short,
  /// so four items give a full row plus one **left-aligned** tile at the same
  /// width as the others, instead of one stretched across the viewport.
  Widget _grid(BuildContext context, WidgetRef ref, String? runId) {
    final items = block.items;
    final rowCount = (items.length + columns - 1) ~/ columns;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var row = 0; row < rowCount; row++) ...[
          if (row > 0) const SizedBox(height: rowGap),
          Row(
            // `items-start` on the frame's row: tiles top-align and keep their
            // natural heights, so a two-line name grows its own tile downward
            // rather than padding its neighbours.
            //
            // ⚠️ Deliberately NOT wrapped in `IntrinsicHeight` to equalise
            // them. The tile measures its cover with a `LayoutBuilder`, and
            // `LayoutBuilder` cannot answer an intrinsic query — the pair
            // throws `LayoutBuilder does not support returning intrinsic
            // dimensions` at layout time. Equal heights would also be wrong
            // here: every cover is already the same height (same column width,
            // fixed aspect), so the only variation is text, which the design
            // lets vary.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var col = 0; col < columns; col++) ...[
                if (col > 0) const SizedBox(width: columnGap),
                Expanded(
                  child: switch (row * columns + col) {
                    final i when i < items.length => _tile(
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

  Widget _tile(
    BuildContext context,
    WidgetRef ref,
    FeedVenueItem venue,
    int index,
    String? runId,
  ) {
    // Captured during build (ref valid); the onResolved closure fires from
    // ImpressionDetector.dispose() where ref is dead, so it must not ref.read.
    final tracker = ref.read(discoverySessionTrackerProvider);
    // Seen-suppression rail (PROD-4315). `watch`, not `read`: the provider is
    // autoDispose+family, so leaving the page ends this surface's scroll.
    final suppressionTracker = ref.watch(
      feedHomeImpressionTrackerProvider((
        blockId: block.id,
        itemType: block.itemType,
        surface: FeedImpressionSurface.venueGrid,
      )),
    );
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
      key: ValueKey('block:${block.id}:venue_grid-${venue.id}'),
      // BOTH rails (PROD-4315) — this surface used to emit clicks with no
      // impression denominator, so the engine believed these venues had never
      // been seen and kept re-serving them. Production measured venue-side
      // impression coverage at 0.6% of served items.
      //
      // `venue_grid` now carries its own weight server-side
      // (`feed_venue_grid`); before that it fell through to the flat `feed`
      // default, which is safe by design but scored a grid tile as if it were a
      // generic list row.
      scopeId: 'block:${block.id}:venue_grid',
      itemId: venue.id,
      // Scopes a tap's resolveForItem to THIS card when the same item is also
      // mounted in another block (D82).
      blockId: block.id,
      onImpression: () => suppressionTracker.record(venue.id, cardIndex: index),
      onEngagementQualified: (dwellMs) => tracker.impression(
        itemId: venue.id,
        itemType: block.itemType,
        runId: runId,
        blockType: 'venue_grid',
        blockId: block.id,
        surface: FeedImpressionSurface.venueGrid,
        cardIndex: index,
        dwellMs: dwellMs,
      ),
      onResolved: (dwellMs, qualified, endReason) => tracker.exposureEnd(
        dwellMs: dwellMs,
        qualified: qualified,
        endReason: endReason,
        itemId: venue.id,
        itemType: block.itemType,
        runId: runId,
        blockType: 'venue_grid',
        blockId: block.id,
        surface: FeedImpressionSurface.venueGrid,
        cardIndex: index,
      ),
      child: FeedVenueGridTile(
        // Item id, not index: a refetch that reorders the grid must not let Flutter
        // reuse one tile's element — and its save state — for another venue.
        key: ValueKey('feed-venue-grid-${block.id}-${venue.id}'),
        venue: venue,
        onTap: () => openFeedItemDetail(
          context,
          ref,
          // The BLOCK's declared type, never the active filter (D34).
          itemType: block.itemType,
          item: venue,
          blockId: block.id,
          // The grid is its own surface class for exposure weighting — it is not a
          // bundle and must not be counted as one.
          surface: FeedImpressionSurface.venueGrid,
          cardIndex: index,
          runId: runId,
        ),
      ),
    );
  }
}
