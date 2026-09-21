import 'dart:math' show max;

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/exceptions/api_exceptions.dart';
import '../core/services/app_group_bridge.dart';
import '../core/services/storage_service.dart';
import '../core/services/unified_analytics_service.dart';
import '../core/utils/note_text.dart';
import '../data/models/models.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import 'api_provider.dart';
import 'auth_provider.dart';

/// State for user lists
/// Signal emitted when an item is removed from a list via
/// `ListsNotifier.removeFromLists` (the bookmark-sheet un-check flow). The
/// `unifiedListProvider` picks this up from `ListsState.recentRemovals` and
/// reconciles its local `state.items` without a full refetch. (PROD-1395)
class RemovedItemSignal {
  final String listId;
  final String? eventId;
  final String? venueId;
  final String? googlePlaceId;

  /// PROD-3873 — the backend removal cascaded: for the OWNER, removing an
  /// entity removes it from every list of theirs holding it (Saved Items, the
  /// typed lists, and every zine), not just [listId]. A cascade signal tells
  /// every mounted OWNED list view to drop the entity by content, keeping the
  /// coupled auto-managed lists (Saved Items / My Places / My Events) in sync.
  /// Normal (non-cascade) signals still reconcile only the matching [listId] —
  /// a collaborator's single-row removal must not touch other lists.
  final bool cascade;

  const RemovedItemSignal({
    required this.listId,
    this.eventId,
    this.venueId,
    this.googlePlaceId,
    this.cascade = false,
  });
}

class ListsState {
  final List<UserList> lists;
  final List<UserList> followingLists;
  final List<SuggestedList> suggestedLists;
  final List<UserList> curatedLists;
  final List<UserList> recommendedLists;
  final UserList? defaultList;
  final bool isLoading;
  final bool isLoadingFollowing;
  final bool isLoadingSuggested;
  final bool isLoadingCurated;

  /// Whether a scope change (local ↔ worldwide) is refreshing data.
  /// When true, stale content stays visible with a dimming overlay.
  final bool isRefreshingScope;

  /// Whether each section has more items beyond what's displayed
  final bool hasMoreOwned;
  final bool hasMoreCurated;
  final bool hasMoreFollowing;
  final bool hasMoreRecommended;
  final String? error;

  /// IDs of events saved in any owned list (for saved indicator)
  final Set<String> savedEventIds;

  /// IDs of venues saved in any owned list (for saved indicator)
  final Set<String> savedVenueIds;

  /// Google Place IDs saved in any owned list (for matching external places)
  final Set<String> savedGooglePlaceIds;

  /// Whether the saved item cache has been loaded
  final bool isSavedCacheLoaded;

  /// Pending optimistic items not yet confirmed by backend.
  /// Map of listId -> `List<OptimisticListItem>`.
  final Map<String, List<OptimisticListItem>> pendingItems;

  /// Append-only log of items removed via `removeFromLists` — used by
  /// `unifiedListProvider` to update its local items list when a removal
  /// happens outside its own `removeItem` call (e.g., the bookmark sheet
  /// unchecking a list the user is currently viewing).
  ///
  /// The consumer listens for length changes and processes any new entries
  /// whose `listId` matches its `listIdKeys`. Kept bounded (rolling window
  /// of 50 entries) to prevent unbounded growth. (PROD-1395)
  final List<RemovedItemSignal> recentRemovals;

  /// IDs of lists deleted via `deleteList()` after the API call succeeded.
  /// Used by `yoursShelfProvider` (in-memory removal) and
  /// `listsHubItemsProvider` (map-pin / calendar-event filter against
  /// read-after-write lag) to suppress the deleted list from /yours
  /// without waiting for a network refetch. (PROD-2084)
  ///
  /// Bounded — see `_appendListId` for the capping logic.
  /// **Not** a "did the API succeed" signal: deletions that fail never
  /// reach this set, so consumers can treat membership as authoritative.
  final Set<String> recentlyDeletedListIds;

  /// IDs of lists unfollowed via `UnifiedListNotifier.toggleFollow()`
  /// after the unfollow API call succeeded. Mirror of
  /// [recentlyDeletedListIds] for the "A seguir" surfaces of `/yours`:
  /// `followingShelfProvider` (drops cards immediately) and the
  /// `mode=following` branch of `listsHubItemsProvider` (drops map pins
  /// and calendar events whose `listId` matches). PROD-2128 —
  /// `listsSearchResultsProvider` does NOT consult this set because the
  /// BE's `scope=following` filter already evaluates the user's
  /// currently-followed lists at query time, and the search-call
  /// debounce + post-API-success tombstone write makes the gap
  /// vanishingly small.
  ///
  /// Bounded via the same `_appendListId` helper. Authoritative —
  /// failed unfollows never reach this set.
  final Set<String> recentlyUnfollowedListIds;

  /// IDs of lists just created via `createList()` after the API call
  /// succeeded. Consumed by `yoursShelfProvider._onListsProviderChanged`
  /// to prepend the freshly-created zine into the shelf immediately —
  /// without that signal the shelf listener only knows how to patch
  /// existing items or drop tombstoned ones, so a newly-created list
  /// stayed invisible until the screen unmounted and re-drained from BE
  /// (the "go home, come back" recovery the user discovered in
  /// PROD-2216). Mirror of [recentlyDeletedListIds] in spirit — same
  /// `_appendListId` cap, same authoritative semantics (failed creates
  /// never reach this set).
  final Set<String> recentlyCreatedListIds;

  const ListsState({
    this.lists = const [],
    this.followingLists = const [],
    this.suggestedLists = const [],
    this.curatedLists = const [],
    this.recommendedLists = const [],
    this.defaultList,
    this.isLoading = false,
    this.isLoadingFollowing = false,
    this.isLoadingSuggested = false,
    this.isLoadingCurated = false,
    this.isRefreshingScope = false,
    this.hasMoreOwned = false,
    this.hasMoreCurated = false,
    this.hasMoreFollowing = false,
    this.hasMoreRecommended = false,
    this.error,
    this.savedEventIds = const {},
    this.savedVenueIds = const {},
    this.savedGooglePlaceIds = const {},
    this.isSavedCacheLoaded = false,
    this.pendingItems = const {},
    this.recentRemovals = const [],
    this.recentlyDeletedListIds = const {},
    this.recentlyUnfollowedListIds = const {},
    this.recentlyCreatedListIds = const {},
  });

  ListsState copyWith({
    List<UserList>? lists,
    List<UserList>? followingLists,
    List<SuggestedList>? suggestedLists,
    List<UserList>? curatedLists,
    List<UserList>? recommendedLists,
    UserList? defaultList,
    bool? isLoading,
    bool? isLoadingFollowing,
    bool? isLoadingSuggested,
    bool? isLoadingCurated,
    bool? isRefreshingScope,
    bool? hasMoreOwned,
    bool? hasMoreCurated,
    bool? hasMoreFollowing,
    bool? hasMoreRecommended,
    String? error,
    Set<String>? savedEventIds,
    Set<String>? savedVenueIds,
    Set<String>? savedGooglePlaceIds,
    bool? isSavedCacheLoaded,
    Map<String, List<OptimisticListItem>>? pendingItems,
    List<RemovedItemSignal>? recentRemovals,
    Set<String>? recentlyDeletedListIds,
    Set<String>? recentlyUnfollowedListIds,
    Set<String>? recentlyCreatedListIds,
  }) {
    return ListsState(
      lists: lists ?? this.lists,
      followingLists: followingLists ?? this.followingLists,
      suggestedLists: suggestedLists ?? this.suggestedLists,
      curatedLists: curatedLists ?? this.curatedLists,
      recommendedLists: recommendedLists ?? this.recommendedLists,
      defaultList: defaultList ?? this.defaultList,
      isLoading: isLoading ?? this.isLoading,
      isLoadingFollowing: isLoadingFollowing ?? this.isLoadingFollowing,
      isLoadingSuggested: isLoadingSuggested ?? this.isLoadingSuggested,
      isLoadingCurated: isLoadingCurated ?? this.isLoadingCurated,
      isRefreshingScope: isRefreshingScope ?? this.isRefreshingScope,
      hasMoreOwned: hasMoreOwned ?? this.hasMoreOwned,
      hasMoreCurated: hasMoreCurated ?? this.hasMoreCurated,
      hasMoreFollowing: hasMoreFollowing ?? this.hasMoreFollowing,
      hasMoreRecommended: hasMoreRecommended ?? this.hasMoreRecommended,
      error: error,
      savedEventIds: savedEventIds ?? this.savedEventIds,
      savedVenueIds: savedVenueIds ?? this.savedVenueIds,
      savedGooglePlaceIds: savedGooglePlaceIds ?? this.savedGooglePlaceIds,
      isSavedCacheLoaded: isSavedCacheLoaded ?? this.isSavedCacheLoaded,
      pendingItems: pendingItems ?? this.pendingItems,
      recentRemovals: recentRemovals ?? this.recentRemovals,
      recentlyDeletedListIds:
          recentlyDeletedListIds ?? this.recentlyDeletedListIds,
      recentlyUnfollowedListIds:
          recentlyUnfollowedListIds ?? this.recentlyUnfollowedListIds,
      recentlyCreatedListIds:
          recentlyCreatedListIds ?? this.recentlyCreatedListIds,
    );
  }

