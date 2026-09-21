// PROD-4076 — opening the entity behind a feed card or bundle row.
//
// **Routed by `item_type`, never by assumption.** v0 emits `event` only, but
// the bundle declares its entity type on the wire (D34) and venues follow. A
// hardcoded `/events/{id}` would keep compiling and start opening the wrong
// page the day a venue bundle ships — the failure being a real page about the
// wrong entity, which reads as a data bug rather than a routing one.
//
// An unknown type opens nothing rather than guessing. Same posture as the
// dispatcher's unknown-block rule: an older client meeting a newer type does
// less, never something wrong.
//
// `itemType` is the BLOCK's declared type, deliberately kept separate from the
// item's Dart class. The two agree on every payload the backend sends, and
// passing the declared one keeps this function honest about which of the two is
// the contract (D34). Only `item.id` is read here, so the sealed base suffices.

import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../data/models/feed_home.dart';
import '../../../../providers/api_provider.dart';
import '../../../../providers/detail_seed_provider.dart';
import '../../../../shared/widgets/hero_image_warmup.dart';
import '../../../../shared/widgets/impression_detector.dart';
import '../../../lists/utils/zine_cover_seed.dart';
import '../../../lists/utils/zine_item_color.dart';
import '../providers/feed_home_provider.dart';
import 'feed_zine_cover.dart';

/// Path for [itemType] + [id], or null when this build does not know the type.
String? feedItemDetailPath(String itemType, String id) {
  if (id.isEmpty) return null;
  return switch (itemType) {
    'event' => '/events/$id',
    'venue' => '/venues/$id',
    // ⚠️ `/lists/`, not `/zines/` (PROD-4118). The app calls it a zine, the
    // route has always called it a list, and the wire type is `zine` — three
    // vocabularies for one thing, and this is where they meet.
    //
    // A bare UUID is correct here even though every other surface pushes
    // `list.urlIdentifier`: that getter is `slug ?? id`, so the route already
    // resolves both, and `FeedZineItem` carries no slug.
    'zine' => '/lists/$id',
    _ => null,
  };
}

