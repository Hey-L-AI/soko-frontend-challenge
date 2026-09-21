import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/discovery_engagement.dart';
import 'discovery_engagement_sender.dart';

/// Presentation context remembered per item so a later `action` (whose call
/// site — save sheet, follow toggle, thumb — has no block in hand) inherits
/// the provenance of the exposure that earned it, instead of falling back to
/// the latest fetched page's run (the latest-page-attribution gap, but for
/// actions).
class _ItemContext {
  final String? runId;
  final String? blockId;
  final String? blockType;
  final String? surface;
  const _ItemContext({this.runId, this.blockId, this.blockType, this.surface});
}

/// One in-flight detail navigation (PROD-4307): minted at tap, closed when
/// the pushed route pops. Holds the ORIGIN session id — the visit the tap
/// belonged to, which the detail's own occlusion of the feed will close —
/// and a foreground-only monotonic dwell clock (paused while backgrounded).
class _DetailNavigation {
  final String originSessionId;
  final String itemId;
  final String itemType;
  final String? runId;
  final String? blockId;
  final String? blockType;
  final String? surface;
  final Stopwatch dwell = Stopwatch()..start();
  _DetailNavigation({
    required this.originSessionId,
    required this.itemId,
    required this.itemType,
    this.runId,
    this.blockId,
    this.blockType,
    this.surface,
  });
}

