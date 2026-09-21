import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/exceptions/api_exceptions.dart';
import '../../../core/utils/provider_cache.dart';
import '../../../data/datasources/interfaces/api_interfaces.dart';
import '../../../data/models/library_feed.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../models/library_filter.dart';

/// Lands with no category. Named `libraryTabProvider` so hot reload drops the old Eventos default.
///
/// NOT autoDispose: the selected tab must survive a trip to Home and back.
/// `LibraryScreen` no longer resets it on mount.
final libraryTabProvider = StateProvider<LibraryFilter>(
  (_) => LibraryFilter.initial,
);

final librarySearchOpenProvider = StateProvider.autoDispose<bool>((_) => false);

/// Immediate query for zines. Server feeds watch [librarySearchDebouncedQueryProvider].
final librarySearchQueryProvider = StateProvider.autoDispose<String>((_) => '');

/// Debounced copy of [librarySearchQueryProvider] for server feeds.
final librarySearchDebouncedQueryProvider = StateProvider.autoDispose<String>(
  (_) => '',
);

void resetLibrarySearch(WidgetRef ref) {
  ref.read(librarySearchQueryProvider.notifier).state = '';
  ref.read(librarySearchDebouncedQueryProvider.notifier).state = '';
}

/// Merged-feed `sort` query. Default `recent`. Typed feeds watch this too.
/// Not autoDispose — same reason as [libraryTabProvider].
final librarySortProvider = StateProvider<LibrarySort>(
  (_) => LibrarySort.recent,
);

/// List vs grid layout for `/library` rows. Not autoDispose — same reason as
/// [libraryTabProvider].
final libraryViewProvider = StateProvider<LibraryViewMode>(
  (_) => LibraryViewMode.list,
);

/// Last scroll offset of `/library`, restored on the next mount so a trip to
/// Home and back lands where the user left off.
final libraryScrollOffsetProvider = StateProvider<double>((_) => 0);

/// Local calendar days that have a saved event, for the Date dropdown.
final libraryEventHighlightDaysProvider =
    StateProvider.autoDispose<Set<DateTime>>((_) => {});

/// Page size for `GET /users/me/library`. Spec default is 20; max is 50.
const int kLibraryPageSize = 20;

@immutable
class LibraryFeedState {
  final List<LibraryFeedItem> items;
  final String? nextCursor;
  final bool loading;
  final bool loadingMore;
  final Object? error;
  final Object? loadMoreError;

