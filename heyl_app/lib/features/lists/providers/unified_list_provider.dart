import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../core/exceptions/api_exceptions.dart';
import '../../../core/services/analytics/app_entry_providers.dart';
import '../../../core/services/attribution_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/utils/note_text.dart';
import '../../../data/datasources/interfaces/api_interfaces.dart';
import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/lists_provider.dart';
import '../utils/zine_cover_recipe.dart';

/// Holds the referral `ref` query parameter extracted from the URL.
/// Set by the router before the unified list provider is created.
final publicListRefProvider = StateProvider<String?>((ref) => null);

/// View mode for list detail.
///
/// Top-level view mode for the list page (PROD-1700).
///
/// The redesigned list page exposes two modes — `zine` (default) and `list`.
/// Calendar and map are rendered as inner widgets inside the Zine view, not
/// as top-level modes (see `docs/designs/list-page-redesign.md` § 6).
enum ListViewMode { zine, list }

/// Unified state for viewing any list (owned, followed, or public)
///
/// This state supports all viewing contexts:
/// - Authenticated owner: full edit controls
/// - Authenticated non-owner: follow/save capabilities
/// - Non-authenticated: read-only with login prompts for gated actions
class UnifiedListState {
  /// The list data (normalized from either UserList or PublicList)
  final UserList? list;

  /// List items.
  ///
  /// As of PROD-1967 these are synthesised from the slim list-items
  /// endpoint (`listItemsSlim`) — the FE keeps `UserListItem` as the
  /// in-memory shape (every consumer reads from its getters) but the
  /// underlying payload is the BE's slim projection. `event` / `venue`
  /// maps carry only the fields the list-page widgets actually read
  /// (title, image, category, geo, dates) — richer fields (opening
  /// hours, ratings, descriptions, …) live on the standalone in-list
  /// detail page, which fetches them on demand.
  final List<UserListItem> items;

  /// Server-deduped map pins covering every unique venue across the
  /// whole list (PROD-1966 § Pagination shape A — full set on every
  /// response, including pages where `offset > 0`). The cover map
  /// renders from this directly instead of running an FE-side dedupe
  /// over [items]; in particular, it stays complete even before the
  /// background tail finishes appending to [items].
  final List<SlimMapPin> mapPins;

  /// Total item count matching the current filter (set by the BE on
  /// the first slim response). Used by the progressive loader to
  /// decide whether to fetch a background tail, and by callers that
  /// want the authoritative count without waiting for [items] to
  /// finish appending.
  final int totalItems;

  /// Whether the current user owns this list
  final bool isOwner;

  /// Whether the current user is following this list (authenticated non-owner only)
  final bool isFollowing;

  /// Whether the follow action is in progress
  final bool isFollowLoading;

  /// Whether the list is loading
  final bool isLoading;

  /// Whether items are loading
  final bool isLoadingItems;

  /// Sticky: `true` once an item fetch (a lightweight [prefetch] seed or a
  /// full load) has completed at least once, so callers KNOW the real item
  /// count. The empty-owner hero gates on this (not the weaker
  /// `!isLoadingItems`) so it never flashes over a list whose items simply
  /// haven't been fetched yet — e.g. during the instant-cover window after a
  /// Library warm seeds only the cover. PROD-4XXX.
  final bool itemsLoaded;

  /// Whether the list was not found (404 or 403)
  final bool isNotFound;

  /// Error message (for recoverable errors)
  final String? error;

  /// Current view mode
  final ListViewMode viewMode;

  /// Current filter
  final SavedItemType? filter;

  /// View-only ordering override sent as `sort` on the slim item endpoints
  /// (backend v1.128.0). `null` — the default — omits the param, which is how
  /// the BE is asked for the list's OWN order, including an owner's
  /// hand-arranged `custom` sequence. Nothing is written back either way.
  ///
  /// Surfaced only in List view ([ZineItemSortMenu]); the Zine pager reads the
  /// same [items], so a sort chosen in List view carries over to it.
  final ZineItemSort? sort;

  /// Whether the page is in owner-only edit mode (PROD-1783). When true,
  /// the list header swaps Edit → Done, hides Toggle/Share/Add, and the
  /// List-view body renders the cover row, inline-editable title and
  /// description, drag handles + delete on rows, and auto-expanded item
  /// notes. Every mutation still commits immediately (no global Cancel).
  final bool editMode;

  /// View mode the user was on before they entered edit mode. Edit mode
  /// always forces [ListViewMode.list] (the inline editors only render
  /// in List view); on exit we restore this so a Zine viewer doesn't
  /// get bounced into List as a side effect of editing. `null` outside
  /// edit-mode.
  final ListViewMode? viewModeBeforeEdit;

  /// Count of in-flight API mutations spawned by the user's edit-mode
  /// actions (title/description commits, note saves, reorder, delete,
  /// cover change). Goes up when a mutation starts and back down when
  /// it settles (success or failure). The chrome's Done button reads
  /// `> 0` to swap its icon for a spinner and disable taps so the
  /// user can't exit edit mode while a save is still racing. PROD-1783.
  final int pendingMutations;

  const UnifiedListState({
    this.list,
    this.items = const [],
    this.mapPins = const [],
    this.totalItems = 0,
    this.isOwner = false,
    this.isFollowing = false,
    this.isFollowLoading = false,
    this.isLoading = false,
    this.isLoadingItems = false,
    this.itemsLoaded = false,
    this.isNotFound = false,
    this.error,
    this.viewMode = ListViewMode.zine,
    this.filter,
    this.sort,
    this.editMode = false,
    this.viewModeBeforeEdit,
    this.pendingMutations = 0,
  });

  UnifiedListState copyWith({
    UserList? list,
    List<UserListItem>? items,
    List<SlimMapPin>? mapPins,
    int? totalItems,
    bool? isOwner,
    bool? isFollowing,
    bool? isFollowLoading,
    bool? isLoading,
    bool? isLoadingItems,
    bool? itemsLoaded,
    bool? isNotFound,
    String? error,
    ListViewMode? viewMode,
    SavedItemType? filter,
    ZineItemSort? sort,
    bool clearSort = false,
    bool? editMode,
    ListViewMode? viewModeBeforeEdit,
    bool clearViewModeBeforeEdit = false,
    int? pendingMutations,
    bool clearFilter = false,
    bool clearError = false,
  }) {
    return UnifiedListState(
      list: list ?? this.list,
      items: items ?? this.items,
      mapPins: mapPins ?? this.mapPins,
      totalItems: totalItems ?? this.totalItems,
      isOwner: isOwner ?? this.isOwner,
      isFollowing: isFollowing ?? this.isFollowing,
      isFollowLoading: isFollowLoading ?? this.isFollowLoading,
      isLoading: isLoading ?? this.isLoading,
      isLoadingItems: isLoadingItems ?? this.isLoadingItems,
      itemsLoaded: itemsLoaded ?? this.itemsLoaded,
      isNotFound: isNotFound ?? this.isNotFound,
      error: clearError ? null : (error ?? this.error),
      viewMode: viewMode ?? this.viewMode,
      filter: clearFilter ? null : (filter ?? this.filter),
      sort: clearSort ? null : (sort ?? this.sort),
      editMode: editMode ?? this.editMode,
      viewModeBeforeEdit: clearViewModeBeforeEdit
          ? null
          : (viewModeBeforeEdit ?? this.viewModeBeforeEdit),
      pendingMutations: pendingMutations ?? this.pendingMutations,
    );
  }

  /// Get events only
  List<UserListItem> get events =>
      items.where((i) => i.itemType == SavedItemType.event).toList();

  /// Get places only
  List<UserListItem> get places =>
      items.where((i) => i.itemType == SavedItemType.place).toList();

  /// Whether this list has a custom sort order (any item has sort_order > 0).
  bool get hasCustomSortOrder => items.any((i) => i.sortOrder > 0);

  /// Get filtered items based on current filter.
  /// If items have custom sort_order, that order is preserved.
  /// Otherwise, events are sorted by date (ascending) and shown before venues.
  List<UserListItem> get filteredItems {
    final base = filter == null
        ? items
        : items.where((i) => i.itemType == filter).toList();

    // If custom sort order exists, respect it
    if (hasCustomSortOrder) {
      final sorted = List<UserListItem>.from(base);
      sorted.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return sorted;
    }

    // Default: separate events and venues
    final events = base
        .where((i) => i.itemType == SavedItemType.event)
        .toList();
    final venues = base
        .where((i) => i.itemType == SavedItemType.place)
        .toList();

    // Sort events by date (ascending, nulls last)
    events.sort((a, b) {
      final aDate = a.eventDate;
      final bDate = b.eventDate;
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return aDate.compareTo(bDate);
    });

    return [...events, ...venues];
  }

  /// Get items with valid coordinates (for map view)
  List<UserListItem> get itemsWithCoordinates =>
      items.where((i) => i.latitude != null && i.longitude != null).toList();
}

/// Notifier for unified list viewing
///
/// Automatically selects the appropriate API endpoint based on auth state:
/// - Authenticated: /api/v1/app/lists/{list_id} (can see own private lists)
/// - Non-authenticated: /api/v1/app/lists/{list_id}/public (only public lists)
class UnifiedListNotifier extends StateNotifier<UnifiedListState> {
  final String listId;
  final IListsApi _api;
  final UnifiedAnalyticsService _analytics;

  /// Tier 2 (B3): was this list the target of a deep link in the last 60 s?
  /// Feeds `list_open.source`. Defaults to never (tests, callers without the
  /// latch).
  final bool Function(String listId) _wasDeepLinkTarget;
  static bool _neverDeepLinkTarget(String _) => false;
  bool _hasTrackedOpen = false;

  /// PROD-4XXX — instant-cover / on-visible prefetch (see [prefetch] and
  /// [ensureFullyLoaded]).
  ///
  /// `true` once a full [load] (metadata + first-page + background tail) has
  /// been kicked off, so [ensureFullyLoaded] is idempotent — the open screen
  /// can call it unconditionally without double-fetching a list the factory
  /// already full-loaded (the default, non-prefetched path).
  bool _fullLoadTriggered = false;

