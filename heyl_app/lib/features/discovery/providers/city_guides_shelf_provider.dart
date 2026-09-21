import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/provider_cache.dart';
import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import 'curation_radius.dart';
import 'paged_shelf_state.dart';
import '../../../providers/auth_provider.dart';

const int _kPageSize = 10;

/// PROD-3269 — remount-survival TTL, mirror of the Editor Picks shelf.
const Duration _kShelfCacheTtl = Duration(hours: 3);

/// Powers the Discovery "City Guides" shelf — public lists flagged
/// `city_guide=true` (PROD-1513). Mirror of [editorPicksShelfProvider];
/// differs only in the BE flag consumed.
///
/// PROD-2323 — paginated: first page via `build()`, subsequent pages via
/// `loadMore()` on horizontal-scroll edge.
final cityGuidesShelfProvider =
    AsyncNotifierProvider.autoDispose<CityGuidesShelfNotifier, PagedShelfState>(
      CityGuidesShelfNotifier.new,
    );

class CityGuidesShelfNotifier
    extends AutoDisposeAsyncNotifier<PagedShelfState> {
  @override
  Future<PagedShelfState> build() async {
    // PROD-3269 — survive Discovery remounts within the TTL instead of
    // re-firing the expensive /lists/public query per mount. Failed
    // builds close the link so a remount retries immediately (mirror of
    // the Editor Picks shelf).
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
      cityGuide: true,
      latitude: coords?.lat,
      longitude: coords?.lon,
      // Curation is city-scale — see [curationRadiusKm]. From Barra da Tijuca
      // the picker's own radius returned ZERO city guides (PROD-3800).
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
