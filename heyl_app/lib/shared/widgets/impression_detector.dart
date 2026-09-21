import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Fires [onImpression] once [child] has stayed >= 70% visible continuously
/// for [dwell]. A card flicked past faster than [dwell] never fires — this
/// filters the "strobe" captures of fast scrolling (cards that were merely
/// mid-screen at a sample tick, not actually seen).
///
/// Dedup across scroll re-entry is the caller's responsibility (the shelf
/// notifier's Set). This widget only guards against firing more than once in
/// its own lifetime via [_fired].
///
/// Note: dwell resolution is bounded by
/// `VisibilityDetectorController.updateInterval` (set globally at app start).
/// [dwell] should be >= ~2x that interval or a single sample tick can satisfy
/// it.
class ImpressionDetector extends StatefulWidget {
  const ImpressionDetector({
    super.key,
    required this.scopeId,
    required this.itemId,
    required this.onImpression,
    required this.child,
    this.dwell = const Duration(milliseconds: 300),
    this.onResolved,
    this.onEngagementQualified,
    this.blockId,
  });

  /// Which surface this detector belongs to — a shelf id, or a feed block plus
  /// its surface class.
  ///
  /// ⚠️ **Required, and required on purpose.** `VisibilityDetector` keys its
  /// bookkeeping in a **static, app-global** map
  /// (`render_visibility_detector.dart`: two `static` maps keyed by `Key` —
  /// `_updates` and `_lastVisibility`), so two
  /// simultaneously-mounted detectors sharing a key corrupt each other in two
  /// silent ways: the later one overwrites the earlier's pending update, and
  /// they share a `_lastVisibility` entry, so one's recorded visibility makes
  /// the other's genuine appearance read as "no change" and the callback is
  /// **suppressed entirely**. The result is an under-count that looks like
  /// nothing at all.
  ///
  /// This key used to be `impr-[itemId]` alone, which was safe only by
  /// construction: one shelf, one list, an entity appearing once. The
  /// server-driven feed voids that — D82 has bundles run their own query, so
  /// one event can be a hero *and* a highlighted bundle row on one page, and
  /// a bundle's see-all page co-exists in the navigator with the feed it was
  /// opened from.
  ///
  /// **The scope must distinguish surfaces, not just containers.** A bundle
  /// and its see-all page share a `block_id`, so scoping on that alone still
  /// collides; pair it with the surface class. Optional would have been the
  /// worse API: it defaults to the broken form, and the next caller to forget
  /// it reintroduces a bug with no symptom.
  final String scopeId;

  final String itemId;
  final VoidCallback onImpression;
  final Widget child;
  final Duration dwell;

  /// Fired when an **exposure episode** ends — the card left the viewport, the
  /// widget was disposed, or the user tapped through
  /// ([ImpressionDetector.resolveForItem]). `dwellMs` is the episode's
  /// accumulated at-threshold visible time; `qualified` is whether the episode
  /// reached the dwell threshold; `endReason` is one of `scrolled_away`,
  /// `tap`, `disposed` (contract v2, PROD-4304/4306).
  ///
  /// **Episodes re-arm.** A short pass (unqualified end) followed by a later
  /// genuine view emits a second resolution — re-entry is a new exposure. An
  /// initial `visibleFraction == 0` callback (below-fold cards on first paint)
  /// neither resolves nor latches anything.
  ///
  /// Independent of [onImpression], which still fires **once per widget
  /// lifetime** at threshold + [dwell] — the seen-suppression contract is
  /// unchanged.
  final void Function(int dwellMs, bool qualified, String endReason)?
  onResolved;

  /// Fired at the moment an episode qualifies (≥70% visible continuously for
  /// [dwell]) — the contract-v2 `impression` emit point. `dwellMs` is the
  /// episode dwell accumulated so far. Fires at most once per episode; a
  /// re-entry episode that qualifies again fires again (the tracker's
  /// session-scoped dedup decides what to keep).
  final void Function(int dwellMs)? onEngagementQualified;

  /// The feed block this detector's card lives in, when there is one. Lets
  /// [resolveForItem] target ONE card of an item that appears in several
  /// blocks at once (hero + bundle row, D82) instead of stamping every copy's
  /// exposure with the tapped card's end reason.
  final String? blockId;

