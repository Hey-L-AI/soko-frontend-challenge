/// Client-side discovery-session engagement (PROD-4257).
///
/// Models the batch posted to `POST /api/v1/app/discovery/engagement` — the
/// dense, graded labels (impression → dwell → tap → save) the ranker learns
/// from. Where `POST /feed/impressions` answers *have we shown this* and the
/// `item_impression` analytics event answers *where*, this rail answers *what
/// the user did inside one feed visit*.
///
/// A **discovery session** = one feed visit (open → leave / background /
/// navigate away). The client mints a `session_id` and stitches every event of
/// the visit under it. A visit spans several page fetches, each with its own
/// server `run_id`, so each item-level event carries both: `session_id`
/// stitches the visit, `(run_id, item_id)` joins the behaviour back to the
/// exact served slate (`discovery_runs`).
library;

/// `event_kind` values on [DiscoveryEngagementEventIn]. Wire strings, matching
/// the contract's enum exactly.
abstract final class DiscoveryEngagementKind {
  /// Brackets the start of one feed visit.
  static const String sessionStart = 'session_start';

  /// Brackets the end of one feed visit; carries the session aggregates
  /// (`scroll_depth`, `session_dwell_ms`, `engaged`).
  static const String sessionEnd = 'session_end';

  /// A card qualified as seen (≥70% visible past the dwell threshold); carries
  /// `dwell_ms`. Emitted **at qualification time** (contract v2), not at exit.
  static const String impression = 'impression';

  /// The user opened the card.
  static const String tap = 'tap';

  /// The card entered the viewport but left below the dwell threshold with no
  /// tap — a soft negative; carries `dwell_ms`.
  ///
  /// **Legacy (contract v1).** New clients emit [exposureEnd] instead; readers
  /// treat `scroll_past` as an unqualified exposure end.
  static const String scrollPast = 'scroll_past';

  /// A continuous visibility interval ended (contract v2). Carries the full
  /// `dwell_ms` of the interval, `engaged` = whether it qualified, and
  /// `end_reason`. Re-entry starts a new exposure.
  static const String exposureEnd = 'exposure_end';

  /// A served page's blocks actually rendered (contract v2). Carries the
  /// page's `run_id`; separates delivered candidates from presented content.
  static const String pagePresented = 'page_presented';

  /// Filter/mode change, refresh, or slate paging (contract v2). The context
  /// label travels in `block_type`; no item fields.
  static const String contextChanged = 'context_changed';

  /// A downstream reaction (save / like / dislike / share / going); carries
  /// `action_kind`.
  static const String action = 'action';

  /// Foreground dwell on the opened item's detail page until return
  /// (PROD-4307). Carries `dwell_ms` + `navigation_id`, and is attributed to
  /// the ORIGINATING feed session (the one the tap belonged to) — emitted
  /// only for feed-originated opens.
  static const String detailEngagement = 'detail_engagement';
}

/// `action_kind` values, set only on `action` events. Wire strings matching the
/// contract enum.
abstract final class DiscoveryEngagementAction {
  static const String save = 'save';
  static const String unsave = 'unsave';
  static const String like = 'like';
  static const String dislike = 'dislike';
  static const String share = 'share';
  static const String going = 'going';
  static const String unGoing = 'un_going';

  /// PROD-4521 — a follow / unfollow from a people card.
  ///
  /// ⚠️ **New values, and that is safe**: `action_kind` is an **open string**
  /// in the engagement contract, not an enum — an unknown value is kept, never
  /// a 422, so a new reaction records the moment a client ships it. No backend
  /// change was needed.
  ///
  /// ⚠️ **Do NOT reuse `save`/`unsave` for a follow.** `feed_zine_follow.dart`
  /// does, and says why in its own comment: at the time, the contract had no
  /// `follow`. That was true then and is not a precedent. A person is not
  /// saved, and merging person-follows with event-saves and zine-saves under
  /// one `action_kind` is a `GROUP BY` that is wrong in a way nothing flags.
  static const String follow = 'follow';
  static const String unfollow = 'unfollow';
}

/// One client-observed engagement inside a discovery session.
///
/// A union across [eventKind]: fields not relevant to a kind stay `null` and
/// are omitted from the wire body. Item-level kinds carry `itemId`/`itemType`;
/// session-level kinds carry the session aggregates instead.
class DiscoveryEngagementEventIn {
  /// Contract schema version stamped on every event. v1 = the pre-contract
  /// PROD-4257 shape (no event_id/seq); v2 = the PROD-4304 contract.
  static const int schemaVersion = 2;