  /// Get owned lists (excluding default)
  List<UserList> get ownedLists =>
      lists.where((l) => !l.isDefault && l.isOwner).toList();

  /// Get default list ID
  String? get defaultListId => defaultList?.id;

  /// Get suggested lists excluding any that are already followed.
  /// This provides instant UI feedback when a list is followed.
  List<SuggestedList> get filteredSuggestedLists {
    final followingIds = followingLists.map((l) => l.id).toSet();
    return suggestedLists.where((s) => !followingIds.contains(s.id)).toList();
  }

  // sokoLists and recommendedLists are now populated directly from the
  // /discover or /curated endpoints — see curatedLists and recommendedLists fields.

  /// Get pending items for a specific list
  List<OptimisticListItem> getPendingItemsForList(String listId) {
    return pendingItems[listId] ?? [];
  }
}

/// Result of adding to lists with detailed status
class AddToListsResult {
  final bool success;
  final List<String> addedListIds;
  final List<String> failedListIds;
  final String? errorMessage;
  final bool isRetryable;

  const AddToListsResult({
    required this.success,
    this.addedListIds = const [],
    this.failedListIds = const [],
    this.errorMessage,
    this.isRetryable = false,
  });
}

/// Outcome of [ListsNotifier.quickSave] (PROD-3873). Sealed so the caller can
/// branch cleanly — most importantly to tell a shared-bucket rate-limit
/// (`429`) apart from a real failure and show the right copy.
sealed class QuickSaveResult {
  const QuickSaveResult();
}

/// The item was saved (or was already saved — idempotent). [listId] is the
/// Saved Items list the server resolved and filed it into.
///
/// The post-save sheet needs [listId]: a tip typed afterwards is written by
/// re-POSTing to this list, which the backend treats as an upsert on the tip.
class QuickSaveSuccess extends QuickSaveResult {
  final String listId;
  const QuickSaveSuccess(this.listId);
}

/// The shared 30/min lists-items bucket rejected this save (`429`). Distinct
/// from a failure so the UI can say "slow down" rather than "couldn't save".
class QuickSaveRateLimited extends QuickSaveResult {
  final int retryAfterSeconds;
  const QuickSaveRateLimited(this.retryAfterSeconds);
}

/// The backend refused to save this place (PROD-3872 #1328): a street/area, a
/// non-business, or a closed venue. [errorCode] ∈ {`PLACE_NOT_SAVEABLE`,
/// `PLACE_UNAVAILABLE`, `SAVE_FAILED`} — the caller maps it to localized copy
/// so quicksave shows the specific reason, not the generic "couldn't save".
class QuickSaveRejected extends QuickSaveResult {
  final String errorCode;
  const QuickSaveRejected(this.errorCode);
}

/// The save failed for any other reason. [message] is a diagnostic string.
class QuickSaveFailed extends QuickSaveResult {
  final String message;
  const QuickSaveFailed(this.message);
}

/// Notifier for user lists
class ListsNotifier extends StateNotifier<ListsState> {
  final IListsApi _api;
  final StorageService _storageService;
  final UnifiedAnalyticsService _analytics;

  /// Resolves the signed-in user's id, for the `owner_is_self` analytics
  /// property (PROD-3095). Injected as a callback — mirroring
  /// `UnifiedListNotifier` — so it always reads current auth rather than a
  /// snapshot, and so existing tests can keep constructing this notifier
  /// without it.
  final String? Function()? _getCurrentUserId;

  // Saved-state cache warming — SWR-style guard so redundant triggers don't
  // re-hit `GET /users/me/saved/entity-ids`. `loadAllOwnedItems()` skips the
  // fetch when the cache was loaded within [_savedIdsStaleWindow] and coalesces
  // concurrent callers onto one in-flight request. `loadAllOwnedItems(force:
  // true)` bypasses both — used for auth-flip, lists-hub pull-to-refresh, and
  // post-save/remove reconciles, where we must re-read the server's truth
  // (e.g. a removed item may still be saved in another list). PROD-2845 follow-up.
  static const Duration _savedIdsStaleWindow = Duration(minutes: 15);
  DateTime? _savedIdsLoadedAt;
  Future<void>? _savedIdsInflight;

  ListsNotifier(
    this._api,
    this._storageService,
    this._analytics, {
    String? Function()? getCurrentUserId,
  }) : _getCurrentUserId = getCurrentUserId,
       super(const ListsState()) {
    _loadFromStorage();
  }

  /// Load lists from local storage first (stale-while-revalidate)
  void _loadFromStorage() {
    final cachedLists = _storageService.loadUserLists();
    if (cachedLists.isNotEmpty) {
      final defaultList = cachedLists.where((l) => l.isDefault).firstOrNull;
      state = state.copyWith(lists: cachedLists, defaultList: defaultList);
    }
    // Also restore curated/following/recommended from cache
    final sections = _storageService.loadDiscoverSections();
    if (sections != null) {
      state = state.copyWith(
        curatedLists: sections.curated.isNotEmpty ? sections.curated : null,
        followingLists: sections.following.isNotEmpty
            ? sections.following
            : null,
        recommendedLists: sections.recommended.isNotEmpty
            ? sections.recommended
            : null,
      );
    }
  }

  /// Persist current lists and discover sections to storage
  Future<void> _persistToStorage() async {
    await _storageService.saveUserLists(state.lists);
    await _storageService.saveDiscoverSections(
      curated: state.curatedLists,
      following: state.followingLists,
      recommended: state.recommendedLists,
    );
    _writeAppGroupSnapshot();
  }

  /// Mirror the current owned lists into the App Group so the iOS Share
  /// Extension can render its picker without making a network call. Names
  /// only — no covers/items. Backend-managed lists (PROD-1741 `system_kind`
  /// — IG auto-list, onboarding seed, saved items, weekly bundle, user
  /// contributions) are flagged so the extension can hide them from the
  /// picker. PROD-2725 widened the flag from `isFromInstagram` to
  /// `isSystemManaged` so all system kinds are filtered, not just the IG
  /// auto-list.
  void _writeAppGroupSnapshot() {
    final snapshot = state.lists
        .map(
          (l) => AppGroupListSnapshot(
            id: l.id,
            name: l.name,
            isSystemManaged: l.isSystemManaged,
          ),
        )
        .toList();
    AppGroupBridge.instance.writeLists(snapshot);
  }

