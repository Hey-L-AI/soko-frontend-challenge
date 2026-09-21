import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/social/user_search_item.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';
import '../services/contact_sync_service.dart';
import '../utils/locals_shuffle.dart';

/// People discovery — search + suggestions (PROD-2777 / PROD-2821), phase 4.

/// Contact discovery service (mobile-only) — reads the address book, hashes
/// phones, and matches against Soko users.
final contactSyncServiceProvider = Provider<ContactSyncService>((ref) {
  return ContactSyncService(ref.watch(peopleApiProvider));
});

/// Session cache of the last successful contact sync (a matched list). The Find
/// Contacts screen holds its phase in local widget state, so navigating away and
/// back would otherwise rebuild it into the "Sync contacts" intro even after a
/// successful sync. Restoring from this cache on mount keeps the results
/// visible. Populated only for successful, non-empty matches; lives for the app
/// session and clears on restart. See [ContactMatchesScreen].
class ContactSyncCache extends Notifier<ContactSyncResult?> {
  @override
  ContactSyncResult? build() => null;

  void store(ContactSyncResult result) => state = result;
}

final contactSyncCacheProvider =
    NotifierProvider<ContactSyncCache, ContactSyncResult?>(
      ContactSyncCache.new,
    );

/// Search users by handle (prefix) or name (substring). The backend requires
/// >= 2 chars; shorter queries short-circuit to an empty result.
///
/// A leading `@` is stripped so typing `@handle` searches the same as `handle`
/// (users naturally prefix handles with `@`; the stored handle has none).
final peopleSearchProvider = FutureProvider.autoDispose
    .family<UserSearchListResponse, String>((ref, query) async {
      var q = query.trim();
      if (q.startsWith('@')) q = q.substring(1).trim();
      if (q.length < 2) {
        return const UserSearchListResponse(items: [], total: 0);
      }
      return ref.watch(peopleApiProvider).search(q);
    });

/// Page size of the suggestions list for the pages AFTER the first. The first
/// page is [_suggestionsFetchLimit] — see there for why the two differ.
const int _suggestionsPageSize = 20;

/// How many suggestions the first fetch asks for — deeper than any surface
/// displays, so [shuffleLocals] has people to rotate *between*.
///
/// The Locals shelf shows ten. Fetching only what it shows meant every
/// re-order drew from the same twenty names, and the measured tie band is
/// wider than that: twelve equally-ranked people were competing for eight
/// slots and forty-six more never surfaced at all. 50 is the endpoint's
/// ceiling (`maximum: 50` on `/users/suggested`), so it is as deep as the
/// client can reach without a backend change.
///
/// Reaching further means rotating server-side — the seeded bucket-shuffle
/// `venues_with_events.py` already uses for Espaços (PROD-2745).
const int _suggestionsFetchLimit = 50;

/// How long the first page survives with nothing watching it. Long enough to
/// cover navigating away and back (Discovery is a `ShellRoute`, so switching
/// bottom-nav tabs destroys the screen and, with plain autoDispose, the list
/// with it); short enough that the ranking is never stale for long. A
/// suggestions list is not time-critical.
const Duration _suggestionsCacheWindow = Duration(minutes: 5);

/// Suggested users to follow — "Locals near you" + friends-of-friends.
///
/// The first page, and the ONLY fetch of it anywhere: the Discovery **Locals
/// shelf**, the search overlay's **Leitores** tab, the profile's Locals tab and
/// the find-people page's first page all read this one provider (the last via
/// [suggestedUsersPagedProvider]). It used to be shared like that, then the
/// pagination work gave find-people a private provider and the app started
/// re-fetching 20 names it already had in memory — half a second of empty
/// section on every entry (PROD-3800).
///
/// Scoped to the Discovery picker city (PROD-3748): watches
/// [resolvedSearchLocationProvider] so the shelf re-fetches — and the *locals*
/// tier re-ranks against the picked city — whenever the city changes.
final suggestedUsersProvider =
    FutureProvider.autoDispose<UserSearchListResponse>((ref) async {
      _keepAliveFor(ref, _suggestionsCacheWindow);
      final loc = await ref.watch(resolvedSearchLocationProvider.future);
      return ref
          .watch(peopleApiProvider)
          .suggested(
            limit: _suggestionsFetchLimit,
            cityId: loc.cityId,
            latitude: loc.centerLat,
            longitude: loc.centerLon,
            locationSource: 'picker',
          );
    });

