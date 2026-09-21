import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/provider_cache.dart';
import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import 'curation_radius.dart';
import 'paged_shelf_state.dart';
import '../../../providers/auth_provider.dart';

const int _kPageSize = 10;

/// PROD-3269 — how long a fetched shelf survives losing its listeners
/// (Discovery unmounts). Editor picks are a slow-moving curated set;
/// matches the "Mais seguidas" TTL (PROD-3266). Picker-coords changes
/// and pull-to-refresh still refetch immediately (see `cacheFor`).
const Duration _kShelfCacheTtl = Duration(hours: 3);

/// Powers the Discovery "Editor Picks" shelf — public lists flagged
/// `editor_pick=true` by Soko admins (PROD-1513).
///
/// Scoped to the picker centroid when coords are available; otherwise
/// the request fires without location params (PROD-1999 removed the
/// silent stored-location fallback on `/lists/public`, so omitting coords
/// yields a global result).
///
/// Empty lists are filtered out — admins shouldn't be able to pick a
/// just-created empty list and have it ship to Discovery. Defensive
/// rather than relying solely on the curation flow.
///
/// PROD-2323 — paginated: first page via `build()`, subsequent pages via
/// `loadMore()` on horizontal-scroll edge.
final editorPicksShelfProvider =
    AsyncNotifierProvider.autoDispose<
      EditorPicksShelfNotifier,
      PagedShelfState
    >(EditorPicksShelfNotifier.new);

class EditorPicksShelfNotifier
    extends AutoDisposeAsyncNotifier<PagedShelfState> {
  @override
  Future<PagedShelfState> build() async {
    // PROD-3269 — survive Discovery remounts within the TTL instead of
    // re-firing the expensive /lists/public query per mount. Only
    // SUCCESSFUL builds are worth caching: on failure the link is
    // closed so leaving + remounting Discovery retries immediately
    // instead of serving a cached AsyncError for hours.
    final link = ref.cacheFor(_kShelfCacheTtl);
    // PROD-3581 — `cacheFor` above defeats `autoDispose`, so this shelf and
    // its data outlive a sign-out for the whole TTL. `UserListOut` carries the
    // VIEWER's relationship fields (`is_following`, `user_role`), so the
    // cached items are not purely public catalog. Depend on the identity
    // explicitly rather than relying on a change reaching us through
    // `resolvedSearchLocationProvider` — that chain works today but is three
    // hops long and branches, and it would go quiet without anything failing.
    // `.select` on the id means token refreshes don't rebuild, and an account
    // switch is rare, so `cacheFor`'s purpose (PROD-3242: stop re-firing the
    // most expensive backend query on every Discovery remount) is untouched.
    ref.watch(authStateProvider.select((s) => s.user?.id));
    try {
      // PROD-3201 — radius comes from the resolved search location's
      // tier (SEARCH_RANGE_CONFIG mirror), not a local constant.
      final resolved = await ref.watch(resolvedSearchLocationProvider.future);
      return await _fetchPage(
        coords: resolved.center,
        radiusKm: resolved.radiusKm,
        offset: 0,
        existing: const [],
      );
    } catch (_) {
      link.close();
      rethrow;
    }
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null ||
        !current.hasMore ||
        current.isLoadingMore ||
        current.loadMoreError != null) {
      return;
    }
    // PROD-3581 — the identity `watch` in `build()` starts a REBUILD, but
    // Riverpod reuses the notifier instance across builds, so a `loadMore()`
    // already awaiting when the account changes would still land its write:
    // account A's `current.items` plus A's freshly-fetched page, into account
    // B's shelf. Capture the id and drop the write instead.
    final accountAtStart = ref.read(authStateProvider).user?.id;
    final resolved = await ref.read(resolvedSearchLocationProvider.future);
    // The account can also change while the line above is awaiting.
    if (ref.read(authStateProvider).user?.id != accountAtStart) return;
    state = AsyncData(
      current.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );
    try {
      final next = await _fetchPage(
        coords: resolved.center,
        radiusKm: resolved.radiusKm,
        offset: current.nextOffset,
        existing: current.items,
      );
      if (ref.read(authStateProvider).user?.id != accountAtStart) return;
      state = AsyncData(next);
    } catch (e) {
      if (ref.read(authStateProvider).user?.id != accountAtStart) return;
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: e),
      );
    }
  }

  Future<void> retryLoadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore) return;
    state = AsyncData(current.copyWith(clearLoadMoreError: true));
    await loadMore();
  }

  Future<PagedShelfState> _fetchPage({
    required ({double lat, double lon})? coords,
    required double? radiusKm,
    required int offset,
    required List<UserList> existing,
  }) async {
    final api = ref.read(listsApiProvider);
    final response = await api.listPublicLists(
      editorPick: true,
      latitude: coords?.lat,
      longitude: coords?.lon,
      // Curation is city-scale — see [curationRadiusKm].
      radiusKm: coords == null ? null : curationRadiusKm(radiusKm),
      locationSource: coords == null ? null : 'picker',
      limit: _kPageSize,
      offset: offset,
    );
    final newItems = response.items
        .where((list) => list.itemCount > 0)
        .toList();
    return PagedShelfState(
      items: [...existing, ...newItems],
      nextOffset: offset + response.items.length,
      hasMore: response.items.length == _kPageSize,
      isLoadingMore: false,
      loadMoreError: null,
    );
  }
}
