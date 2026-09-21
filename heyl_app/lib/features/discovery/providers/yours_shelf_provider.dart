import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/lists_provider.dart';
import '../../lists/providers/auto_lists_filter_provider.dart';
import 'paged_shelf_state.dart';

/// PROD-2091 — page size and drain cap for paginated fetches.
///
/// Initial-load drain has NO iteration cap (uncapped while there are no
/// visible items yet) so a user with hundreds of auto-lists and
/// `includeAutoLists=false` still resolves to a non-empty shelf or a
/// real end-of-stream — never an empty state with `hasMore=true`.
///
/// `loadMore`-time drain is capped at 5 iterations as a defensive
/// ceiling against pathological filter ratios. If the cap is hit with
/// zero visible items, `nextOffset` still advances by the raw fetched
/// count and the post-frame edge check in `_PagedHorizontalRow` will
/// schedule another `loadMore` — the shelf self-recovers without
/// fetching 50+ filtered pages in a single user action.
const int _pageSize = 10;
const int _maxLoadMoreDrainIterations = 5;

/// Powers the Discovery "Yours" shelf — the user's own lists. Surfaces
/// in PT-PT as "Tuas".
///
/// Two paths feed the shelf state:
/// 1. **Initial load** — `GET /api/v1/app/users/me/lists?limit=10&offset=0`
///    via the `listsApiProvider`, draining pages until at least one
///    visible item exists or the BE signals end-of-stream.
/// 2. **In-place patches** — listens to [listsProvider] and patches the
///    cached items whenever the central store updates. Cover edits land
///    instantly without a BE roundtrip (PROD-1908 follow-up).
/// 3. **Tombstone removals** — same listener handles deletes via
///    `listsProvider.recentlyDeletedListIds`. Both the live case and the
///    read-after-write case (refetch returns the just-deleted row) are
///    covered: the build-time tombstone filter catches the second.
/// 4. **Create insertions** (PROD-2216) — the same listener watches
///    `listsProvider.recentlyCreatedListIds` and prepends a just-created
///    zine to the shelf so it appears at `/yours` immediately. Without
///    this, the listener silently ignored new ids — only patching
///    matching ones and dropping tombstoned ones — and the freshly-created
///    list stayed invisible until the screen unmounted and re-drained
///    from BE.
///
/// On scroll near the right edge, `_PagedHorizontalRow` calls
/// [YoursShelfNotifier.loadMore] to fetch the next page; failures are
/// surfaced via a trailing retry tile that fires [retryLoadMore].
final yoursShelfProvider =
    AsyncNotifierProvider.autoDispose<YoursShelfNotifier, PagedShelfState>(
      YoursShelfNotifier.new,
    );

class YoursShelfNotifier extends AutoDisposeAsyncNotifier<PagedShelfState> {
  // PROD-2091 — bumped on every `build()` and every `_fetchAndAppend()`
  // call. An in-flight fetch captures the version at start; if it has
  // moved by the time the await resolves (rebuild from
  // `includeAutoListsProvider`, or a concurrent `loadMore`), the late
  // response is discarded so it can't overwrite the newer state.
  int _currentVersion = 0;

  // PROD-2091 — set in the `ref.onDispose` callback so post-await
  // writes can short-circuit cleanly. Riverpod 2.6.x doesn't expose
  // `ref.mounted` on `AutoDisposeAsyncNotifierProviderRef`, so this
  // flag is the equivalent guard.
  bool _disposed = false;

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
    // `watch` so `includeAutoLists` flips trigger a fresh `build()`.
    final includeAutoLists = ref.watch(includeAutoListsProvider);

    // Patch local cache when listsProvider's central store mutates
    // (cover edits, renames, visibility toggles, tombstones, and
    // PROD-2216 create insertions). Pure in-place update — no BE
    // roundtrip. Must run BEFORE the early returns inside the listener
    // so removals are caught even when `next.lists` is empty.
    ref.listen(listsProvider, _onListsProviderChanged);

    // Read tombstones once at build time so the initial drain can
    // filter out lists the user just deleted but the BE still returns
    // (read-after-write lag).
    final tombstones = ref.read(
      listsProvider.select((s) => s.recentlyDeletedListIds),
    );

