import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/environment.dart';
import '../../../core/utils/provider_cache.dart';
import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../moderation/providers/blocked_users_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import 'paged_shelf_state.dart';
import '../../../providers/auth_provider.dart';

const int _kPageSize = 10;

/// PROD-3269 — remount-survival TTL, mirror of the Editor Picks shelf.
/// This shelf's by-handle endpoint shares `/lists/public`'s expensive
/// query shape (197 reqs / 2,392s in the PROD-3242 incident window).
const Duration _kShelfCacheTtl = Duration(hours: 3);

/// Powers the Discovery "Recommended" shelf — Soko's public lists, fetched
/// via `GET /api/v1/app/users/by-handle/{handle}/lists/public` (PROD-1516,
/// PROD-1573, PROD-1999). Surfaces in PT-PT as "Recomendado".
///
/// The handle comes from `EnvironmentConfig.sokoHandle` (env-overridable via
/// `SOKO_HANDLE`). When the backend returns 404 (no active user matching
/// the handle), the provider returns an empty state so the shelf hides
/// gracefully — preferable to crashing or surfacing an error for what is
/// effectively a misconfiguration.
///
/// `editorPick: false` and `cityGuide: false` exclude lists already promoted
/// in the Editor Picks and City Guides shelves (PROD-1573), so the three
/// Soko-sourced shelves don't overlap.
///
/// Scoped to the picker centroid (PROD-1999). PROD-2005 — when picker
/// coords aren't available (no city picked, or a Google-sourced pick whose
/// `resolveCity` failed) the shelf hides instead of falling back to an
/// unfiltered global fetch.
///
/// PROD-2323 — paginated: first page via `build()`, subsequent pages via
/// `loadMore()` on horizontal-scroll edge (drives the same auto-fire path
/// `_PagedHorizontalRow` uses on Yours/Following).
final recommendedShelfProvider =
    AsyncNotifierProvider.autoDispose<
      RecommendedShelfNotifier,
      PagedShelfState
    >(RecommendedShelfNotifier.new);

class RecommendedShelfNotifier
    extends AutoDisposeAsyncNotifier<PagedShelfState> {
  @override
  Future<PagedShelfState> build() async {
    // PROD-3269 — survive Discovery remounts within the TTL instead of
    // re-firing the expensive by-handle query per mount. Failed builds
    // close the link so a remount retries immediately (mirror of the
    // Editor Picks shelf).
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
      // PROD-3201 — radius from the resolved search location's tier.
      final resolved = await ref.watch(resolvedSearchLocationProvider.future);
      final coords = resolved.center;
      // `watch` (not `read`) so the provider rebuilds when the viewer
      // blocks an author. Matches the previous FutureProvider behavior —
      // accepted trade-off is that a fresh block drops the user back to
      // page 1; in practice Soko itself isn't blockable.
      final blockedIds = ref.watch(blockedUserIdsProvider);
      if (coords == null) return const PagedShelfState.empty();
      return await _fetchPage(
        coords: coords,
        radiusKm: resolved.radiusKm,
        blocked: blockedIds,
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
    final coords = resolved.center;
    if (coords == null) return;
    final blocked = ref.read(blockedUserIdsProvider);
    // The account can also change while the line above is awaiting.
    if (ref.read(authStateProvider).user?.id != accountAtStart) return;
    state = AsyncData(
      current.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );
    try {
      final next = await _fetchPage(
        coords: coords,
        radiusKm: resolved.radiusKm,
        blocked: blocked,
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
    required ({double lat, double lon}) coords,
    required double? radiusKm,
    required Set<String> blocked,
    required int offset,
    required List<UserList> existing,
  }) async {
    final api = ref.read(listsApiProvider);
    try {
      final response = await api.listPublicListsByHandle(
        handle: EnvironmentConfig.sokoHandle,
        editorPick: false,
        cityGuide: false,
        latitude: coords.lat,
        longitude: coords.lon,
        radiusKm: radiusKm,
        locationSource: 'picker',
        limit: _kPageSize,
        offset: offset,
      );
      // Drop empty lists — Soko's draft / in-progress lists shouldn't
      // surface on a public-facing recommendation shelf.
      final nonEmpty = response.items
          .where((list) => list.itemCount > 0)
          .toList();
      final filtered = filterByBlockedAuthors(nonEmpty, blocked);
      return PagedShelfState(
        items: [...existing, ...filtered],
        // BE offset advances by the raw page size — filtered drops are
        // not refetched.
        nextOffset: offset + response.items.length,
        hasMore: response.items.length == _kPageSize,
        isLoadingMore: false,
        loadMoreError: null,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        debugPrint(
          '[Recommended] handle "${EnvironmentConfig.sokoHandle}" not found — hiding shelf',
        );
        return const PagedShelfState.empty();
      }
      rethrow;
    }
  }
}