/// Owns one **discovery session** — a foreground feed visit — and turns feed
/// interactions into engagement events on the [DiscoveryEngagementSender]
/// (PROD-4257, contract v2 PROD-4304/4306).
///
/// A visit spans several page fetches, each with its own server `run_id`; the
/// tracker's [_sessionId] stitches them. Every event is stamped with an
/// immutable `event_id` (UUIDv4, stable across retries — the ledger's
/// idempotency key) and a per-session `seq` so readers can order a visit
/// without trusting the client clock.
///
/// **Lifecycle.** The owning screen drives [startSession]/[endSession] from
/// **route/tab visibility**, not widget mount — navigating to a detail ends
/// feed-visible time, returning opens a fresh visit. The tracker also observes
/// app lifecycle: backgrounding ends the session, and returning re-opens a
/// fresh one if a screen still wants tracking — so a visit never silently
/// spans a background gap. Durations use a monotonic [Stopwatch], never wall
/// clock.
class DiscoverySessionTracker with WidgetsBindingObserver {
  DiscoverySessionTracker(this._sender, {DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc()) {
    WidgetsBinding.instance.addObserver(this);
  }

  final DiscoveryEngagementSender _sender;
  final DateTime Function() _now;
  final _uuid = const Uuid();

  String? _sessionId;

  /// True between [startSession] and [endSession] from the screen's point of
  /// view — distinct from whether a session id is currently live. Lets a
  /// background→foreground round-trip re-open a session the screen never left.
  bool _wantActive = false;

  /// Discovery surfaces currently visible ([acquireSurface]/[releaseSurface]).
  /// The session closes only when the LAST surface releases — a feed →
  /// see-all transition (both discovery surfaces) keeps one visit alive, and
  /// the [_closeLinger] debounce below absorbs the callback-ordering window
  /// where the outgoing surface reports hidden before the incoming one
  /// reports visible.
  final Set<String> _heldSurfaces = {};
  Timer? _closeTimer;
  static const Duration _closeLinger = Duration(milliseconds: 800);

  /// PROD-4532 — the filter on screen as a visit OPENS, or null when there is
  /// none to report. Invoked immediately after `session_start` is enqueued, so
  /// the resulting `context_changed` is always `seq 1`.
  ///
  /// **Why a hook rather than a call at the mount site.** Per-filter dwell is
  /// the time between consecutive `context_changed` beats inside a visit, so
  /// every visit needs an opening marker, not just the ones a screen mounts
  /// for. [_open] is reached from three places — [acquireSurface] (the feed's
  /// `initState` and the `VisibilityDetector` re-acquire),
  /// [didChangeAppLifecycleState] on resume, and [handleIdentityChange]. A call
  /// placed next to `acquireSurface` in `initState` covers the first and misses
  /// the other two, leaving those visits with an unattributable first segment.
  /// Putting it here makes "every open gets a beat" structural.
  ///
  /// Wired once at provider construction, exactly as [beforeClose] is.
  String? Function()? onOpen;

  /// Invoked with the close reason IMMEDIATELY before `session_end` is
  /// enqueued — the seam [ImpressionDetector.resolveAllOpenEpisodes] hangs on,
  /// so every open exposure resolves INTO the closing session rather than
  /// being dropped by the no-live-session guard after it. Wired once at
  /// provider construction.
  void Function(String reason)? beforeClose;

  /// Presentation context per item id, remembered from the exposures/taps of
  /// this session (see [_ItemContext]). Cleared per visit.
  final Map<String, _ItemContext> _itemContext = {};

  /// In-flight detail navigations by navigation id (PROD-4307). NOT cleared
  /// on session close — the detail visit outlives the feed session it came
  /// from by design, and its event is attributed to the origin session.
  final Map<String, _DetailNavigation> _detailNavigations = {};

  /// Monotonic foreground clock for `session_dwell_ms` — immune to wall-clock
  /// adjustments mid-visit (contract v2: durations use monotonic time).
  final Stopwatch _visitClock = Stopwatch();
  bool _engaged = false;

  /// Per-session monotonically increasing event sequence.
  int _seq = 0;

  /// Feed-global slot ordering for scroll depth. The home feed has no global
  /// slate index, so slots are ordinalized in **first-observed order** — users
  /// scroll top-down, so the order slots first report visibility approximates
  /// display order, and unlike the old per-block `cardIndex` it never resets
  /// to zero at each block boundary (the
  /// per-block-index-reported-as-global-depth gap). Flat feeds that do carry a
  /// served `position` use it directly.
  final Map<String, int> _slotOrdinals = {};
  int _deepestSlot = -1;

  /// The `run_id` of the most recently fetched page this visit — the
  /// **fallback only**. Contract v2 attribution is per-item: blocks pass their
  /// own block/page `run_id` explicitly and this default covers legacy call
  /// sites, so a `loadMore` no longer re-tags still-mounted run-A cards with
  /// run B (the latest-page-attribution gap).
  String? _currentRunId;

  /// The session id of the visit currently in progress, or null when none.
  String? get sessionId => _sessionId;

  /// Record the run_id of the page just fetched. Called by the feed notifier on
  /// every fetch; null pages (run logging off / composed feed) clear it.
  void setCurrentRunId(String? runId) => _currentRunId = runId;

  /// A discovery surface (feed page, bundle see-all) became visible. The
  /// session opens on the first acquire and STAYS open while any surface
  /// holds it — one visit spans feed → see-all → feed. Idempotent per tag.
  void acquireSurface(String tag) {
    _heldSurfaces.add(tag);
    _wantActive = true;
    _closeTimer?.cancel();
    _closeTimer = null;
    if (_sessionId == null) _open();
  }

  /// A discovery surface fully left view. When it was the LAST one, the close
  /// is debounced by [_closeLinger]: an incoming discovery surface's acquire
  /// (delivered in a later visibility sweep) cancels it, so a feed → see-all
  /// hand-over never splits or drops the visit. Navigation to a NON-discovery
  /// surface (detail, another tab) lets the timer fire and the visit closes.
  void releaseSurface(String tag, {String reason = 'screen_hidden'}) {
    _heldSurfaces.remove(tag);
    if (_heldSurfaces.isNotEmpty || _sessionId == null) return;
    _wantActive = false;
    _closeTimer?.cancel();
    _closeTimer = Timer(_closeLinger, () {
      _closeTimer = null;
      _close(reason);
    });
  }

  /// Begin a feed visit. Idempotent: a second call while a session is live is a
  /// no-op, so a screen that re-runs `initState`-style wiring does not mint a
  /// second visit. Legacy alias of [acquireSurface] for the mount-driven
  /// call sites; visibility-driven screens use acquire/release directly.
  void startSession() => acquireSurface('screen');

  /// End the current feed visit IMMEDIATELY (no linger), emitting
  /// `session_end` with the aggregates and flushing so the visit lands even
  /// if the app is about to be torn down. [reason] names why the visit closed
  /// (`navigation`, `screen_hidden`, `background`, `sign_out`, `disposed`).
  void endSession({String reason = 'navigation'}) {
    _heldSurfaces.clear();
    _wantActive = false;
    _closeTimer?.cancel();
    _closeTimer = null;
    _close(reason);
  }

  /// The signed-in actor changed (sign-out / account switch). Everything
  /// observed under the old actor is abandoned WITHOUT emitting: the buffered
  /// events are dropped (identity epoch — they must never post under the new
  /// actor's token) and the live session state is discarded rather than
  /// closed, because a `session_end` enqueued now would itself cross the
  /// epoch. If a discovery surface is still visible, a fresh session opens
  /// for the new actor.
  void handleIdentityChange() {
    _sender.clearForIdentityChange();
    _closeTimer?.cancel();
    _closeTimer = null;
    _sessionId = null;
    _visitClock.stop();
    _itemContext.clear();
    // Pending detail navigations belong to the OLD actor's visit — a later
    // pop must not emit their dwell under the new actor's token.
    _detailNavigations.clear();
    if (_heldSurfaces.isNotEmpty) _open();
  }

  void _open() {
    _sessionId = _uuid.v4();
    _seq = 0;
    _visitClock
      ..reset()
      ..start();
    _slotOrdinals.clear();
    _itemContext.clear();
    _deepestSlot = -1;
    _engaged = false;
    _enqueue(_sessionId!, eventKind: DiscoveryEngagementKind.sessionStart);
    // PROD-4532 — the opening filter beat, straight after `session_start` so it
    // is `seq 1`. Per-filter dwell reads the gap between consecutive
    // `context_changed` beats, and without this the FIRST segment of every
    // visit has no opening marker to measure from.
    //
    // ⚠️ **After the enqueue above, never before.** [contextChanged] no-ops
    // when no session is live, so a beat emitted before the id is minted would
    // silently vanish — and the symptom is a missing row, not an error.
    final openingFilter = onOpen?.call();
    if (openingFilter != null) {
      contextChanged(context: 'filter:$openingFilter');
    }
  }

  void _close(String reason) {
    _closeTimer?.cancel();
    _closeTimer = null;
    final id = _sessionId;
    if (id == null) return;
    // Resolve every open exposure episode INTO this session first — the
    // card detectors' own zero-visibility callbacks arrive after the
    // session wrapper's in the same sweep and would otherwise be dropped.
    beforeClose?.call(reason);
    _visitClock.stop();
    _enqueue(
      id,
      eventKind: DiscoveryEngagementKind.sessionEnd,
      scrollDepth: _deepestSlot >= 0 ? _deepestSlot : null,
      sessionDwellMs: _visitClock.elapsedMilliseconds,
      engaged: _engaged,
      endReason: reason,
    );
    _sessionId = null;
    // A visit boundary is a natural flush point — don't let the last visit sit
    // in the buffer behind the debounce.
    _sender.flush();
  }

  /// A served page's blocks actually rendered (contract v2 `page_presented`) —
  /// separates delivered candidates from presented content.
  void pagePresented({String? runId, String? surface}) {
    final id = _sessionId;
    if (id == null) return;
    _enqueue(
      id,
      eventKind: DiscoveryEngagementKind.pagePresented,
      runId: runId ?? _currentRunId,
      surface: surface,
    );
  }

  /// Filter/mode change, refresh, or slate paging (contract v2
  /// `context_changed`). [context] is the structured label (e.g.
  /// `filter:events`, `refresh`, `page:2`).
  void contextChanged({required String context, String? surface}) {
    final id = _sessionId;
    if (id == null) return;
    _enqueue(
      id,
      eventKind: DiscoveryEngagementKind.contextChanged,
      blockType: context,
      surface: surface,
    );
  }

  /// A card qualified as seen — emitted **at qualification time** from
  /// [ImpressionDetector.onEngagementQualified]. Once per exposure episode;
  /// repeat episodes are legitimate repeat impressions (never collapsed).
  void impression({
    required String itemId,
    required String itemType,
    String? runId,
    String? blockType,
    String? blockId,
    String? surface,
    int? position,
    int? cardIndex,
    int? dwellMs,
  }) {
    _observeSlot(position, cardIndex, blockId);
    _emitItem(
      DiscoveryEngagementKind.impression,
      itemId: itemId,
      itemType: itemType,
      runId: runId,
      blockType: blockType,
      blockId: blockId,
      surface: surface,
      position: position,
      cardIndex: cardIndex,
      dwellMs: dwellMs,
    );
  }

  /// An exposure episode ended ([ImpressionDetector.onResolved], contract v2
  /// `exposure_end`). Carries the episode's full at-threshold dwell,
  /// `engaged` = whether it qualified, and the end reason. A zero-dwell
  /// unqualified episode is dropped as noise.
  void exposureEnd({
    required int dwellMs,
    required bool qualified,
    required String endReason,
    required String itemId,
    required String itemType,
    String? runId,
    String? blockType,
    String? blockId,
    String? surface,
    int? position,
    int? cardIndex,
  }) {
    if (dwellMs <= 0 && !qualified) return;
    _observeSlot(position, cardIndex, blockId);
    _emitItem(
      DiscoveryEngagementKind.exposureEnd,
      itemId: itemId,
      itemType: itemType,
      runId: runId,
      blockType: blockType,
      blockId: blockId,
      surface: surface,
      position: position,
      cardIndex: cardIndex,
      dwellMs: dwellMs,
      engaged: qualified,
      endReason: endReason,
    );
  }

  /// The user opened a card (or a container affordance — a bundle header /
  /// "see all"). Marks the visit engaged. The caller resolves the card's
  /// pending exposure first ([ImpressionDetector.resolveForItem]) so the
  /// exposure precedes the tap in `seq` order.
  void tap({
    required String itemId,
    required String itemType,
    String? runId,
    String? blockType,
    String? blockId,
    String? surface,
    int? position,
    int? cardIndex,
    String? navigationId,
  }) {
    _engaged = true;
    _observeSlot(position, cardIndex, blockId);
    _emitItem(
      DiscoveryEngagementKind.tap,
      itemId: itemId,
      itemType: itemType,
      runId: runId,
      blockType: blockType,
      blockId: blockId,
      surface: surface,
      position: position,
      cardIndex: cardIndex,
      navigationId: navigationId,
    );
  }

  /// A card open is navigating to the item's detail (PROD-4307). Mints the
  /// `navigation_id` that joins the `tap` to the `detail_engagement` the
  /// navigation produces, and starts a foreground-only monotonic dwell clock.
  /// Returns null with no live session — a detail opened outside a visit has
  /// no origin to attribute to, and emits nothing.
  String? beginDetailNavigation({
    required String itemId,
    required String itemType,
    String? runId,
    String? blockType,
    String? blockId,
    String? surface,
  }) {
    final origin = _sessionId;
    if (origin == null) return null;
    final navId = _uuid.v4();
    _detailNavigations[navId] = _DetailNavigation(
      originSessionId: origin,
      itemId: itemId,
      itemType: itemType,
      runId: runId,
      blockId: blockId,
      blockType: blockType,
      surface: surface,
    );
    return navId;
  }

  /// The detail route pushed for [navigationId] popped — emit
  /// `detail_engagement` with the foreground dwell, attributed to the
  /// ORIGINATING session (deliberately: the feed session underneath closed
  /// when the detail covered it, and the dwell belongs to the visit whose tap
  /// earned it). `seq` is omitted — the origin session's counter is gone;
  /// readers order this event by `occurred_at`/`navigation_id`.
  void endDetailNavigation(String? navigationId) {
    if (navigationId == null) return;
    final nav = _detailNavigations.remove(navigationId);
    if (nav == null) return;
    nav.dwell.stop();
    // Deeper navigation from the detail counts as continued engagement with
    // what the card opened; a zero-dwell pop (instant back) is still a fact.
    _enqueue(
      nav.originSessionId,
      eventKind: DiscoveryEngagementKind.detailEngagement,
      runId: nav.runId,
      navigationId: navigationId,
      itemId: nav.itemId,
      itemType: nav.itemType,
      blockType: nav.blockType,
      blockId: nav.blockId,
      surface: nav.surface,
      dwellMs: nav.dwell.elapsedMilliseconds,
      withSeq: false,
    );
  }

  /// A **confirmed** downstream reaction on a feed card (save / unsave / like /
  /// dislike / share / going / un_going) — emitted after the backend mutation
  /// succeeds, never on optimistic UI. Marks the visit engaged.
  ///
  /// Context an action call site cannot supply (the save sheet / follow
  /// toggle / thumb has no block in hand) is inherited from THIS session's
  /// remembered exposure/tap of the same item — the provenance that actually
  /// earned the action — never from the latest fetched page's run.
  void action({
    required String actionKind,
    required String itemId,
    required String itemType,
    String? runId,
    String? blockType,
    String? blockId,
    String? surface,
    int? position,
    int? cardIndex,
  }) {
    _engaged = true;
    final remembered = _itemContext[itemId];
    _emitItem(
      DiscoveryEngagementKind.action,
      itemId: itemId,
      itemType: itemType,
      runId: runId ?? remembered?.runId,
      blockType: blockType ?? remembered?.blockType,
      blockId: blockId ?? remembered?.blockId,
      surface: surface ?? remembered?.surface,
      position: position,
      cardIndex: cardIndex,
      actionKind: actionKind,
    );
  }

  void _emitItem(
    String kind, {
    required String itemId,
    required String itemType,
    String? runId,
    String? blockType,
    String? blockId,
    String? surface,
    int? position,
    int? cardIndex,
    int? dwellMs,
    bool? engaged,
    String? actionKind,
    String? endReason,
    String? navigationId,
  }) {
    final id = _sessionId;
    // No live session → drop. An interaction with no visit to attach to has no
    // slate to join and no session to stitch; recording it would create an
    // orphan row. In practice the screen opens the session before it can be
    // interacted with (and [beforeClose] resolves open exposures INTO a
    // closing session before this guard could drop them).
    if (id == null) return;
    // Remember the presentation context this item was last exposed/tapped
    // under, so a later `action` from a context-less call site inherits it.
    if (kind != DiscoveryEngagementKind.action &&
        (runId != null || blockId != null)) {
      _itemContext[itemId] = _ItemContext(
        runId: runId,
        blockId: blockId,
        blockType: blockType,
        surface: surface,
      );
    }
    _enqueue(
      id,
      eventKind: kind,
      runId: runId ?? _currentRunId,
      navigationId: navigationId,
      itemId: itemId,
      itemType: itemType,
      blockType: blockType,
      blockId: blockId,
      surface: surface,
      position: position,
      cardIndex: cardIndex,
      dwellMs: dwellMs,
      engaged: engaged,
      actionKind: actionKind,
      endReason: endReason,
    );
  }

  /// Single enqueue point: stamps `event_id` + `seq` on every event so nothing
  /// reaches the sender without the contract-v2 envelope. [withSeq] false
  /// omits the sequence — used for events attributed to an already-closed
  /// session (detail engagement), whose counter is gone.
  void _enqueue(
    String sessionId, {
    required String eventKind,
    String? runId,
    String? itemId,
    String? itemType,
    String? blockType,
    String? blockId,
    String? surface,
    int? position,
    int? cardIndex,
    int? dwellMs,
    int? scrollDepth,
    int? sessionDwellMs,
    bool? engaged,
    String? actionKind,
    String? endReason,
    String? navigationId,
    bool withSeq = true,
  }) {
    _sender.enqueue(
      sessionId,
      DiscoveryEngagementEventIn(
        eventId: _uuid.v4(),
        seq: withSeq ? _seq++ : null,
        navigationId: navigationId,
        eventKind: eventKind,
        occurredAt: _now(),
        runId: runId,
        itemId: itemId,
        itemType: itemType,
        blockType: blockType,
        blockId: blockId,
        surface: surface,
        position: position,
        cardIndex: cardIndex,
        dwellMs: dwellMs,
        scrollDepth: scrollDepth,
        sessionDwellMs: sessionDwellMs,
        engaged: engaged,
        actionKind: actionKind,
        endReason: endReason,
      ),
    );
  }

  /// Feed-global scroll depth. A served `position` (flat `/discovery` result)
  /// is used directly; block-composed feeds ordinalize `(blockId, cardIndex)`
  /// slots in first-observed order — monotonic across blocks, unlike the raw
  /// per-block index that reset to zero at every block boundary.
  void _observeSlot(int? position, int? cardIndex, String? blockId) {
    int? slot;
    if (position != null) {
      slot = position;
    } else if (cardIndex != null) {
      final key = '${blockId ?? ''}#$cardIndex';
      slot = _slotOrdinals.putIfAbsent(key, () => _slotOrdinals.length);
    }
    if (slot != null && slot > _deepestSlot) _deepestSlot = slot;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // A visit ends when the app leaves the foreground. Keep [_wantActive] so
      // returning re-opens a fresh visit for a screen that never left.
      _close('background');
      // Detail dwell is FOREGROUND time only — pause every in-flight
      // navigation's clock; the visit-level close above does not end them
      // (the detail is still the top route and resumes with the app).
      for (final nav in _detailNavigations.values) {
        nav.dwell.stop();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_wantActive && _sessionId == null) _open();
      for (final nav in _detailNavigations.values) {
        nav.dwell.start();
      }
    }
  }

  void dispose() {
    _closeTimer?.cancel();
    _closeTimer = null;
    _close('disposed');
    WidgetsBinding.instance.removeObserver(this);
  }
}