    final result = await _drain(
      offset: 0,
      maxIterations: null, // uncapped on initial load
      includeAutoLists: includeAutoLists,
      tombstones: tombstones,
    );
    if (fetchVersion != _currentVersion) {
      // A newer build started while we were draining — discard.
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

  /// Auto-fire path: triggered when the user scrolls near the right
  /// edge of the shelf, or by the post-frame underfilled-row check.
  /// No-ops if pagination is already in flight, end-of-stream reached,
  /// or a prior `loadMore` errored (use [retryLoadMore] to recover).
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

  /// Explicit retry path used by the trailing error tile. Clears the
  /// error first so [loadMore]'s error-guard can pass, then delegates
  /// to the shared fetch. Separate method because folding the
  /// clear-then-fetch flow into `loadMore` would let scroll-edge
  /// auto-fires retry on every notification — exactly what the
  /// `loadMoreError` guard exists to prevent.
  Future<void> retryLoadMore() async {
    final initial = state.valueOrNull;
    if (initial == null) return;
    if (initial.isLoadingMore) return;
    // Reuse the already-cleared snapshot — we just wrote it to state, so
    // re-reading via `state.value!` would only re-derive what we already
    // have AND trip the `check-error-handling-discipline` linter (see
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
      // Snapshot filter inputs once per `loadMore` call so all drained
      // pages apply consistent filtering even if the user toggles
      // `includeAutoLists` mid-fetch (the toggle will trigger a fresh
      // `build()`; this in-flight call will be discarded via the
      // version-token guard below).
      final includeAutoLists = ref.read(includeAutoListsProvider);
      final tombstones = ref.read(
        listsProvider.select((s) => s.recentlyDeletedListIds),
      );

      final next = await _drain(
        offset: initial.nextOffset,
        maxIterations: _maxLoadMoreDrainIterations,
        includeAutoLists: includeAutoLists,
        tombstones: tombstones,
      );
      if (_disposed) return;
      if (fetchVersion != _currentVersion) return;

      // Re-read `state.value` after the await — `listsProvider`
      // listener patches that landed during the fetch would otherwise
      // be clobbered by `initial.copyWith(...)`. Use `valueOrNull` per
      // the team's discipline (see
      // [`learnings/asyncvalue-value-throws-on-error.md`]); fall back to
      // `initial` if state somehow flipped out of `AsyncData` while we
      // were awaiting (shouldn't happen — `_disposed` + version-token
      // guards above already catch the realistic cases — but the linter
      // bans `.value!` on principle).
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

  /// Drain loop — fetches pages until at least one visible item exists,
  /// or the BE signals end-of-stream (`response.items.length <
  /// _pageSize`), or [maxIterations] is hit (when non-null).
  ///
  /// `requireVisibleItems` is implicit: we always loop until visible
  /// items exist or the loop terminates for another reason. The
  /// concrete callers only care about the initial-load (uncapped) vs
  /// `loadMore` (capped) distinction, which is encoded in
  /// [maxIterations].
  Future<PagedDrainResult> _drain({
    required int offset,
    required int? maxIterations,
    required bool includeAutoLists,
    required Set<String> tombstones,
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
      final response = await api.listMyLists(
        limit: _pageSize,
        offset: currentOffset,
      );
      rawCount += response.items.length;
      Iterable<UserList> filtered = response.items;
      if (!includeAutoLists) {
        filtered = filtered.where((l) => !l.isSystemManaged);
      }
      if (tombstones.isNotEmpty) {
        filtered = filtered.where((l) => !tombstones.contains(l.id));
      }
      visible.addAll(filtered);
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

  /// Append [incoming] to [existing], dropping any id already present.
  /// Cheap insurance against offset-pagination drift under concurrent
  /// create/delete on other clients.
  List<UserList> _dedupeAppend(
    List<UserList> existing,
    List<UserList> incoming,
  ) {
    final seen = {for (final l in existing) l.id};
    return [...existing, ...incoming.where((l) => seen.add(l.id))];
  }

  void _onListsProviderChanged(ListsState? previous, ListsState next) {
    final current = state.valueOrNull;
    if (current == null) return;

    List<UserList>? workingItems;

    // 1. Removals — drop any list the central store tombstoned. Must run
    // before any early returns; the tombstone signal is independent of
    // whether `next.lists` carries entries.
    final tombstones = next.recentlyDeletedListIds;
    if (tombstones.isNotEmpty) {
      final filtered = current.items
          .where((l) => !tombstones.contains(l.id))
          .toList();
      if (filtered.length != current.items.length) {
        workingItems = filtered;
      }
    }

    // 2. Insertions (PROD-2216) — when `createList` succeeds it appends
    // the new id to `recentlyCreatedListIds`. Diff against `previous` so
    // we only react to ids that just landed, not the whole set (which
    // also stays populated across subsequent `loadLists()` / Discover
    // refreshes that preserve the field via `copyWith`). For each newly-
    // created id, look up the `UserList` in `next.lists` (where
    // `createList` prepended it) and add it to the shelf if not already
    // there. A diff-based heuristic on `next.lists - previous.lists`
    // wouldn't work — `loadLists()` fires with `limit=50` right after a
    // create, so page-2-of-the-shelf entries would arrive in `next.lists`
    // and get falsely prepended out of pagination order. The explicit
    // signal scopes the prepend to true creates only.
    final prevCreated = previous?.recentlyCreatedListIds ?? const <String>{};
    final nextCreated = next.recentlyCreatedListIds;
    if (!identical(prevCreated, nextCreated)) {
      final newlyCreated = nextCreated.difference(prevCreated);
      if (newlyCreated.isNotEmpty) {
        final base = workingItems ?? current.items;
        final existingIds = {for (final l in base) l.id};
        // Preserve `next.lists` order so the most-recently-created list
        // ends up at position 0 of the shelf (matches `createList`'s
        // prepend-to-head contract).
        final inserts = <UserList>[];
        for (final l in next.lists) {
          if (newlyCreated.contains(l.id) && !existingIds.contains(l.id)) {
            inserts.add(l);
          }
        }
        if (inserts.isNotEmpty) {
          workingItems = [...inserts, ...base];
        }
      }
    }

    // 3. Patches — only meaningful when the central store has entries.
    final lookup = {for (final l in next.lists) l.id: l};
    if (lookup.isNotEmpty) {
      final base = workingItems ?? current.items;
      var patched = false;
      final updated = <UserList>[];
      for (final l in base) {
        final replacement = lookup[l.id];
        if (replacement != null && !identical(replacement, l)) {
          patched = true;
          updated.add(replacement);
        } else {
          updated.add(l);
        }
      }
      if (patched) {
        workingItems = updated;
      }
    }

    if (workingItems != null) {
      state = AsyncData(current.copyWith(items: workingItems));
    }
  }
}