/// Bumped to re-roll the Locals order without going back to the network.
///
/// Mirrors how "Mais seguidas" stays fresh (PROD-2416 / PROD-3242): the fetch
/// is expensive — `/users/suggested` measures 450–600 ms, most of it the
/// backend re-ranking the pool — and it returns the same ranking every time,
/// so refetching to get variety costs a lot and changes nothing. Re-ordering
/// the response we already hold costs nothing and changes everything.
///
/// [LocalsShelf] bumps this on the transition back into Discovery.
final localsOrderSeedProvider = StateProvider<int>((ref) => 0);

/// [suggestedUsersProvider]'s response, ordered for display by
/// [shuffleLocals]: profile photos favoured, backend ranking still counted, and
/// a different draw each time [localsOrderSeedProvider] moves.
///
/// Every Locals surface reads THIS, not the raw fetch, so the shelf and Find
/// People always agree on who is where. The raw provider stays untouched
/// underneath, keeping its keep-alive window and its city scope.
final orderedSuggestedUsersProvider =
    FutureProvider.autoDispose<UserSearchListResponse>((ref) async {
      final res = await ref.watch(suggestedUsersProvider.future);
      // Watched, not read: bumping the seed re-runs exactly this, and the
      // awaited fetch above is already cached, so no request is issued.
      ref.watch(localsOrderSeedProvider);
      return UserSearchListResponse(
        items: shuffleLocals(res.items, Random()),
        total: res.total,
      );
    });

/// Hold an autoDispose provider's value for [window] after its last listener
/// goes, instead of dropping it the moment the screen unmounts.
void _keepAliveFor(Ref ref, Duration window) {
  final link = ref.keepAlive();
  final timer = Timer(window, link.close);
  ref.onDispose(timer.cancel);
}

/// Paginated suggested-users state for the find-people page's "Locais
/// sugeridos" list — loads more as the user scrolls until the ranked
/// candidate pool is exhausted (it's a finite ranked list, not an endless
/// feed). [items] holds every row fetched from the server (client-side
/// dismissals are filtered at render time, so they don't shift the offset).
class SuggestedUsersState {
  final List<UserSearchItem> items;

  /// Server offset for the next page = number of rows fetched so far.
  final int nextOffset;
  final bool hasMore;
  final bool isLoadingMore;
  final Object? loadMoreError;

  const SuggestedUsersState({
    this.items = const [],
    this.nextOffset = 0,
    this.hasMore = true,
    this.isLoadingMore = false,
    this.loadMoreError,
  });

  SuggestedUsersState copyWith({
    List<UserSearchItem>? items,
    int? nextOffset,
    bool? hasMore,
    bool? isLoadingMore,
    Object? loadMoreError,
    bool clearError = false,
  }) {
    return SuggestedUsersState(
      items: items ?? this.items,
      nextOffset: nextOffset ?? this.nextOffset,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
    );
  }
}