  /// Content keys removed locally within the last [_recentRemovalTtl]. Used
  /// to suppress re-adds in [loadItemsQuietly] when the backend GET still
  /// returns a just-deleted item (read-after-write lag, batched removes
  /// during the Instagram-share review flow, etc.).
  final Map<String, DateTime> _recentlyRemovedKeys = {};
  static const Duration _recentRemovalTtl = Duration(seconds: 15);

  /// The resolved list UUID. The constructor [listId] may be a slug from the
  /// URL (e.g. "my-awesome-list"). Once the list loads, this returns the real
  /// UUID for API mutation calls that require it.
  String get _resolvedListId => state.list?.id ?? listId;

  /// All list-id keys this notifier should match when reading per-list state
  /// out of [listsProvider] (e.g. `pendingItems[listId]`). Includes the
  /// family key (possibly a URL slug) AND the resolved UUID once the list
  /// has loaded. Callers may write to either key — e.g. the search sheet
  /// uses the resolved UUID to avoid 422 errors on the backend add call,
  /// while the route passes the slug as the family key (PROD-1395).
  Set<String> get listIdKeys {
    final uuid = state.list?.id;
    return {listId, if (uuid != null && uuid != listId) uuid};
  }

  final bool Function() _isAuthenticated;
  final String? Function() _getCurrentUserId;
  final String? Function() _getCurrentUserName;
  final bool Function(String) _isListFollowed;
  final Future<void> Function() _refreshFollowingLists;
  final void Function(String) _markListUnfollowed;
  final void Function(String) _markListFollowed;
  // PROD-2130 — optimistic push of the just-followed list into the
  // global `followingLists` cache. Lets the FollowingShelf restore the
  // card immediately instead of waiting for `_refreshFollowingLists`.
  final void Function(UserList) _prependFollowingList;
  final List<OptimisticListItem> Function() _getPendingItems;
  // PROD-3873 — invoked after a removal. Receives the ids of every list the
  // cascade touched (from bulk-delete's `cascaded_list_ids`); empty for the
  // single-item DELETE, whose `204` carries no ids.
  final Future<void> Function(Set<String> cascadedListIds)? _onItemRemoved;
  final String? _referralRef;
  final Future<String?> Function() _getVisitorId;

  /// Bridge to `listsProvider.updateList()` — wires the persistence side of
  /// [commitListUpdate] (PROD-1783 page-level edit mode). Optional so older
  /// call sites that don't need server-side persistence don't have to
  /// supply one; in practice the provider factory always passes it.
  final Future<void> Function(UserListUpdate)? _persistListUpdate;

  UnifiedListNotifier(
    this.listId,
    this._api,
    this._analytics, {
    required bool Function() isAuthenticated,
    required String? Function() getCurrentUserId,
    required String? Function() getCurrentUserName,
    required bool Function(String) isListFollowed,
    required Future<void> Function() refreshFollowingLists,
    required void Function(String) markListUnfollowed,
    required void Function(String) markListFollowed,
    required void Function(UserList) prependFollowingList,
    required List<OptimisticListItem> Function() getPendingItems,
    Future<void> Function(Set<String> cascadedListIds)? onItemRemoved,
    String? referralRef,
    required Future<String?> Function() getVisitorId,
    Future<void> Function(UserListUpdate)? persistListUpdate,
    bool Function(String listId)? wasDeepLinkTarget,
  }) : _wasDeepLinkTarget = wasDeepLinkTarget ?? _neverDeepLinkTarget,
       _isAuthenticated = isAuthenticated,
       _getCurrentUserId = getCurrentUserId,
       _getCurrentUserName = getCurrentUserName,
       _isListFollowed = isListFollowed,
       _refreshFollowingLists = refreshFollowingLists,
       _markListUnfollowed = markListUnfollowed,
       _markListFollowed = markListFollowed,
       _prependFollowingList = prependFollowingList,
       _getPendingItems = getPendingItems,
       _onItemRemoved = onItemRemoved,
       _referralRef = referralRef,
       _getVisitorId = getVisitorId,
       _persistListUpdate = persistListUpdate,
       super(const UnifiedListState());

  /// Load the list using the appropriate endpoint based on auth state.
  ///
  /// If the user appears authenticated but the token is stale (e.g., opened a
  /// public list link in an in-app browser with expired credentials), the
  /// authenticated endpoint will fail with 401. In that case, we fall back to
  /// the public endpoint so the user can still view public list content.
  Future<void> loadList() async {
    final actionContext = _analytics.actionContext;
    UserList? loadedList;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      if (_isAuthenticated()) {
        try {
          loadedList = await _loadAuthenticatedList();
        } catch (e) {
          // If authenticated endpoint fails with 401 (expired/invalid token),
          // fall back to public endpoint. This handles users with stale tokens
          // who open public list links (e.g., from Instagram stories).
          if (_isAuthenticationError(e)) {
            loadedList = await _loadPublicList();
          } else {
            rethrow;
          }
        }
      } else {
        loadedList = await _loadPublicList();
      }
    } catch (e) {
      _handleError(e);
    }

