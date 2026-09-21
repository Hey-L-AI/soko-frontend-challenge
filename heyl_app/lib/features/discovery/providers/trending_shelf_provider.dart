import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/models/resolved_search_location.dart';
import '../../moderation/providers/blocked_users_provider.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// Page size for the Trending feed — matches the OpenAPI cap that
/// `/lists/public` returns sensible top-N batches at (`limit` accepts
/// up to 100; 10 keeps the horizontal shelf snappy and gives the
/// PROD-2221 default-content vertical grid five rows per page).
const int _kPageSize = 10;

/// PROD-3269 — how long a fetched Zines grid stays fresh for the
/// stale-gated paths ([TrendingShelfNotifier.refreshIfStale]: overlay
/// open on the Zines tab, in-section tab flips). The ranking is
/// last-7-day follow events, so 15 min of reuse loses nothing visible
/// while cutting the per-overlay-open `/lists/public` refetch (the
/// backend's most expensive query — PROD-3242). Forced paths (explicit
/// [TrendingShelfNotifier.refresh]: picker-coords change, login,
/// error retry) bypass this; a coords MISMATCH also bypasses it — see
/// [TrendingShelfNotifier.refreshIfStale] (the PROD-2743 guard).
const Duration _kZinesGridTtl = Duration(minutes: 15);

/// State for the Discovery "Trending" shelf — public lists ranked by
/// follow events in the last 7 days (`sort=popular_last_week`,
/// PROD-1513). Surfaces in PT-PT as "Mais seguidas".
///
/// Scoped to the picker city when coords are available (lat/lon +
/// 100 km). When the picker has no resolvable coords the request is
/// fired without any location params — PROD-1999 removed the silent
/// stored-location fallback on `/lists/public`, so omitting coords
/// simply yields a global (unfiltered) result.
///
/// Empty lists (`item_count == 0`) are filtered out — surfacing other
/// users' empty lists on Discovery is bad UX. The user's own empty
/// lists still render on the Yours shelf where in-progress lists are
/// expected.
///
/// PROD-2221 — converted from a single-page `FutureProvider` to a
/// paginated `StateNotifier` so the new default-content vertical grid
/// (search overlay, Zines filter, no query) can load further pages on
/// scroll. The horizontal "Em destaque" shelf still renders the first
/// page (`itemsForShelf` getter / `items` field — same data either
/// way).
@immutable
class TrendingShelfState {
  final List<UserList> items;

  /// Whether another page is worth requesting. PROD-3267: no longer
  /// derived from the response `total` (`items.length < total`) — that
  /// coupled us to a field the BE computes via an expensive second query
  /// execution (PROD-3242/PROD-3246) and, because [items] is post-cull
  /// while `total` was pre-cull, it never converged at end-of-list (the
  /// load-more spinner never disappeared — see
  /// `learnings/paged-shelf-hasmore-via-raw-page-size.md`). The notifier
  /// now sets this per page: the backend's explicit `has_more` when
  /// present, else the full-page heuristic on the RAW (pre-cull) row
  /// count — the same rule the Editor Picks / City Guides shelves use.
  final bool hasMore;
  final bool isInitialLoading;
  final bool isLoadingMore;
  final Object? error;

  const TrendingShelfState({
    this.items = const [],
    this.hasMore = false,
    this.isInitialLoading = true,
    this.isLoadingMore = false,
    this.error,
  });

