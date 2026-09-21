import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/lists_provider.dart';
import '../../moderation/providers/blocked_users_provider.dart';
import 'paged_shelf_state.dart';

/// Page size and drain cap for paginated fetches. Mirrors the Yours
/// shelf provider — see [yoursShelfProvider] for the rationale on the
/// uncapped initial drain vs the capped `loadMore` drain.
///
/// PROD-2091 — Following had no client-side filter at v1. PROD-2128
/// added the unfollow-tombstone filter so an unfollowed list drops out
/// of the shelf before the next BE refetch; the drain may now need a
/// second iteration when the first page is dominated by tombstoned
/// entries.
const int _pageSize = 10;
const int _maxLoadMoreDrainIterations = 5;

/// PROD-2091 — sibling to [yoursShelfProvider]. Powers the Following
/// shelf surfaced on the Yours page when the toggle flips to "Following":
/// the lists this user has followed (via `POST /lists/{id}/follow`).
///
/// Two paths feed the shelf state:
/// 1. **Initial load** — `GET /api/v1/app/users/me/lists/following?limit=10&offset=0`
///    via the `listsApiProvider`. The API client flattens follow-row
///    envelopes into bare [UserList]s and synthesises `total =
///    items.length` when the BE omits the field — which is why the
///    end-of-stream signal is length-based, not total-based.
/// 2. **In-place patches** — listens to [listsProvider] for cover
///    edits, renames, follow / unfollow toggles, etc. so the shelf
///    reflects mutations without a BE roundtrip.
///
/// PROD-2128 — unfollow tombstones. After
/// `UnifiedListNotifier.toggleFollow()` succeeds in unfollow direction,
/// `listsProvider.markListUnfollowed()` adds the id to
/// [ListsState.recentlyUnfollowedListIds]. This shelf filters that set
/// at both fetch time ([_drain]) and patch time
/// ([_onListsProviderChanged]) so an unfollowed card disappears
/// immediately without waiting for the user to navigate away and back.
///
/// PROD-2130 — re-follow restoration. The reverse direction (`unfollow
/// → re-follow` from the list-detail page) lacked symmetric handling:
/// the tombstone left the set but the shelf items were never rebuilt
/// to include the card, so the list stayed invisible until the Yours
/// section itself unmounted and the provider was disposed (which then
/// rebuilt from BE). The listener now tracks ids that *leave* the
/// tombstone set and re-inserts the matching [UserList] from
/// [ListsState.followingLists] (which `UnifiedListNotifier.toggleFollow`
/// refreshes from the BE after a successful follow). When the un-tombstone
/// and the `followingLists` refresh land in different ticks (the common
/// case — `markListFollowed` is sync, `_refreshFollowingLists` awaits BE),
/// the pending id is queued and resolved on the next listener call.
final followingShelfProvider =
    AsyncNotifierProvider.autoDispose<FollowingShelfNotifier, PagedShelfState>(
      FollowingShelfNotifier.new,
    );

class FollowingShelfNotifier extends AutoDisposeAsyncNotifier<PagedShelfState> {
  // PROD-2091 — bumped on every `build()` and every `_fetchAndAppend()`
  // call. An in-flight fetch captures the version at start and discards
  // late responses when the version moves (rebuild, concurrent
  // `loadMore`, etc.).
  int _currentVersion = 0;

  // Set in the `ref.onDispose` callback so post-await writes can
  // short-circuit cleanly. Riverpod 2.6.x doesn't expose `ref.mounted`
  // on `AutoDisposeAsyncNotifierProviderRef`.
  bool _disposed = false;

  // PROD-2130 — ids that just left `recentlyUnfollowedListIds` (i.e.
  // the user re-followed a list whose card was hidden by the tombstone
  // filter). Drained as each id surfaces in `next.followingLists` on
  // subsequent listener calls.
  final Set<String> _pendingRefollowIds = {};

