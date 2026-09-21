// PROD-4068 — impression bookkeeping for the server-driven feed's surfaces.
//
// `ImpressionScrollTracker` takes a `Ref`, not a `WidgetRef`, and owns
// per-surface state (the dedup set, the scroll seed) that must outlive a single
// build. A provider is how a widget gets one without minting a fresh tracker —
// and therefore a fresh, empty dedup set — on every rebuild.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/impression_scroll_tracker.dart';
import '../../../../data/models/feed_impression.dart';

/// Identity of one see-all page: its block, and the entity type its rows carry.
typedef FeedSeeAllTrackerKey = ({String blockId, String itemType});

/// Identity of one **home-page** surface: its block, the entity type it carries,
/// and its surface class.
///
/// The surface is part of the key and not derivable from the block: the Zines
/// page puts a `zine_grid` and a zine `bundle` on the same page, and the bundle
/// additionally has a see-all page that shares its `block_id`. Keying on block
/// alone would collide all three into one dedup set — and worse, into one
/// `VisibilityDetector` key, whose bookkeeping map is app-global and static, so
/// the collision suppresses callbacks rather than erroring.
typedef FeedHomeTrackerKey = ({
  String blockId,
  String itemType,
  String surface,
});

/// Tracker for a bundle's see-all page (D83 — the page emits **both** rails for
/// the rows actually seen).
///
/// `autoDispose` so leaving the page ends the surface: coming back is a new
/// visit and should count again, which is the same semantics `startScroll()`
/// gives a shelf refresh.
///
/// **Keyed by block, and separately from the home-page bundle.** The two share
/// a `block_id` but are different surfaces — see [ImpressionScrollTracker.
/// scopeId], which folds the surface class in for exactly this reason.
final feedBundleSeeAllTrackerProvider = Provider.autoDispose
    .family<ImpressionScrollTracker, FeedSeeAllTrackerKey>((ref, key) {
      final tracker = ImpressionScrollTracker(
        ref,
        itemType: key.itemType,
        blockId: key.blockId,
        // Derived, not fixed: one page renders three entity types, and a zine
        // see-all is its own weighted corpus (`zine_bundle_see_all`). This was
        // a constant while only events and venues shared the page.
        surface: FeedImpressionSurface.bundleSeeAllFor(key.itemType),
      );
      // Mints the scroll identity and clears the dedup set. Without it the
      // suppression rail would post with a null seed.
      tracker.startScroll();
      return tracker;
    });

/// Tracker for a surface on the **home feed** — a `zine_grid`'s tiles, or a
/// bundle's highlighted rows (PROD-4118).
///
/// This started as the home feed's first impression rail, scoped to the zine
/// blocks only (Zé's call, 2026-09-01: instrument the new surface rather than
/// ship a third uninstrumented one). **PROD-4315 closed the rest**, so the hero,
/// the highlighted bundle rows and the venue grid now report here too and a
/// `GROUP BY surface` no longer shows `zine_*` alone. The one surface still
/// deliberately absent is the weekly bundle, whose item is a list/batch id
/// rather than an entity — see `feed_weekly_bundle_block.dart`.
///
/// `autoDispose` for the same reason its see-all sibling is: leaving the page
/// ends the surface, and coming back is a new visit that should count again.
final feedHomeImpressionTrackerProvider = Provider.autoDispose
    .family<ImpressionScrollTracker, FeedHomeTrackerKey>((ref, key) {
      final tracker = ImpressionScrollTracker(
        ref,
        itemType: key.itemType,
        blockId: key.blockId,
        surface: key.surface,
      );
      tracker.startScroll();
      return tracker;
    });
