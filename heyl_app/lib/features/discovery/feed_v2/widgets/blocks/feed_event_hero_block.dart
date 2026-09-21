// PROD-4006 — the `event_hero` block. Figma `7304-23446` / `7304-23766`.
//
// **One card per item.** The block carries `items`, and the v0 Eventos layout
// sends two (`feed_layout.py`, `LayoutElement(block_id="hero-lead", count=2)`).
// The ticket's "used twice" is a different axis — the block type appears at
// layout positions #1 and #5, as `hero-lead` and `hero-tail` — and both things
// are true at once, which is easy to read as one.
//
// The only difference between the two occurrences is the eyebrow (D20): #1
// carries "Em destaque", #5 carries nothing. That travels with the **block**,
// not with the item, which is exactly why they are one block type and not two.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../data/models/feed_home.dart';
import '../../../../../data/models/feed_impression.dart';
import '../../../../../providers/api_provider.dart';
import '../../../../../shared/widgets/impression_detector.dart';
import '../../providers/feed_home_provider.dart';
import '../../providers/feed_impression_trackers.dart';
import '../../utils/feed_item_open.dart';
import '../feed_page_content.dart';
import 'feed_block_atoms.dart';
import 'feed_hero_card.dart';
import 'feed_reactions_row.dart';

class FeedEventHeroBlock extends ConsumerWidget {
  final FeedBlockEventHero block;

  const FeedEventHeroBlock({super.key, required this.block});

  /// Gap between stacked cards inside one block.
  ///
  /// The same 30 the page puts between everything else: Figma `7304-23414`
  /// draws the two hero cards as two 500 px frames exactly 30 apart, like every
  /// other pair of elements on the page. What separates them from two *blocks*
  /// is the absence of a `FeedBlockDivider` between them, not a tighter gap —
  /// this was 12 for that reason before the rule existed to carry it.
  static const double _cardGap = kFeedPageBlockGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read the tracker HERE, not inside onResolved: that callback fires from
    // ImpressionDetector.dispose(), where `ref` is deactivated and a lookup
    // throws. The provider is keepAlive, so the captured instance outlives the
    // card. Same pattern the shelf impression trackers use.
    final tracker = ref.read(discoverySessionTrackerProvider);
    // Seen-suppression rail (PROD-4315). `watch`, not `read`: the provider is
    // autoDispose+family, so leaving the page must end this surface's scroll.
    final suppressionTracker = ref.watch(
      feedHomeImpressionTrackerProvider((
        blockId: block.id,
        itemType: 'event',
        surface: FeedImpressionSurface.hero,
      )),
    );
    // The run that served THIS block (PROD-4303): the wire block's own run_id
    // when the backend sends one, else the run of the page it arrived on.
    // Captured once here — the callbacks below fire where `ref` may be dead.
    final runId =
        block.runId ??
        ref.read(feedHomeProvider).valueOrNull?.runIdForBlock(block.id);
    return FeedBlockSurface(
      block: block,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < block.items.length; i++) ...[
            if (i > 0) const SizedBox(height: _cardGap),
            ImpressionDetector(
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
              key: ValueKey('block:${block.id}:hero-${block.items[i].id}'),
              // BOTH rails (PROD-4315). The `onImpression` below was a no-op
              // while the home feed's suppression coverage was still an open
              // scope; this is that scope closing.
              //
              // The hero is the block users most notice repeating, and it was
              // the one the engine was least able to see: production measured
              // 14.4% impression coverage at the top three positions, so
              // seen-suppression dropped 0.55 of ~156 candidates and a
              // returning viewer's top-10 repeated 36.6% day over day.
              //
              // Safe to join the rail because the detector already gates on 70%
              // visible for 300 ms — a hero scrolled past at speed still
              // records nothing. `feed_hero` is the heaviest exposure weight
              // (0.7) in RETRIEVAL_TYPE_WEIGHTS, which is the intent: a
              // full-width card is hard to miss, so it should fatigue fastest.
              scopeId: 'block:${block.id}:hero',
              itemId: block.items[i].id,
              // Scopes a tap's resolveForItem to THIS card when the same item
              // is also mounted in another block (hero + bundle row, D82).
              blockId: block.id,
              onImpression: () =>
                  suppressionTracker.record(block.items[i].id, cardIndex: i),
              onEngagementQualified: (dwellMs) => tracker.impression(
                itemId: block.items[i].id,
                itemType: 'event',
                runId: runId,
                blockType: 'event_hero',
                blockId: block.id,
                surface: FeedImpressionSurface.hero,
                cardIndex: i,
                dwellMs: dwellMs,
              ),
              onResolved: (dwellMs, qualified, endReason) =>
                  tracker.exposureEnd(
                    dwellMs: dwellMs,
                    qualified: qualified,
                    endReason: endReason,
                    itemId: block.items[i].id,
                    itemType: 'event',
                    runId: runId,
                    blockType: 'event_hero',
                    blockId: block.id,
                    surface: FeedImpressionSurface.hero,
                    cardIndex: i,
                  ),
              child: FeedHeroCard(
                // Item id, not block id: the two cards in one block must have
                // distinct keys or Flutter reuses the first card's element for
                // the second when the list reorders.
                key: ValueKey('feed-hero-${block.id}-${block.items[i].id}'),
                item: block.items[i],
                // The eyebrow belongs to the block and describes the group, so it
                // is drawn once, above the first card. Repeating it would claim
                // each card is separately featured.
                eyebrow: i == 0 ? block.eyebrow : null,
                // PROD-4076. `event_hero` has no `item_type` on the wire — the
                // block type IS the type, unlike `bundle` which declares one
                // (D34) — so the constant is right here and an assumption in the
                // bundle.
                onTap: () => openFeedItemDetail(
                  context,
                  ref,
                  itemType: 'event',
                  item: block.items[i],
                  blockId: block.id,
                  surface: FeedImpressionSurface.hero,
                  cardIndex: i,
                  runId: runId,
                ),
              ),
            ),
          ],
          // No gutter of its own: `FeedPageContent` already established the
          // content column, and the row starts at x0 of the same 400 px frame
          // the card does (`7304:23814`).
          if (block.reactions != null)
            FeedReactionsRow(reactions: block.reactions!),
        ],
      ),
    );
  }
}