  @override
  Future<PagedShelfState> build() async {
    final fetchVersion = ++_currentVersion;
    // Riverpod runs the PREVIOUS build's `onDispose` before a rebuild, not
    // only on a real teardown, and preserves this notifier instance across
    // builds — so without clearing it here the flag latches on the first
    // rebuild and every guard below silently wins forever. `_currentVersion`
    // is what answers "superseded"; this only answers "gone".
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
    });

    ref.listen(listsProvider, _onListsProviderChanged);
    // PROD-2264 follow-up — when the viewer blocks a user, drop that
    // author's lists from the shelf without a refetch.
    ref.listen<Set<String>>(blockedUserIdsProvider, _onBlockedIdsChanged);

    final result = await _drain(
      offset: 0,
      maxIterations: null, // uncapped on initial load
    );
    if (fetchVersion != _currentVersion) {
      throw StateError('Superseded by newer build');
    }
    return PagedShelfState(
      items: result.visibleItems,
      nextOffset: result.rawCount,
      hasMore: result.hasMore,
      isLoadingMore: false,
      loadMoreError: null,
    );
  }

  Future<void> loadMore() async {
    final initial = state.valueOrNull;
    if (initial == null) return;
    if (!initial.hasMore ||
        initial.isLoadingMore ||
        initial.loadMoreError != null) {
      return;
    }
    await _fetchAndAppend(initial);
  }

  Future<void> retryLoadMore() async {
    final initial = state.valueOrNull;
    if (initial == null) return;
    if (initial.isLoadingMore) return;
    // Reuse the already-cleared snapshot to avoid a `.value!` re-read
    // (banned by `check-error-handling-discipline`; see
    // [`learnings/asyncvalue-value-throws-on-error.md`]).
    final cleared = initial.copyWith(clearLoadMoreError: true);
    state = AsyncData(cleared);
    await _fetchAndAppend(cleared);
  }

  Future<void> _fetchAndAppend(PagedShelfState initial) async {
    final fetchVersion = ++_currentVersion;
    state = AsyncData(
      initial.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );

    try {
      final next = await _drain(
        offset: initial.nextOffset,
        maxIterations: _maxLoadMoreDrainIterations,
      );
      if (_disposed) return;
      if (fetchVersion != _currentVersion) return;

      // Re-read `state.value` after the await — `listsProvider`
      // listener patches that landed during the fetch would otherwise
      // be clobbered by `initial.copyWith(...)`. `valueOrNull` per team
      // discipline; the `?? initial` fallback covers the
      // shouldn't-happen case where state flipped out of `AsyncData`
      // (already caught by `_disposed` + version-token guards above).
      final current = state.valueOrNull ?? initial;
      final merged = _dedupeAppend(current.items, next.visibleItems);
      state = AsyncData(
        current.copyWith(
          items: merged,
          nextOffset: current.nextOffset + next.rawCount,
          hasMore: next.hasMore,
          isLoadingMore: false,
          clearLoadMoreError: true,
        ),
      );
    } catch (e, _) {
      if (_disposed) return;
      if (fetchVersion != _currentVersion) return;
      final current = state.valueOrNull ?? initial;
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: e),
      );
    }
  }

  Future<PagedDrainResult> _drain({
    required int offset,
    required int? maxIterations,
  }) async {
    final api = ref.read(listsApiProvider);
    int rawCount = 0;
    final visible = <UserList>[];
    var currentOffset = offset;
    var iterations = 0;
    var reachedEnd = false;
    while (true) {
      if (maxIterations != null && iterations >= maxIterations) break;
      iterations++;
      final response = await api.listFollowedLists(
        limit: _pageSize,
        offset: currentOffset,
      );
      rawCount += response.items.length;
      // PROD-2128 — drop lists tombstoned by `markListUnfollowed`.
      // Read on each iteration so a concurrent unfollow during the
      // drain takes effect on the next page. `rawCount` still tracks
      // unfiltered length so `nextOffset` keeps marching the BE
      // pointer; if the entire page is tombstoned, the drain loops to
      // backfill toward at least one visible item.
      // PROD-2264 follow-up — also drop lists authored by blocked
      // users, same mechanic (read on each iteration so a block during
      // the drain takes effect on the next page).
      final tombstones = ref.read(listsProvider).recentlyUnfollowedListIds;
      final blockedAuthors = ref.read(blockedUserIdsProvider);
      visible.addAll(
        response.items.where(
          (l) =>
              !tombstones.contains(l.id) && !blockedAuthors.contains(l.ownerId),
        ),
      );
      if (response.items.length < _pageSize) {
        reachedEnd = true;
        break;
      }
      if (visible.isNotEmpty) break;
      currentOffset += response.items.length;
    }
    return PagedDrainResult(
      rawCount: rawCount,
      visibleItems: visible,
      hasMore: !reachedEnd,
    );
  }

  List<UserList> _dedupeAppend(
    List<UserList> existing,
    List<UserList> incoming,
  ) {
    final seen = {for (final l in existing) l.id};
    return [...existing, ...incoming.where((l) => seen.add(l.id))];
  }

  /// PROD-2264 follow-up — react to a block landing while the shelf is
  /// already populated. Mirrors the tombstone-add branch of
  /// [_onListsProviderChanged]: compute the new ids, drop matching
  /// items in place, re-emit state if anything changed. No refetch.
  void _onBlockedIdsChanged(Set<String>? previous, Set<String> next) {
    final current = state.valueOrNull;
    if (current == null) return;
    final prev = previous ?? const <String>{};
    final newlyBlocked = next.difference(prev);
    if (newlyBlocked.isEmpty) return;
    final filtered = current.items
        .where((l) => !newlyBlocked.contains(l.ownerId))
        .toList();
    if (filtered.length == current.items.length) return;
    state = AsyncData(current.copyWith(items: filtered));
  }

  void _onListsProviderChanged(ListsState? previous, ListsState next) {
    final current = state.valueOrNull;
    if (current == null) return;

    // PROD-2128 — react to new unfollow tombstones. Compute the
    // additions whenever the set instance changed (identity is the
    // cheap short-circuit: `markListUnfollowed` returns early when the
    // id was already tombstoned, so identical(prev, next) catches the
    // no-op case). Comparing by length would silently miss the
    // cap-rolling case (at 50 entries, a new tombstone drops the oldest
    // and length stays 50 — the new id is still in `difference`).
    final prevTombstones =
        previous?.recentlyUnfollowedListIds ?? const <String>{};
    final nextTombstones = next.recentlyUnfollowedListIds;
    final tombstonesChanged = !identical(nextTombstones, prevTombstones);
    final newlyTombstoned = tombstonesChanged
        ? nextTombstones.difference(prevTombstones)
        : const <String>{};
    // PROD-2130 — ids that just *left* the tombstone set (re-follow
    // after an unfollow). Queue them; the corresponding `UserList` may
    // not appear in `next.followingLists` until
    // `UnifiedListNotifier._refreshFollowingLists` resolves, which lands
    // in a later listener call.
    final newlyUntombstoned = tombstonesChanged
        ? prevTombstones.difference(nextTombstones)
        : const <String>{};

    var items = current.items;
    var changed = false;
    if (newlyTombstoned.isNotEmpty) {
      final filtered = items
          .where((l) => !newlyTombstoned.contains(l.id))
          .toList();
      if (filtered.length != items.length) {
        items = filtered;
        changed = true;
      }
      // A re-tombstone supersedes a pending re-follow for the same id
      // (rapid follow → unfollow toggle while the BE refresh is in flight).
      _pendingRefollowIds.removeAll(newlyTombstoned);
    }
    if (newlyUntombstoned.isNotEmpty) {
      _pendingRefollowIds.addAll(newlyUntombstoned);
    }

    // PROD-2130 — try to drain pending re-follow ids against the
    // latest `followingLists`. Each drained id is prepended to the
    // shelf so the user sees the just-re-followed list at the top,
    // mirroring the instant feedback the tombstone path gives on
    // unfollow. Ids that aren't in `followingLists` yet stay queued for
    // the next listener call.
    if (_pendingRefollowIds.isNotEmpty) {
      final followingLookup = {for (final l in next.followingLists) l.id: l};
      final existingIds = {for (final l in items) l.id};
      final restored = <UserList>[];
      final resolved = <String>{};
      for (final id in _pendingRefollowIds) {
        if (existingIds.contains(id)) {
          // Already on the shelf (e.g., the user re-followed something
          // outside the tombstone filter window, or a patch landed in
          // the same tick). Nothing to add — just clear the queue.
          resolved.add(id);
          continue;
        }
        final restoredList = followingLookup[id];
        if (restoredList != null) {
          restored.add(restoredList);
          resolved.add(id);
        }
      }
      if (restored.isNotEmpty) {
        items = [...restored, ...items];
        changed = true;
      }
      _pendingRefollowIds.removeAll(resolved);
    }

    // In-place patches from `next.lists` (cover edits, renames, etc.).
    final lookup = {for (final l in next.lists) l.id: l};
    if (lookup.isNotEmpty) {
      final updated = <UserList>[];
      for (final l in items) {
        final replacement = lookup[l.id];
        if (replacement != null && !identical(replacement, l)) {
          changed = true;
          updated.add(replacement);
        } else {
          updated.add(l);
        }
      }
      items = updated;
    }

    if (changed) {
      state = AsyncData(current.copyWith(items: items));
    }
  }
}