    // Track list open once per provider lifetime to avoid duplicates.
    // The provider may call loadList() twice (initial public load + auth reload),
    // but we only want one list_open event per list view.
    if (_analytics.isActionContextCurrent(actionContext) &&
        !_hasTrackedOpen &&
        loadedList != null) {
      _hasTrackedOpen = true;
      final fromDeepLink =
          _wasDeepLinkTarget(loadedList.id) || _wasDeepLinkTarget(listId);
      _analytics.trackListOpen(
        actionContext: actionContext,
        listId: loadedList.id,
        list: loadedList,
        listName: loadedList.name,
        source: fromDeepLink ? 'deep_link' : 'in_app',
      );

      // Fire list_link_opened when the session has campaign attribution
      // (UTM params or external referrer). UTM props are auto-merged by
      // _dispatch. This distinguishes shared-link opens from internal nav.
      if (_analytics.hasSessionAttribution) {
        _analytics.trackListLinkOpened(
          actionContext: actionContext,
          listId: loadedList.id,
          list: loadedList,
          listName: loadedList.name,
          referrer: _analytics.sessionReferrer,
        );
      }
    }
  }

  /// Load list using authenticated endpoint
  Future<UserList?> _loadAuthenticatedList() async {
    try {
      var list = await _api.getList(_resolvedListId);
      final currentUserId = _getCurrentUserId();
      final isOwner = list.ownerId == currentUserId || list.userRole == 'owner';
      // PROD-2130 — trust the BE's authoritative `is_following` flag
      // (also reflected by `user_role == 'follower'`). The
      // `listsProvider.followingLists` cache is paginated (50 per page)
      // and the new FollowingShelf (PROD-2091) maintains its own state
      // without writing back to it, so `_isListFollowed` returns false
      // when the user opens a followed list whose entry isn't in that
      // global cache — making the Follow/A Seguir button start in the
      // wrong state and requiring multiple taps before unfollow lands.
      // The cache check stays as a defensive fallback for any BE
      // response that predates the field.
      final isFollowing =
          list.isFollowing ??
          (list.userRole == 'follower' || _isListFollowed(listId));

      // UserListOut doesn't include a nested owner object, so ownerName is
      // null. Populate it from the current user's profile for owned lists.
      if (isOwner && list.ownerName == null) {
        list = list.copyWith(ownerName: _getCurrentUserName());
      }

      state = state.copyWith(
        list: list,
        isOwner: isOwner,
        isFollowing: isFollowing,
        isLoading: false,
        isNotFound: false,
      );
      return list;
    } catch (e) {
      // Check for 403/404 - treat both as "not found" for security
      if (_isNotFoundError(e)) {
        state = state.copyWith(isLoading: false, isNotFound: true);
        return null;
      }
      rethrow;
    }
  }

  /// Load list using public (unauthenticated) endpoint
  Future<UserList?> _loadPublicList() async {
    try {
      final publicList = await _api.getPublicList(
        _resolvedListId,
        ref: _referralRef,
        visitorId: await _getVisitorId(),
      );

      // Convert PublicList to UserList for unified handling
      final userList = _convertPublicListToUserList(publicList);

      state = state.copyWith(
        list: userList,
        isOwner: false,
        isFollowing: false,
        isLoading: false,
        isNotFound: false,
      );
      return userList;
    } catch (e) {
      // 404 means the list is private or doesn't exist
      if (_isNotFoundError(e)) {
        state = state.copyWith(isLoading: false, isNotFound: true);
        return null;
      }
      rethrow;
    }
  }

  /// Load list items, with the same auth fallback as [loadList].
  Future<void> loadItems({SavedItemType? filter}) async {
    state = state.copyWith(
      isLoadingItems: true,
      clearError: true,
      filter: filter,
      clearFilter: filter == null,
    );

    try {
      if (_isAuthenticated()) {
        try {
          await _loadAuthenticatedItems(filter: filter);
        } catch (e) {
          if (_isAuthenticationError(e)) {
            await _loadPublicItems(filter: filter);
          } else {
            rethrow;
          }
        }
      } else {
        await _loadPublicItems(filter: filter);
      }
    } catch (e) {
      _handleError(e);
      state = state.copyWith(isLoadingItems: false);
    }
  }

  /// First-paint page size for the slim endpoint. Trades a slightly
  /// taller HTTP for a much faster time-to-render — 50 rows is enough
  /// to fill the viewport on every screen size we ship, and the rest
  /// streams in via [_appendSlimTail] without blocking the UI.
  static const int _slimFirstPageLimit = 50;

  /// Background-tail page size. Slim payloads are small enough that the
  /// BE-imposed cap of 500 is safe in one shot — typical lists finish
  /// in a single tail page.
  static const int _slimTailPageLimit = 500;

  /// Load items using authenticated endpoint.
  ///
  /// PROD-1967 progressive fetch:
  ///   1. First-paint request at `limit=50, offset=0`. Set
  ///      `state.items` from the slim response and let the page render.
  ///   2. If more items remain (`items.length < total`), kick off a
  ///      background tail that pages at `limit=500` and appends each
  ///      page in-place. Pin set is whole-list from response 1 (BE
  ///      pagination shape A) so the cover map renders immediately.
  Future<void> _loadAuthenticatedItems({SavedItemType? filter}) async {
    final sort = state.sort;
    final firstPage = await _api.listItemsSlim(
      _resolvedListId,
      itemType: filter,
      limit: _slimFirstPageLimit,
      offset: 0,
      sort: sort,
    );

    final firstHeavy = firstPage.items.map((s) => slimItemToHeavy(s)).toList();
    final merged = _mergeWithOptimistic(firstHeavy, filter: filter);

    state = state.copyWith(
      items: merged,
      mapPins: firstPage.mapPins,
      totalItems: firstPage.total,
      isLoadingItems: false,
      itemsLoaded: true,
    );

    if (firstPage.items.length < firstPage.total) {
      // Kick off the tail; don't await — first paint already happened.
      // ignore: discarded_futures
      _appendSlimTail(
        startOffset: firstPage.items.length,
        total: firstPage.total,
        filter: filter,
        authenticated: true,
        sort: sort,
      );
    }
  }

  /// Load items using public (unauthenticated) endpoint with the same
  /// progressive shape as [_loadAuthenticatedItems].
  Future<void> _loadPublicItems({SavedItemType? filter}) async {
    final visitorId = await _getVisitorId();

    final sort = state.sort;
    final firstPage = await _api.listPublicItemsSlim(
      _resolvedListId,
      itemType: filter,
      limit: _slimFirstPageLimit,
      offset: 0,
      ref: _referralRef,
      visitorId: visitorId,
      sort: sort,
    );

    final firstHeavy = firstPage.items.map((s) => slimItemToHeavy(s)).toList();

    state = state.copyWith(
      items: firstHeavy,
      mapPins: firstPage.mapPins,
      totalItems: firstPage.total,
      isLoadingItems: false,
      itemsLoaded: true,
    );

    if (firstPage.items.length < firstPage.total) {
      // ignore: discarded_futures
      _appendSlimTail(
        startOffset: firstPage.items.length,
        total: firstPage.total,
        filter: filter,
        authenticated: false,
        visitorId: visitorId,
        sort: sort,
      );
    }
  }

  /// Pages the slim endpoint at `limit=500` starting from [startOffset]
  /// and appends each page to `state.items` as it arrives. Bails out
  /// silently if the notifier is disposed mid-flight or if any page
  /// fails — first paint already rendered, so a partial tail degrades
  /// gracefully (the user can pull-to-refresh, or whoever called
  /// `loadItems` again will retry).
  Future<void> _appendSlimTail({
    required int startOffset,
    required int total,
    SavedItemType? filter,
    required bool authenticated,
    String? visitorId,
    ZineItemSort? sort,
  }) async {
    var offset = startOffset;
    try {
      // [sort] is the ordering the first page was fetched under. If the user
      // picks a different one mid-tail, `loadItems` has already restarted from
      // page 0 — bail rather than append rows from a stale ordering, which
      // would interleave two different sequences.
      while (mounted && offset < total && state.sort == sort) {
        final page = authenticated
            ? await _api.listItemsSlim(
                _resolvedListId,
                itemType: filter,
                limit: _slimTailPageLimit,
                offset: offset,
                sort: sort,
              )
            : await _api.listPublicItemsSlim(
                _resolvedListId,
                itemType: filter,
                limit: _slimTailPageLimit,
                offset: offset,
                ref: _referralRef,
                visitorId: visitorId,
                sort: sort,
              );
        if (!mounted) return;
        if (page.items.isEmpty) return;

        final heavies = page.items.map((s) => slimItemToHeavy(s)).toList();
        // De-dup against current items so an optimistic item that the
        // backend has now confirmed isn't double-counted. Match by
        // content key (matches `mergeOptimisticItemsLocally` semantics).
        final existingKeys = state.items.map(_contentKey).toSet();
        final fresh = heavies
            .where((h) => !existingKeys.contains(_contentKey(h)))
            .toList();

        state = state.copyWith(items: [...state.items, ...fresh]);
        offset += page.items.length;
        // Defensive: BE could plausibly return fewer than `limit` rows
        // on the last page even when offset+items < total (e.g., filter
        // races). Break to avoid an infinite loop.
        if (page.items.length < _slimTailPageLimit) return;
      }
    } catch (e) {
      debugPrint('[UnifiedListProvider] background tail failed: $e');
      // Silent — first paint already happened.
    }
  }

  /// Merge backend items with the local optimistic set, dropping
  /// optimistic rows that the backend has now confirmed (by content
  /// key) so the user doesn't see the same item twice.
  List<UserListItem> _mergeWithOptimistic(
    List<UserListItem> backendItems, {
    SavedItemType? filter,
  }) {
    final pendingItems = _getPendingItems();
    if (pendingItems.isEmpty) return backendItems;

    final userId = _getCurrentUserId() ?? '';
    final optimisticUserItems = pendingItems
        .map((item) => item.toUserListItem(userId))
        .toList();

    final filteredOptimistic = filter == null
        ? optimisticUserItems
        : optimisticUserItems.where((item) => item.itemType == filter).toList();

    final filtered = backendItems.where((backendItem) {
      return !pendingItems.any(
        (pending) => _itemsMatch(backendItem, pending.place),
      );
    }).toList();

    return [...filtered, ...filteredOptimistic];
  }

  /// Check if a backend item matches a pending place (for deduplication)
  bool _itemsMatch(UserListItem backendItem, ItemSuggestion place) {
    if (place.eventId != null && backendItem.eventId == place.eventId)
      return true;
    if (place.venueId != null && backendItem.venueId == place.venueId)
      return true;
    if (place.googlePlaceId != null &&
        backendItem.googlePlaceId == place.googlePlaceId)
      return true;
    return false;
  }

  /// Load both list and items
  Future<void> load() async {
    // Mark the full-load path as taken so a later [ensureFullyLoaded] (the
    // open screen calls it unconditionally) becomes a no-op. This is what
    // keeps the default, non-prefetched open from double-fetching.
    _fullLoadTriggered = true;

    // Fire both opening round-trips concurrently. The slim items fetch only
    // needs the route's list_id (`_resolvedListId`), not the metadata body, so
    // it need not wait on [loadList]. Chaining them (the shape PROD-3211
    // measured) meant a slow `GET /lists/{id}` tail — 3–4.7s at p90 in prod —
    // also delayed the items and, through them, the zine's first paint. Running
    // them in parallel takes the slim round-trip off the critical path.
    //
    // Safe to interleave: both mutate `state` only through await-free
    // `copyWith`, so on Dart's single-threaded loop no update is lost; and
    // [loadItems] swallows its own errors into `state`, so `itemsFuture` never
    // rejects. If the list turns out not-found/errored, [ListPageScreen] gates
    // on that ahead of the items (see `_buildSlivers`), and the extra items
    // request — which resolves to the same not-found state — is harmless.
    //
    // ⚠️ EXCEPT when the route param is a SLUG and the viewer is signed in.
    // `_resolvedListId` is `state.list?.id ?? listId`, and the parallel shape
    // runs [loadItems] while `state.list` is still null — so it sends the raw
    // route param. That is fine for every id the app itself pushes (a UUID) and
    // for guests (`GET /lists/{id}/public/items/slim` takes "List UUID or
    // URL-friendly slug"), but the AUTHENTICATED endpoint
    // `GET /lists/{id}/items/slim` is declared `format: uuid` — "List UUID" —
    // and 422s on a slug. The 422 is not an auth error, so it does not fall
    // back to the public endpoint; it lands in [loadItems]'s catch and is
    // swallowed into `state.error` with `items` left empty.
    //
    // Net effect before this guard: a signed-in user opening a SHARED link
    // (`/lists/my-awesome-zine`) got a zine stuck on its "still loading" cover
    // forever, while a guest opening the identical link was fine. Reported
    // 2026-09-15 ("opening a deeplink seems to lead to the same result").
    //
    // So: serialise only that case. Every in-app open still pays the parallel
    // path PROD-3211 measured.
    if (_isAuthenticated() && !_looksLikeUuid(listId)) {
      await loadList();
      await loadItems();
      return;
    }

    // ignore: discarded_futures
    final itemsFuture = loadItems();
    await loadList();
    await itemsFuture;
  }

  /// Canonical 8-4-4-4-12 hex UUID, case-insensitive.
  ///
  /// Used to tell a route param that is already a list id from one that is a
  /// URL slug and must be resolved via [loadList] first — see [load]. Slugs are
  /// lowercase words joined by hyphens, so they can never match this shape.
  static final RegExp _uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static bool _looksLikeUuid(String value) => _uuidRe.hasMatch(value);

  /// Ensure the list is fully loaded (metadata + first page + background
  /// tail). Idempotent: a no-op if a full [load] already ran, otherwise it
  /// upgrades a lightweight [prefetch] seed to the full load.
  ///
  /// The open screen ([ListPageScreen]) calls this on mount. For the default
  /// path the provider factory already ran [load] at creation, so this
  /// short-circuits. For a Library-warmed list the factory ran [prefetch]
  /// (cover only), and this loads the items — without a full-screen skeleton,
  /// because the cover is already seeded and the zine view shows a static
  /// cover until the items arrive.
  Future<void> ensureFullyLoaded() async {
    if (_fullLoadTriggered) return;
    await load();
  }

  /// Lightweight, analytics-free warm-up used by the Library's on-visible
  /// prefetch (PROD-4XXX). Seeds ONLY the cover from the already-known
  /// [UserList] metadata (zero network) so opening the zine paints its cover
  /// instantly instead of waiting on the metadata round-trip.
  ///
  /// Deliberately seeds NO items: the zine pager (`TurnPageView`) must mount
  /// with the real first page, never an under-filled seed set that later
  /// grows — that transition corrupts the vendored page controller on the
  /// first flip. Items stream in via [ensureFullyLoaded] on open, and the
  /// zine view shows a static cover until they arrive.
  ///
  /// Deliberately does NOT go through [loadList]: that path fires the
  /// `list_open` analytics event, which must only fire when the user actually
  /// opens the zine — not when a row scrolls into view. The full load (with
  /// its single `list_open`) runs later via [ensureFullyLoaded] on open.
  Future<void> prefetch({UserList? seedList}) async {
    if (seedList != null && state.list == null) {
      _seedCoverFromList(seedList);
    }
  }

  /// Seed `state.list` (and ownership) from an already-loaded [UserList]
  /// without any network call or analytics. Used by [prefetch] so the cover
  /// renders instantly on open.
  void _seedCoverFromList(UserList list) {
    if (state.list != null) return;
    final currentUserId = _getCurrentUserId();
    final isOwner = list.ownerId == currentUserId || list.userRole == 'owner';
    final isFollowing =
        list.isFollowing ??
        (list.userRole == 'follower' || _isListFollowed(listId));
    state = state.copyWith(
      list: list,
      isOwner: isOwner,
      isFollowing: isFollowing,
    );
  }

  /// Toggle follow/unfollow status (authenticated users only)
  Future<bool> toggleFollow() async {
    if (!_isAuthenticated() || state.isFollowLoading) return false;

    final wasFollowing = state.isFollowing;

    state = state.copyWith(isFollowLoading: true);

    try {
      if (wasFollowing) {
        await _api.unfollowList(_resolvedListId);
        // PROD-2128 — tombstone the list so the "A seguir" surfaces
        // (shelf + map/calendar/search under `scope=following`) drop it
        // immediately instead of waiting until the user navigates away
        // and back.
        _markListUnfollowed(_resolvedListId);
      } else {
        await _api.followList(_resolvedListId);
        // PROD-2128 — clear any prior tombstone for this list so an
        // unfollow → re-follow round-trip doesn't leave the new follow
        // hidden behind a stale `recentlyUnfollowedListIds` entry. No-op
        // on the common follow-without-prior-unfollow path.
        _markListFollowed(_resolvedListId);
        // PROD-2130 — also push the list into the global `followingLists`
        // cache so the FollowingShelf can restore the card in the same
        // frame instead of waiting for `_refreshFollowingLists` below to
        // complete its BE roundtrip. The subsequent refresh overwrites
        // this optimistic entry with the BE-authoritative page (it's
        // idempotent — same id, same data within follower-count drift).
        final currentList = state.list;
        if (currentList != null) {
          _prependFollowingList(currentList);
        }
      }

      // Optimistic update: flip isFollowing AND bump the local
      // followerCount so the header stats line reflects the action
      // in the same frame. The follow/unfollow endpoints return
      // `{ status: "following" }` with no count, so we bump locally
      // and reconcile against the server below.
      final newIsFollowing = !wasFollowing;
      final currentList = state.list;
      final bumpedList = currentList?.copyWith(
        followerCount: newIsFollowing
            ? currentList.followerCount + 1
            : (currentList.followerCount > 0
                  ? currentList.followerCount - 1
                  : 0),
      );
      state = state.copyWith(
        isFollowing: newIsFollowing,
        isFollowLoading: false,
        list: bumpedList,
      );

      // Sync with global lists provider
      await _refreshFollowingLists();

      // Track follow/unfollow. `state.list` already carries the post-toggle
      // `followerCount` (the bumped copy was written to state above), which is
      // what becomes `follower_count`.
      if (newIsFollowing) {
        _analytics.trackListFollow(
          listId: state.list?.id ?? listId,
          listName: state.list?.name,
          list: state.list,
          currentUserId: _getCurrentUserId(),
        );
      } else {
        await _analytics.trackListUnfollow(
          listId: state.list?.id ?? listId,
          listName: state.list?.name,
          list: state.list,
          currentUserId: _getCurrentUserId(),
        );
      }

      // Silent reconcile: re-fetch the list so the count matches the
      // server (covers concurrent follows from other users between
      // taps, server-side recounts, etc.). The user already got
      // instant feedback above — errors here are swallowed.
      // ignore: discarded_futures
      _reconcileListAfterFollow();

      return true;
    } catch (e) {
      state = state.copyWith(isFollowLoading: false, error: e.toString());
      return false;
    }
  }

  /// Silent re-fetch after a successful follow/unfollow. Replaces
  /// `state.list` with the server value so `followerCount` reconciles
  /// against any drift from the optimistic ±1 bump. Preserves the
  /// owner-name enrichment that `_loadAuthenticatedList` applies for
  /// owned lists (no-op for followers, who can't own the list).
  Future<void> _reconcileListAfterFollow() async {
    try {
      final fresh = await _api.getList(_resolvedListId);
      if (!mounted) return;
      final preservedOwnerName = state.list?.ownerName;
      final reconciled = (preservedOwnerName != null && fresh.ownerName == null)
          ? fresh.copyWith(ownerName: preservedOwnerName)
          : fresh;
      state = state.copyWith(list: reconciled);
    } catch (_) {
      // Silent — the optimistic count already gave the user feedback.
    }
  }

  /// Set view mode
  void setViewMode(ListViewMode mode) {
    state = state.copyWith(viewMode: mode);
  }

  /// Pick the item ordering and refetch (List view's sort menu).
  ///
  /// The BE owns the ordering — `chronological` ranks by the next occurrence
  /// still ahead and `alphabetical` folds accents through the DB collation,
  /// neither of which the client can reproduce faithfully — so this refetches
  /// from page 0 rather than re-sorting `state.items` locally.
  ///
  /// [sort] `null` means "the list's own order": the param is omitted, which
  /// is how an owner's hand-arranged `custom` sequence comes back.
  Future<void> setSort(ZineItemSort? sort) async {
    if (state.sort == sort) return;
    // Keep the painted rows up while page 1 refetches. Clearing them would
    // drop the page to the full-screen `ListZineSkeleton` (which the screen
    // shows on `isLoadingItems && items.isEmpty`), so every sort tap would
    // tear the whole list page down and rebuild it.
    state = state.copyWith(sort: sort, clearSort: sort == null);
    await loadItems(filter: state.filter);
  }

  /// Update list visibility optimistically (owner only)
  void updateVisibilityOptimistic(ListVisibility visibility) {
    if (state.list == null || !state.isOwner) return;

    final updatedList = state.list!.copyWith(
      visibility: visibility,
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(list: updatedList);

    // Track visibility change (PostHog)
    _analytics.trackListVisibilityChange(
      listId: state.list?.id ?? listId,
      visibility: visibility.name,
      listName: state.list?.name,
    );
  }

  /// Update list name/description/prompt optimistically (owner only)
  ///
  /// Set [clearPrompt] to true when the user explicitly clears the prompt
  /// (empty field in the edit dialog). Without this flag, a null [prompt]
  /// is treated as "don't change" by [UserList.copyWith].
  void updateListOptimistic({
    String? name,
    String? description,
    String? prompt,
    bool clearPrompt = false,
  }) {
    if (state.list == null || !state.isOwner) return;

    final updatedList = state.list!.copyWith(
      name: name ?? state.list!.name,
      description: description,
      prompt: prompt,
      clearPrompt: clearPrompt,
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(list: updatedList);
  }

  /// Wrap an in-flight API mutation so the page can show a spinner on
  /// the chrome's Done button (PROD-1783). The counter increments
  /// synchronously before any await and decrements in a `finally`
  /// — including the case where the underlying call throws.
  Future<T> _withPendingMutation<T>(Future<T> Function() body) async {
    state = state.copyWith(pendingMutations: state.pendingMutations + 1);
    try {
      return await body();
    } finally {
      // Guard against double-decrement (state might have been reset by
      // a refresh in the middle of the await chain).
      final next = state.pendingMutations - 1;
      state = state.copyWith(pendingMutations: next < 0 ? 0 : next);
    }
  }

  /// Enter page-level edit mode (PROD-1783, owner only). Forces the view
  /// mode to [ListViewMode.list] in the same flip so callers don't have to
  /// orchestrate two state changes; the cover row + inline editors only
  /// make sense in list view. The user's pre-edit view mode is stashed
  /// in [UnifiedListState.viewModeBeforeEdit] so [exitEditMode] can
  /// restore it. No API calls — pure local-state transition.
  Future<void> enterEditMode() async {
    if (!state.isOwner) return;
    if (state.editMode && state.viewMode == ListViewMode.list) return;
    // A view-only sort must not become the stored order. [reorderItems] posts
    // the WHOLE visible sequence as the new custom order, so one drag under an
    // active sort would permanently rewrite the list to that ordering.
    //
    // AWAIT the restore, don't fire-and-forget it. [setSort] deliberately keeps
    // the painted rows up while it refetches, so returning early would open
    // edit mode over the SORTED rows with `sort` already null — the flag guard
    // passes while the rows are still wrong, and a drag in that window persists
    // the sort. Proven by `_race_probe`; see `unified_list_sort_test.dart`.
    if (state.sort != null) {
      await setSort(null);
      if (!mounted || !state.isOwner) return;
    }
    state = state.copyWith(
      editMode: true,
      viewMode: ListViewMode.list,
      // Only snapshot if we haven't already (re-entering edit-mode
      // after a partial-exit edge case shouldn't overwrite the
      // user's real prior choice).
      viewModeBeforeEdit: state.viewModeBeforeEdit ?? state.viewMode,
    );
  }

  /// Exit edit mode (PROD-1783). Restores the user's pre-edit view mode
  /// — a Zine viewer who edits should land back on Zine, not List
  /// (which is what edit-mode forced for the inline editors). Each
  /// mutation in edit mode committed immediately, so there are no
  /// outstanding writes to flush here.
  void exitEditMode() {
    if (!state.editMode) return;
    final restoreTo = state.viewModeBeforeEdit ?? state.viewMode;
    state = state.copyWith(
      editMode: false,
      viewMode: restoreTo,
      clearViewModeBeforeEdit: true,
    );
  }

  /// Commit a list metadata update (name / description / prompt) by first
  /// optimistically updating local state and then persisting via
  /// [listsProvider.updateList]. Wraps the previous
  /// `list_page_screen._handleEdit` orchestration so the inline title and
  /// description editors (PROD-1783 edit mode) can fire-and-forget without
  /// re-implementing rollback.
  ///
  /// Returns `true` when the API call succeeded; on failure, the local
  /// state is rolled back to the previous values.
  Future<bool> commitListUpdate({
    String? name,
    String? description,
    String? prompt,
    bool clearPrompt = false,
  }) async {
    final originalList = state.list;
    if (originalList == null || !state.isOwner) return false;
    if (_persistListUpdate == null) return false;

    updateListOptimistic(
      name: name,
      description: description,
      prompt: prompt,
      clearPrompt: clearPrompt,
    );

    return _withPendingMutation(() async {
      try {
        // `_persistListUpdate` was null-checked above; flow analysis on
        // class fields doesn't carry through to this async closure,
        // hence the bang.
        // ignore: unnecessary_non_null_assertion
        await _persistListUpdate!(
          UserListUpdate(
            name: name,
            description: description,
            prompt: prompt,
            clearPrompt: clearPrompt,
          ),
        );
        await refresh();
        return true;
      } catch (e) {
        debugPrint('[UnifiedListProvider] commitListUpdate failed: $e');
        // Roll back to the original values.
        state = state.copyWith(list: originalList);
        // PROD-2264 — surface the wordlist filter rejection so the
        // calling widget can render the backend's message. Other
        // failures stay swallowed (returning false) to preserve the
        // existing optimistic-rollback contract.
        final blocked = ContentBlockedException.tryFrom(e);
        if (blocked != null) throw blocked;
        return false;
      }
    });
  }

  /// Upload a cover image from device (gallery or camera)
  Future<bool> uploadCover(String imagePath) async {
    if (state.list == null || !state.isOwner) return false;

    try {
      final updatedList = await _api.uploadListCover(
        _resolvedListId,
        imagePath,
      );
      state = state.copyWith(list: updatedList);
      // Track cover change (PostHog)
      _analytics.trackListCoverChange(
        listId: state.list?.id ?? listId,
        listName: state.list?.name,
      );
      return true;
    } catch (e) {
      debugPrint('[UnifiedListProvider] uploadCover failed: $e');
      return false;
    }
  }

  /// Set cover from an existing URL (e.g. from a list item's image)
  Future<bool> setCoverFromUrl(String imageUrl) async {
    if (state.list == null || !state.isOwner) return false;

    // Optimistic update — also toggle isCover on items
    final originalList = state.list;
    final originalItems = state.items;
    final updatedItems = state.items
        .map((item) => item.copyWith(isCover: item.imageUrl == imageUrl))
        .toList();
    state = state.copyWith(
      list: state.list!.copyWith(
        coverImageUrl: imageUrl,
        updatedAt: DateTime.now(),
      ),
      items: updatedItems,
    );

    return _withPendingMutation(() async {
      try {
        await _api.updateList(
          _resolvedListId,
          UserListUpdate(coverImageUrl: imageUrl),
        );
        // Track cover change (PostHog)
        _analytics.trackListCoverChange(
          listId: state.list?.id ?? listId,
          listName: state.list?.name,
        );
        return true;
      } catch (e) {
        debugPrint('[UnifiedListProvider] setCoverFromUrl failed: $e');
        state = state.copyWith(list: originalList, items: originalItems);
        return false;
      }
    });
  }

  /// PROD-1908 — set any subset of cover-recipe fields with a single
  /// PATCH. Passing `null` for a field with the corresponding
  /// `clearXxx: true` flag clears it on the backend (BE accepts JSON
  /// `null` to clear, see PROD-1907 contract). Untouched fields are
  /// omitted from the request entirely — the BE leaves them unchanged.
  ///
  /// The Dart OpenAPI codegen serialiser quirk that BE flagged on
  /// PROD-1907 (unset nullable fields emitted as `null` and silently
  /// clearing) is sidestepped here because we hand-build the
  /// [UserListUpdate] payload, and `UserListUpdate.toJson()` emits only
  /// the keys explicitly populated.
  Future<bool> setCoverRecipe({
    String? type,
    String? color,
    bool clearColor = false,
    String? texture,
    bool clearTexture = false,
    String? textColor,
    bool clearTextColor = false,
    String? itemId,
    bool clearItemId = false,
  }) async {
    if (state.list == null || !state.isOwner) return false;

    final originalList = state.list;
    final originalItems = state.items;

    // Optimistic update — apply the touched fields locally. Per-field
    // clearer flags on UserList.copyWith propagate the BE's null-clears
    // accurately (a bare `coverColor: null` would otherwise read as
    // "leave unchanged" because copyWith uses `?? this.coverColor`).
    //
    // PROD-1932 + PROD-2425 — `coverItemImageUrl` is BE-derived but it's
    // what discovery shelves (e.g. `yoursShelfProvider`) pin to:
    // `ZineCoverRecipe.fromUserList(list)` on the shelf card is called
    // WITHOUT an `itemLookup`, so a null URL forces the card into the
    // background_color fallback even when `coverType == item_image` and
    // `coverItemId` is set. The PROD-1932 approach (clear-and-let-BE-
    // re-derive on next GET) worked when shelves disposed on navigation,
    // but `yoursShelfProvider` stays alive on push/pop — the GET never
    // fires and `/yours` shows "no image" indefinitely. Fix: resolve the
    // new URL locally from `state.items` (where the picked item lives
    // with its `imageUrl` getter) and inject it into the optimistic
    // UserList. Falls back to the clear path only when we can't resolve
    // (recipe transitioning to background_color, or picked item has no
    // imageUrl).
    final bool invalidateItemImageUrl =
        type != null || itemId != null || clearItemId;
    final bool nowHasItemImage =
        !clearItemId &&
        (itemId != null ||
            (type == ZineCoverType.itemImage.wire &&
                state.list!.coverItemId != null));
    String? resolvedItemImageUrl;
    if (nowHasItemImage) {
      final effectiveItemId = itemId ?? state.list!.coverItemId;
      if (effectiveItemId != null) {
        final item = state.items.firstWhereOrNull(
          (i) => i.id == effectiveItemId,
        );
        resolvedItemImageUrl = item?.imageUrl;
      }
    }
    final bool clearItemImageUrl =
        invalidateItemImageUrl && resolvedItemImageUrl == null;
    final next = state.list!.copyWith(
      coverType: type,
      coverColor: color,
      clearCoverColor: clearColor,
      coverTexture: texture,
      clearCoverTexture: clearTexture,
      coverTextColor: textColor,
      clearCoverTextColor: clearTextColor,
      coverItemId: itemId,
      clearCoverItemId: clearItemId,
      coverItemImageUrl: resolvedItemImageUrl,
      clearCoverItemImageUrl: clearItemImageUrl,
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(list: next);

    return _withPendingMutation(() async {
      try {
        await _api.updateList(
          _resolvedListId,
          UserListUpdate(
            coverType: type,
            coverColor: color,
            clearCoverColor: clearColor,
            coverTexture: texture,
            clearCoverTexture: clearTexture,
            coverTextColor: textColor,
            clearCoverTextColor: clearTextColor,
            coverItemId: itemId,
            clearCoverItemId: clearItemId,
          ),
        );
        _analytics.trackListCoverChange(
          listId: state.list?.id ?? listId,
          listName: state.list?.name,
        );
        return true;
      } catch (e) {
        debugPrint('[UnifiedListProvider] setCoverRecipe failed: $e');
        state = state.copyWith(list: originalList, items: originalItems);
        return false;
      }
    });
  }

  /// PROD-3217 — merge the server-derived render fields (`cover_share_render_url`
  /// and its `cover_share_render_signature`) from a share-render upload response
  /// into the current list, without touching any other field. The upload
  /// response is a full `UserListOut`, but the user may have made further
  /// optimistic cover edits since the render was captured; copying only these
  /// BE-derived fields avoids clobbering them. Carrying the signature lets the
  /// next share's freshness check see the fresh value without a refetch.
  void mergeServerRenderUrl(UserList serverList) {
    final current = state.list;
    if (current == null || current.id != serverList.id) return;
    if (current.coverShareRenderUrl == serverList.coverShareRenderUrl &&
        current.coverShareRenderSignature ==
            serverList.coverShareRenderSignature) {
      return;
    }
    state = state.copyWith(
      list: current.copyWith(
        coverShareRenderUrl: serverList.coverShareRenderUrl,
        coverShareRenderSignature: serverList.coverShareRenderSignature,
      ),
    );
  }

  /// Remove the current cover image
  Future<bool> removeCover() async {
    if (state.list == null || !state.isOwner) return false;

    // Optimistic update - clear cover and isCover on all items
    final originalList = state.list;
    final originalItems = state.items;
    final updatedItems = state.items
        .map((item) => item.isCover ? item.copyWith(isCover: false) : item)
        .toList();
    state = state.copyWith(
      list: state.list!.copyWith(clearCover: true, updatedAt: DateTime.now()),
      items: updatedItems,
    );

    try {
      await _api.updateList(
        _resolvedListId,
        const UserListUpdate(clearCover: true),
      );
      return true;
    } catch (e) {
      debugPrint('[UnifiedListProvider] removeCover failed: $e');
      state = state.copyWith(list: originalList, items: originalItems);
      return false;
    }
  }

  /// Remove item from list (owner only, optimistic update)
  Future<bool> removeItem(String itemId) async {
    if (!state.isOwner) return false;

    // Store original state for rollback
    final originalItems = state.items;
    final originalList = state.list;

    // Get item for analytics + content-key tracking before removal.
    // firstWhereOrNull guards against an empty `state.items` (the
    // previous `orElse: () => state.items.first` crashed with
    // "Bad state: No element" in that case — PROD-2084 audit).
    final item = state.items.firstWhereOrNull((i) => i.id == itemId);
    if (item == null) {
      // Nothing to optimistically remove — bail without touching state
      // or the API; the caller's UI invariant (item exists) was wrong.
      return false;
    }
    final itemType = item.itemType.name;
    final removedKey = _contentKey(item);
    // The list's TRUE total (server `total`), not the loaded page. `itemCount`
    // below is overwritten with the loaded-items length, so it cannot be used
    // for analytics — items load progressively (PROD-1967). See PROD-3095.
    final originalTotal = state.totalItems;
    final sizeAfter = _sizeAfterRemoving(originalTotal, 1);

    // Was this the item currently used as the list cover? If so the backend
    // rolls the cover over to the next image-bearing item (or clears it) on
    // delete, and we must re-sync `state.list` afterwards — otherwise the zine
    // view + edit-zine keep rendering the now-deleted item's cover image while
    // the lists-hub card (which refetches separately) shows the rolled-over one.
    final wasCoverItem = state.list?.coverItemId == itemId;

    // Optimistic update - remove item immediately
    final updatedItems = state.items.where((i) => i.id != itemId).toList();
    final updatedList = state.list?.copyWith(
      itemCount: updatedItems.length,
      updatedAt: DateTime.now(),
      // Drop the stale cover pointer immediately so the deleted item's image
      // stops showing at once; the authoritative rolled-over cover is refetched
      // below once the API confirms the removal.
      clearCoverItemId: wasCoverItem,
      clearCoverItemImageUrl: wasCoverItem,
    );
    state = state.copyWith(
      items: updatedItems,
      list: updatedList,
      totalItems: sizeAfter ?? originalTotal,
    );

    return _withPendingMutation(() async {
      try {
        await _api.removeItem(_resolvedListId, itemId);
        _markRecentlyRemoved(removedKey);

        // If we just removed the cover item, refetch the list identity so
        // `state.list` picks up the backend's rolled-over cover (new
        // cover_item_id / cover_type / resolved image). Best-effort: the
        // removal already committed server-side, so a refresh failure must NOT
        // roll the removal back — swallow it (the cover simply stays in its
        // optimistically-cleared state until the next full reload).
        if (wasCoverItem) {
          try {
            await _loadAuthenticatedList();
          } catch (e, st) {
            unawaited(Sentry.captureException(e, stackTrace: st));
          }
        }

        // Refresh saved state in ListsNotifier (non-blocking — the heavy
        // loadAllOwnedItems runs in the background so the UI stays snappy).
        // Single DELETE's 204 carries no cascade ids (PROD-3873).
        _onItemRemoved?.call(const {});

        // Track item removal (Backend + Firebase).
        _analytics.trackListItemRemove(
          listId: state.list?.id ?? listId,
          itemType: itemType,
          eventId: item.eventId,
          venueId: item.venueId,
          listName: state.list?.name,
          itemName: item.title,
          list: state.list,
          currentUserId: _getCurrentUserId(),
          listSizeAfter: sizeAfter,
        );

        return true;
      } catch (e, st) {
        // Rollback on failure. PROD-2084 — forward to Sentry so the
        // next item-remove regression doesn't stay invisible. `unawaited`
        // is critical here: this catch sits inside _withPendingMutation,
        // and we must not let the captureException Future block the
        // mutation path or flip our return to a throw.
        unawaited(Sentry.captureException(e, stackTrace: st));
        state = state.copyWith(
          items: originalItems,
          list: originalList,
          totalItems: originalTotal,
        );
        return false;
      }
    });
  }

  /// Authoritative post-removal item count for analytics, or null when this
  /// notifier has no trustworthy total (the list was never loaded through a
  /// paginated endpoint, so `totalItems` is still 0).
  ///
  /// Growth thresholds notifications on `list_size_after`, so emitting nothing
  /// beats emitting a number the list never had. PROD-3095.
  int? _sizeAfterRemoving(int total, int removed) {
    if (total <= 0) return null;
    final next = total - removed;
    return next < 0 ? 0 : next;
  }

  /// Bulk-remove a set of items in a single API call (PROD-1722).
  ///
  /// Optimistically removes them from `state.items`, marks each as recently
  /// removed (so the trailing `loadItemsQuietly` doesn't silently re-add them
  /// under read-after-write lag), and awaits the server response. On failure,
  /// the entire batch is rolled back. On partial server skip, only the
  /// successfully-deleted ids stay removed.
  ///
  /// Used by the Instagram-share review sheet to collapse N parallel DELETEs
  /// into one call so the per-route rate limiter (30 req/min) is respected
  /// when the user un-checks several events at once.
  Future<bool> bulkRemoveItems(List<String> itemIds) async {
    if (!state.isOwner) return false;
    if (itemIds.isEmpty) return true;

    final originalItems = state.items;
    final originalList = state.list;

    final removeSet = itemIds.toSet();
    final removedItems = state.items
        .where((i) => removeSet.contains(i.id))
        .toList();
    if (removedItems.isEmpty) return true;

    // True total (server `total`), not the loaded page — see PROD-3095.
    final originalTotal = state.totalItems;

    final updatedItems = state.items
        .where((i) => !removeSet.contains(i.id))
        .toList();
    final updatedList = state.list?.copyWith(
      itemCount: updatedItems.length,
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(
      items: updatedItems,
      list: updatedList,
      totalItems:
          _sizeAfterRemoving(originalTotal, removedItems.length) ??
          originalTotal,
    );

    try {
      final result = await _api.bulkDeleteItems(_resolvedListId, itemIds);

      // Restore any items the server marked `forbidden` (collaborator who
      // didn't add them). `not_found` is treated as already-deleted — no
      // restore needed.
      final forbiddenIds = result.skipped
          .where((s) => s.reason == 'forbidden')
          .map((s) => s.itemId)
          .toSet();
      if (forbiddenIds.isNotEmpty) {
        final restored = removedItems
            .where((i) => forbiddenIds.contains(i.id))
            .toList();
        if (restored.isNotEmpty) {
          state = state.copyWith(items: [...state.items, ...restored]);
        }
      }

      // Only the non-forbidden items actually went away. Correct the total
      // before it is reported as `list_size_after` — the optimistic write above
      // assumed the whole batch was deleted.
      final actuallyRemoved = removedItems
          .where((i) => !forbiddenIds.contains(i.id))
          .length;
      final sizeAfter = _sizeAfterRemoving(originalTotal, actuallyRemoved);
      state = state.copyWith(totalItems: sizeAfter ?? originalTotal);

      // Tombstone every deleted content key so loadItemsQuietly's append
      // pass can't re-add them under read-after-write lag.
      for (final item in removedItems) {
        if (forbiddenIds.contains(item.id)) continue;
        _markRecentlyRemoved(_contentKey(item));
      }

      // Bulk delete cascades server-side; `cascaded_list_ids` names every list
      // that lost a row so the callback can refresh their open views (PROD-3873).
      _onItemRemoved?.call(result.cascadedListIds.toSet());

      final currentUserId = _getCurrentUserId();
      for (final item in removedItems) {
        if (forbiddenIds.contains(item.id)) continue;
        _analytics.trackListItemRemove(
          listId: state.list?.id ?? listId,
          itemType: item.itemType.name,
          eventId: item.eventId,
          venueId: item.venueId,
          listName: state.list?.name,
          itemName: item.title,
          list: state.list,
          currentUserId: currentUserId,
          // The batch lands atomically, so every event in it reports the same
          // post-batch total.
          listSizeAfter: sizeAfter,
        );
      }

      return true;
    } catch (e) {
      debugPrint('[UnifiedListProvider] bulkRemoveItems failed: $e');
      state = state.copyWith(
        items: originalItems,
        list: originalList,
        totalItems: originalTotal,
      );
      return false;
    }
  }

  /// Reorder items in the list (owner only, optimistic update).
  ///
  /// [oldIndex] and [newIndex] are indices in the current filtered items list.
  /// Sends the full reordered list of item IDs to the backend.
  Future<bool> reorderItems(int oldIndex, int newIndex) async {
    if (!state.isOwner) return false;
    // Never persist an order derived from rows that are mid-replacement. This
    // call posts the WHOLE visible sequence as the list's new custom order, so
    // reordering a stale or partially-loaded set writes that set as the truth.
    // Belt-and-braces with [enterEditMode]'s await: this guards the write
    // itself, so any future path reaching edit mode during a fetch is safe too.
    if (state.isLoadingItems) return false;

    // Work with the full items list (not filtered)
    final originalItems = state.items;
    final reordered = List<UserListItem>.from(originalItems);

    // Adjust newIndex per Flutter's ReorderableListView convention:
    // if moving down, newIndex is off by one
    var adjustedNewIndex = newIndex;
    if (adjustedNewIndex > oldIndex) {
      adjustedNewIndex -= 1;
    }

    final item = reordered.removeAt(oldIndex);
    reordered.insert(adjustedNewIndex, item);

    // Update sort_order values to match new positions
    final withSortOrder = [
      for (var i = 0; i < reordered.length; i++)
        reordered[i].copyWith(sortOrder: i),
    ];

    // Optimistic update
    state = state.copyWith(items: withSortOrder);

    return _withPendingMutation(
      () => _reorderItemsCommit(withSortOrder, originalItems),
    );
  }

  Future<bool> _reorderItemsCommit(
    List<UserListItem> withSortOrder,
    List<UserListItem> originalItems,
  ) async {
    try {
      final itemIds = withSortOrder.map((i) => i.id).toList();
      await _api.reorderItems(_resolvedListId, itemIds);
      // Track reorder (PostHog)
      _analytics.trackListReorder(
        listId: state.list?.id ?? listId,
        listName: state.list?.name,
      );
      return true;
    } catch (e) {
      // Rollback on failure
      debugPrint('[UnifiedListProvider] reorderItems failed: $e');
      state = state.copyWith(items: originalItems);
      return false;
    }
  }

  /// Remove item from local state only (when already removed via another provider)
  UserListItem? removeItemFromLocalState(String itemId) {
    // firstWhereOrNull replaces the old `firstWhere(..., orElse: () =>
    // state.items.first)` + dead `item.id != itemId` guard. The previous
    // shape would crash on an empty `state.items` before reaching the
    // guard, so the guard had no defensive value. (PROD-2084 audit)
    final item = state.items.firstWhereOrNull((i) => i.id == itemId);
    if (item == null) return null;

    // True total (server `total`), not the loaded page — see PROD-3095.
    final sizeAfter = _sizeAfterRemoving(state.totalItems, 1);

    final updatedItems = state.items.where((i) => i.id != itemId).toList();
    final updatedList = state.list?.copyWith(
      itemCount: updatedItems.length,
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(
      items: updatedItems,
      list: updatedList,
      totalItems: sizeAfter ?? state.totalItems,
    );
    _markRecentlyRemoved(_contentKey(item));

    // Track item removal (Backend + Firebase).
    _analytics.trackListItemRemove(
      listId: state.list?.id ?? listId,
      itemType: item.itemType.name,
      eventId: item.eventId,
      venueId: item.venueId,
      listName: state.list?.name,
      itemName: item.title,
      list: state.list,
      currentUserId: _getCurrentUserId(),
      listSizeAfter: sizeAfter,
    );

    return item;
  }

  /// Remove item from local state by content key — used when the caller knows
  /// which venue/event was removed but not the per-list `itemId` (e.g. the
  /// bookmark sheet un-checking a list).
  ///
  /// Symmetric to how `mergeOptimisticItemsLocally` adds by content key. The
  /// backend removal is done by the caller before this call; this method only
  /// updates local state so the list detail view reflects the change
  /// immediately instead of waiting for a full reload.
  ///
  /// Returns the removed item, or null if no matching item was found.
  UserListItem? removeItemByContent({
    String? eventId,
    String? venueId,
    String? googlePlaceId,
  }) {
    if (eventId == null && venueId == null && googlePlaceId == null) {
      return null;
    }
    final index = state.items.indexWhere(
      (i) =>
          (eventId != null && i.eventId == eventId) ||
          (venueId != null && i.venueId == venueId) ||
          (googlePlaceId != null && i.googlePlaceId == googlePlaceId),
    );
    if (index == -1) return null;

    final item = state.items[index];
    final updatedItems = [...state.items]..removeAt(index);
    final updatedList = state.list?.copyWith(
      itemCount: updatedItems.length,
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(items: updatedItems, list: updatedList);
    _markRecentlyRemoved(_contentKey(item));
    return item;
  }

  /// Instantly merge pending optimistic items into the local state.
  ///
  /// This avoids the delay of a full API round-trip — the new item appears
  /// in the list immediately when `pendingItems` updates.
  void mergeOptimisticItemsLocally() {
    final pendingItems = _getPendingItems();
    if (pendingItems.isEmpty) return;

    final userId = _getCurrentUserId() ?? '';
    final existingItems = state.items;

    // Convert pending items to UserListItem
    final optimisticUserItems = pendingItems
        .map((item) => item.toUserListItem(userId))
        .toList();

    // Deduplicate: skip items already present by content key
    final newItems = optimisticUserItems.where((opt) {
      return !existingItems.any((existing) => _contentKeysMatch(existing, opt));
    }).toList();

    if (newItems.isEmpty) return;

    state = state.copyWith(items: [...existingItems, ...newItems]);
  }

  /// Check if two items match by content key (eventId/venueId/googlePlaceId)
  bool _contentKeysMatch(UserListItem a, UserListItem b) {
    if (a.eventId != null && a.eventId == b.eventId) return true;
    if (a.venueId != null && a.venueId == b.venueId) return true;
    if (a.googlePlaceId != null && a.googlePlaceId == b.googlePlaceId)
      return true;
    return false;
  }

  /// Reload items in the background without showing a loading spinner.
  ///
  /// Used when optimistic updates (e.g., adding a suggestion) trigger a
  /// refresh — the user already sees the item, so we don't want the list
  /// to disappear behind a loading indicator.
  ///
  /// Preserves the current local ordering: existing items keep their
  /// positions (optimistic items are upgraded in-place with backend data),
  /// and only genuinely new items are appended at the end.
  Future<void> loadItemsQuietly() async {
    try {
      ({List<UserListItem> items, List<SlimMapPin> mapPins, int total}) result;
      if (_isAuthenticated()) {
        try {
          result = await _fetchSlimItems(authenticated: true);
        } catch (e) {
          if (_isAuthenticationError(e)) {
            result = await _fetchSlimItems(authenticated: false);
          } else {
            return; // Silently fail
          }
        }
      } else {
        result = await _fetchSlimItems(authenticated: false);
      }

      if (!mounted) return;
      final freshItems = result.items;
      // Refresh map pins from the fresh response — they're whole-list
      // scoped so this is authoritative.
      state = state.copyWith(mapPins: result.mapPins, totalItems: result.total);

      // Build a lookup from content key → fresh backend item
      final freshByKey = <String, UserListItem>{};
      for (final item in freshItems) {
        final key = _contentKey(item);
        freshByKey[key] = item;
      }

      // Build a set of content keys still pending confirmation
      final pendingItems = _getPendingItems();
      final pendingKeys = <String>{};
      final userId = _getCurrentUserId() ?? '';
      for (final pending in pendingItems) {
        pendingKeys.add(_contentKey(pending.toUserListItem(userId)));
      }

      // Walk existing items in order, upgrading optimistic → backend data.
      // Drop orphaned optimistic items (not in backend AND not in pending).
      final seenKeys = <String>{};
      final merged = <UserListItem>[];
      for (final existing in state.items) {
        final key = _contentKey(existing);
        final fresh = freshByKey[key];
        if (fresh != null) {
          merged.add(fresh); // Replace with backend version (real ID, etc.)
        } else if (pendingKeys.contains(key)) {
          merged.add(existing); // Still pending — keep optimistic item
        } else if (freshByKey.isEmpty) {
          merged.add(existing); // Backend returned nothing — keep all
        } else {
          // Not in backend AND not pending — orphaned optimistic item (save
          // failed after retries). Drop it silently; the suggestions provider
          // has already set lastSaveError to notify the user.
          continue;
        }
        seenKeys.add(key);
      }

      // Append any backend items we haven't seen (e.g. added from another
      // device). These go at the end to avoid shifting visible items.
      // Skip items the user just removed locally — read-after-write lag
      // can otherwise silently re-add them right after the delete commits.
      _expireRecentlyRemoved();
      for (final item in freshItems) {
        final key = _contentKey(item);
        if (seenKeys.contains(key)) continue;
        if (_recentlyRemovedKeys.containsKey(key)) continue;
        merged.add(item);
        seenKeys.add(key);
      }

      state = state.copyWith(items: merged, isLoadingItems: false);
    } catch (_) {
      // Silently fail — existing items remain visible
    }
  }

  /// Content key for stable identity across optimistic → backend transitions.
  String _contentKey(UserListItem item) {
    if (item.eventId != null) return 'e:${item.eventId}';
    if (item.venueId != null) return 'v:${item.venueId}';
    if (item.googlePlaceId != null) return 'g:${item.googlePlaceId}';
    return 'id:${item.id}';
  }

  void _markRecentlyRemoved(String key) {
    _recentlyRemovedKeys[key] = DateTime.now();
  }

  void _expireRecentlyRemoved() {
    final now = DateTime.now();
    _recentlyRemovedKeys.removeWhere(
      (_, ts) => now.difference(ts) > _recentRemovalTtl,
    );
  }

  /// Background-fetch the full item set using the slim endpoint. Used
  /// by [loadItemsQuietly], which does its own merge so we just need
  /// the synthesised heavy items here. Pages at `limit=500` (the BE
  /// max) and stops when total is reached or a short page comes back.
  Future<({List<UserListItem> items, List<SlimMapPin> mapPins, int total})>
  _fetchSlimItems({SavedItemType? filter, required bool authenticated}) async {
    final all = <UserListItem>[];
    var mapPins = const <SlimMapPin>[];
    var total = 0;
    var offset = 0;
    final sort = state.sort;
    final visitorId = authenticated ? null : await _getVisitorId();

    while (true) {
      final page = authenticated
          ? await _api.listItemsSlim(
              _resolvedListId,
              itemType: filter,
              limit: _slimTailPageLimit,
              offset: offset,
              sort: sort,
            )
          : await _api.listPublicItemsSlim(
              _resolvedListId,
              itemType: filter,
              limit: _slimTailPageLimit,
              offset: offset,
              ref: _referralRef,
              visitorId: visitorId,
              sort: sort,
            );
      total = page.total;
      if (offset == 0) {
        mapPins = page.mapPins;
      }
      all.addAll(page.items.map((s) => slimItemToHeavy(s)));
      if (all.length >= total || page.items.length < _slimTailPageLimit) {
        break;
      }
      offset += page.items.length;
    }

    return (items: all, mapPins: mapPins, total: total);
  }

  /// Update a single item's tip in local state and persist to API.
  Future<bool> updateItemTip(String itemId, String tip) async {
    final actionContext = _analytics.actionContext;
    final originalItems = state.items;

    // Optimistic local update
    final clearTip = tip.isEmpty;
    final updatedItems = state.items.map((item) {
      if (item.id == itemId) {
        return clearTip
            ? item.copyWith(clearTip: true)
            : item.copyWith(tip: tip);
      }
      return item;
    }).toList();
    state = state.copyWith(items: updatedItems);

    // The backend's authoritative transition for this tip edit (PROD-4552).
    // Null until a write confirms; an older backend reports unknown.
    NoteAction? noteAction;
    final ok = await _withPendingMutation(() async {
      try {
        final result = await _api.updateItem(
          _resolvedListId,
          itemId,
          // An omitted tip means "unchanged" to the backend. Keep the empty
          // string in the PATCH body so clearing a note survives serialization.
          UserListItemUpdate(tip: tip),
        );
        noteAction = result.noteAction;
        return true;
      } catch (e) {
        // API failure: roll back the optimistic update and report.
        debugPrint('[UnifiedListProvider] updateItemTip failed: $e');
        state = state.copyWith(items: originalItems);
        // PROD-2264 — surface the wordlist filter rejection so
        // [ListItemNote] can render the backend's message. Other
        // failures stay swallowed (returning false) to preserve the
        // existing rollback + errorUnknown snackbar contract.
        final blocked = ContentBlockedException.tryFrom(e);
        if (blocked != null) throw blocked;
        return false;
      }
    });
    if (!ok) return false;

    // Analytics — best-effort, MUST NOT cause a successful save to be
    // reported as a failure. firstWhereOrNull keeps the lookup
    // structurally safe (no `Bad state: No element` on an empty
    // originalItems); the outer try/catch still swallows any analytics
    // call that throws. (PROD-2084 audit)
    try {
      final item = originalItems.firstWhereOrNull((i) => i.id == itemId);
      // PROD-4553 — a standalone tip edit is a "later annotation": emit the
      // note event with the backend transition but NO save_flow_id (its
      // absence is what the report joins on). Suppress a no-op re-submit
      // (unchanged); an older backend without the metadata reports unknown.
      final action = noteAction ?? NoteAction.unknown;
      if (item != null && action != NoteAction.unchanged) {
        _analytics.trackListElementNote(
          actionContext: actionContext,
          listId: state.list?.id ?? listId,
          itemType: item.itemType == SavedItemType.event ? 'event' : 'place',
          eventId: item.eventId,
          venueId: item.venueId,
          itemName: item.title,
          listItemId: itemId,
          noteAction: action,
          hasNote: noteIsPresent(tip),
          noteLength: noteLength(tip),
          source: ListSource.listUi,
        );
      }
    } catch (e) {
      debugPrint('[UnifiedListProvider] updateItemTip analytics skipped: $e');
    }

    return true;
  }

  /// Refresh list and items
  Future<void> refresh() => load();

  /// Background-refresh items if any venue/event items are missing images.
  /// Called on screen re-entry to self-heal after backend cache warming.
  void refreshIfItemsIncomplete() {
    final hasIncompleteItems = state.items.any(
      (item) =>
          item.imageUrl == null &&
          (item.venueId != null || item.eventId != null),
    );
    if (hasIncompleteItems) {
      loadItemsQuietly();
    }
  }

  /// Convert PublicList to UserList for unified handling
  UserList _convertPublicListToUserList(PublicList publicList) {
    return UserList(
      id: publicList.id,
      ownerId: publicList.owner.id,
      name: publicList.name,
      slug: publicList.slug,
      description: publicList.description,
      visibility: publicList.visibility,
      isCollaborative: false, // Not exposed in public API
      isDefault: false, // Not exposed in public API
      itemCount: publicList.itemCount,
      memberCount: 0, // Not exposed in public API
      followerCount: publicList.followerCount,
      createdAt: publicList.createdAt,
      updatedAt: publicList.updatedAt,
      ownerName: publicList.owner.displayName,
      ownerHandle: publicList.owner.handle,
      systemKind: publicList.systemKind,
      editorPick: publicList.editorPick,
      cityGuide: publicList.cityGuide,
      verified: publicList.verified,
      knownContextFields: publicList.knownContextFields,
      previewImages: publicList.previewImages,
      // PROD-1918 batch 6 quick win — propagate the full cover recipe so
      // unauthenticated viewers see the same cover as authenticated ones.
      // Pre-PR-1918 the converter dropped every cover_* field, which
      // made every public-list view fall back to the FE deterministic
      // recipe regardless of the owner's choices (latent since PROD-1907).
      coverImageUrl: publicList.coverImageUrl,
      coverType: publicList.coverType,
      coverColor: publicList.coverColor,
      coverTexture: publicList.coverTexture,
      coverTextColor: publicList.coverTextColor,
      coverItemId: publicList.coverItemId,
      coverItemImageUrl: publicList.coverItemImageUrl,
      coverShowTitle: publicList.coverShowTitle,
      coverShowTexture: publicList.coverShowTexture,
      coverShowLogo: publicList.coverShowLogo,
    );
  }

  /// Check if an error is a 401 authentication error (expired/invalid token)
  bool _isAuthenticationError(Object error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('401') || errorStr.contains('unauthorized');
  }

  /// Check if an error indicates "not found" (404 or 403)
  bool _isNotFoundError(Object error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('404') ||
        errorStr.contains('403') ||
        errorStr.contains('not found') ||
        errorStr.contains('forbidden');
  }

  /// Handle errors uniformly
  void _handleError(Object error) {
    if (_isNotFoundError(error)) {
      state = state.copyWith(
        isLoading: false,
        isLoadingItems: false,
        isNotFound: true,
      );
    } else {
      state = state.copyWith(
        isLoading: false,
        isLoadingItems: false,
        error: error.toString(),
      );
    }
  }
}

/// Provider family for unified list detail (parameterized by listId)
// Explicit type annotation (not inferred): the `onItemRemoved` closure below
// references `unifiedListProvider` itself to fan out cascade refreshes
// (PROD-3873), which would otherwise be a top-level self-inference cycle.
final StateNotifierProviderFamily<UnifiedListNotifier, UnifiedListState, String>
unifiedListProvider = StateNotifierProvider.family<UnifiedListNotifier, UnifiedListState, String>((
  ref,
  listId,
) {
  final api = ref.watch(listsApiProvider);
  final analytics = ref.watch(unifiedAnalyticsProvider);
  final listsNotifier = ref.read(listsProvider.notifier);
  final referralRef = ref.read(publicListRefProvider);

  late final UnifiedListNotifier notifier;
  notifier = UnifiedListNotifier(
    listId,
    api,
    analytics,
    isAuthenticated: () => ref.read(authStateProvider).isAuthenticated,
    getCurrentUserId: () => ref.read(currentUserProvider)?.id,
    getCurrentUserName: () => ref.read(currentUserProvider)?.fullName,
    isListFollowed: (id) => listsNotifier.isListFollowed(id),
    refreshFollowingLists: () => listsNotifier.loadFollowingLists(),
    markListUnfollowed: (id) => listsNotifier.markListUnfollowed(id),
    markListFollowed: (id) => listsNotifier.markListFollowed(id),
    wasDeepLinkTarget: (id) =>
        ref.read(deepLinkTargetLatchProvider).wasTargeted('list', id),
    prependFollowingList: (list) => listsNotifier.prependFollowingList(list),
    getPendingItems: () {
      // Collect pending items stored under either the family key (slug) or
      // the resolved UUID — callers may use either (PROD-1395).
      final lists = ref.read(listsProvider);
      final out = <OptimisticListItem>[];
      for (final key in notifier.listIdKeys) {
        out.addAll(lists.getPendingItemsForList(key));
      }
      return out;
    },
    onItemRemoved: (cascadedListIds) async {
      // Force past the freshness window — a removed item may still be
      // saved in another list, so we need the server's current truth.
      await listsNotifier.loadAllOwnedItems(force: true);
      // Also refresh list metadata so the hub shows updated item counts
      listsNotifier.loadLists();
      // PROD-3873 — a bulk cascade removed the item from other lists too.
      // Refresh any of those that have a live detail view, by BOTH id and
      // slug (the family-key gotcha). No-op when nothing is mounted.
      if (cascadedListIds.isNotEmpty) {
        final lists = ref.read(listsProvider).lists;
        final keys = <String>{};
        for (final id in cascadedListIds) {
          keys.add(id);
          final match = lists.where((l) => l.id == id).firstOrNull;
          final slug = match?.slug;
          if (slug != null && slug.isNotEmpty) keys.add(slug);
        }
        for (final key in keys) {
          final p = unifiedListProvider(key);
          if (ref.exists(p)) {
            // ignore: discarded_futures
            ref.read(p.notifier).loadItemsQuietly();
          }
        }
      }
    },
    referralRef: referralRef,
    getVisitorId: () async {
      try {
        return await ref.read(attributionServiceProvider).getVisitorId();
      } catch (_) {
        return null;
      }
    },
    persistListUpdate: (update) => listsNotifier.updateList(listId, update),
  );

  // Listen to pendingItems + recentRemovals changes from listsProvider. Check
  // both the family key (slug from URL) and the resolved UUID — the search
  // sheet writes with the UUID to avoid backend 422s, but the listener was
  // previously only checking the slug (PROD-1395).
  ref.listen<ListsState>(listsProvider, (previous, next) {
    // --- Adds: pendingItems delta ---
    var prevPending = 0;
    var nextPending = 0;
    for (final key in notifier.listIdKeys) {
      prevPending += previous?.pendingItems[key]?.length ?? 0;
      nextPending += next.pendingItems[key]?.length ?? 0;
    }
    if (prevPending != nextPending) {
      notifier.mergeOptimisticItemsLocally();
      notifier.loadItemsQuietly();
    }

    // --- Removes: new entries in recentRemovals matching our list keys ---
    final prevLen = previous?.recentRemovals.length ?? 0;
    final nextLen = next.recentRemovals.length;
    if (nextLen > prevLen) {
      final keys = notifier.listIdKeys;
      final newEntries = next.recentRemovals.sublist(prevLen);
      for (final sig in newEntries) {
        // PROD-3873 — a cascade signal reconciles EVERY owned list view by
        // content (the entity left all of the owner's lists), so the
        // coupled Saved Items / My Places / My Events stay in sync. A normal
        // signal still only touches the list it was emitted for.
        final applies =
            keys.contains(sig.listId) ||
            (sig.cascade && notifier.state.isOwner);
        if (applies) {
          notifier.removeItemByContent(
            eventId: sig.eventId,
            venueId: sig.venueId,
            googlePlaceId: sig.googlePlaceId,
          );
        }
      }
    }
  });

  // Re-load when auth transitions from uninitialized → authenticated.
  // This handles the case where the user refreshes the browser on a list page:
  // the router allows the route before auth initializes (for public list access),
  // so the provider initially loads via the public endpoint. Once auth is ready
  // and the user is authenticated, reload via the authenticated endpoint to get
  // full owner controls (3-dot menu, edit, etc.).
  ref.listen<AuthState>(authStateProvider, (previous, next) {
    if (previous != null &&
        !previous.isInitialized &&
        next.isInitialized &&
        next.isAuthenticated) {
      notifier.load();
    }
  });

  // PROD-4XXX — instant-cover / on-visible prefetch. If the Library flagged
  // a warm-intent for this list (row scrolled into view), do a lightweight
  // analytics-free seed (cover + first pages, no tail) instead of the full
  // load. The open screen upgrades it via `ensureFullyLoaded()`. Every other
  // creation path (direct open, detail pages, chrome, `ref.invalidate`) has
  // no intent and takes the unchanged full-load path.
  final warmSeed = ref.read(zineWarmIntentProvider)[listId];
  if (warmSeed != null) {
    // ignore: discarded_futures
    notifier.prefetch(seedList: warmSeed);
  } else {
    // ignore: discarded_futures
    notifier.load();
  }
  return notifier;
});

/// Per-list warm-intent registry for the on-visible zine prefetch (PROD-4XXX).
///
/// The Library writes an entry (`listId -> UserList` metadata) *before* it
/// first reads `unifiedListProvider(listId)`, so the provider factory can tell
/// a lazy on-visible warm-up apart from a real open and branch to the
/// lightweight [UnifiedListNotifier.prefetch] instead of the full
/// [UnifiedListNotifier.load]. Read once at factory creation; entries are
/// harmless to leave in place (they only matter at first creation).
final zineWarmIntentProvider = StateProvider<Map<String, UserList>>(
  (ref) => const {},
);
