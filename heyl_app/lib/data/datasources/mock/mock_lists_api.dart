import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/utils/note_text.dart';
import '../../models/models.dart';
import '../../models/social/follow_user_summary.dart';
import '../interfaces/api_interfaces.dart';

/// Mock implementation of Lists API
class MockListsApi implements IListsApi {
  final List<UserList> _lists = [];
  final Map<String, List<UserListItem>> _listItems = {};
  final Set<String> _followedListIds = {};
  final Set<String> _googlePlaceIds = {};
  String? _defaultListId;
  String _userId = 'mock_user_1';
  int _listIdCounter = 1;
  int _itemIdCounter = 1;

  MockListsApi() {
    // Create default list on initialization
    _createDefaultList();
  }

  void _createDefaultList() {
    final defaultList = UserList(
      id: 'list_default',
      ownerId: _userId,
      name: 'Favorites',
      description: null,
      visibility: ListVisibility.private,
      isCollaborative: false,
      isDefault: true,
      createdAt: DateTime.now().subtract(const Duration(days: 30)),
      updatedAt: DateTime.now(),
      itemCount: 0,
      memberCount: 1,
      followerCount: 0,
      userRole: 'owner',
      isFollowing: null,
    );
    _lists.add(defaultList);
    _listItems['list_default'] = [];
    _defaultListId = 'list_default';
  }

  @override
  Future<UserListsResponse> listMyLists({
    String? q,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? scope,
    String? containsVenueId,
    String? containsEventId,
    String? containsGooglePlaceId,
    int limit = 50,
    int offset = 0,
  }) async {
    await _simulateDelay();

    // Sort by updatedAt descending, but keep default list first
    final sortedLists = List<UserList>.from(_lists);
    sortedLists.sort((a, b) {
      if (a.isDefault) return -1;
      if (b.isDefault) return 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });

    // The `contains_*` filters are passed through to the real API to find
    // which lists already contain a given item. The mock doesn't track
    // per-list membership richly enough to simulate this, so when any
    // filter is set we return an empty set — tests wanting authoritative
    // pre-selection should use real lists.
    if (containsVenueId != null ||
        containsEventId != null ||
        containsGooglePlaceId != null) {
      return const UserListsResponse(items: [], total: 0);
    }

    // Apply pagination
    final paginatedLists = sortedLists.skip(offset).take(limit).toList();

    return UserListsResponse(items: paginatedLists, total: _lists.length);
  }

  @override
  Future<ListsMapPinsResponse> getListsMapPins({
    String? cityId,
    bool? includeCollaborative,
    String? sessionToken,
    String? locale,
    String? scope,
    int limit = 1000,
    int offset = 0,
  }) async {
    await _simulateDelay();
    // Mock returns an empty response — the /lists hub uses the real
    // backend on staging. Tests that need populated data should inject a
    // fake provider override rather than rely on this mock.
    return const ListsMapPinsResponse(items: [], total: 0);
  }

  @override
  Future<ListsCalendarEventsResponse> getListsCalendarEvents({
    String? cityId,
    required DateTime fromDate,
    required DateTime toDate,
    bool? includeCollaborative,
    String? sessionToken,
    String? locale,
    String? scope,
    int limit = 500,
    int offset = 0,
  }) async {
    await _simulateDelay();
    return const ListsCalendarEventsResponse(items: [], total: 0);
  }

  @override
  Future<SavedSearchItemsResponse> searchSavedItems({
    required String q,
    SavedItemType? itemType,
    bool? includeCollaborative,
    String? locale,
    String? scope,
    int limit = 100,
    int offset = 0,
  }) async {
    await _simulateDelay();
    return const SavedSearchItemsResponse(items: [], total: 0);
  }