  /// Load all discovery sections in a single API call.
  /// Populates lists, curatedLists, followingLists, and recommendedLists.
  Future<void> loadDiscoverLists({
    String? scope,
    double? latitude,
    double? longitude,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    // Set loading flags only for sections that have no cached data.
    // Sections with data show stale content while refreshing (stale-while-revalidate).
    final hasAnyData = state.lists.isNotEmpty || state.curatedLists.isNotEmpty;
    state = state.copyWith(
      isLoading: state.lists.isEmpty ? true : null,
      isLoadingCurated: state.curatedLists.isEmpty ? true : null,
      isLoadingFollowing: state.followingLists.isEmpty ? true : null,
      isLoadingSuggested: state.recommendedLists.isEmpty ? true : null,
      isRefreshingScope: hasAnyData ? true : null,
    );

    try {
      final response = await _api.discoverLists(
        scope: scope,
        latitude: latitude,
        longitude: longitude,
        locationMode: locationMode,
        adminBoundaryId: adminBoundaryId,
      );

      final lists = response.yourLists.items;
      final defaultList = lists.where((l) => l.isDefault).firstOrNull;

      state = state.copyWith(
        lists: lists,
        defaultList: defaultList,
        curatedLists: response.curated.items,
        followingLists: response.following.items,
        recommendedLists: response.recommended.items,
        isLoading: false,
        isLoadingCurated: false,
        isLoadingFollowing: false,
        isLoadingSuggested: false,
        isRefreshingScope: false,
        hasMoreOwned: response.yourLists.hasMore,
        hasMoreCurated: response.curated.hasMore,
        hasMoreFollowing: response.following.hasMore,
        hasMoreRecommended: response.recommended.hasMore,
      );
      await _persistToStorage();

      // Populate saved items cache for bookmark indicators.
      // PROD-2845: `loadAllOwnedItems()` now hits the bulk `getSavedEntityIds`
      // endpoint — one request that returns full, deduped coverage of every
      // saved event/venue/google-place across all owned (+ collaborative)
      // lists. This supersedes the old per-list fan-out (and the PROD-2138
      // truncation caveats about the discover endpoint's 10-list `your_lists`
      // slice).
      // This runs from the lists-hub pull-to-refresh (`refresh()` →
      // `loadDiscoverLists`), so `force: true` bypasses the freshness window —
      // the user pulled precisely because they expect fresh data (and it's
      // their recovery path if a prior populate failed).
      loadAllOwnedItems(force: true);
    } catch (e) {
      final hasAnyData =
          state.lists.isNotEmpty || state.curatedLists.isNotEmpty;
      state = state.copyWith(
        isLoading: false,
        isLoadingCurated: false,
        isLoadingFollowing: false,
        isLoadingSuggested: false,
        isRefreshingScope: false,
        error: hasAnyData ? null : e.toString(),
      );
    }
  }

  /// Load curated/Soko lists. When [loadMore] is true, appends next page.
  Future<void> loadCuratedLists({
    bool loadMore = false,
    String? scope,
    double? latitude,
    double? longitude,
  }) async {
    final hasData = state.curatedLists.isNotEmpty;
    if (!hasData && !loadMore) {
      state = state.copyWith(isLoadingCurated: true);
    } else if (!loadMore) {
      state = state.copyWith(isRefreshingScope: true);
    }
    try {
      final offset = loadMore ? state.curatedLists.length : 0;
      final response = await _api.listCuratedLists(
        limit: 50,
        offset: offset,
        scope: scope,
        latitude: latitude,
        longitude: longitude,
      );
      final merged = loadMore
          ? [...state.curatedLists, ...response.items]
          : response.items;
      state = state.copyWith(
        curatedLists: merged,
        isLoadingCurated: false,
        isRefreshingScope: false,
        hasMoreCurated: merged.length < response.total,
      );
    } catch (e) {
      state = state.copyWith(isLoadingCurated: false, isRefreshingScope: false);
    }
  }

  /// Load user's own lists. When [loadMore] is true, appends next page.
  Future<void> loadLists({
    bool loadMore = false,
    String? scope,
    double? latitude,
    double? longitude,
  }) async {
    final hasData = state.lists.isNotEmpty;
    if (!hasData && !loadMore) {
      state = state.copyWith(isLoading: true, error: null);
    } else if (!loadMore) {
      state = state.copyWith(isRefreshingScope: true);
    }

    try {
      final offset = loadMore ? state.lists.length : 0;
      final response = await _api.listMyLists(
        limit: 50,
        offset: offset,
        scope: scope,
        latitude: latitude,
        longitude: longitude,
      );
      final lists = loadMore
          ? [...state.lists, ...response.items]
          : response.items;
      final defaultList = lists.where((l) => l.isDefault).firstOrNull;

      state = state.copyWith(
        lists: lists,
        defaultList: defaultList,
        isLoading: false,
        isRefreshingScope: false,
        hasMoreOwned: lists.length < response.total,
      );
      await _persistToStorage();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        isRefreshingScope: false,
        error: (hasData || loadMore) ? null : e.toString(),
      );
    }
  }

