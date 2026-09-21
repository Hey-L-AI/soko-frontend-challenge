import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../moderation/providers/blocked_users_provider.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// Number of "most followed" lists the homepage shelf fetches AND displays
/// (PROD-3242 widened the window from a top-25 cull to the full fetched
/// 50). The shelf is a fixed top-N window — no infinite scroll. Empty-list
/// culling may leave fewer than 50 on screen; 50 is well under the
/// `/lists/public` `limit` cap of 100.
const int _kFetchLimit = 50;

/// How long a fetched top-50 stays fresh. Within this window, returning
/// to the homepage reshuffles the cached lists locally instead of
/// refetching — `/lists/public` is the single most expensive query on the
/// backend (PROD-3242 incident) and all-time save ranks move slowly, so
/// the previous per-navigation refetch bought no visible change anyway.
/// Forced refreshes (picker-coords change, login, pull-to-refresh, error
/// retry) bypass the TTL.
const Duration _kShelfTtl = Duration(hours: 3);

/// State for the homepage "Mais seguidas" (Most followed) shelf
/// (PROD-2416, revised under PROD-3242).
///
/// Ranking: the top [_kFetchLimit] public lists by **all-time save count**
/// (`sort=popular` → `follower_count DESC` on `/lists/public`; a list's
/// "Saves" stat IS its follower count). This replaces the previous
/// `popular_last_week` ranking, which sorted by follow events in the
/// last 7 days and surfaced low-save lists that happened to get a couple
/// of recent follows.
///
/// PROD-2416's business ask was that the shelf "doesn't look static"
/// between homepage visits. The original implementation refetched from
/// the BE on every return — which hammered the expensive `/lists/public`
/// query (PROD-3242) yet rarely changed the visible order, because
/// all-time save ranks are stable. Now the fetch result is cached for
/// [_kShelfTtl] and each return to the homepage **reshuffles the cached
/// lists locally** (see [MostFollowedShelfNotifier.onReturnToHomepage]);
/// the initial fetch renders in backend rank order.
///
/// Scoped to the picker city when coords are available (lat/lon +
/// 100 km); fired without location params otherwise (global result —
/// PROD-1999 removed the silent stored-location fallback).
///
/// Empty lists (`item_count == 0`) are culled — surfacing other users'
/// empty lists on the homepage is bad UX.
///
/// This shelf has its own provider (NOT [trendingShelfProvider], which
/// still backs the search-overlay grid's infinite-scroll Zines feed).
/// PROD-2416 scoped the top-25 refresh behavior to the homepage row
/// only, leaving the overlay's PROD-2221 paging untouched.
@immutable
class MostFollowedShelfState {
  final List<UserList> items;
  final bool isInitialLoading;
  final Object? error;

  const MostFollowedShelfState({
    this.items = const [],
    this.isInitialLoading = true,
    this.error,
  });

