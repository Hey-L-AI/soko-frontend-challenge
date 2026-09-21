// PROD-4006 — the `weekly_bundle` block. Figma `7304-24341`.
//
// The ticket calls this one "existing element, payload unchanged", and it is:
// the frame is today's Discovery weekly-bundle card, unaltered. So this widget
// is almost entirely reuse — `DiscoveryImageTemplateCard` for the frame,
// `WeeklyBundleCover` for the composed lime cover.
//
// **The one real difference is where the data comes from, and it is the point
// of the whole umbrella.** `WeeklyBundleSection` calls `weeklyBundleProvider`,
// which fetches `/recommendations/weekly` — one of the nine calls that compose
// today's home page. Here the cover fields arrive *inside the block*, so this
// widget must not fetch anything. If it ever grows a provider watch, the feed
// has quietly gone back to being N calls.
//
// The card still opens the existing overlay, which loads the bundle's items on
// demand — that is a tap, not a page load, and it was always a separate fetch.
//
// The `ref.read`s below (PROD-4303) don't break that rule: they read the
// engagement tracker and the already-fetched feed state's run map — no watch,
// no request.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../../core/router/app_router.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../data/models/feed_impression.dart';
import '../../../../../l10n/generated/l10n.dart';
import '../../../../../providers/api_provider.dart';
import '../../../../../shared/widgets/impression_detector.dart';
import '../../../../weekly_bundle/weekly_bundle_nav.dart';
import '../../../widgets/sections/_image_template_card.dart';
import '../../../widgets/sections/_weekly_bundle_cover.dart';
import '../../providers/feed_home_provider.dart';
import 'feed_block_atoms.dart';

class FeedWeeklyBundleBlock extends ConsumerWidget {
  final FeedBlockWeeklyBundle block;

  const FeedWeeklyBundleBlock({super.key, required this.block});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final locale = Localizations.localeOf(context).toString();
    final date = block.weekStart?.toLocal() ?? DateTime.now();

    // Read the tracker HERE, not inside the callbacks: they fire from
    // ImpressionDetector.dispose(), where `ref` is deactivated and a lookup
    // throws. The provider is keepAlive, so the captured instance outlives
    // the card. Same pattern as the hero block.
    final tracker = ref.read(discoverySessionTrackerProvider);
    // The run that served THIS block (PROD-4303): the wire block's own run_id
    // when the backend sends one, else the run of the page it arrived on.
    final runId =
        block.runId ??
        ref.read(feedHomeProvider).valueOrNull?.runIdForBlock(block.id);
    // The block renders ONE card — the bundle cover itself — so the exposure's
    // item is the bundle: the list it opens when known, else the block id.
    // The items behind it stay on `/recommendations/weekly` and get their own
    // exposure on the overlay, never here.
    final itemId = block.listId ?? block.batchId ?? block.id;

    return FeedBlockSurface(
      block: block,
      child: ImpressionDetector(
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
        key: ValueKey('block:${block.id}:weekly-$itemId'),
        // Engagement rail ONLY — and unlike the hero and the bundle rows, this
        // one stays that way after PROD-4315 closed the home feed's suppression
        // coverage. The reason is not scope, it is identity: `itemId` above is a
        // LIST / batch / block id, and the suppression store is keyed on an
        // ENTITY (`user`, `event|venue|list`, id). Posting a batch or block id
        // there would write rows for things that are not entities and fatigue
        // nothing real. The bundle's actual events get their own exposure on
        // `/recommendations/weekly`, which is where they are entities.
        scopeId: 'block:${block.id}:weekly',
        itemId: itemId,
        // Scopes a tap's resolveForItem to THIS card when the same item is
        // also mounted in another block (D82).
        blockId: block.id,
        onImpression: () {},
        onEngagementQualified: (dwellMs) => tracker.impression(
          itemId: itemId,
          itemType: 'weekly_bundle',
          runId: runId,
          blockType: 'weekly_bundle',
          blockId: block.id,
          surface: FeedImpressionSurface.bundleHighlight,
          cardIndex: 0,
          dwellMs: dwellMs,
        ),
        onResolved: (dwellMs, qualified, endReason) => tracker.exposureEnd(
          dwellMs: dwellMs,
          qualified: qualified,
          endReason: endReason,
          itemId: itemId,
          itemType: 'weekly_bundle',
          runId: runId,
          blockType: 'weekly_bundle',
          blockId: block.id,
          surface: FeedImpressionSurface.bundleHighlight,
          cardIndex: 0,
        ),
        child: DiscoveryImageTemplateCard(
          cover: WeeklyBundleCover(
            imageUrls: block.coverImageUrls,
            date: date,
            locale: locale,
          ),
          // Prefer what the backend sent — it is localized (D7) and it is the
          // block's own copy — and fall back to the app's existing strings,
          // which are what today's section renders. The fallback is not
          // defensive padding: the v0 composer sets `title` from
          // `weekly_bundle_title`, but an older or partial payload must still
          // produce a card that reads correctly rather than one with a blank
          // headline.
          titleBold: block.title ?? l10n.discoveryWeeklyBundleTitle,
          titleLight:
              block.subtitle ??
              l10n.discoveryWeeklyBundleDateSuffix(
                DateFormat('d MMMM', locale).format(date),
              ),
          byline: l10n.discoveryWeeklyBundleByline,
          // Deliberately NOT `blurImage`. The template can blur its photo
          // layer alone, which is a nicer treatment — but `FeedBlockSurface`
          // is the one place in the feed that reads `blurred`, and that is
          // what makes "the client applies no guest policy of its own" (D10)
          // checkable rather than aspirational. One consistent treatment
          // across five blocks beats a better one on a single block.
          onTap: () {
            // PROD-4303 — a container open ENGAGES the visit: a reader whose
            // whole visit is opening the weekly bundle must not read as a
            // bounce. Exposure resolves first so it precedes the tap in `seq`
            // order (contract v2).
            ImpressionDetector.resolveForItem(itemId, blockId: block.id);
            tracker.tap(
              itemId: itemId,
              itemType: 'weekly_bundle',
              blockType: 'weekly_bundle',
              blockId: block.id,
              runId: runId,
              surface: FeedImpressionSurface.bundleHighlight,
            );
            context.push(
              AppRoutes.weeklyBundle,
              // Tells the `/weekly-bundle` redirect to render the overlay
              // rather than bounce an in-app tap back through Discovery.
              extra: const WeeklyBundleNav.inApp(),
            );
          },
        ),
      ),
    );
  }
}