  TrendingShelfState copyWith({
    List<UserList>? items,
    bool? hasMore,
    bool? isInitialLoading,
    bool? isLoadingMore,
    Object? error,
    bool clearError = false,
  }) {
    return TrendingShelfState(
      items: items ?? this.items,
      hasMore: hasMore ?? this.hasMore,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class TrendingShelfNotifier extends StateNotifier<TrendingShelfState> {
  final Ref _ref;

  /// Injectable clock so tests can pin the [refreshIfStale] TTL.
  final DateTime Function() _now;

  /// When the current grid was (re)fetched from offset 0, and for which
  /// resolved search-center coords. Drive [refreshIfStale]'s freshness
  /// check; null until the first successful [refresh] (and after
  /// [clear]). `loadMore` pages extend the same ranking snapshot, so
  /// they deliberately do NOT bump the timestamp.
  DateTime? _lastFetchedAt;
  ({double lat, double lon})? _lastFetchedCoords;

  /// Offset to pass on the NEXT page request. We track this separately
  /// from `items.length` because empty-list filtering can drop rows
  /// from the response, but the BE pagination cursor advances on
  /// pre-filter rows.
  int _nextOffset = 0;

  /// Pre-block-filter cache of the items currently held in state. Lets
  /// [reapplyBlockFilter] re-run the filter against the latest
  /// [blockedUserIdsProvider] without a network refetch when the viewer
  /// blocks a user (PROD-2264 follow-up). Empty-list culling is already
  /// applied here — only the blocked-author filter is dynamic.
  List<UserList> _rawItems = const [];

  /// PROD-2654 — generation guard. Bumped on every [refresh] / [clear]; the
  /// in-flight fetch discards its `state =` write if superseded. Stops account
  /// A's lists from landing after a switch to account B.
  int _epoch = 0;

  TrendingShelfNotifier(this._ref, {DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(const TrendingShelfState()) {
    refresh();
  }

  Future<void> refresh() async {
    final myEpoch = ++_epoch; // PROD-2654 — supersede any in-flight fetch
    state = state.copyWith(isInitialLoading: true, clearError: true);
    _nextOffset = 0;
    try {
      final resolved = await _readResolved();
      final coords = resolved.center;
      final response = await _fetchPage(offset: 0, resolved: resolved);
      if (myEpoch != _epoch) return; // superseded → discard
      // PROD-3267 — advance the cursor by the RAW rows actually received,
      // not a fixed page size: with an explicit `has_more: true` on a
      // short page, a fixed advance would skip the unreceived rows.
      // Identical to `_kPageSize` for full pages (today's only
      // hasMore-true shape under the heuristic).
      _nextOffset = response.items.length;
      // PROD-3269 — commit the freshness metadata TOGETHER and only on a
      // SUCCESSFUL offset-0 fetch. Committing coords earlier (or from
      // loadMore) opens a stale-city hole: a failed/superseded forced
      // refresh after a city change would leave "new coords + old
      // timestamp", which [refreshIfStale] would wrongly read as fresh.
      _lastFetchedAt = _now();
      _lastFetchedCoords = coords;
      _rawItems = response.items.where((list) => list.itemCount > 0).toList();
      state = TrendingShelfState(
        items: _applyBlockFilter(_rawItems),
        hasMore: _pageHasMore(response),
        isInitialLoading: false,
      );
    } catch (e) {
      if (myEpoch != _epoch) return; // stale failure → discard
      state = state.copyWith(isInitialLoading: false, error: e);
    }
  }

  /// PROD-3269 — the stale-gated variant of [refresh], used by the
  /// overlay-open / tab-flip paths in `DefaultContentSection`. Reuses
  /// the current grid when it's younger than [_kZinesGridTtl] AND was
  /// fetched for the CURRENT resolved search-center coords — the coords
  /// comparison is the PROD-2743 guard: a city change made while the
  /// zines tab wasn't mounted (so the widget's coord listener couldn't
  /// fire) must still refetch on tab-in, TTL or not.
  Future<void> refreshIfStale() async {
    final ({double lat, double lon})? coords;
    try {
      coords = (await _readResolved()).center;
    } catch (_) {
      // Resolver hiccup on the preflight read — the widget calls this
      // fire-and-forget, so don't let the error escape unhandled. Fall
      // through to [refresh], whose own catch stores the failure in
      // state like the pre-TTL paths did.
      await refresh();
      return;
    }
    final fetchedAt = _lastFetchedAt;
    // An error state is never "fresh" (codex P2): a failed same-city
    // forced refresh or a load-more error leaves `state.error` set while
    // the last SUCCESS timestamp can still be inside the TTL — reusing
    // would pin the error banner on screen for the rest of the window
    // instead of retrying on the next overlay open / tab flip.
    final fresh =
        state.error == null &&
        fetchedAt != null &&
        _now().difference(fetchedAt) < _kZinesGridTtl &&
        coords == _lastFetchedCoords;
    if (fresh) return;
    await refresh();
  }

  /// PROD-2654 — clear synchronously on logout / account switch so guest
  /// discovery never renders the previous account's lists. Bumps the epoch
  /// (discards any in-flight fetch) and resets the page cursor.
  void clear() {
    _epoch++;
    _rawItems = const [];
    _nextOffset = 0;
    _lastFetchedAt = null;
    _lastFetchedCoords = null;
    state = const TrendingShelfState(isInitialLoading: false);
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore) return;
    final myEpoch = _epoch; // PROD-2654 — discard append if superseded
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final resolved = await _readResolved();
      final response = await _fetchPage(
        offset: _nextOffset,
        resolved: resolved,
      );
      if (myEpoch != _epoch) return; // stale response → discard
      _nextOffset += response.items.length; // raw rows received (PROD-3267)
      final newItems = response.items
          .where((list) => list.itemCount > 0)
          .toList();
      _rawItems = [..._rawItems, ...newItems];
      state = state.copyWith(
        items: _applyBlockFilter(_rawItems),
        hasMore: _pageHasMore(response),
        isLoadingMore: false,
      );
    } catch (e) {
      if (myEpoch != _epoch) return; // stale failure → discard
      state = state.copyWith(isLoadingMore: false, error: e);
    }
  }

  /// Re-runs the blocked-author filter against [_rawItems] and updates
  /// state in place. No network call. Called from the
  /// [blockedUserIdsProvider] listener in the factory below so a block
  /// committed elsewhere in the app (e.g. from a list-detail page)
  /// removes the blocked user's lists from the shelf instantly.
  void reapplyBlockFilter() {
    if (_rawItems.isEmpty) return;
    final filtered = _applyBlockFilter(_rawItems);
    if (filtered.length == state.items.length) return;
    state = state.copyWith(items: filtered);
  }

  List<UserList> _applyBlockFilter(List<UserList> items) {
    final blocked = _ref.read(blockedUserIdsProvider);
    return filterByBlockedAuthors(items, blocked);
  }

  /// Whether [response] suggests another page exists (PROD-3267).
  ///
  /// The backend's explicit `has_more` is authoritative when present.
  /// `/lists/public` doesn't send it today, so the fallback is the
  /// full-page heuristic on the RAW response row count (pre empty-cull,
  /// pre block-filter — client-side filtering must never mask a full
  /// backend page). A short page means the corpus is exhausted; an
  /// exact-multiple corpus costs one extra empty request, which the
  /// empty response then turns into `hasMore == false`.
  ///
  /// An EMPTY raw page is terminal regardless of the explicit flag: the
  /// cursor advances by rows received, so zero rows means no progress is
  /// possible — honoring a (buggy) `items: [], has_more: true` response
  /// would re-request the same offset forever.
  static bool _pageHasMore(UserListsResponse response) {
    if (response.items.isEmpty) return false;
    return response.hasMoreExplicit ?? response.items.length == _kPageSize;
  }

  /// Resolved search location for the request. Hoisted out of
  /// [_fetchPage] so [refresh] can commit the freshness metadata with the
  /// exact coords the successful response was fetched for (PROD-3269),
  /// and so the request radius follows the resolved tier rather than a
  /// local constant (PROD-3201).
  Future<ResolvedSearchLocation> _readResolved() =>
      _ref.read(resolvedSearchLocationProvider.future);

  Future<UserListsResponse> _fetchPage({
    required int offset,
    required ResolvedSearchLocation resolved,
  }) async {
    final api = _ref.read(listsApiProvider);
    final coords = resolved.center;
    return api.listPublicLists(
      sort: 'popular_last_week',
      latitude: coords?.lat,
      longitude: coords?.lon,
      radiusKm: coords == null ? null : resolved.radiusKm,
      locationSource: coords == null ? null : 'picker',
      limit: _kPageSize,
      offset: offset,
    );
  }
}

final trendingShelfProvider =
    StateNotifierProvider.autoDispose<
      TrendingShelfNotifier,
      TrendingShelfState
    >((ref) {
      // PROD-2221 — outlive the per-page consumer. Idle Discovery's
      // [TrendingShelf] and the search overlay's [DefaultContentSection]
      // both watch this provider; the refCount transiently drops to 0
      // during the overlay-open transition, which (without keepAlive)
      // disposes the notifier and forces a fresh refresh that strands
      // empty results if the BE is slow or returns []. Pull-to-refresh
      // and the scope listens below remain the explicit invalidation
      // points.
      ref.keepAlive();
      final notifier = TrendingShelfNotifier(ref);
      // PROD-2743 — NO picker-coords listener here on purpose. This provider is
      // consumed only by the overlay's [DefaultContentSection], created lazily
      // when the overlay opens — by which point `resolvedSearchLocationProvider` is
      // already resolved + cached, so a provider-internal `ref.listen` never
      // sees an initial settle and (with a seed guard) swallows the first real
      // coord change. The overlay's coord-refetch is owned by
      // [DefaultContentSection] instead: a widget-level
      // `ref.listen(resolvedSearchLocationProvider.select(...))` that fires while the
      // tab is mounted, plus an `initState` refetch on tab-activation. The
      // widget is the reliable observer; see the REPRO in
      // `shelf_location_refetch_test.dart` for why the provider-level listener
      // was unreliable for this lazily-created shelf.
      // PROD-2264 follow-up — when the viewer blocks a user from
      // anywhere in the app (e.g. a list-detail page they navigated to
      // from this shelf), drop the blocked author's lists from the
      // shelf without a refetch. `addLocalBlock` updates the id set
      // instantly so this listener fires the same tick as the block.
      ref.listen(blockedUserIdsProvider, (prev, next) {
        if (prev == next) return;
        notifier.reapplyBlockFilter();
      });
      // PROD-2654 — keepAlive() survives logout; reset on account change.
      // `clear()` on logout, `refresh()` on login/switch.
      ref.listen<String?>(authStateProvider.select((s) => s.user?.id), (
        prev,
        next,
      ) {
        if (prev == next) return;
        if (next == null) {
          notifier.clear();
        } else {
          notifier.refresh();
        }
      });
      return notifier;
    });
