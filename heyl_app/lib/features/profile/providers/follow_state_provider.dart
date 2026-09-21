import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/utils/settling_value.dart';
import 'public_profile_providers.dart';

/// App-wide source of truth for follow relationships the viewer has changed this
/// session — the shared "board" every follow button reads and writes.
///
/// Values are `'none' | 'requested' | 'following'` (the same strings the follow
/// buttons already use). A button displays `store[userId] ?? serverSeed`, and
/// taps through [FollowStateStore.toggle]. Because every button `watch`es this
/// provider, a change on one screen rebuilds the same user's button on every
/// other screen instantly — no per-screen cache invalidation, no stale
/// "Follow back".
///
/// It holds ONLY users the viewer touched this session; everyone else falls back
/// to their server value. It intentionally does NOT track whether they follow
/// YOU (the "Follow back" seed) — tapping your own button never changes that, so
/// that axis stays server-seeded per widget. Cleared on restart, when the next
/// fetch is authoritative.
class FollowStateStore extends Notifier<Map<String, String>> {
  /// One [SettlingValue] per user the viewer has tapped. It carries the
  /// relationship the SERVER last confirmed, while `state` carries what the
  /// screen shows — the two differ only while a tap is outrunning the
  /// round-trip.
  final Map<String, SettlingValue<String>> _axes = {};

  /// Bumped per [build]. Answers "was I superseded?", which the map being
  /// cleared does not: a write already in the air belongs to the PREVIOUS
  /// viewer and must not land in this one's store.
  int _generation = 0;

  @override
  Map<String, String> build() {
    // This provider is user-scoped, so an A→B account switch invalidates it —
    // but Riverpod 2.6 REUSES the notifier instance across a rebuild. `state`
    // resets; anything hanging off a field does not.
    //
    // Leaving `_axes` in place carries A's confirmed relationships into B's
    // session, and it fails silently: B taps Follow on someone A already
    // followed, the drain sees truth == target, sends NOTHING, and the button
    // paints "Following" over a follow edge that does not exist.
    _axes.clear();
    _generation++;
    return const {};
  }

  /// Record the viewer's relationship to [userId] after a mutation this store
  /// did not run — the bulk "follow all" path, which walks distinct users and
  /// so has no re-tap to converge.
  void set(String userId, String relationship) {
    _axisFor(userId, relationship).supersede(relationship);
    state = {...state, userId: relationship};
  }

  /// Whether a write for [userId] is in the air or queued behind one. The
  /// button stays tappable regardless — this is for callers that must not treat
  /// the painted relationship as confirmed yet.
  bool isSettling(String userId) => _axes[userId]?.settling ?? false;

  /// Flip [userId] between followed and not, painting the new state instantly.
  ///
  /// [seedRel] is the widget's server-seeded relationship, used only the first
  /// time this user is touched. Returns the relationship the server confirmed,
  /// or `null` when the write failed (the paint is reverted) or when a newer tap
  /// is still converging — in both cases there is nothing settled to act on.
  ///
  /// **Never drops a tap.** A tap made while a write is out paints immediately
  /// and is queued; the running loop sends it once the first write answers.
  Future<String?> toggle({
    required String userId,
    required String seedRel,
    required String source,
    bool followsYou = false,
    bool isSoko = false,
  }) async {
    final generation = _generation;
    final axis = _axisFor(userId, seedRel);
    final shown = state[userId] ?? seedRel;
    final wasActive = shown == 'following' || shown == 'requested';
    // Optimistic. A private account confirms as 'requested', but every follow
    // control renders 'requested' and 'following' the same way, so painting
    // 'following' cannot mis-render in the gap.
    final desired = axis.intend(wasActive ? 'none' : 'following');
    state = {...state, userId: desired};

    String? settled;
    await axis.drain(
      write: (from, to) => _write(
        userId,
        from,
        to,
        source: source,
        followsYou: followsYou,
        isSoko: isSoko,
      ),
      onSettled: (truth) {
        settled = truth;
        state = {...state, userId: truth};
      },
      onFailed: (_, truth) {
        // Nothing landed — fall back to what the server last confirmed.
        state = {...state, userId: truth};
      },
      // No `onWrote`: here the store IS the screen, and a landed write with a
      // newer tap queued behind it must not repaint over that tap.
      //
      // `isAlive` is the account-switch guard, not a disposal one: this
      // provider is never torn down mid-session. A write that outlives the
      // purge belongs to the viewer who left.
      isAlive: () => generation == _generation,
    );
    return settled;
  }

  /// Run a telemetry call so a failure inside it cannot fail the mutation that
  /// already succeeded. Swallows deliberately: there is nothing a caller could
  /// do about a dropped analytics event, and the alternative — letting it
  /// bubble — reverts a confirmed follow on screen.
  ///
  /// ⚠️ **Load-bearing, and the reason is one layer up.** A throw out of
  /// [_write] reaches `SettlingValue.drain`, whose contract is "onFailed fires
  /// once if a write throws, and the queue is dropped" — so the paint falls
  /// back to server truth and the user sees their follow undone, although the
  /// server accepted it. Telemetry must never decide whether a mutation counts.
  ///
  /// Restored when release/people-feed merged into develop (2026-09-17). The
  /// guard shipped in PROD-4521 on `applyFollowToggle`, which #1671 replaced
  /// with this store — the rewrite dropped it and reintroduced the defect on
  /// all eleven follow surfaces. Pinned by
  /// `feed_people_grid_impressions_test.dart` → "a PostHog failure cannot
  /// swallow the ledger row", which fails without this.
  void _safely(void Function() emit) {
    try {
      emit();
    } catch (_) {
      // Intentionally ignored; see the call sites.
    }
  }

  /// The network call plus its confirmed-only side effects. Runs after the
  /// await, so analytics count writes the server accepted and never optimistic
  /// taps it later rejected.
  Future<String> _write(
    String userId,
    String from,
    String to, {
    required String source,
    required bool followsYou,
    required bool isSoko,
  }) async {
    final api = ref.read(followsApiProvider);
    final analytics = ref.read(unifiedAnalyticsProvider);
    final actionContext = analytics.actionContext;
    final String next;
    if (to == 'none') {
      await api.unfollow(userId);
      next = 'none';
      _safely(
        () => analytics.trackUserUnfollow(
          actionContext: actionContext,
          targetUserId: userId,
          source: source,
          // 'requested' here means a cancelled pending request, a different
          // signal from unfollowing an accepted follow.
          previousState: from,
          isSoko: isSoko,
        ),
      );
    } else {
      final res = await api.follow(userId);
      next = res.requested ? 'requested' : 'following';
      _safely(
        () => analytics.trackUserFollow(
          actionContext: actionContext,
          targetUserId: userId,
          source: source,
          resultingState: next,
          isSoko: isSoko,
          wasFollowBack: followsYou,
        ),
      );
    }
    // My own "following" count is optimistic too, so it tracks the tap wherever
    // I am rather than waiting for a profile refetch.
    final delta = followingCountDelta(from, next);
    if (delta != 0) {
      ref.read(myFollowingCountDeltaProvider.notifier).bump(delta);
    }
    return next;
  }

  SettlingValue<String> _axisFor(String userId, String seedRel) =>
      _axes.putIfAbsent(userId, () => SettlingValue<String>(seedRel));
}

final followStateProvider =
    NotifierProvider<FollowStateStore, Map<String, String>>(
      FollowStateStore.new,
    );
