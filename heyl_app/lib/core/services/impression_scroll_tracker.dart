import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/feed_impression.dart';
import '../../providers/api_provider.dart';
import 'unified_analytics_service.dart';

/// Surface-agnostic impression bookkeeping for a paged shelf or a feed block.
///
/// Owns the per-feed-load dedup set and the per-scroll seed/snapshot identity,
/// and fans a first-sight impression to BOTH the analytics event
/// (`item_impression`) and the backend seen-suppression sender.
///
/// **One method feeds both rails**, and that is the reason to compose this
/// class rather than emit either rail directly: anything that posts one while
/// bypassing the other silently drops it, and the drop is invisible from the
/// client because both sends are fire-and-forget.
///
/// The two rails record deliberately different things. `item_impression`
/// answers *where* a card was shown, per sighting, and so carries the
/// container and the position. `POST /feed/impressions` answers *have we shown
/// this, how often, how recently* — it is entity-keyed and cross-surface by
/// design, so it carries no position at all, only a coarse [surface] class
/// used to weight the exposure.
class ImpressionScrollTracker {
  ImpressionScrollTracker(
    this._ref, {
    required this.itemType, // 'event' | 'venue'
    this.shelfId,
    this.blockId,
    this.surface,
  }) : assert(
         (shelfId == null) != (blockId == null),
         'Exactly one of shelfId / blockId. No surface is a shelf AND a block, '
         'so a row carrying both describes a layout that does not exist — and '
         'the failure is a plausible, wrong, silent GROUP BY rather than an '
         'error.',
       );

  final Ref _ref;
  final String itemType;

  /// Legacy Discovery shelf (`happening`, `near_you_places`). Mutually
  /// exclusive with [blockId].
  final String? shelfId;

  /// Server-driven feed block — a **layout slot id** (`hero-lead`,
  /// `bundle-venue`), never derived from the content filling the slot, so a
  /// slot's impression history stays continuous when its data source changes
  /// underneath it. Mutually exclusive with [shelfId].
  final String? blockId;

  /// Coarse block class for exposure weighting — see [FeedImpressionSurface].
  /// Null on legacy shelves, which record at the flat feed weight.
  final String? surface;

  /// Identity of the surface these impressions belong to.
  ///
  /// **The single source of truth for two things that must never disagree**:
  /// the `ImpressionDetector` key and the [_impressed] dedup gate below. They
  /// used to be derived independently — the widget keyed on `itemId` alone
  /// while the tracker's Set did too — which was safe only while one entity
  /// could appear once per page.
  ///
  /// [surface] is part of it, not just [blockId]: a bundle and its see-all
  /// page share a block id, so scoping on the container alone would still
  /// collide across the two.
  String get scopeId =>
      shelfId != null ? 'shelf:$shelfId' : 'block:$blockId:${surface ?? '-'}';

  /// Ids already counted this feed load — the once-per-load dedup gate.
  final Set<String> _impressed = {};

  /// Per-scroll identity for backend seen-suppression. Minted on [startScroll],
  /// reused across the scroll's pages so the scroll's own impressions don't
  /// reorder its later pages.
  String? seed;
  DateTime? snapshotAt;

  /// Begin a new scroll (a fresh feed load): reset the dedup and mint a new
  /// seed + snapshot. Call from the notifier's `refresh()`.
  void startScroll() {
    _impressed.clear();
    seed = const Uuid().v4();
    snapshotAt = DateTime.now().toUtc();
  }

  /// Reset the dedup set WITHOUT minting a new scroll id (logout / account
  /// switch). Call from the notifier's `clear()`.
  void reset() => _impressed.clear();

  /// Re-adopt a previously-minted scroll identity (seed + snapshot) without
  /// clearing the dedup set. Used when a shelf re-shows a cached feed page so
  /// its later pagination continues under the same seed instead of minting a
  /// fresh one.
  void restoreScroll(String? seed, DateTime? snapshotAt) {
    this.seed = seed;
    this.snapshotAt = snapshotAt;
  }

  /// Record a card impression, once per feed load per **(surface, item)**.
  /// Fires the analytics event and enqueues the backend suppression report.
  void record(String id, {required int cardIndex}) {
    // Scoped, not bare `id`. Each tracker instance owns one surface, so this
    // is belt-and-braces within an instance — but it makes the gate read the
    // same way as `scopeId`'s other consumer, and it is correct if a tracker
    // is ever shared.
    if (_impressed.add('$scopeId:$id')) {
      _ref
          .read(unifiedAnalyticsProvider)
          .trackItemImpression(
            itemId: id,
            itemType: itemType,
            shelfId: shelfId,
            blockId: blockId,
            surface: surface,
            cardIndex: cardIndex,
          );
      _ref
          .read(feedImpressionSenderProvider)
          .enqueue(
            FeedImpressionIn(
              itemId: id,
              itemType: itemType,
              seenAt: DateTime.now().toUtc(),
              // Position stays off this rail by design; the class does not.
              surface: surface,
            ),
          );
    }
  }
}