class SuggestedUsersPaged
    extends AutoDisposeAsyncNotifier<SuggestedUsersState> {
  static const int _pageSize = _suggestionsPageSize;

  @override
  Future<SuggestedUsersState> build() async {
    // Page 1 IS [orderedSuggestedUsersProvider] — same endpoint, same city
    // scope, same rows, same order as the Locals shelf. Watching it instead of
    // issuing a private copy means arriving from the shelf (or the profile's
    // Locals tab) paints on the first frame off the already-loaded response,
    // and a cold arrival still costs exactly one request, now shared with
    // whatever asks next (PROD-3800).
    //
    // Reading the ORDERED provider also means the shelf and this list never
    // disagree about who is where — arriving from the shelf, the first faces
    // are the ones just tapped past.
    //
    // City scope comes with it: that provider watches
    // [resolvedSearchLocationProvider], so a city change rebuilds this notifier
    // from offset 0 and pages never mix scopes.
    //
    // Consequence worth knowing: anything that invalidates the shared provider
    // (a follow from the search row, which deliberately refreshes Locals)
    // rebuilds this list back to page 1. That is the intended refresh, and the
    // suggestions list is hidden while search is open. A seed bump does the
    // same, but it only fires on the way back INTO Discovery — by which point
    // this screen has been popped, so no one is mid-scroll when it happens.
    final first = await ref.watch(orderedSuggestedUsersProvider.future);
    return SuggestedUsersState(
      items: first.items,
      nextOffset: first.items.length,
      // Against the FETCH limit, not [_pageSize]: the first page is 50 rows,
      // so comparing to 20 would read a full page as a drained pool and kill
      // scrolling at the first screen.
      hasMore: first.items.length == _suggestionsFetchLimit,
    );
  }

  Future<void> loadMore() async {
    final cur = state.valueOrNull;
    if (cur == null ||
        !cur.hasMore ||
        cur.isLoadingMore ||
        cur.loadMoreError != null) {
      return;
    }
    state = AsyncData(cur.copyWith(isLoadingMore: true, clearError: true));
    try {
      // Same scope as build() — cached, and a city change would have rebuilt
      // this notifier, so the next page can't straddle two cities.
      final loc = await ref.read(resolvedSearchLocationProvider.future);
      final res = await ref
          .read(peopleApiProvider)
          .suggested(
            limit: _pageSize,
            offset: cur.nextOffset,
            cityId: loc.cityId,
            latitude: loc.centerLat,
            longitude: loc.centerLon,
            locationSource: 'picker',
          );
      // Order the new page WITHIN ITSELF and append. Re-ordering `cur.items`
      // too would reshuffle rows the reader is already looking at, moving the
      // list under their finger mid-scroll.
      final merged = [...cur.items, ...shuffleLocals(res.items, Random())];
      state = AsyncData(
        cur.copyWith(
          items: merged,
          nextOffset: merged.length,
          hasMore: res.items.length == _pageSize,
          isLoadingMore: false,
        ),
      );
    } catch (e) {
      state = AsyncData(cur.copyWith(isLoadingMore: false, loadMoreError: e));
    }
  }

  Future<void> retryLoadMore() async {
    final cur = state.valueOrNull;
    if (cur == null) return;
    state = AsyncData(cur.copyWith(clearError: true));
    await loadMore();
  }
}

final suggestedUsersPagedProvider =
    AsyncNotifierProvider.autoDispose<SuggestedUsersPaged, SuggestedUsersState>(
      SuggestedUsersPaged.new,
    );

/// Pull-to-refresh for Find People's "Locals suggested" list: re-fetch the
/// ranked pool and rebuild the paged list from page 1.
///
/// Invalidating the base fetch is enough — [orderedSuggestedUsersProvider]
/// re-shuffles the fresh response and [SuggestedUsersPaged.build] watches that,
/// so the notifier rebuilds off it. Pages the reader had loaded are dropped,
/// which is what a refresh means here. The list stays on screen throughout:
/// the rebuild is a *refresh* in Riverpod's sense (previous value retained),
/// and `AsyncValue.when` skips the loading branch for those by default.
///
/// The returned future stays pending until the fetch resolves so
/// `CupertinoSliverRefreshControl` holds its spinner while real data loads.
/// 600 ms floor prevents a flash-collapse on an instant (cached) response; 4 s
/// ceiling stops a hung API from stranding the spinner. Mirrors
/// `refreshDiscoveryFeed`.
Future<void> refreshSuggestedPeople(WidgetRef ref) async {
  ref.invalidate(suggestedUsersProvider);
  await Future.wait<void>([
    Future<void>.delayed(const Duration(milliseconds: 600)),
    // Errors swallowed — the section renders its own error state.
    ref
        .read(orderedSuggestedUsersProvider.future)
        .then<void>((_) {}, onError: (_) {})
        .timeout(const Duration(seconds: 4), onTimeout: () {}),
  ]);
}

/// User IDs the viewer dismissed from the "Locals suggested" surfaces this
/// session (client-side hide via the "X"). Shared by the profile Locals tab and
/// the Find People suggestions so a dismissal hides the person on both. Kept
/// out of [suggestedUsersProvider] so re-fetching doesn't clear dismissals.
class DismissedSuggestions extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void dismiss(String userId) => state = {...state, userId};
}

final dismissedSuggestionsProvider =
    NotifierProvider<DismissedSuggestions, Set<String>>(
      DismissedSuggestions.new,
    );