  /// Immutable client-minted UUIDv4, stable across retries — the DB uniqueness
  /// key. Minted once at event creation (by the tracker), never regenerated.
  final String? eventId;

  /// Per-session monotonically increasing sequence, assigned at enqueue.
  /// Orders events within a session independent of clock quality.
  final int? seq;

  /// One of [DiscoveryEngagementKind].
  final String eventKind;

  /// Client time the event fired (UTC). Clamped server-side to a sane window;
  /// used to order events within a session.
  final DateTime occurredAt;

  /// The served slate this event refers to (`FeedHomeOut.runId` /
  /// `DiscoveryForYouResponse.runId`). Null for session-level events and
  /// whenever the slate had no persisted run.
  final String? runId;

  /// Id of the element — an entity id for a card, or the block/container id for
  /// a container interaction. Null for session-level events.
  final String? itemId;

  /// What was interacted with. Open string (unknowns kept, never a 422). Known
  /// values: `event`, `venue`, `zine`, `person`, and the container kind
  /// `bundle`. **`zine` on the wire = `list` in the store**, same as
  /// `FeedImpressionIn`.
  final String? itemType;

  /// Class of the container the element lived in (e.g. `event_hero`,
  /// `zine_grid`, `bundle`, `people_rail`). Open string.
  final String? blockType;

  /// Zero-based rank of the item in the served slate, when known
  /// (`DiscoveryForYouItem.position`). Null on the block-composed home feed,
  /// where [cardIndex] carries the observed slot instead.
  final int? position;

  /// Client-side slot the card occupied when the event fired (0-based within
  /// its block/shelf) — the positional signal on the home feed.
  final int? cardIndex;

  /// Id of the block/shelf that showed the card, when applicable.
  final String? blockId;

  /// Coarse block class that showed the card (same vocabulary as
  /// `FeedImpressionIn.surface`). Open string.
  final String? surface;

  /// For `impression`/`scroll_past`: how long the card stayed in the viewport,
  /// in milliseconds.
  final int? dwellMs;

  /// For `session_end`: the deepest item index the user reached in the visit.
  final int? scrollDepth;

  /// For `session_end`: total time the feed was in view this visit, in ms.
  final int? sessionDwellMs;

  /// For `session_end`: whether the visit produced any tap or action.
  final bool? engaged;

  /// For `action` events: which downstream reaction fired (one of
  /// [DiscoveryEngagementAction]).
  final String? actionKind;

  /// For `exposure_end` / `session_end`: why the interval closed. Known values:
  /// `scrolled_away`, `tap`, `screen_hidden`, `disposed`, `background`,
  /// `navigation`, `sign_out`. Open string; the backend keeps unknowns.
  final String? endReason;

  /// Per-card-open UUID (PROD-4307): minted once at tap time and stamped on
  /// BOTH the `tap` and the `detail_engagement` its navigation produced, so
  /// detail dwell joins its originating exposure exactly. Null elsewhere.
  final String? navigationId;

  const DiscoveryEngagementEventIn({
    required this.eventKind,
    required this.occurredAt,
    this.eventId,
    this.seq,
    this.endReason,
    this.navigationId,
    this.runId,
    this.itemId,
    this.itemType,
    this.blockType,
    this.position,
    this.cardIndex,
    this.blockId,
    this.surface,
    this.dwellMs,
    this.scrollDepth,
    this.sessionDwellMs,
    this.engaged,
    this.actionKind,
  });

  Map<String, dynamic> toJson() => {
    'event_kind': eventKind,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'schema_version': schemaVersion,
    if (eventId != null) 'event_id': eventId,
    if (seq != null) 'seq': seq,
    if (endReason != null) 'end_reason': endReason,
    if (navigationId != null) 'navigation_id': navigationId,
    if (runId != null) 'run_id': runId,
    if (itemId != null) 'item_id': itemId,
    if (itemType != null) 'item_type': itemType,
    if (blockType != null) 'block_type': blockType,
    if (position != null) 'position': position,
    if (cardIndex != null) 'card_index': cardIndex,
    if (blockId != null) 'block_id': blockId,
    if (surface != null) 'surface': surface,
    if (dwellMs != null) 'dwell_ms': dwellMs,
    if (scrollDepth != null) 'scroll_depth': scrollDepth,
    if (sessionDwellMs != null) 'session_dwell_ms': sessionDwellMs,
    if (engaged != null) 'engaged': engaged,
    if (actionKind != null) 'action_kind': actionKind,
  };
}