  MostFollowedShelfState copyWith({
    List<UserList>? items,
    bool? isInitialLoading,
    Object? error,
    bool clearError = false,
  }) {
    return MostFollowedShelfState(
      items: items ?? this.items,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class MostFollowedShelfNotifier extends StateNotifier<MostFollowedShelfState> {
  final Ref _ref;

  /// Injectable clock / RNG so tests can pin the TTL and the shuffle.
  final DateTime Function() _now;
  final Random _random;

  /// Pre-block-filter cache: the top-50 most-saved lists (post empty-cull),
  /// in whatever order is currently displayed (BE rank after a fetch,
  /// shuffled after a return). Lets [reapplyBlockFilter] re-run the
  /// blocked-author filter without a refetch while preserving that order.
  List<UserList> _rawItems = const [];

  /// Guards against overlapping fetches — a rapid back-and-forth to the
  /// homepage shouldn't fire a second request while one is in flight.
  bool _isFetching = false;

  /// PROD-2654 — generation guard. Bumped on every [refresh] / [clear]; the
  /// in-flight fetch discards its `state =` write if superseded. Stops account
  /// A's lists from landing after a switch to account B.
  int _epoch = 0;

  /// When the current [_rawItems] were fetched — drives the [_kShelfTtl]
  /// freshness check in [onReturnToHomepage]. Null until the first
  /// successful fetch (and after [clear]).
  DateTime? _lastFetchedAt;

  MostFollowedShelfNotifier(
    this._ref, {
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random(),
       super(const MostFollowedShelfState()) {
    refresh();
  }

  /// Fetch the top-50 most-saved lists and display them in backend order.
  ///
  /// [silent] keeps the currently-visible items on screen while the
  /// refetch is in flight (no skeleton flash) and preserves them if the
  /// request fails — used by [onReturnToHomepage]'s TTL-expiry refetch so
  /// the shelf never blinks back to a loader.
  Future<void> refresh({bool silent = false}) async {
    if (_isFetching) return;
    _isFetching = true;
    final myEpoch = ++_epoch; // PROD-2654 — supersede any in-flight fetch
    if (!silent) {
      state = state.copyWith(isInitialLoading: true, clearError: true);
    }
    try {
      final response = await _fetchTopLists();
      if (myEpoch != _epoch) {
        return; // superseded → discard (finally resets flag)
      }
      _rawItems = response.items.where((list) => list.itemCount > 0).toList();
      _lastFetchedAt = _now();
      state = MostFollowedShelfState(
        items: _applyBlockFilter(_rawItems),
        isInitialLoading: false,
      );
    } catch (e) {
      // On a silent refetch failure, keep whatever's already on screen.
      if (!silent && myEpoch == _epoch) {
        state = state.copyWith(isInitialLoading: false, error: e);
      }
    } finally {
      _isFetching = false;
    }
  }

  /// PROD-2654 — clear synchronously on logout / account switch so guest
  /// discovery never renders the previous account's lists. Bumps the epoch
  /// (discards any in-flight fetch) and frees the `_isFetching` latch so the
  /// post-login [refresh] isn't blocked.
  void clear() {
    _epoch++;
    _isFetching = false;
    _rawItems = const [];
    _lastFetchedAt = null;
    state = const MostFollowedShelfState(isInitialLoading: false);
  }

  /// Called when the user navigates back to the homepage.
  ///
  /// PROD-2416 asked that the shelf be "reordered every time the user goes
  /// back to the homepage, so that it doesn't look static". The original
  /// implementation refetched from the BE per return — one execution of
  /// the most expensive backend query each time (PROD-3242 incident) that
  /// rarely changed the visible order, since all-time save ranks are
  /// stable. Instead: **reshuffle the cached top-50 locally** (no
  /// network), and only refetch — silently, keeping items on screen —
  /// once the cache is older than [_kShelfTtl]. A TTL refetch is shuffled
  /// too, so every return reorders the shelf.
  Future<void> onReturnToHomepage() async {
    final fetchedAt = _lastFetchedAt;
    final isFresh =
        fetchedAt != null && _now().difference(fetchedAt) < _kShelfTtl;
    if (!isFresh || _rawItems.isEmpty) {
      await refresh(silent: true);
    }
    _reshuffle();
  }

  /// Locally reorders the cached top-50 (no network) so the shelf
  /// presents a different arrangement on every return to the homepage.
  void _reshuffle() {
    if (_rawItems.length < 2) return;
    _rawItems = List.of(_rawItems)..shuffle(_random);
    state = MostFollowedShelfState(
      items: _applyBlockFilter(_rawItems),
      isInitialLoading: false,
    );
  }

  /// Re-runs the blocked-author filter against the currently-displayed
  /// items and updates state in place (no network, preserves the current
  /// display order). Called from the [blockedUserIdsProvider] listener so
  /// a block committed elsewhere drops the blocked user's lists instantly.
  void reapplyBlockFilter() {
    if (_rawItems.isEmpty) return;
    final filtered = _applyBlockFilter(_rawItems);
    if (listEquals(filtered, state.items)) return;
    state = state.copyWith(items: filtered);
  }

  List<UserList> _applyBlockFilter(List<UserList> items) {
    final blocked = _ref.read(blockedUserIdsProvider);
    return filterByBlockedAuthors(items, blocked);
  }

  Future<UserListsResponse> _fetchTopLists() async {
    final api = _ref.read(listsApiProvider);
    final resolved = await _ref.read(resolvedSearchLocationProvider.future);
    final coords = resolved.center;
    return api.listPublicLists(
      // PROD-2416: all-time save count (follower_count DESC), NOT
      // `popular_last_week` (last-7-day follow events).
      sort: 'popular',
      latitude: coords?.lat,
      longitude: coords?.lon,
      radiusKm: coords == null ? null : resolved.radiusKm,
      locationSource: coords == null ? null : 'picker',
      limit: _kFetchLimit,
      offset: 0,
    );
  }
}

final mostFollowedShelfProvider =
    StateNotifierProvider.autoDispose<
      MostFollowedShelfNotifier,
      MostFollowedShelfState
    >((ref) {
      // Outlive the per-frame consumer so the shelf's data survives the
      // transient refCount→0 dips during search-overlay open/close and
      // route transitions (same rationale as [trendingShelfProvider]).
      ref.keepAlive();
      final notifier = MostFollowedShelfNotifier(ref);
      // PROD-2743 — refetch when the RESOLVED picker coords change. We listen to
      // `resolvedSearchLocationProvider` (settled lat/lon) rather than raw
      // `cityScopeProvider` to dodge the AsyncLoading interleave and stale-read
      // races. The seed comes from a direct `ref.read` at registration — NOT a
      // "skip the first settle" flag — because `ref.listen` never replays the
      // already-present value, and this FutureProvider is non-autoDispose
      // (usually already cached by the home shelves before this one is built).
      // A skip-first-settle guard would then mistake the FIRST real change for
      // the seed and swallow it — the overlay auto→manual bug, reproduced in
      // `shelf_location_refetch_test.dart` (REPRO). `select(valueOrNull)`
      // ignores AsyncLoading ticks; records compare structurally.
      var lastCoords = ref
          .read(resolvedSearchLocationProvider)
          .valueOrNull
          ?.center;
      ref.listen(
        resolvedSearchLocationProvider.select((c) => c.valueOrNull?.center),
        (_, next) {
          if (next == lastCoords) return;
          lastCoords = next;
          notifier.refresh();
        },
      );
      // Drop a blocked author's lists from the shelf without a refetch.
      ref.listen(blockedUserIdsProvider, (prev, next) {
        if (prev == next) return;
        notifier.reapplyBlockFilter();
      });
      // PROD-2654 — keepAlive() survives logout; reset on account change so
      // the next account doesn't inherit the previous account's
      // blocked-filtered list set. `clear()` on logout, `refresh()` on login.
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