  const LibraryFeedState({
    this.items = const [],
    this.nextCursor,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.loadMoreError,
  });

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  LibraryFeedState copyWith({
    List<LibraryFeedItem>? items,
    String? nextCursor,
    bool clearCursor = false,
    bool? loading,
    bool? loadingMore,
    Object? error,
    bool clearError = false,
    Object? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return LibraryFeedState(
      items: items ?? this.items,
      nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

/// 422 (or a thrown [ValidationException]) on a paged `GET` means the cursor
/// is stale — drop it and refetch page 1. Never retry the same cursor.
bool isStaleLibraryCursor(Object error) {
  if (error is ValidationException) return true;
  if (error is DioException) {
    if (error.response?.statusCode == 422) return true;
    final inner = error.error;
    if (inner is ValidationException) return true;
  }
  return false;
}

/// Pin cap or a system pin. The interceptor maps every 409 to
/// [EmailExistsException] except onboarding zines ([NotReadyException]).
bool isLibraryPinConflict(Object error) {
  if (error is EmailExistsException || error is NotReadyException) return true;
  if (error is ApiException && error.statusCode == 409) return true;
  if (error is DioException) {
    if (error.response?.statusCode == 409) return true;
    final inner = error.error;
    if (inner is Object && isLibraryPinConflict(inner)) return true;
  }
  return false;
}

class LibraryFeedNotifier extends StateNotifier<LibraryFeedState> {
  LibraryFeedNotifier(
    this._api,
    this._q,
    this._sort, {
    this.types,
    this.membership,
    this.when,
    this.fromDate,
    this.toDate,
  }) : super(const LibraryFeedState());

  final ILibraryApi _api;
  final String _q;
  final LibrarySort _sort;

  /// Null `types` = merged feed.
  final String? types;
  final String? membership;
  final String? when;
  final String? fromDate;
  final String? toDate;

  Future<LibraryFeedOut> _get({String? cursor}) {
    return _api.getLibrary(
      limit: kLibraryPageSize,
      cursor: cursor,
      sort: _sort.wire,
      types: types,
      q: _q.isEmpty ? null : _q,
      membership: membership,
      when: when,
      fromDate: fromDate,
      toDate: toDate,
    );
  }

  Future<void> refresh({bool silent = false}) async {
    final keepItems = silent && state.items.isNotEmpty;
    state = keepItems
        ? state.copyWith(
            clearError: true,
            clearLoadMoreError: true,
            loadingMore: false,
          )
        : state.copyWith(
            loading: true,
            clearError: true,
            clearLoadMoreError: true,
            clearCursor: true,
          );
    try {
      final out = await _get();
      if (!mounted) return;
      state = keepItems
          ? _mergeFreshFirstPage(out)
          : LibraryFeedState(items: out.items, nextCursor: out.nextCursor);
    } catch (e) {
      if (!mounted) return;
      if (keepItems) {
        // Keep the painted page. A 422 on page 1 after detail is not a
        // paging ghost — do not wipe rows the user just came back to.
        state = state.copyWith(loading: false, loadingMore: false);
        return;
      }
      if (isStaleLibraryCursor(e)) {
        state = LibraryFeedState(error: e);
        return;
      }
      state = LibraryFeedState(error: e);
    }
  }

  /// Fold a freshly fetched page 1 into an already-paged feed.
  ///
  /// A silent refresh only suppresses the SPINNER. Replacing `items` wholesale
  /// would also throw away every page the user had scrolled into — a feed
  /// paged out to 100 rows would snap back to 20 the moment they returned
  /// from Home or backed out of a detail, with the restored scroll offset
  /// landing past the end of the shortened list.
  ///
  /// So: take the fresh page 1, keep everything the old list held BEYOND the
  /// first page, and drop any retained row that page 1 now carries (an item
  /// can move up between fetches, and a duplicate row is worse than a stale
  /// one). The cursor stays the OLD one, because the retained tail is what
  /// paging must continue after — `out.nextCursor` points just past page 1
  /// and would re-serve pages the user already has. A tail cursor that has
  /// since gone stale is not a new problem: `loadMore` already treats 422 as
  /// "drop the cursor and refetch page 1".
  LibraryFeedState _mergeFreshFirstPage(LibraryFeedOut out) {
    final previous = state.items;
    if (previous.length <= kLibraryPageSize) {
      // Nothing was paged in, so this is an ordinary page-1 refresh and the
      // fresh cursor is the correct one.
      return LibraryFeedState(items: out.items, nextCursor: out.nextCursor);
    }
    String keyOf(LibraryFeedItem item) => '${item.type.wire}:${item.id}';
    final seen = {for (final item in out.items) keyOf(item)};
    return LibraryFeedState(
      items: [
        ...out.items,
        for (final item in previous.skip(kLibraryPageSize))
          if (seen.add(keyOf(item))) item,
      ],
      nextCursor: state.nextCursor,
    );
  }

  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null ||
        cursor.isEmpty ||
        state.loading ||
        state.loadingMore) {
      return;
    }
    state = state.copyWith(loadingMore: true, clearLoadMoreError: true);
    try {
      final out = await _get(cursor: cursor);
      if (!mounted) return;
      state = state.copyWith(
        items: [...state.items, ...out.items],
        nextCursor: out.nextCursor,
        clearCursor: out.nextCursor == null,
        loadingMore: false,
      );
    } catch (e) {
      if (!mounted) return;
      if (isStaleLibraryCursor(e)) {
        await refresh();
        return;
      }
      state = state.copyWith(loadingMore: false, loadMoreError: e);
    }
  }
}

LibraryFeedNotifier _libraryFeedNotifier(Ref ref, LibraryFilter filter) {
  final q = ref.watch(librarySearchDebouncedQueryProvider).trim();
  final sort = ref.watch(librarySortProvider);
  final category = filter.category;
  final range = libraryEventDateQuery(filter);
  final notifier = LibraryFeedNotifier(
    ref.watch(libraryApiProvider),
    q,
    sort,
    types: category == null ? null : libraryFeedTypeFor(category).wire,
    membership: libraryMembershipQuery(filter),
    when: libraryWhenQuery(filter),
    fromDate: range.fromDate,
    toDate: range.toDate,
  );
  // Guests 401 on GET /users/me/library — skip until signed in.
  if (ref.watch(isAuthenticatedProvider)) {
    Future<void>.microtask(notifier.refresh);
  }
  return notifier;
}

/// How long a parked library page keeps its rows. A tab swap or a trip to
/// Home unmounts the feed's only listener; without this the next visit
/// refetches from page 1 behind a spinner. Freshness comes from
/// `LibraryScreen`'s silent revalidate on mount, not from tearing the page
/// down (PROD-3269's `cacheFor`, same idea as the Discovery shelves).
const Duration kLibraryFeedCacheTtl = Duration(minutes: 30);

/// Merged landing feed. Recreated when query or sort changes so paging
/// starts at page 1.
final libraryFeedProvider =
    StateNotifierProvider.autoDispose<LibraryFeedNotifier, LibraryFeedState>((
      ref,
    ) {
      ref.cacheFor(kLibraryFeedCacheTtl);
      return _libraryFeedNotifier(ref, LibraryFilter.initial);
    });

/// Hard ceiling on how many typed pages stay parked at once.
///
/// The tab space itself is small — Eventos (all / Futuros / Passados), Zines
/// (Tuas / Seguidas / Feitas para ti), Sítios, Pessoas — about eight keys. The
/// Date chip is what makes the key space open-ended: [LibraryFilter] carries
/// `selectedDate`, so every day tapped in the calendar mints its own page.
/// Twenty days browsed is twenty parked pages, each holding up to
/// [kLibraryPageSize] rows for the whole TTL with nothing reclaiming them.
///
/// Twelve keeps the entire fixed tab set resident and leaves a few slots for
/// recent dates. Beyond that, the least-recently-used page is dropped.
const int kMaxParkedLibraryPages = 12;

/// Least-recently-used bound over the parked typed pages.
///
/// `cacheFor` alone is a TTL with no ceiling — it answers "how long" and says
/// nothing about "how many". This answers the second question by holding each
/// page's [KeepAliveLink] in an insertion-ordered map and closing the oldest
/// once the map outgrows [kMaxParkedLibraryPages]. Closing a link does not
/// dispose anything by itself; it just hands the provider back to
/// `autoDispose`, which reclaims it when its last listener goes. The page the
/// user is looking at is therefore never at risk: it has a listener, and
/// [touch] has just moved it to the most-recent end anyway.
class ParkedLibraryPages {
  ParkedLibraryPages({this.maxPages = kMaxParkedLibraryPages});

  final int maxPages;

  /// Insertion-ordered (Dart `Map` is a `LinkedHashMap`), oldest first.
  /// Re-inserting a key moves it to the most-recent end.
  final Map<LibraryFilter, KeepAliveLink> _links = {};

  @visibleForTesting
  List<LibraryFilter> get parked => _links.keys.toList(growable: false);

  /// Register a freshly built page and evict down to [maxPages].
  void park(LibraryFilter key, KeepAliveLink link) {
    _links.remove(key);
    _links[key] = link;
    while (_links.length > maxPages) {
      final oldest = _links.keys.first;
      _links.remove(oldest)?.close();
    }
  }

  /// Mark a page as just used. Without this the order would be build order,
  /// not use order — and build order evicts exactly the wrong pages, since
  /// the fixed tabs are built first and a run of date picks would push them
  /// all out.
  void touch(LibraryFilter key) {
    final link = _links.remove(key);
    if (link != null) _links[key] = link;
  }

  /// Drop the bookkeeping for a page that has been disposed (TTL expiry,
  /// eviction, or the cross-account purge).
  void forget(LibraryFilter key) => _links.remove(key);
}

/// Owns the LRU bound for this container's lifetime. Holds no account data —
/// entries are cleaned up by each page's own `onDispose`, including on the
/// cross-account purge.
final parkedLibraryPagesProvider = Provider<ParkedLibraryPages>(
  (_) => ParkedLibraryPages(),
);

/// Per-tab library page, keyed on the WHOLE [LibraryFilter] rather than the
/// item type. The cursor and the `membership` / `when` / date query are all
/// scoped to one tab + sub-filter, so each combination owns its own parked
/// page. Keying on the type alone and reading the live tab inside would
/// rebuild every kept-alive sibling with the wrong (null) params the moment
/// the user swapped tabs.
///
/// Parked pages are bounded by [ParkedLibraryPages] — see
/// [kMaxParkedLibraryPages] for why the Date chip makes that necessary.
final libraryTypedFeedProvider = StateNotifierProvider.autoDispose
    .family<LibraryFeedNotifier, LibraryFeedState, LibraryFilter>((
      ref,
      filter,
    ) {
      final parked = ref.read(parkedLibraryPagesProvider);
      parked.park(filter, ref.cacheFor(kLibraryFeedCacheTtl));
      ref.onDispose(() => parked.forget(filter));
      return _libraryFeedNotifier(ref, filter);
    });

/// How a mount should refresh a parked page.
///
/// * `null` — a fetch is already in flight; do nothing. The boot warm's
///   request is often still in the air on the first visit.
/// * `true` — rows are painted, so refresh **silently**: they stay on screen
///   while page 1 refetches and a return trip never flashes a spinner.
/// * `false` — the page is empty or errored, so refresh **loudly**. This is
///   the one that matters: `cacheFor` parks a failed page for the whole TTL,
///   and without this the user keeps landing on the same error block with no
///   retry. Skipping the refresh here was a regression against the old
///   `autoDispose` behaviour, where a remount rebuilt and recovered by itself.
bool? libraryMountRefreshMode(LibraryFeedState state) {
  if (state.loading || state.loadingMore) return null;
  return state.items.isNotEmpty;
}

/// The feed backing [filter]: the merged landing feed when no category is
/// selected, otherwise that tab's own page.
AutoDisposeStateNotifierProvider<LibraryFeedNotifier, LibraryFeedState>
libraryFeedFor(LibraryFilter filter) {
  return filter.category == null
      ? libraryFeedProvider
      : libraryTypedFeedProvider(filter);
}