  /// Ensure default list exists and return it
  Future<UserList> ensureDefaultList() async {
    if (state.defaultList != null) {
      return state.defaultList!;
    }

    try {
      final defaultList = await _api.getDefaultList();

      // Add to lists if not already present
      final updatedLists = List<UserList>.from(state.lists);
      final existingIndex = updatedLists.indexWhere(
        (l) => l.id == defaultList.id,
      );
      if (existingIndex == -1) {
        updatedLists.insert(0, defaultList);
      } else {
        updatedLists[existingIndex] = defaultList;
      }

      state = state.copyWith(lists: updatedLists, defaultList: defaultList);
      await _persistToStorage();

      return defaultList;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }

  /// Create a new list
  Future<UserList> createList(UserListCreate request) async {
    try {
      final list = await _api.createList(request);

      // PROD-2216 — signal the create so `yoursShelfProvider` can prepend
      // the new zine to the shelf immediately. Without this, the shelf
      // listener only patches existing items and drops tombstoned ones —
      // the new id silently fell through, leaving `/yours` stale until
      // the screen unmounted and re-drained from BE.
      final updatedLists = [list, ...state.lists];
      final createdIds = _appendListId(state.recentlyCreatedListIds, list.id);
      state = state.copyWith(
        lists: updatedLists,
        recentlyCreatedListIds: createdIds,
      );
      await _persistToStorage();

      // Track list creation (Firebase + PostHog)
      _analytics.trackListCreate(
        listId: list.id,
        isPublic: list.visibility == ListVisibility.public,
        hasDescription:
            request.description != null && request.description!.isNotEmpty,
        hasPrompt: request.prompt != null && request.prompt!.isNotEmpty,
        source: request.source,
        listName: list.name,
        itemCount: list.itemCount,
      );

      // Refresh lists from API to get server-generated preview images
      Future.microtask(() => loadLists());

      return list;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }

  /// Update a list
  Future<void> updateList(String listId, UserListUpdate request) async {
    // Defence-in-depth: the UI hides rename/edit-description on system-
    // managed lists (PROD-1741), but any code path that constructs a
    // mutating UserListUpdate must also fail fast. Visibility / cover
    // changes are still allowed.
    UserList? target;
    for (final l in state.lists) {
      if (l.id == listId) {
        target = l;
        break;
      }
    }
    if (target != null && target.isSystemManaged) {
      final mutatesIdentity =
          request.name != null ||
          request.description != null ||
          request.prompt != null ||
          request.clearPrompt;
      if (mutatesIdentity) {
        throw StateError(
          'Cannot rename or edit description of a system-managed list '
          '(system_kind = ${target.systemKind}); name/description are '
          'controlled by the backend.',
        );
      }
    }

    try {
      final updatedList = await _api.updateList(listId, request);

      final updatedLists = state.lists.map((l) {
        return l.id == listId ? updatedList : l;
      }).toList();

      // Update default list reference if needed
      UserList? newDefaultList = state.defaultList;
      if (state.defaultList?.id == listId) {
        newDefaultList = updatedList;
      }

      state = state.copyWith(lists: updatedLists, defaultList: newDefaultList);
      await _persistToStorage();

      // Track list update (Firebase + PostHog)
      _analytics.trackListUpdate(
        listId: updatedList.id,
        listName: updatedList.name,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }

  /// Update a list's local state without hitting the API or firing analytics.
  /// Use when the API call was already made by another provider (e.g. cover
  /// changes via UnifiedListProvider).
  void updateListLocally(String listId, UserList updatedList) {
    final updatedLists = state.lists.map((l) {
      return l.id == listId ? updatedList : l;
    }).toList();

    UserList? newDefaultList = state.defaultList;
    if (state.defaultList?.id == listId) {
      newDefaultList = updatedList;
    }

    state = state.copyWith(lists: updatedLists, defaultList: newDefaultList);
    _persistToStorage();
  }

  /// Delete a list.
  ///
  /// Takes the fully-resolved [UserList] (not just an id) because the
  /// caller — `_handleDelete` in `list_page_screen.dart` — already holds
  /// it from `unifiedListProvider`, and looking it up here from
  /// `state.lists` was the source of PROD-2084: when the user lands on a
  /// list detail page without first visiting the Lists hub (deep link,
  /// refresh, share link), `state.lists` is empty, and the old
  /// `firstWhere(..., orElse: () => state.lists.first)` threw
  /// `StateError: Bad state: No element` before the API call could fire.
  Future<void> deleteList(UserList list) async {
    // Defence-in-depth: the UI hides the delete affordance on system-managed
    // lists (PROD-1741), but any code path that reaches this method must
    // also fail fast — the backend would reject the request anyway, but a
    // local short-circuit avoids a misleading toast.
    if (list.isSystemManaged) {
      throw StateError(
        'Cannot delete a system-managed list (system_kind = '
        '${list.systemKind}); remove individual items instead.',
      );
    }

    try {
      await _api.deleteList(list.id);

      final updatedLists = state.lists.where((l) => l.id != list.id).toList();
      // Tombstone the id (capped) so /yours consumers can drop the list
      // from in-memory caches immediately and filter map/calendar
      // synthetic items against read-after-write lag. (PROD-2084)
      final tombstones = _appendListId(state.recentlyDeletedListIds, list.id);
      state = state.copyWith(
        lists: updatedLists,
        recentlyDeletedListIds: tombstones,
      );
      await _persistToStorage();

      // Track list deletion (Firebase + PostHog)
      _analytics.trackListDelete(
        listId: list.id,
        itemCount: list.itemCount,
        listName: list.name,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }

  /// Record that the caller just unfollowed [listId] so the "A seguir"
  /// surfaces of `/yours` (shelf + map/calendar/search under
  /// `scope=following`) can drop the list from their caches without
  /// waiting for a network refetch. Called from
  /// `UnifiedListNotifier.toggleFollow()` after the unfollow API call
  /// returns 2xx. (PROD-2128)
  void markListUnfollowed(String listId) {
    final tombstones = _appendListId(state.recentlyUnfollowedListIds, listId);
    if (identical(tombstones, state.recentlyUnfollowedListIds)) return;
    state = state.copyWith(recentlyUnfollowedListIds: tombstones);
  }

  /// Inverse of [markListUnfollowed]: clear [listId] from the tombstone set
  /// after a successful re-follow. Without this, an unfollow → re-follow
  /// cycle would leave a stale tombstone that hides the list from the
  /// `/yours` "A seguir" surfaces (shelf + map / calendar / saved-items
  /// under `scope=following`) until 50 more unfollows roll it off the cap.
  ///
  /// Called from `UnifiedListNotifier.toggleFollow()` after the follow API
  /// call returns 2xx. No-op when the id is not tombstoned (cheap; avoids
  /// a spurious state write on the common follow-without-prior-unfollow
  /// path). (PROD-2128)
  void markListFollowed(String listId) {
    final current = state.recentlyUnfollowedListIds;
    if (!current.contains(listId)) return;
    final next = current.where((id) => id != listId).toSet();
    state = state.copyWith(recentlyUnfollowedListIds: next);
  }

  /// Prepend a just-followed [list] to [ListsState.followingLists] so
  /// downstream consumers ([followingShelfProvider], `/yours` "A seguir"
  /// surfaces) can restore the card before the BE refresh roundtrip
  /// completes. Idempotent — no-op when the id is already in the cache.
  ///
  /// Called from `UnifiedListNotifier.toggleFollow()` immediately after
  /// `markListFollowed`, paired with the `UserList` carried in the
  /// unified provider's `state.list`. The subsequent
  /// `_refreshFollowingLists` call overwrites this optimistic entry
  /// with the BE-authoritative page — by which point the shelf has
  /// already shown the card. (PROD-2130)
  void prependFollowingList(UserList list) {
    if (state.followingLists.any((l) => l.id == list.id)) return;
    state = state.copyWith(followingLists: [list, ...state.followingLists]);
  }

  /// Append [id] to [current], capping the set at 50 entries by dropping
  /// the oldest insertions. Order is preserved because consumers may
  /// inspect insertion order for diagnostics. Returns the same instance
  /// when [id] is already present so callers can skip a `copyWith`.
  /// (PROD-2084 / PROD-2128)
  static Set<String> _appendListId(Set<String> current, String id) {
    if (current.contains(id)) return current;
    const cap = 50;
    if (current.length < cap) {
      return {...current, id};
    }
    final trimmed = current.skip(current.length - cap + 1).toSet();
    trimmed.add(id);
    return trimmed;
  }

  /// Quicksave — save without a list picker (PROD-3873).
  ///
  /// Uses `POST /app/lists/items`: the server resolves the caller's Saved Items
  /// list (creating it lazily) and returns its id on the written item. No
  /// client-side default-list resolution — the destination is the backend's
  /// choice. Flips the local saved-state cache optimistically so the bookmark
  /// fills on the same frame, then refreshes lists for preview covers.
  ///
  /// Returns a [QuickSaveResult]: [QuickSaveRateLimited] on a `429` from the
  /// shared 30/min bucket, [QuickSaveFailed] otherwise, [QuickSaveSuccess]
  /// (carrying the resolved list id) when the item lands.
  Future<QuickSaveResult> quickSave(
    ItemSuggestion place, {
    String? eventOccurrenceId,
    // PROD-4553 — the save-flow correlation key allocated at the user action
    // that opened this save (in `showAddToListSheet`). Threaded onto the save
    // events so a note written later in the same flow can be joined to this
    // insertion. Standalone callers get a fresh one so every save has a flow.
    String? saveFlowId,
  }) async {
    final flowId = saveFlowId ?? const Uuid().v4();
    final actionContext = _analytics.actionContext;
    // Flip the bookmark on the TAP, not on the response. This used to sit
    // after the `await` below, so the icon waited out the POST — on a slow
    // connection the tap looked like it did nothing, which reads as a dropped
    // tap and invites a second one. `_applyOptimisticSaveState` is the same
    // helper `addToListsOptimistic` uses, so both save paths now flip
    // identically.
    //
    // Safe to revert precisely: this method only runs when the caller has
    // already established the item was NOT saved, so removing the ids on
    // failure cannot clear a bookmark some other list was holding up.
    _applyOptimisticSaveState(place);

    try {
      final request = await UserListItemCreate.fromItemSuggestion(
        place,
        eventOccurrenceId: eventOccurrenceId,
      );
      final addResult = await _api.addItemToDefaultDestination(request);
      final listId = addResult.item.listId;

      // Update item count for the server-chosen list.
      _incrementListItemCount(listId);

      // Track quick save. `list_size_after` is the server's authoritative
      // post-write count (PROD-3296); `state.lists` is only re-read for the
      // list's own properties, never for the count.
      final itemType = place.type == 'event' ? 'event' : 'place';
      final trackedList = state.lists.where((l) => l.id == listId).firstOrNull;
      if (addResult.created != false) {
        _analytics.trackListItemAdd(
          actionContext: actionContext,
          listId: listId,
          itemType: itemType,
          source: 'quick_save',
          eventId: place.eventId,
          venueId: place.venueId,
          googlePlaceId: place.googlePlaceId,
          itemName: place.name,
          listName: trackedList?.name,
          list: trackedList,
          currentUserId: _getCurrentUserId?.call(),
          listSizeAfter: addResult.listItemCount,
          listItemId: addResult.item.id,
          hasNote: noteIsPresent(request.tip),
          noteLength: noteLength(request.tip),
          saveFlowId: flowId,
        );
      }

      // Refresh lists from API to get updated preview images (and to surface
      // the newly-created Saved Items / typed lists on first save).
      Future.microtask(() => loadLists());

      return QuickSaveSuccess(listId);
    } on RateLimitException catch (e) {
      // Shared 30/min bucket with the explicit add route — do NOT set
      // state.error (that drives the generic failure toast); the caller shows
      // dedicated "slow down" copy off this branch.
      _revertOptimisticSaveState(place);
      return QuickSaveRateLimited(e.retryAfterSeconds);
    } catch (e) {
      // Every failure below leaves the item unsaved, so the optimistic flip
      // must come back off — otherwise the bookmark stays filled on an item
      // the server refused, and the next tap reads it as saved and opens the
      // manage drawer instead of retrying the save.
      _revertOptimisticSaveState(place);
      // A save-refusal (street/closed/non-business) carries a stable
      // error_code — surface the specific localized reason (#1328) rather than
      // the generic "couldn't save".
      final rejected = PlaceSaveRejectedException.tryFrom(e);
      if (rejected != null) {
        return QuickSaveRejected(rejected.errorCode);
      }
      state = state.copyWith(error: e.toString());
      return QuickSaveFailed(e.toString());
    }
  }

  /// Undo an optimistic save flip by removing exactly [place]'s own ids from
  /// the CURRENT sets.
  ///
  /// Deliberately not a snapshot restore. The POST runs unserialized, so other
  /// writers reach these sets while it is in flight — a second quicksave, or a
  /// `_reloadSavedIds()` landing the user's full saved set. Restoring a
  /// pre-flip snapshot would discard whatever they wrote, hollowing bookmarks
  /// that have nothing to do with this failure. Failures cluster on slow
  /// connections, which is exactly when that overlap is likeliest.
  ///
  /// Only safe because [quickSave] runs solely on an item the caller has
  /// already established was NOT saved — so these ids are ours to remove.
  ///
  /// The Google-place cache inside [IListsApi] is left alone: it is a
  /// dedup/lookup cache keyed by id, not saved-state, nothing reads it for
  /// bookmark state ([isItemSavedProvider] takes only [ListsState]), and
  /// `loadAllOwnedItems()` clears it before every refill.
  void _revertOptimisticSaveState(ItemSuggestion place) {
    final eventIds = Set<String>.from(state.savedEventIds);
    final venueIds = Set<String>.from(state.savedVenueIds);
    final googlePlaceIds = Set<String>.from(state.savedGooglePlaceIds);

    if (place.eventId != null) eventIds.remove(place.eventId!);
    if (place.venueId != null) venueIds.remove(place.venueId!);
    if (place.googlePlaceId != null) {
      googlePlaceIds.remove(place.googlePlaceId!);
    }

    state = state.copyWith(
      savedEventIds: eventIds,
      savedVenueIds: venueIds,
      savedGooglePlaceIds: googlePlaceIds,
    );
  }

  /// Remove from default list (for heart icon toggle)
  Future<bool> removeFromDefaultList(ItemSuggestion place) async {
    if (state.defaultList == null) return false;

    try {
      // We need to find the item ID first - this requires loading items
      // For now, we'll rely on the detail provider to handle removal
      // This is a simplified version that just returns false
      return false;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Add item to specific lists with retry logic
  ///
  /// [source] tracks where the action originated from (use [ListSource] constants)
  Future<AddToListsResult> addToLists(
    List<String> listIds,
    ItemSuggestion place, {
    String? tip,
    String? source,
  }) async {
    final actionContext = _analytics.actionContext;
    final request = (await UserListItemCreate.fromItemSuggestion(
      place,
      tip: tip,
    )).copyWithSource(source);
    final addedListIds = <String>[];
    final failedListIds = <String>[];
    // The add loop and the analytics loop below are separate passes, so the
    // per-list API results have to be carried across. `list_size_after` comes
    // from these, never from `state.lists` (PROD-3296).
    //
    // Keyed by list id, so a duplicate id in [listIds] would let the second
    // (idempotent, `created: false`) result overwrite the first and suppress
    // the real insert's event. De-duped below so that can't happen.
    final addResults = <String, UserListItemAddResult>{};
    String? lastError;
    bool isRetryable = false;
    int maxAttempts = 0;

    final isExternal = place.eventId == null && place.venueId == null;
    final stopwatch = Stopwatch()..start();

    debugPrint(
      '[AddToLists] Starting - lists=${listIds.length}, mode=${isExternal ? "external" : "by-id"}, place=${place.name}',
    );

    for (final listId in listIds.toSet()) {
      var success = false;
      var attempts = 0;
      const maxRetries = 3;

      while (!success && attempts < maxRetries) {
        attempts++;
        try {
          debugPrint('[AddToLists] Attempt $attempts for list $listId');
          addResults[listId] = await _api.addItem(listId, request);
          success = true;
          addedListIds.add(listId);
          _incrementListItemCount(listId);
          debugPrint(
            '[AddToLists] List $listId succeeded on attempt $attempts',
          );
        } catch (e) {
          final retryable = _isRetryableError(e);
          debugPrint(
            '[AddToLists] List $listId attempt $attempts failed: ${e.runtimeType}, retryable=$retryable',
          );

          if (!retryable || attempts >= maxRetries) {
            failedListIds.add(listId);
            lastError = _extractErrorMessage(e);
            isRetryable = retryable;
            break;
          }
          // Exponential backoff: 2s, 4s
          await Future.delayed(Duration(seconds: 2 * attempts));
        }
      }
      maxAttempts = max(maxAttempts, attempts);
    }

    // Update saved state for successful additions
    if (addedListIds.isNotEmpty) {
      final newEventIds = Set<String>.from(state.savedEventIds);
      final newVenueIds = Set<String>.from(state.savedVenueIds);
      final newGooglePlaceIds = Set<String>.from(state.savedGooglePlaceIds);
      if (place.eventId != null) newEventIds.add(place.eventId!);
      if (place.venueId != null) newVenueIds.add(place.venueId!);
      if (place.googlePlaceId != null) {
        newGooglePlaceIds.add(place.googlePlaceId!);
        _api.addGooglePlaceIdToCache(place.googlePlaceId!);
      }
      state = state.copyWith(
        savedEventIds: newEventIds,
        savedVenueIds: newVenueIds,
        savedGooglePlaceIds: newGooglePlaceIds,
      );

      // Track list item add for each list (PostHog)
      final itemType = place.eventId != null ? 'event' : 'place';
      final currentUserId = _getCurrentUserId?.call();
      for (final listId in addedListIds) {
        final addResult = addResults[listId];
        // An idempotent re-add did not grow the list — emitting would repeat a
        // count and re-fire Growth's `list_size_after == N` flow (PROD-3296).
        if (addResult?.created == false) continue;
        // `state.lists` supplies the list's own properties; the count comes
        // from the server.
        final list = state.lists.where((l) => l.id == listId).firstOrNull;
        _analytics.trackListItemAdd(
          actionContext: actionContext,
          listId: listId,
          itemType: itemType,
          source: source,
          eventId: place.eventId,
          venueId: place.venueId,
          googlePlaceId: place.googlePlaceId,
          itemName: place.name,
          listName: list?.name,
          list: list,
          currentUserId: currentUserId,
          listSizeAfter: addResult?.listItemCount,
        );
      }

      // Refresh lists from API to get updated preview images
      Future.microtask(() => loadLists());
    }

    debugPrint(
      '[AddToLists] Completed in ${stopwatch.elapsedMilliseconds}ms - added=${addedListIds.length}, failed=${failedListIds.length}',
    );

    return AddToListsResult(
      success: failedListIds.isEmpty,
      addedListIds: addedListIds,
      failedListIds: failedListIds,
      errorMessage: lastError,
      isRetryable: isRetryable,
    );
  }

  /// Add item to lists with optimistic UI update
  ///
  /// Updates local state immediately and closes the UI, then executes
  /// API calls in the background with automatic retry.
  ///
  /// [source] tracks where the action originated from (use [ListSource] constants)
  /// [onSuccess] is called immediately after optimistic update (before API)
  /// [onError] is called only after all retries fail
  void addToListsOptimistic(
    List<String> listIds,
    ItemSuggestion place, {
    String? tip,
    String? source,
    String? eventOccurrenceId,
    // PROD-4553 — the save-flow correlation key from the opening user action,
    // shared with the quick-save that may have preceded this drawer commit so
    // an in-flow note joins the same flow. See [quickSave].
    String? saveFlowId,
    required void Function() onSuccess,
    required void Function(
      String errorMessage,
      bool canRetry,
      void Function()? retry,
    )
    onError,
  }) {
    if (listIds.isEmpty) {
      onSuccess();
      return;
    }

    final isExternal = place.eventId == null && place.venueId == null;
    debugPrint(
      '[AddToListsOptimistic] Starting - lists=${listIds.length}, mode=${isExternal ? "external" : "by-id"}, place=${place.name}',
    );

    // 1. Create optimistic items for each list and add to pendingItems
    final newPendingItems = Map<String, List<OptimisticListItem>>.from(
      state.pendingItems,
    );
    final createdItems = <OptimisticListItem>[];
    for (final listId in listIds) {
      final optimisticItem = OptimisticListItem.create(
        listId: listId,
        place: place,
        tip: tip,
      );
      createdItems.add(optimisticItem);
      newPendingItems.putIfAbsent(listId, () => []);
      newPendingItems[listId] = [...newPendingItems[listId]!, optimisticItem];
    }

    // 2. Apply optimistic update IMMEDIATELY
    _applyOptimisticSaveState(place);

    // 3. Increment item counts for all lists
    for (final listId in listIds) {
      _incrementListItemCount(listId);
    }

    // 4. Update state with pending items
    state = state.copyWith(pendingItems: newPendingItems);

    // 5. Persist to storage for consistency
    _persistToStorage();

    // 6. Analytics is NOT emitted here.
    //
    // `list_item_add` carries `list_size_after`, which Growth thresholds on to
    // fire "your Zine reached N places". The API write hasn't happened yet, and
    // `_executeBackgroundAddToLists` rolls the count back when every retry fails
    // — so emitting now would announce a save that never persisted. The event is
    // emitted per-list on CONFIRMED success instead (PROD-3095).

    // 7. Call success immediately - UI can close now
    onSuccess();

    // 8. Execute API calls in background with retry
    _executeBackgroundAddToLists(
      optimisticItems: createdItems,
      place: place,
      tip: tip,
      source: source,
      eventOccurrenceId: eventOccurrenceId,
      saveFlowId: saveFlowId,
      onError: onError,
    );
  }

  /// Apply optimistic save state update
  void _applyOptimisticSaveState(ItemSuggestion place) {
    final newEventIds = Set<String>.from(state.savedEventIds);
    final newVenueIds = Set<String>.from(state.savedVenueIds);
    final newGooglePlaceIds = Set<String>.from(state.savedGooglePlaceIds);

    if (place.eventId != null) newEventIds.add(place.eventId!);
    if (place.venueId != null) newVenueIds.add(place.venueId!);
    if (place.googlePlaceId != null) {
      newGooglePlaceIds.add(place.googlePlaceId!);
      _api.addGooglePlaceIdToCache(place.googlePlaceId!);
    }

    state = state.copyWith(
      savedEventIds: newEventIds,
      savedVenueIds: newVenueIds,
      savedGooglePlaceIds: newGooglePlaceIds,
    );
  }

  /// Execute background API calls with automatic retry
  Future<void> _executeBackgroundAddToLists({
    required List<OptimisticListItem> optimisticItems,
    required ItemSuggestion place,
    String? tip,
    String? source,
    String? eventOccurrenceId,
    String? saveFlowId,
    required void Function(
      String errorMessage,
      bool canRetry,
      void Function()? retry,
    )
    onError,
    int attemptNumber = 1,
    AnalyticsActionContext? initiatingContext,
  }) async {
    final actionContext = initiatingContext ?? _analytics.actionContext;
    // Stable across the whole flow, including silent retries below, so a note
    // written in the same drawer joins the same insertion (PROD-4553). A direct
    // caller that passed none still gets a flow so every save has one.
    final flowId = saveFlowId ?? const Uuid().v4();
    final request = (await UserListItemCreate.fromItemSuggestion(
      place,
      tip: tip,
      eventOccurrenceId: eventOccurrenceId,
    )).copyWithSource(source);
    final failedItems = <OptimisticListItem>[];
    String? lastError;

    for (final item in optimisticItems) {
      try {
        debugPrint(
          '[AddToListsOptimistic] Attempt $attemptNumber for list ${item.listId}',
        );
        final addResult = await _api.addItem(item.listId, request);
        debugPrint('[AddToListsOptimistic] List ${item.listId} succeeded');
        // Success - remove from pending items
        _removePendingItem(item.listId, item.tempId);

        // The optimistic +1 above assumed an insertion. `created: false` means
        // the row was already there and the list did NOT grow — undo it, or the
        // count on screen stays one too high until the next `loadLists()`.
        //
        // This is reachable whenever a caller re-POSTs to a list the item is
        // already in. The add-to-list sheet does exactly that to write a tip
        // (the POST upserts `tip`, so a tip needs no separate PATCH), and the
        // sheet has no way to know the row exists — `contains_*` returns lists,
        // not memberships. The server already answered it, inside the writing
        // transaction (PROD-3295), so `created` is authoritative.
        if (addResult.created == false) {
          _decrementListItemCount(item.listId);
        }

        // Track the add only now that the backend has CONFIRMED it (PROD-3095),
        // and only when it actually inserted (PROD-3296). `list_size_after`
        // comes from the server's authoritative count — never from
        // `state.lists`, whose optimistic counter raced with list refreshes and
        // reported 0 on 44% of first adds.
        final trackedList = state.lists
            .where((l) => l.id == item.listId)
            .firstOrNull;
        final itemType = place.type == 'event' ? 'event' : 'place';
        if (addResult.created != false) {
          _analytics.trackListItemAdd(
            actionContext: actionContext,
            listId: item.listId,
            itemType: itemType,
            source: source,
            eventId: place.eventId,
            venueId: place.venueId,
            itemName: place.name,
            listName: trackedList?.name,
            list: trackedList,
            currentUserId: _getCurrentUserId?.call(),
            listSizeAfter: addResult.listItemCount,
            listItemId: addResult.item.id,
            hasNote: noteIsPresent(tip),
            noteLength: noteLength(tip),
            saveFlowId: flowId,
          );
        }

        // A note written in this same POST — persisted at insertion (created
        // with a note) or a tip-only upsert on an already-saved item (PROD-4553).
        // The backend's authoritative note_action drives it: a real change emits
        // list_element_note joined to this insertion by list_item_id + the
        // originating save_flow_id; an unchanged/no-op tip emits nothing. When an
        // older backend omits the transition we only report a note event if the
        // request actually carried a note, so a plain save never looks like one.
        final noteAction = addResult.noteAction;
        final emitNote =
            noteAction.isNoteChange ||
            (noteAction == NoteAction.unknown && noteIsPresent(tip));
        if (emitNote) {
          _analytics.trackListElementNote(
            actionContext: actionContext,
            listId: item.listId,
            itemType: itemType,
            eventId: place.eventId,
            venueId: place.venueId,
            itemName: place.name,
            listName: trackedList?.name,
            listItemId: addResult.item.id,
            noteAction: noteAction,
            hasNote: noteIsPresent(tip),
            noteLength: noteLength(tip),
            source: source,
            saveFlowId: flowId,
          );
        }
      } catch (e) {
        debugPrint(
          '[AddToListsOptimistic] List ${item.listId} failed: ${e.runtimeType}',
        );
        failedItems.add(item);
        lastError = _extractErrorMessage(e);
      }
    }

    // All succeeded
    if (failedItems.isEmpty) {
      debugPrint('[AddToListsOptimistic] All lists succeeded');
      // Refresh lists to get updated preview images
      Future.microtask(() => loadLists());
      return;
    }

    // A save-refusal (PLACE_NOT_SAVEABLE / PLACE_UNAVAILABLE / SAVE_FAILED) or a
    // content-blocked tip is a permanent 4xx — retrying just fails again (and
    // re-hits the same street/closed venue, as PROD saw a curator do 6× in a
    // row). Treat it as terminal: skip the silent retries and surface the copy.
    final err = lastError;
    final isTerminalRefusal =
        err != null &&
        (err.startsWith(saveRejectedPrefix) ||
            err.startsWith(contentBlockedPrefix));

    // Some failed - check if we should retry silently
    const maxSilentRetries = 2;
    if (attemptNumber < maxSilentRetries && !isTerminalRefusal) {
      // Silent retry with exponential backoff
      final delay = Duration(seconds: 2 * attemptNumber);
      debugPrint(
        '[AddToListsOptimistic] Silent retry $attemptNumber in ${delay.inSeconds}s for ${failedItems.length} lists',
      );
      await Future.delayed(delay);

      return _executeBackgroundAddToLists(
        optimisticItems: failedItems,
        place: place,
        tip: tip,
        source: source,
        eventOccurrenceId: eventOccurrenceId,
        saveFlowId: flowId,
        onError: onError,
        attemptNumber: attemptNumber + 1,
        initiatingContext: actionContext,
      );
    }

    // All retries exhausted - revert optimistic update and notify user
    debugPrint(
      '[AddToListsOptimistic] All retries exhausted, reverting ${failedItems.length} lists',
    );

    // Revert item counts and remove pending items for failed lists
    for (final item in failedItems) {
      _decrementListItemCount(item.listId);
      _removePendingItem(item.listId, item.tempId);
    }

    // Reload saved state to get accurate data (force past the freshness
    // window — the failed save was optimistically applied and must be undone;
    // the item's true saved-state depends on its membership in other lists).
    Future.microtask(() => loadAllOwnedItems(force: true));

    // Notify user with error. When the failure carries a displayable sentinel
    // (content-blocked copy or a save-refusal code), pass it straight through
    // so the sheet renders the specific, localized message; otherwise fall back
    // to the generic count.
    final failedListIds = failedItems.map((i) => i.listId).toList();
    String? displayableCopy;
    if (err != null &&
        (err.startsWith(saveRejectedPrefix) ||
            err.startsWith(contentBlockedPrefix))) {
      displayableCopy = err;
    }
    final errorMessage =
        displayableCopy ??
        (failedItems.length == 1
            ? 'Failed to save to 1 list'
            : 'Failed to save to ${failedItems.length} lists');

    final isRetryable = lastError == 'timeout' || lastError == 'network';

    onError(
      errorMessage,
      isRetryable,
      isRetryable
          ? () => addToListsOptimistic(
              failedListIds,
              place,
              tip: tip,
              source: source,
              // The user retrying the same failed save is a continuation of
              // this flow, not a new one (PROD-4553) — keep the id so a note
              // added after the retry still joins this insertion.
              saveFlowId: flowId,
              onSuccess: () {}, // Silent on retry success
              onError: onError,
            )
          : null,
    );
  }

  /// Remove a pending optimistic item from state
  void _removePendingItem(String listId, String tempId) {
    final newPendingItems = Map<String, List<OptimisticListItem>>.from(
      state.pendingItems,
    );
    if (newPendingItems.containsKey(listId)) {
      newPendingItems[listId] = newPendingItems[listId]!
          .where((item) => item.tempId != tempId)
          .toList();
      if (newPendingItems[listId]!.isEmpty) {
        newPendingItems.remove(listId);
      }
      state = state.copyWith(pendingItems: newPendingItems);
    }
  }

  /// Check if an error is retryable (network/timeout issues)
  bool _isRetryableError(Object error) {
    if (error is DioException) {
      // Retry on timeout errors
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError) {
        return true;
      }
      // Retry on 5xx server errors
      final statusCode = error.response?.statusCode;
      if (statusCode != null && statusCode >= 500) return true;
    }
    return false;
  }

  /// Extract a user-friendly error message from an error.
  ///
  /// PROD-2264 — when the wordlist filter rejects an item tip on
  /// `POST /lists/{id}/items`, surface the backend's already-localized
  /// message via the [contentBlockedPrefix] sentinel so the calling
  /// sheet can render it directly. Other failures collapse to category
  /// constants (`timeout` / `network` / `unknown`) — unchanged.
  ///
  /// CONTENT_BLOCKED (400) is already non-retryable via
  /// [_isRetryableError] (4xx ≠ 5xx, not a timeout), so no retry-loop
  /// change is needed.
  String _extractErrorMessage(Object error) {
    final blocked = ContentBlockedException.tryFrom(error);
    if (blocked != null) {
      return '$contentBlockedPrefix${blocked.userMessage}';
    }
    final saveRejected = PlaceSaveRejectedException.tryFrom(error);
    if (saveRejected != null) {
      return '$saveRejectedPrefix${saveRejected.errorCode}';
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return 'timeout';
      }
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout) {
        return 'network';
      }
    }
    return 'unknown';
  }

  /// Sentinel prefix marking a content-blocked error inside
  /// [_extractErrorMessage]'s string output. Sheets that consume the
  /// `onError(errorMessage, ...)` callback of [addToListsOptimistic]
  /// strip this prefix and render what follows directly. Other callers
  /// can keep ignoring the message string — they'll just see the
  /// prefixed sentence flow through.
  static const String contentBlockedPrefix = '__content_blocked__:';

  /// Sentinel prefix marking a save-refusal error (backend `error_code` ∈
  /// {`PLACE_NOT_SAVEABLE`, `PLACE_UNAVAILABLE`, `SAVE_FAILED`}) inside
  /// [_extractErrorMessage]'s string output. What follows is the raw
  /// `error_code`; the add-to-list sheet strips this prefix and maps the code
  /// to localized copy. These are permanent (4xx) refusals — see the terminal
  /// short-circuit in [_executeBackgroundAddToLists].
  static const String saveRejectedPrefix = '__save_rejected__:';

  /// Remove item from specific lists
  Future<bool> removeFromLists(
    List<String> listIds,
    ItemSuggestion place, {
    // PROD-3873 — set when the removal is from one of the OWNER's own lists.
    // The backend then cascades the entity out of every list they hold it in,
    // so we emit a cascade signal that reconciles all mounted owned list views
    // (Saved Items / My Places / My Events + other zines) by content.
    bool cascade = false,
  }) async {
    final removalSignals = <RemovedItemSignal>[];
    // PROD-3873 — once the first DELETE in a cascade lands, the backend has
    // already soft-deleted the entity from every owned list, so the sibling
    // lists are reconciled locally without another DELETE (which would 404).
    var cascadeHandled = false;
    try {
      for (final listId in listIds) {
        if (cascade && cascadeHandled) {
          _decrementListItemCount(listId);
          removalSignals.add(
            RemovedItemSignal(
              listId: listId,
              eventId: place.eventId,
              venueId: place.venueId,
              googlePlaceId: place.googlePlaceId,
            ),
          );
          continue;
        }
        // Get the item ID from cache
        var itemId = _api.getItemId(
          listId,
          eventId: place.eventId,
          venueId: place.venueId,
          googlePlaceId: place.googlePlaceId,
        );

        // Cache miss — refresh by fetching all items for this list,
        // then retry. This handles the race where _updateListCache
        // was called with stale data (fetched before the item was saved).
        if (itemId == null) {
          debugPrint(
            '[removeFromLists] Cache miss for list $listId '
            '(eventId=${place.eventId}, venueId=${place.venueId}, '
            'googlePlaceId=${place.googlePlaceId}). Refreshing cache...',
          );
          var offset = 0;
          const limit = 100;
          while (true) {
            final response = await _api.listItems(
              listId,
              limit: limit,
              offset: offset,
            );
            if (response.items.length < limit ||
                offset + response.items.length >= response.total) {
              break;
            }
            offset += limit;
          }
          itemId = _api.getItemId(
            listId,
            eventId: place.eventId,
            venueId: place.venueId,
            googlePlaceId: place.googlePlaceId,
          );
        }

        if (itemId != null) {
          try {
            await _api.removeItem(listId, itemId);
          } on NotFoundException {
            // Already gone (e.g. a cascade sibling) — the intended outcome.
            debugPrint(
              '[removeFromLists] $listId already gone — treated as removed',
            );
          } on DioException catch (e) {
            // Same "already gone" case when the 404 surfaces raw (no interceptor
            // mapping on this Dio) — swallow only 404, rethrow anything else.
            if (e.response?.statusCode != 404) rethrow;
            debugPrint('[removeFromLists] $listId 404 — treated as removed');
          }
          // The DELETE (or its tolerated 404) has done the cascade; skip the
          // redundant sibling DELETEs (PROD-3873).
          if (cascade) cascadeHandled = true;
          _decrementListItemCount(listId);
          final itemType = place.eventId != null ? 'event' : 'place';
          // Post-decrement, so `itemCount` is the post-removal size.
          final list = state.lists.where((l) => l.id == listId).firstOrNull;
          final listName = list?.name;
          _analytics.trackListItemRemove(
            listId: listId,
            itemType: itemType,
            list: list,
            currentUserId: _getCurrentUserId?.call(),
            // `state.lists` holds the list's true total (server count, kept in
            // step by _increment/_decrementListItemCount) — post-decrement here.
            listSizeAfter: list?.itemCount,
            eventId: place.eventId,
            venueId: place.venueId,
            itemName: place.name,
            listName: listName,
          );
          removalSignals.add(
            RemovedItemSignal(
              listId: listId,
              eventId: place.eventId,
              venueId: place.venueId,
              googlePlaceId: place.googlePlaceId,
            ),
          );
        } else {
          debugPrint(
            '[removeFromLists] Item not found in list $listId '
            'even after cache refresh — skipping removal',
          );
        }
      }

      // PROD-3873 — when the removal was from an owned list, the backend
      // cascaded the entity out of EVERY list the owner holds it in. Emit one
      // cascade signal so every mounted owned view (the coupled Saved Items /
      // My Places / My Events + other zines) drops it by content, not just the
      // list we called DELETE on.
      if (cascade && removalSignals.isNotEmpty) {
        removalSignals.add(
          RemovedItemSignal(
            listId: listIds.isNotEmpty ? listIds.first : '',
            eventId: place.eventId,
            venueId: place.venueId,
            googlePlaceId: place.googlePlaceId,
            cascade: true,
          ),
        );
      }

      // Push removal signals so listeners (like unifiedListProvider) can
      // reconcile their local items list without a full refetch. Cap the
      // rolling log at 50 entries to prevent unbounded growth. (PROD-1395)
      if (removalSignals.isNotEmpty) {
        final combined = [...state.recentRemovals, ...removalSignals];
        final capped = combined.length > 50
            ? combined.sublist(combined.length - 50)
            : combined;
        state = state.copyWith(recentRemovals: capped);
      }

      // Reload all owned items to update saved state accurately — force past
      // the freshness window since the item might still be in other lists.
      await loadAllOwnedItems(force: true);

      // Refresh lists from API to get updated preview images
      Future.microtask(() => loadLists());

      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Check if an item is in the default list
  bool isInDefaultList({String? eventId, String? venueId}) {
    return _api.isInDefaultList(eventId: eventId, venueId: venueId);
  }

  /// Check if an item is in any owned list
  bool isInAnyOwnedList({String? eventId, String? venueId}) {
    return _api.isInAnyOwnedList(eventId: eventId, venueId: venueId);
  }

  /// Check if a list is followed by the current user
  bool isListFollowed(String listId) {
    return state.followingLists.any((list) => list.id == listId);
  }

  /// Load all owned items into cache for saved indicator
  /// If [lists] is provided, uses those instead of fetching again
  /// Warm the saved-state cache (`savedEventIds` / `savedVenueIds` /
  /// `savedGooglePlaceIds`) from the bulk `getSavedEntityIds` endpoint.
  ///
  /// Deduplicates concurrent callers onto one in-flight request and skips the
  /// network fetch entirely when the cache is still fresh (loaded within
  /// [_savedIdsStaleWindow]). Pass [force] to bypass both — see the field
  /// comment for when that's required.
  Future<void> loadAllOwnedItems({bool force = false}) async {
    if (!force) {
      final inflight = _savedIdsInflight;
      if (inflight != null) return inflight;
      if (state.isSavedCacheLoaded &&
          _savedIdsLoadedAt != null &&
          DateTime.now().difference(_savedIdsLoadedAt!) <
              _savedIdsStaleWindow) {
        return;
      }
    }
    final future = _reloadSavedIds();
    _savedIdsInflight = future;
    try {
      await future;
    } finally {
      // Only clear if we're still the current in-flight request (a later
      // forced reload may have replaced it).
      if (identical(_savedIdsInflight, future)) _savedIdsInflight = null;
    }
  }

  Future<void> _reloadSavedIds() async {
    await _api.loadAllOwnedItems();
    _savedIdsLoadedAt = DateTime.now();
    // Copy cache to state to trigger UI rebuilds
    state = state.copyWith(
      savedEventIds: Set<String>.from(_api.allOwnedEventIds),
      savedVenueIds: Set<String>.from(_api.allOwnedVenueIds),
      savedGooglePlaceIds: Set<String>.from(_api.allOwnedGooglePlaceIds),
      isSavedCacheLoaded: true,
    );
  }

  /// Load lists user is following (stale-while-revalidate pattern)
  /// Load following lists. When [loadMore] is true, appends next page.
  Future<void> loadFollowingLists({
    bool loadMore = false,
    String? scope,
    double? latitude,
    double? longitude,
  }) async {
    final hasData = state.followingLists.isNotEmpty;
    if (!hasData && !loadMore) {
      state = state.copyWith(isLoadingFollowing: true);
    } else if (!loadMore) {
      state = state.copyWith(isRefreshingScope: true);
    }

    try {
      final offset = loadMore ? state.followingLists.length : 0;
      const limit = 50;
      final response = await _api.listFollowedLists(
        limit: limit,
        offset: offset,
        scope: scope,
        latitude: latitude,
        longitude: longitude,
      );
      final merged = loadMore
          ? [...state.followingLists, ...response.items]
          : response.items;
      state = state.copyWith(
        followingLists: merged,
        isLoadingFollowing: false,
        isRefreshingScope: false,
        hasMoreFollowing: merged.length < response.total,
      );
    } catch (e) {
      state = state.copyWith(
        isLoadingFollowing: false,
        isRefreshingScope: false,
        error: (hasData || loadMore) ? null : e.toString(),
      );
    }
  }

  /// Load suggested/recommended lists. When [loadMore] is true, appends next page.
  ///
  /// [locationMode]/[adminBoundaryId] (PROD-3196) forward the per-drawer
  /// contain-vs-around intent; both null → the backend default `around`.
  Future<void> loadSuggestedLists({
    bool loadMore = false,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    final hasData =
        state.recommendedLists.isNotEmpty || state.suggestedLists.isNotEmpty;
    if (!hasData && !loadMore) {
      state = state.copyWith(isLoadingSuggested: true);
    }

    try {
      const limit = 20;
      final suggestedLists = await _api.getSuggestedLists(
        limit: limit,
        locationMode: locationMode,
        adminBoundaryId: adminBoundaryId,
      );
      // Also populate recommendedLists for the filter view
      final asUserLists = suggestedLists.cast<UserList>();
      state = state.copyWith(
        suggestedLists: suggestedLists,
        recommendedLists: loadMore
            ? [...state.recommendedLists, ...asUserLists]
            : asUserLists,
        isLoadingSuggested: false,
        hasMoreRecommended: false, // Recommended is capped at 20 by design
      );
    } catch (e) {
      state = state.copyWith(
        isLoadingSuggested: false,
        error: (hasData || loadMore) ? null : e.toString(),
      );
    }
  }

  /// Load suggested lists for guest users (stale-while-revalidate pattern)
  ///
  /// Uses provided coordinates if available, otherwise falls back to IP geolocation.
  /// No personalization is applied.
  Future<void> loadGuestSuggestedLists({
    double? latitude,
    double? longitude,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    // Only show loading spinner if we have no cached data
    final hasData = state.suggestedLists.isNotEmpty;
    if (!hasData) {
      state = state.copyWith(isLoadingSuggested: true);
    }

    try {
      final suggestedLists = await _api.getGuestSuggestedLists(
        limit: 40,
        latitude: latitude,
        longitude: longitude,
        locationMode: locationMode,
        adminBoundaryId: adminBoundaryId,
      );
      // Populate both suggestedLists and recommendedLists so the hub
      // "Recommended" section shows content for guest users.
      final asUserLists = suggestedLists.cast<UserList>();
      state = state.copyWith(
        suggestedLists: suggestedLists,
        recommendedLists: asUserLists,
        isLoadingSuggested: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoadingSuggested: false,
        error: hasData ? null : e.toString(),
      );
    }
  }

  /// Refresh all lists via discover endpoint
  ///
  /// [locationMode]/[adminBoundaryId] (PROD-3196) let a caller with the
  /// resolved Search Center request polygon containment for the recommended
  /// section; both null → the backend default `around`.
  Future<void> refresh({
    String? scope,
    double? latitude,
    double? longitude,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    await loadDiscoverLists(
      scope: scope,
      latitude: latitude,
      longitude: longitude,
      locationMode: locationMode,
      adminBoundaryId: adminBoundaryId,
    );
  }

  /// Update item count for a list
  void _incrementListItemCount(String listId) {
    final updatedLists = state.lists.map((l) {
      if (l.id == listId) {
        return l.copyWith(
          itemCount: l.itemCount + 1,
          updatedAt: DateTime.now(),
        );
      }
      return l;
    }).toList();

    // Update default list reference if needed. firstWhereOrNull guards
    // against an orphan defaultList — if the id isn't in updatedLists,
    // leave defaultList unchanged rather than crashing. (PROD-2084 audit)
    UserList? newDefaultList = state.defaultList;
    if (state.defaultList?.id == listId) {
      newDefaultList =
          updatedLists.firstWhereOrNull((l) => l.id == listId) ??
          newDefaultList;
    }

    state = state.copyWith(lists: updatedLists, defaultList: newDefaultList);
  }

  /// Decrement item count for a list
  void _decrementListItemCount(String listId) {
    final updatedLists = state.lists.map((l) {
      if (l.id == listId) {
        return l.copyWith(
          itemCount: (l.itemCount - 1).clamp(0, l.itemCount),
          updatedAt: DateTime.now(),
        );
      }
      return l;
    }).toList();

    // Update default list reference if needed. firstWhereOrNull guards
    // against an orphan defaultList — if the id isn't in updatedLists,
    // leave defaultList unchanged rather than crashing. (PROD-2084 audit)
    UserList? newDefaultList = state.defaultList;
    if (state.defaultList?.id == listId) {
      newDefaultList =
          updatedLists.firstWhereOrNull((l) => l.id == listId) ??
          newDefaultList;
    }

    state = state.copyWith(lists: updatedLists, defaultList: newDefaultList);
  }

  /// Clear state (call on logout)
  void clear() {
    _api.clearCache();
    state = const ListsState();
  }
}

/// Provider for lists state
final listsProvider = StateNotifierProvider<ListsNotifier, ListsState>((ref) {
  final api = ref.watch(listsApiProvider);
  final storageService = ref.watch(storageServiceProvider);
  final analytics = ref.watch(unifiedAnalyticsProvider);
  final notifier = ListsNotifier(
    api,
    storageService,
    analytics,
    getCurrentUserId: () => ref.read(currentUserIdProvider),
  );

  // REMOVED: Deferred loading of `lists` themselves (now handled by
  // ListsHubScreen lifecycle) — keeps app startup fast.
  //
  // PROD-2138: the bookmark icon on the venue/event detail page reads from
  // `state.savedEventIds` / `savedVenueIds` / `savedGooglePlaceIds`, which
  // are populated only by `loadAllOwnedItems()`. Previously the only
  // triggers were `loadDiscoverLists` (pull-to-refresh) and post-save
  // reconciliation, so a user landing directly on a detail page via deep
  // link / shared URL saw the bookmark stuck outline until they manually
  // pulled-to-refresh the lists hub. Fire `loadAllOwnedItems()` once
  // when auth transitions to authenticated, AND on initial provider
  // creation if the user is already authenticated (covers app cold-start
  // with a cached token — the most common case).
  void warmSavedCache({bool force = false}) {
    notifier.loadAllOwnedItems(force: force);
  }

  final initialAuth = ref.read(authStateProvider);
  if (initialAuth.isAuthenticated) {
    // Cold start: cache is empty, so this fetches (the freshness guard only
    // short-circuits once `isSavedCacheLoaded` is true). No force needed.
    warmSavedCache();
  }
  ref.listen<AuthState>(authStateProvider, (previous, next) {
    final justAuthenticated =
        (previous == null || !previous.isAuthenticated) && next.isAuthenticated;
    if (justAuthenticated) {
      // Account switched / just logged in — force past any freshness window so
      // we never serve the previous user's saved ids.
      warmSavedCache(force: true);
    }
  });

  return notifier;
});

/// Provider for lists count
final listsCountProvider = Provider<int>((ref) {
  return ref.watch(listsProvider).lists.length;
});

/// Provider for default list
final defaultListProvider = Provider<UserList?>((ref) {
  return ref.watch(listsProvider).defaultList;
});

/// Provider function to check if an item is saved in any owned list
/// Usage: ref.read(isItemSavedProvider)(eventId: 'xxx') or (venueId: 'xxx') or (googlePlaceId: 'xxx')
/// This watches state, so UI rebuilds when savedEventIds/savedVenueIds/savedGooglePlaceIds change
final isItemSavedProvider =
    Provider<
      bool Function({String? eventId, String? venueId, String? googlePlaceId})
    >((ref) {
      final listsState = ref.watch(listsProvider);
      return ({String? eventId, String? venueId, String? googlePlaceId}) {
        if (eventId != null && listsState.savedEventIds.contains(eventId))
          return true;
        if (venueId != null && listsState.savedVenueIds.contains(venueId))
          return true;
        if (googlePlaceId != null &&
            listsState.savedGooglePlaceIds.contains(googlePlaceId))
          return true;
        return false;
      };
    });