  /// Resolve the current exposure episode of mounted detectors showing
  /// [itemId] — called by the open/action paths **before** the tap/action
  /// event is enqueued, so exposure always precedes it in `seq` order
  /// (PROD-4306: a save/tap must never be credited before exposure).
  ///
  /// With [blockId], only the matching card resolves (plus cards that never
  /// declared a block — the pre-wiring fallback); without it, every copy does.
  /// A `'tap'` resolution also blocks the card from opening a NEW episode
  /// until it has fully left the viewport once — a mid-route-transition
  /// visibility sample must not mint a spurious post-tap impression.
  static void resolveForItem(
    String itemId, {
    String? blockId,
    String endReason = 'tap',
  }) {
    for (final state in List<_ImpressionDetectorState>.of(_mounted)) {
      if (state.widget.itemId != itemId) continue;
      final stateBlock = state.widget.blockId;
      if (blockId != null && stateBlock != null && stateBlock != blockId) {
        continue;
      }
      if (endReason == 'tap') state._blockReopenUntilHidden = true;
      state._resolveEpisode(endReason);
    }
  }

  /// Resolve EVERY mounted detector's open episode — the session tracker's
  /// before-close hook (PROD-4306). Without this, the session's own
  /// `visibleFraction == 0` callback closes the visit before the card
  /// detectors' callbacks fire, and their `exposure_end`s would be dropped by
  /// the tracker's no-live-session guard — censoring dwell on the single most
  /// common exit path (navigation / tab switch / background).
  static void resolveAllOpenEpisodes(String endReason) {
    for (final state in List<_ImpressionDetectorState>.of(_mounted)) {
      state._resolveEpisode(endReason);
    }
  }

  static final Set<_ImpressionDetectorState> _mounted = {};

  @override
  State<ImpressionDetector> createState() => _ImpressionDetectorState();
}

class _ImpressionDetectorState extends State<ImpressionDetector> {
  static const double _threshold = 0.7;
  Timer? _dwellTimer;
  bool _fired = false;

  // Engagement episode bookkeeping (independent of the `_fired`/onImpression
  // path). One "episode" = one exposure: it opens the first time the card is
  // at-threshold visible, accumulates at-threshold time across sub-threshold
  // dips, and closes when the card fully leaves the viewport, is tapped
  // through, or is disposed. Episodes RE-ARM: a closed episode followed by a
  // genuine re-entry opens a new one (contract v2 — re-entry is a new
  // exposure; a short pass no longer swallows a later qualified view).
  //
  // Dwell is a MONOTONIC Stopwatch, per the contract ("durations never use
  // wall clock"): an NTP correction or user clock change mid-episode cannot
  // produce negative or absurd dwell_ms. Start on at-threshold, stop on
  // sub-threshold — the Stopwatch accumulates across dips natively.
  final Stopwatch _visibleClock = Stopwatch();
  bool _episodeQualified = false;

  /// Whether the current episode has ever been at-threshold visible. Guards
  /// the two regression cases: an initial `visibleFraction == 0` callback
  /// (below-fold card on first paint) must neither resolve nor latch, and a
  /// covered-then-revealed card must open a fresh episode.
  bool _episodeOpen = false;

  /// Set by a `'tap'` [ImpressionDetector.resolveForItem]: the card stays
  /// visible under the route transition it just triggered, and a visibility
  /// sample mid-transition must not open (and qualify) a fresh episode for a
  /// card the user has already left. Cleared by a genuine full occlusion.
  bool _blockReopenUntilHidden = false;