/// Fires the click event and opens the entity, in that order.
///
/// **The click event must carry the same join keys as the impression** or the
/// CTR the impression rail exists to measure has no numerator. `block_id` and
/// `card_index` here mirror `trackItemImpression`'s exactly.
///
/// ⚠️ **This applies no guest or gating policy, deliberately** (D10). A blurred
/// block must not open a detail, and it cannot: `FeedBlockSurface` wraps a
/// blurred block's whole subtree in an `IgnorePointer`, so the tap never
/// arrives. Adding a `blurred` check here would be a second, divergent policy
/// shipped in an app release — the exact thing D10 forbids. If you are here
/// because you want to gate something, gate it there, once.
///
/// The home feed once shipped a click numerator with no impression
/// denominator: only the see-all page wrapped its rows in `ImpressionDetector`,
/// so `hero` and `bundle_highlight` produced clicks and no `item_impression`.
/// Raised by codex review 2026-08-28, and closed by PROD-4315 — the hero,
/// highlighted bundle rows and venue grid now carry detectors and report on
/// both rails. The weekly bundle stays click-only on purpose (its item is a
/// list/batch id, not an entity).
///
/// ⚠️ The backend copy of `discovery_shelf_card_clicked` does not land yet —
/// the event is absent from the backend `EVENT_REGISTRY` and has 422'd since
/// it shipped (PROD-4077 registers it). PostHog receives it either way, which
/// is why this is not gated on that ticket.
void openFeedItemDetail(
  BuildContext context,
  WidgetRef ref, {
  required String itemType,
  required FeedItem item,
  required String blockId,
  required String surface,
  required int cardIndex,
  String? runId,
}) {
  final path = feedItemDetailPath(itemType, item.id);
  // Emit only when the tap actually goes somewhere: a click event for a
  // navigation that did not happen would inflate CTR for unroutable types.
  if (path == null) return;

  ref
      .read(unifiedAnalyticsProvider)
      .trackDiscoveryShelfCardClicked(
        blockId: blockId,
        surface: surface,
        cardIndex: cardIndex,
        itemId: item.id,
        itemType: itemType,
        // Page-level, so read here rather than threaded through every block
        // (PROD-4373): which ranking served the feed this card sits on —
        // `personalized` vs `safe_bet` — so dashboards can split CTR by
        // ranking kind without a `discovery_runs` join. Null off the home
        // feed (the provider is down) and on run-less pages.
        slateKind: ref.read(feedHomeProvider).valueOrNull?.slateKind,
      );

  // Resolve the card's pending exposure BEFORE enqueuing the tap (contract
  // v2): the exposure_end (and its qualification impression) must precede the
  // tap in `seq` order, or a save on the detail page is credited before the
  // exposure that earned it. Scoped to THIS block's card: an item mounted in
  // several blocks at once (hero + bundle row, D82) must not have every
  // copy's exposure stamped with the tapped card's end reason.
  ImpressionDetector.resolveForItem(item.id, blockId: blockId);

  // Discovery-session tap (PROD-4257): the graded label between impression and
  // save. Central for every home-feed card open, so all surfaces are covered
  // here even where the impression rail is not yet wired. [runId] is the
  // BLOCK's resolved run (PROD-4303 per-block attribution); when the caller
  // has none the tracker falls back to the current page's.
  //
  // PROD-4307 — the open IS a detail navigation: one navigation_id joins this
  // tap to the detail_engagement emitted when the pushed route pops (below),
  // so detail dwell links to its originating exposure exactly.
  final tracker = ref.read(discoverySessionTrackerProvider);
  final navigationId = tracker.beginDetailNavigation(
    itemId: item.id,
    itemType: itemType,
    runId: runId,
    blockId: blockId,
    surface: surface,
  );
  tracker.tap(
    itemId: item.id,
    itemType: itemType,
    runId: runId,
    blockId: blockId,
    surface: surface,
    cardIndex: cardIndex,
    navigationId: navigationId,
  );

  // PROD-4160-followup — seed the detail shell so the feed → detail shared
  // element has a frame-1 destination (a Hero flight is skipped if the
  // destination isn't laid out on the first open). Event/venue seed the
  // collage; a zine seeds its cover.
  switch (item) {
    case FeedEventItem e:
      // Pre-publish the detail's image-derived pastel synchronously so the
      // shell + PinnedPageChrome paint it on frame one — matching the detail
      // body's own ColoredBox. Without this the shell shows a stale/route-
      // constant colour for one frame behind the correctly-coloured body, which
      // reads as a white/edge line flash on open (the same fix Library applies
      // in `_openEntity`).
      ref.read(standaloneDetailBgProvider.notifier).state =
          cachedZineItemColor(ref, e.id) ?? zineItemFallbackColor(e.id);
      ref.cacheDetailSeed(DetailSeed.fromFeedEventItem(e));
      // Warm the collage poster so the feed → detail Hero flies the photo.
      warmHeroImage(context, e.imageUrl);
    case FeedVenueItem v:
      ref.read(standaloneDetailBgProvider.notifier).state =
          cachedZineItemColor(ref, v.id) ?? zineItemFallbackColor(v.id);
      ref.cacheDetailSeed(DetailSeed.fromFeedVenueItem(v));
      warmHeroImage(context, v.imageUrl);
    case FeedZineItem z:
      final recipe = zineCoverRecipeFor(z);
      ref.cacheZineCoverSeed(
        z.id,
        ZineCoverSeed(recipe: recipe, title: z.name),
      );
      // Warm the cover photo (photo-mode covers only) so the shelf → cover
      // Hero flies the real image, not the solid-colour fallback.
      warmHeroImage(context, recipe.photoUrl);
  }

  // The push future completes when the detail route POPS — that span is the
  // detail engagement (PROD-4307). Deeper navigation from the detail counts
  // as continued engagement with what the card opened; background time is
  // excluded by the tracker's lifecycle pause. Never-popped routes (process
  // death) are censored, not zero-dwell.
  unawaited(
    context
        .push(path)
        .whenComplete(() => tracker.endDetailNavigation(navigationId)),
  );
}
