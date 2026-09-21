// PROD-4006 — the `bundle` block. Figma `7304-23652` / `7304-23918`.
//
// A server-generated title over the block's **highlighted** rows — 1–4 of them,
// typically 3 (D76). From spec v1.110.0 the block also carries its *full*
// result set in `items`, which this widget must not render: that is the see-all
// page's job (PROD-4068), reached through the title + chevron.
//
// **This is the widget the ticket calls out as mattering most**, and the reason
// is what it deliberately does NOT do:
//
//   * It never looks at where the bundle came from. Layout rows #3 and #4 are
//     `bundle-venue` and `bundle-workshops` — one built from a venue's events,
//     one from a category — and the client cannot tell them apart, because the
//     sourcing rule never reaches the wire (D18). That is exactly what lets the
//     backend change selection logic with no app release, and a single
//     `if (block.id == …)` here would quietly end it.
//   * It reads `display` and ignores it (D35). Which fields a row shows may
//     vary per bundle later; the slot is reserved so adding that stays additive.
//     Figma's third bundle example ("Dos teus amigos", `7304-24030`) is that
//     future state, not v0 — it swaps the venue line for a social line. Do not
//     build it from this ticket.
//   * It does not branch on `item_type` beyond the event row. A bundle carries
//     exactly one entity type (D34) and v0 emits `event` only; a second row
//     widget belongs to the ticket that introduces the second type.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/router/app_router.dart';
import '../../../../../core/services/unified_analytics_service.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../data/models/feed_impression.dart';
import '../../../../../providers/api_provider.dart';
import '../../../../../l10n/generated/l10n.dart';
import '../../../../../shared/widgets/impression_detector.dart';
import '../../providers/feed_home_provider.dart';
import '../../providers/feed_impression_trackers.dart';
import '../../utils/feed_item_open.dart';
import '../feed_bundle_hero.dart';
import 'feed_block_atoms.dart';
import 'feed_bundle_row.dart';

class FeedBundleBlock extends ConsumerWidget {
  final FeedBlockBundle block;

  const FeedBundleBlock({super.key, required this.block});

  /// Rows sit at a 90 px pitch over an 80 px box (`7304:23655` → `7304:23682`).
  static const double rowGap = 10;

  /// Title box is 32 tall and the rows frame starts at y52.
  static const double _titleGap = 20;

  /// Opens the full result set, handing the block over rather than refetching
  /// it (D80) — the data arrived with the feed, so there is no spinner.
  ///
  /// Fires the see-more click first. The shelf affordance has always emitted
  /// this and the feed one must too, or the see-all page has traffic with no
  /// recorded entry point — and `discovery_shelf_viewed` is the denominator it
  /// pairs with, which BE registered alongside it for exactly that reason.
  void _openSeeAll(BuildContext context, WidgetRef ref) {
    ref
        .read(unifiedAnalyticsProvider)
        .trackDiscoveryShelfSeeMoreClicked(blockId: block.id);
    // PROD-4303 — the container affordance ENGAGES the visit: a reader who
    // only opens a see-all must not read as a bounce. The tap's item is the
    // bundle itself. Synchronous tap-time reads on a live element — same
    // legality as the analytics read above; the block's own run resolved the
    // same way build resolves it.
    ref
        .read(discoverySessionTrackerProvider)
        .tap(
          itemId: block.id,
          itemType: 'bundle',
          blockType: 'bundle',
          blockId: block.id,
          runId:
              block.runId ??
              ref.read(feedHomeProvider).valueOrNull?.runIdForBlock(block.id),
          surface: FeedImpressionSurface.bundleHighlight,
        );
    // Container-transform source: record where the block sits on screen right
    // now, so the see-all page can slide its matching group up from exactly
    // here (see [feedBundleMorphSourceRectProvider] / `FeedBundleSeeAllScreen`).
    // `context` is this block's own element, so its render box is the block's
    // rect (title + highlighted rows). A Hero can't do this job — the rows are
    // themselves Heroes and Flutter forbids nesting — so we morph by hand.
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      ref.read(feedBundleMorphSourceRectProvider.notifier).state =
          box.localToGlobal(Offset.zero) & box.size;
    }
    context.push(AppRoutes.feedBundleSeeAllPath(block.id), extra: block);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = block.highlightedItems;
    final title = block.title;
    // The run that served THIS block (PROD-4303): the wire block's own run_id
    // when the backend sends one, else the run of the page it arrived on.
    // Captured once here — row callbacks fire where `ref` may be dead.
    final runId =
        block.runId ??
        ref.read(feedHomeProvider).valueOrNull?.runIdForBlock(block.id);