  @override
  Future<DiscoverListsResponse> discoverLists({
    String? q,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? searchRange,
    String? scope,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    await _simulateDelay();
    final myLists = await listMyLists(limit: 10);
    const empty = UserListsResponse(items: [], total: 0);
    return DiscoverListsResponse(
      yourLists: myLists,
      curated: empty,
      following: empty,
      recommended: empty,
    );
  }

  @override
  Future<UserListsResponse> listCuratedLists({
    String? q,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? searchRange,
    String? scope,
    int limit = 10,
    int offset = 0,
  }) async {
    await _simulateDelay();
    return UserListsResponse(items: [], total: 0);
  }

  @override
  Future<UserListsResponse> listPublicLists({
    String? q,
    String? cityId,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? searchRange,
    String? locationSource,
    String? sort,
    bool? editorPick,
    bool? cityGuide,
    bool? verified,
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    await _simulateDelay();
    return UserListsResponse(items: [], total: 0);
  }

  @override
  Future<UserListsResponse> listPublicListsByHandle({
    required String handle,
    bool? editorPick,
    bool? cityGuide,
    String? cityId,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? searchRange,
    String? locationSource,
    int limit = 50,
    int offset = 0,
  }) async {
    await _simulateDelay();
    return UserListsResponse(items: [], total: 0);
  }

  @override
  Future<UserList> createList(UserListCreate request) async {
    await _simulateDelay();

    final now = DateTime.now();
    final listId = 'list_${_listIdCounter++}';

    final list = UserList(
      id: listId,
      ownerId: _userId,
      name: request.name,
      description: request.description,
      visibility: request.visibility,
      isCollaborative: false,
      isDefault: false,
      createdAt: now,
      updatedAt: now,
      itemCount: 0,
      memberCount: 1,
      followerCount: 0,
      userRole: 'owner',
      isFollowing: null,
    );

    _lists.add(list);
    _listItems[listId] = [];

    return list;
  }

  @override
  Future<UserList> getDefaultList() async {
    await _simulateDelay();

    final defaultList = _lists.firstWhere((l) => l.isDefault);
    return defaultList;
  }

  @override
  Future<UserList> getList(String listId) async {
    await _simulateDelay();

    final list = _lists.firstWhere(
      (l) => l.id == listId,
      orElse: () => throw Exception('List not found'),
    );
    return list;
  }

  @override
  Future<UserList> updateList(String listId, UserListUpdate request) async {
    await _simulateDelay();

    final index = _lists.indexWhere((l) => l.id == listId);
    if (index == -1) {
      throw Exception('List not found');
    }

    final existing = _lists[index];

    // Cannot update default list name
    if (existing.isDefault && request.name != null) {
      throw Exception('Cannot rename default list');
    }

    final updated = existing.copyWith(
      name: request.name ?? existing.name,
      description: request.description ?? existing.description,
      visibility: request.visibility ?? existing.visibility,
      updatedAt: DateTime.now(),
    );

    _lists[index] = updated;
    return updated;
  }

  @override
  Future<UserList> uploadListCover(String listId, String imagePath) async {
    await _simulateDelay();
    // Mock: just return the list unchanged
    return _lists.firstWhere(
      (l) => l.id == listId,
      orElse: () => throw Exception('List not found'),
    );
  }

  @override
  Future<UserList> uploadListCoverShareRender(
    String listId,
    Uint8List pngBytes,
  ) async {
    await _simulateDelay();
    // Mock: pretend the render was stored and stamp a fake URL.
    final index = _lists.indexWhere((l) => l.id == listId);
    if (index == -1) throw Exception('List not found');
    final updated = _lists[index].copyWith(
      coverShareRenderUrl: '/api/v1/image/gcs/mock/$listId/share-cover.png',
    );
    _lists[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteList(String listId) async {
    await _simulateDelay();

    final list = _lists.firstWhere(
      (l) => l.id == listId,
      orElse: () => throw Exception('List not found'),
    );

    if (list.isDefault) {
      throw Exception('Cannot delete default list');
    }

    _lists.removeWhere((l) => l.id == listId);
    _listItems.remove(listId);
  }

  @override
  Future<UserListItemsResponse> listItems(
    String listId, {
    SavedItemType? itemType,
    int limit = 50,
    int offset = 0,
  }) async {
    await _simulateDelay();

    var items = _listItems[listId] ?? [];

    // Filter by type if provided
    if (itemType != null) {
      items = items.where((i) => i.itemType == itemType).toList();
    }

    // Sort by addedAt descending
    items = List.from(items);
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));

    // Apply pagination
    final paginatedItems = items.skip(offset).take(limit).toList();

    return UserListItemsResponse(items: paginatedItems, total: items.length);
  }

  /// Mock stand-in for the BE's `sort` param on the slim item endpoints.
  /// `null` keeps the mock's stored order (newest-saved first), matching the
  /// contract where an omitted `sort` means "the list's own order".
  List<UserListItem> _applyItemSort(
    List<UserListItem> items,
    ZineItemSort? sort,
  ) {
    if (sort == null) return items;
    final sorted = List<UserListItem>.from(items);
    switch (sort) {
      case ZineItemSort.recent:
        sorted.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case ZineItemSort.alphabetical:
        sorted.sort(
          (a, b) => (a.title ?? '').toLowerCase().compareTo(
            (b.title ?? '').toLowerCase(),
          ),
        );
      case ZineItemSort.chronological:
        // Dateless rows (places) fall to the end, as the BE does.
        sorted.sort((a, b) {
          final da = a.eventDate;
          final db = b.eventDate;
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return da.compareTo(db);
        });
    }
    return sorted;
  }

  @override
  Future<UserListItemsSlimOut> listItemsSlim(
    String listId, {
    SavedItemType? itemType,
    int limit = 500,
    int offset = 0,
    ZineItemSort? sort,
  }) async {
    await _simulateDelay();

    var items = _listItems[listId] ?? [];
    if (itemType != null) {
      items = items.where((i) => i.itemType == itemType).toList();
    }
    items = List.from(items);
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    items = _applyItemSort(items, sort);

    final total = items.length;
    final paginatedItems = items.skip(offset).take(limit).toList();

    final slimItems = paginatedItems.map(_toSlim).toList();
    final mapPins = _dedupePinsFromHeavy(items);

    return UserListItemsSlimOut(
      items: slimItems,
      mapPins: mapPins,
      total: total,
    );
  }

  @override
  Future<UserListItemAddResult> addItem(
    String listId,
    UserListItemCreate request,
  ) async {
    await _simulateDelay();

    final now = DateTime.now();
    final itemId = 'item_${_itemIdCounter++}';

    // Build event/venue data for display
    Map<String, dynamic>? event;
    Map<String, dynamic>? venue;

    if (request.itemType == SavedItemType.event) {
      event = {
        'id': request.eventId,
        'title': request.eventData?.title ?? 'Event ${request.eventId}',
        'image_url': request.eventData?.imageUrl,
        'category': request.eventData?.category,
        'start_datetime': request.eventData?.date,
        'date': request.eventData?.date,
        'url': request.eventData?.url,
        'description': request.eventData?.description,
        'venue_name': request.eventData?.location,
        'venue_city': request.eventData?.city,
      };
    } else {
      venue = {
        'id': request.venueId,
        'name': request.placeData?.name ?? 'Place ${request.venueId}',
        'image_url': request.placeData?.imageUrl,
        'city': request.placeData?.city,
        'address': request.placeData?.address,
        'latitude': request.placeData?.latitude,
        'longitude': request.placeData?.longitude,
        'rating': request.placeData?.rating,
        'rating_count': request.placeData?.ratingCount,
        'tags': request.placeData?.types,
      };
    }

    final item = UserListItem(
      id: itemId,
      listId: listId,
      addedById: _userId,
      itemType: request.itemType,
      eventId: request.eventId,
      venueId: request.venueId,
      tip: request.tip,
      addedAt: now,
      updatedAt: now,
      isDeleted: false,
      event: event,
      venue: venue,
      addedBy: {'user_id': _userId, 'user_name': 'You'},
    );

    _listItems.putIfAbsent(listId, () => []);
    _listItems[listId]!.add(item);

    // Update list item count
    _updateListItemCount(listId);

    // Mirrors the real backend (PROD-3295): the authoritative post-write count
    // comes back on the response, and this mock always genuinely inserts.
    // A fresh insert with a present note is `added`; without one, no note
    // either side is `unchanged` (PROD-4553).
    return UserListItemAddResult(
      item: item,
      listItemCount: _listItems[listId]!.length,
      created: true,
      noteAction: noteIsPresent(request.tip)
          ? NoteAction.added
          : NoteAction.unchanged,
    );
  }

  @override
  Future<UserListItemAddResult> addItemToDefaultDestination(
    UserListItemCreate request,
  ) async {
    // Quicksave (PROD-3873): mock resolves a stable Saved Items list id and
    // delegates to [addItem]. The returned item carries that list id, mirroring
    // the real server's behavior.
    return addItem('mock-saved-items', request);
  }

  @override
  Future<UserListItemWriteResult> updateItem(
    String listId,
    String itemId,
    UserListItemUpdate request,
  ) async {
    await _simulateDelay();

    final items = _listItems[listId];
    if (items == null) {
      throw Exception('List not found');
    }

    final index = items.indexWhere((i) => i.id == itemId);
    if (index == -1) {
      throw Exception('Item not found');
    }

    final previous = items[index];
    final noteAction = _deriveNoteAction(previous.tip, request.tip);
    // Keep the echoed item consistent with the transition: an empty/removed
    // note must actually clear the tip. copyWith(tip: null) preserves the old
    // value (see UserListItem.copyWith), so clearing needs the clearTip flag.
    final clearTip = !noteIsPresent(request.tip);
    final updated = previous.copyWith(
      tip: clearTip ? null : request.tip,
      clearTip: clearTip,
      updatedAt: DateTime.now(),
    );

    items[index] = updated;
    return UserListItemWriteResult(item: updated, noteAction: noteAction);
  }

  /// Approximate the backend's authoritative transition (PROD-4552) from the
  /// old/new tip using the shared normalization rule, so mock-backed tests see
  /// realistic `note_action` values.
  NoteAction _deriveNoteAction(String? before, String? after) {
    final beforeNorm = normalizeNote(before);
    final afterNorm = normalizeNote(after);
    if (beforeNorm == afterNorm) return NoteAction.unchanged;
    if (beforeNorm.isEmpty) return NoteAction.added;
    if (afterNorm.isEmpty) return NoteAction.removed;
    return NoteAction.updated;
  }

  @override
  Future<void> removeItem(String listId, String itemId) async {
    await _simulateDelay();

    final items = _listItems[listId];
    if (items == null) {
      throw Exception('List not found');
    }

    items.removeWhere((i) => i.id == itemId);

    // Update list item count
    _updateListItemCount(listId);
  }

  @override
  Future<BulkDeleteItemsResponse> bulkDeleteItems(
    String listId,
    List<String> itemIds,
  ) async {
    await _simulateDelay();

    final items = _listItems[listId];
    if (items == null) {
      return BulkDeleteItemsResponse(
        deleted: const [],
        skipped: itemIds
            .map((id) => BulkDeleteSkippedItem(itemId: id, reason: 'not_found'))
            .toList(),
      );
    }

    final present = {for (final i in items) i.id};
    final deleted = <String>[];
    final skipped = <BulkDeleteSkippedItem>[];
    for (final id in itemIds) {
      if (present.contains(id)) {
        deleted.add(id);
      } else {
        skipped.add(BulkDeleteSkippedItem(itemId: id, reason: 'not_found'));
      }
    }
    items.removeWhere((i) => deleted.contains(i.id));
    _updateListItemCount(listId);

    return BulkDeleteItemsResponse(deleted: deleted, skipped: skipped);
  }

  @override
  Future<void> reorderItems(String listId, List<String> itemIds) async {
    await _simulateDelay();
  }

  @override
  bool isInList(
    String listId, {
    String? eventId,
    String? venueId,
    String? googlePlaceId,
  }) {
    final items = _listItems[listId];
    if (items == null) return false;

    return items.any((i) {
      if (eventId != null) return i.eventId == eventId;
      if (venueId != null) return i.venueId == venueId;
      if (googlePlaceId != null) return i.googlePlaceId == googlePlaceId;
      return false;
    });
  }

  @override
  bool isInDefaultList({String? eventId, String? venueId}) {
    if (_defaultListId == null) return false;
    return isInList(_defaultListId!, eventId: eventId, venueId: venueId);
  }

  @override
  bool isInAnyOwnedList({String? eventId, String? venueId}) {
    // Check all owned lists
    for (final list in _lists) {
      if (isInList(list.id, eventId: eventId, venueId: venueId)) {
        return true;
      }
    }
    return false;
  }

  @override
  String? getItemId(
    String listId, {
    String? eventId,
    String? venueId,
    String? googlePlaceId,
  }) {
    final items = _listItems[listId];
    if (items == null) return null;

    for (final item in items) {
      if (eventId != null && item.eventId == eventId) return item.id;
      if (venueId != null && item.venueId == venueId) return item.id;
      if (googlePlaceId != null && item.googlePlaceId == googlePlaceId)
        return item.id;
    }
    return null;
  }

  @override
  Future<void> loadAllOwnedItems() async {
    // In mock, items are already in memory, nothing to load
    await _simulateDelay(milliseconds: 100);
  }

  @override
  Set<String> get allOwnedEventIds {
    final eventIds = <String>{};
    for (final items in _listItems.values) {
      for (final item in items) {
        if (item.eventId != null) {
          eventIds.add(item.eventId!);
        }
      }
    }
    return eventIds;
  }

  @override
  Set<String> get allOwnedVenueIds {
    final venueIds = <String>{};
    for (final items in _listItems.values) {
      for (final item in items) {
        if (item.venueId != null) {
          venueIds.add(item.venueId!);
        }
      }
    }
    return venueIds;
  }

  @override
  Set<String> get allOwnedGooglePlaceIds => Set.unmodifiable(_googlePlaceIds);

  @override
  void addGooglePlaceIdToCache(String googlePlaceId) {
    _googlePlaceIds.add(googlePlaceId);
  }

  @override
  void clearCache() {
    // Reset to initial state
    _lists.clear();
    _listItems.clear();
    _followedListIds.clear();
    _googlePlaceIds.clear();
    _defaultListId = null;
    _listIdCounter = 1;
    _itemIdCounter = 1;
    _createDefaultList();
  }

  // ============================================================================
  // Follow Methods
  // ============================================================================

  @override
  Future<void> followList(String listId) async {
    await _simulateDelay();
    _followedListIds.add(listId);
  }

  @override
  Future<void> unfollowList(String listId) async {
    await _simulateDelay();
    _followedListIds.remove(listId);
  }

  @override
  Future<FollowUserListResponse> getListFollowers(
    String listId, {
    int limit = 50,
    int offset = 0,
  }) async {
    await _simulateDelay();
    return const FollowUserListResponse(items: [], total: 0);
  }

  @override
  Future<UserListsResponse> listFollowedLists({
    String? q,
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? scope,
    int limit = 50,
    int offset = 0,
  }) async {
    await _simulateDelay();
    return const UserListsResponse(items: [], total: 0);
  }

  // ============================================================================
  // Suggested Lists Methods
  // ============================================================================

  @override
  Future<List<SuggestedList>> getSuggestedLists({
    String? q,
    int limit = 10,
    int offset = 0,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    await _simulateDelay();
    // Return empty list for mock - would need external public lists for suggestions
    return [];
  }

  @override
  Future<List<SuggestedList>> getGuestSuggestedLists({
    int limit = 10,
    double? latitude,
    double? longitude,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    await _simulateDelay();
    // Return empty list for mock - would need external public lists for suggestions
    return [];
  }

  // ============================================================================
  // Import Methods
  // ============================================================================

  @override
  Future<ImportJobCreatedResponse> importGoogleMapsList(
    String url, {
    String? listName,
  }) async {
    await _simulateDelay();
    return const ImportJobCreatedResponse(
      jobId: 'mock-job-id',
      status: 'queued',
      message: 'Import job queued.',
    );
  }

  @override
  Future<ImportJobStatusResponse> getImportJobStatus(String jobId) async {
    await _simulateDelay();
    return const ImportJobStatusResponse(
      jobId: 'mock-job-id',
      status: ImportJobStatus.completed,
      result: ImportJobResult(
        success: true,
        listId: 'mock-list-id',
        listName: 'Mock Imported List',
        total: 10,
        imported: 10,
        duplicatesSkipped: 0,
        failed: 0,
      ),
    );
  }

  // ============================================================================
  // Public List Methods (no authentication required)
  // ============================================================================

  @override
  Future<PublicList> getPublicList(
    String listId, {
    String? ref,
    String? visitorId,
  }) async {
    await _simulateDelay();

    final list = _lists.firstWhere(
      (l) => l.id == listId && l.visibility == ListVisibility.public,
      orElse: () => throw Exception('List not found'),
    );

    return PublicList(
      id: list.id,
      name: list.name,
      description: list.description,
      visibility: list.visibility,
      owner: PublicListOwner(
        id: list.ownerId,
        fullName: 'Mock User',
        handle: 'mockuser',
      ),
      itemCount: list.itemCount,
      followerCount: list.followerCount,
      previewImages: null,
      createdAt: list.createdAt,
      updatedAt: list.updatedAt,
    );
  }

  @override
  Future<PublicListItemsResponse> listPublicItems(
    String listId, {
    SavedItemType? itemType,
    int limit = 50,
    int offset = 0,
    String? ref,
    String? visitorId,
  }) async {
    await _simulateDelay();

    // Check if list is public (throws if not found or not public)
    _lists.firstWhere(
      (l) => l.id == listId && l.visibility == ListVisibility.public,
      orElse: () => throw Exception('List not found'),
    );

    var items = _listItems[listId] ?? [];

    // Filter by type if provided
    if (itemType != null) {
      items = items.where((i) => i.itemType == itemType).toList();
    }

    // Sort by addedAt descending
    items = List.from(items);
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));

    // Apply pagination
    final paginatedItems = items.skip(offset).take(limit).toList();

    return PublicListItemsResponse(items: paginatedItems, total: items.length);
  }

  @override
  Future<UserListItemsSlimOut> listPublicItemsSlim(
    String listId, {
    SavedItemType? itemType,
    int limit = 500,
    int offset = 0,
    String? ref,
    String? visitorId,
    ZineItemSort? sort,
  }) async {
    await _simulateDelay();

    _lists.firstWhere(
      (l) => l.id == listId && l.visibility == ListVisibility.public,
      orElse: () => throw Exception('List not found'),
    );

    var items = _listItems[listId] ?? [];
    if (itemType != null) {
      items = items.where((i) => i.itemType == itemType).toList();
    }
    items = List.from(items);
    items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    items = _applyItemSort(items, sort);

    final total = items.length;
    final paginatedItems = items.skip(offset).take(limit).toList();

    final slimItems = paginatedItems.map(_toSlim).toList();
    final mapPins = _dedupePinsFromHeavy(items);

    return UserListItemsSlimOut(
      items: slimItems,
      mapPins: mapPins,
      total: total,
    );
  }

  /// Heavy → slim conversion for the mock. Mirrors the BE projection so
  /// in-memory mock data flows through the same code paths consumers
  /// will hit in staging.
  UserListItemSlim _toSlim(UserListItem item) {
    return UserListItemSlim(
      id: item.id,
      listId: item.listId,
      itemType: item.itemType,
      eventId: item.eventId,
      venueId: item.venueId,
      sortOrder: item.sortOrder,
      tip: item.tip,
      addedAt: item.addedAt,
      isCover: item.isCover,
      title: item.title ?? '',
      descriptionShort: item.descriptionShort,
      imageUrl: item.imageUrl,
      category: item.category,
      // PROD-4115 — mirror the BE slim projection's new display fields.
      subcategory: item.subcategory,
      priceLabel: item.priceLabel,
      latitude: item.latitude,
      longitude: item.longitude,
      address: item.address,
      city: item.city,
      neighborhood: item.neighbourhood,
      venueName: item.venueName,
      nextOccurrenceAt: item.eventDate,
      futureOccurrencesCount: item.itemType == SavedItemType.event ? 0 : null,
      occurrenceDates: item.itemType == SavedItemType.event
          ? item.occurrenceDates
          : null,
      // Mirror the BE slim projection's note-author expansion so the mock
      // note callout renders the author PersonDot like staging.
      addedBy: item.addedBy,
    );
  }

  /// Heavy → slim pin dedupe. Matches the BE semantics: one pin per
  /// unique venue across the full filtered set, with `item_id` = the
  /// earliest-added item pointing at the venue.
  List<SlimMapPin> _dedupePinsFromHeavy(List<UserListItem> items) {
    final earliestByKey = <String, UserListItem>{};
    for (final i in items) {
      if (i.latitude == null || i.longitude == null) continue;
      final key = i.venueId ?? '${i.latitude},${i.longitude}';
      final existing = earliestByKey[key];
      if (existing == null || i.addedAt.isBefore(existing.addedAt)) {
        earliestByKey[key] = i;
      }
    }
    return earliestByKey.values
        .map(
          (i) => SlimMapPin(
            itemId: i.id,
            itemType: i.itemType,
            venueId: i.venueId,
            latitude: i.latitude!,
            longitude: i.longitude!,
            name: i.title ?? '',
            imageUrl: i.imageUrl,
            category: i.category,
          ),
        )
        .toList();
  }

  void _updateListItemCount(String listId) {
    final index = _lists.indexWhere((l) => l.id == listId);
    if (index != -1) {
      final count = _listItems[listId]?.length ?? 0;
      _lists[index] = _lists[index].copyWith(
        itemCount: count,
        updatedAt: DateTime.now(),
      );
    }
  }

  Future<void> _simulateDelay({int milliseconds = 300}) async {
    await Future.delayed(Duration(milliseconds: milliseconds));
  }
}