  @override
  void initState() {
    super.initState();
    ImpressionDetector._mounted.add(this);
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (info.visibleFraction >= _threshold) {
      // Post-tap gate: the card is still painted under the route transition
      // it just triggered — do not open a fresh episode until it has fully
      // left the viewport once.
      if (_blockReopenUntilHidden) return;
      _episodeOpen = true;
      _visibleClock.start();
      // Arm once per episode; leave a running timer running so continuous
      // visibility accumulates rather than restarting on every tick.
      if (!_episodeQualified) {
        _dwellTimer ??= Timer(widget.dwell, () {
          if (!mounted || _episodeQualified || !_episodeOpen) return;
          _episodeQualified = true;
          if (!_fired) {
            // Seen-suppression rail: once per widget lifetime, unchanged.
            _fired = true;
            widget.onImpression();
          }
          // Engagement rail: the contract-v2 `impression` emit point — at
          // qualification, not at exit (a lost exposure_end no longer loses
          // the impression with it).
          widget.onEngagementQualified?.call(
            _visibleClock.elapsedMilliseconds,
          );
        });
      }
    } else {
      // Dropped below threshold — pause the dwell clock and disarm.
      _visibleClock.stop();
      _dwellTimer?.cancel();
      _dwellTimer = null;
      if (info.visibleFraction == 0) {
        // A genuine full occlusion re-arms a tapped card for real re-entry.
        _blockReopenUntilHidden = false;
        // Fully gone (scrolled away) → the exposure is over. Only if an
        // episode is actually open: the FIRST callback for a below-fold card
        // reports 0, and resolving there latched the old one-shot forever
        // (the missing-impressions-after-initially-zero-visibility
        // regression).
        _resolveEpisode('scrolled_away');
      }
    }
  }

  /// Close the current episode, emit it, and re-arm for the next one.
  void _resolveEpisode(String endReason) {
    if (!_episodeOpen) return;
    _visibleClock.stop();
    _dwellTimer?.cancel();
    _dwellTimer = null;
    final dwellMs = _visibleClock.elapsedMilliseconds;
    final qualified = _episodeQualified;
    _episodeOpen = false;
    _visibleClock.reset();
    _episodeQualified = false;
    // A zero-dwell unqualified episode is noise (a card that technically
    // crossed threshold between two samples), not a soft negative.
    if (dwellMs > 0 || qualified) {
      widget.onResolved?.call(dwellMs, qualified, endReason);
    }
  }

  /// The app-global key this detector's visibility state is filed under.
  Key get _key => ValueKey('impr-${widget.scopeId}-${widget.itemId}');

  @override
  void dispose() {
    ImpressionDetector._mounted.remove(this);
    // Resolve the open episode on unmount too: a card disposed while still on
    // screen never fires the visibleFraction==0 path.
    _resolveEpisode('disposed');
    _dwellTimer?.cancel();
    // **Drop this key's entry from the package's static map**, which nothing
    // else does: `RenderVisibilityDetectorBase.dispose()` cancels its
    // composition callback but never calls `forget`, and the "not visible"
    // branch that would remove the entry only runs if a callback fires — which
    // needs a visibility CHANGE, and an unmount is not one.
    //
    // So a disposed detector leaves its last **visible** info behind. Remount
    // the same key (pop a see-all page, open it again) and `_fireCallback`
    // reads that stale entry, finds `info.matchesVisibility(oldInfo)` — the row
    // is at the same offset in the same list — and **returns without calling
    // back**. The return visit records no impression at all, which is the exact
    // opposite of what `autoDispose` on the tracker is for.
    // Drop this key's entry from the package's static maps. **Nothing in the
    // package does this on unmount** — its only `forget` call sits in the
    // `onVisibilityChanged` setter's null branch, and it does not override
    // `didUnmountRenderObject`.
    //
    // ⚠️ **This is hygiene, not a bug fix, and the distinction is worth
    // keeping honest.** Raised by codex review as a live defect — remount the
    // same key (pop a see-all page, reopen it) and `_fireCallback` would read
    // the stale *visible* entry, find `info.matchesVisibility(oldInfo)`, and
    // return without calling back, so the return visit records nothing. It
    // **does not reproduce**: probed with a real Navigator push/pop/push and
    // this line removed, and the second visit still fired. A frame after
    // detach computes zero visibility and takes `_lastVisibility.remove(key)`.
    //
    // Kept anyway, because that rescue is incidental — it depends on a frame
    // running after detach while the layer is gone, which is a property of
    // today's Flutter and package version, not of this contract. The widget
    // creates the entry; the widget removes it. `impression_detector_test.dart`
    // pins the remount-fires-again property regardless of which mechanism
    // delivers it.
    VisibilityDetectorController.instance.forget(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: _key,
      onVisibilityChanged: _onVisibilityChanged,
      child: widget.child,
    );
  }
}