    // Same ARB fallback the see-all page uses for its own heading — which was
    // otherwise unreachable copy, since without a heading here there was no
    // way to open that page.
    final heading = (title != null && title.isNotEmpty)
        ? title
        : (block.hasSeeAll
              ? Lt.of(context).feedBundleSeeAllTitleFallback
              : null);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The title is drawn when the backend sent one **or** when it is the
        // only way to reach the see-all page. Gating the whole heading on
        // `title` alone loses the affordance entirely for a title-less
        // bundle with more results behind it — the rows still render, the
        // chevron does not, and the user silently keeps the highlighted
        // subset. Found by codex review, 2026-08-28.
        if (heading != null) ...[
          // Backend-generated ("Na Casa Capitão", "Para fãs de Julia
          // Mestre") — the one place the sourcing rule is *visible*, and it
          // is visible as prose the backend wrote, not as a type the client
          // switches on.
          // `Mobile/H2` (`7304:23653`) — Season Mix 32, leading 1, tracking
          // **0**. It shipped at 28 with the display face's derived −2 %,
          // which is `Mobile/H1`'s tracking rather than this token's.
          FeedBlockTitle(
            text: heading,
            fontSize: 32,
            letterSpacing: 0,
            // D87 — the affordance appears only when there is something
            // behind the tap. `hasSeeAll` is the WHOLE rule: no per-bundle
            // knowledge here, so the day a bundle's source starts returning
            // more than it shows, the chevron appears with no app release.
            onSeeAll: block.hasSeeAll ? () => _openSeeAll(context, ref) : null,
            seeAllSemanticLabel: block.hasSeeAll
                ? Lt.of(context).feedBundleSeeAllA11y
                : null,
          ),
          const SizedBox(height: _titleGap),
        ],
        // **Highlights, not `items`.** From v1.110.0 `items` is the full
        // result set (up to 30) and `highlighted_item_ids` names the 1–4 the
        // home page shows — rendering `items` here is the documented way to
        // turn this block into a 30-row wall.
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: rowGap),
          _maybeInstrumented(
            ref,
            item: rows[i],
            index: i,
            runId: runId,
            child: FeedBundleRow(
              // Item id, not index: a re-fetch that reorders rows must not
              // let Flutter reuse one row's element (and its save state) for
              // another item.
              key: ValueKey('feed-bundle-${block.id}-${rows[i].id}'),
              item: rows[i],
              // Per-bundle opt-in: only bundles the backend flagged render the
              // friends-going line on their event rows.
              socialProof: block.showSocialProof,
              onTap: () => openFeedItemDetail(
                context,
                ref,
                itemType: block.itemType,
                item: rows[i],
                blockId: block.id,
                surface: FeedImpressionSurface.bundleHighlightFor(
                  block.itemType,
                ),
                // Position within the HIGHLIGHTS, which is what the user sees
                // — not the item's index in the full result set.
                cardIndex: i,
                runId: runId,
              ),
            ),
          ),
        ],
      ],
    );

    return FeedBlockSurface(block: block, child: content);
  }

  /// Wraps a highlighted row in an [ImpressionDetector] — **every row, every
  /// item type** (PROD-4315).
  ///
  /// This used to bail out for anything but a zine, so event and venue bundles
  /// reported clicks with no impression denominator. That asymmetry was the
  /// deliberate, temporary shape PROD-4118 shipped (Zé's call, 2026-09-01:
  /// instrument the new surface rather than add a third uninstrumented one),
  /// and its own note said to delete the branch when the impression rail
  /// landed. That note named PROD-4008; the ticket that actually carries the
  /// rail is PROD-4315 — PROD-4008's own scope table lists these impressions as
  /// explicitly OUT. This is that deletion.
  ///
  /// It was not a reporting nicety. The backend's seen-suppression and its
  /// graded `exposure_penalty` both read `user_entity_impressions`, so an
  /// unreported surface is one the engine believes the viewer has never seen —
  /// and it re-serves it. Production measured **3.9%** of served feed items
  /// carrying an impression (14.4% even at the top three positions), which left
  /// `dropped_seen` at 0.55 of ~156 candidates and a returning viewer seeing
  /// **36.6%** of their top-10 repeat from the previous day.
  ///
  /// The surface is derived per item type, never hardcoded: an entity's
  /// exposure count must not depend on which feed page it happened to appear
  /// on (see [FeedImpressionSurface.bundleHighlightFor]).
  Widget _maybeInstrumented(
    WidgetRef ref, {
    required FeedItem item,
    required int index,
    required String? runId,
    required Widget child,
  }) {
    final surface = FeedImpressionSurface.bundleHighlightFor(block.itemType);
    final tracker = ref.watch(
      feedHomeImpressionTrackerProvider((
        blockId: block.id,
        itemType: block.itemType,
        surface: surface,
      )),
    );
    // Read HERE, not in onResolved — it fires from ImpressionDetector.dispose()
    // where `ref` is dead. keepAlive singleton, safe to capture.
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
      key: ValueKey('${tracker.scopeId}-${item.id}'),
      // From the tracker — this block and its see-all page share a `block_id`,
      // and `VisibilityDetector`'s key map is app-global and static, so the two
      // must not derive the same key.
      scopeId: tracker.scopeId,
      itemId: item.id,
      // Scopes a tap's resolveForItem to THIS card when the same item is also
      // mounted in another block (hero + bundle row, D82).
      blockId: block.id,
      onImpression: () => tracker.record(item.id, cardIndex: index),
      // Discovery-session impression at qualification + exposure_end with
      // dwell on episode close (PROD-4257, contract v2).
      onEngagementQualified: (dwellMs) => sessionTracker.impression(
        itemId: item.id,
        itemType: block.itemType,
        runId: runId,
        blockType: 'bundle',
        blockId: block.id,
        surface: surface,
        cardIndex: index,
        dwellMs: dwellMs,
      ),
      onResolved: (dwellMs, qualified, endReason) => sessionTracker.exposureEnd(
        dwellMs: dwellMs,
        qualified: qualified,
        endReason: endReason,
        itemId: item.id,
        itemType: block.itemType,
        runId: runId,
        blockType: 'bundle',
        blockId: block.id,
        surface: surface,
        cardIndex: index,
      ),
      child: child,
    );
  }
}
