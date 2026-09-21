import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../../models/social/follow_user_summary.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Lists API
class ListsApi implements IListsApi {
  final ApiClient _apiClient;

  // Local cache for quick lookups
  // Map of listId -> Set of eventIds/venueIds/googlePlaceIds in that list
  final Map<String, Set<String>> _listEventIds = {};
  final Map<String, Set<String>> _listVenueIds = {};
  final Map<String, Set<String>> _listGooglePlaceIds = {};

  // Cache for item IDs: Map of listId -> Map of (eventId|venueId|googlePlaceId) -> itemId
  // This enables removal operations which require the itemId
  final Map<String, Map<String, String>> _listItemIds = {};

  // Default list ID (cached after first fetch)
  String? _defaultListId;

  // Default list item cache (for heart icon quick check)
  final Set<String> _defaultListEventIds = {};
  final Set<String> _defaultListVenueIds = {};

  // Global cache for all owned items across all lists
  final Set<String> _allOwnedEventIds = {};
  final Set<String> _allOwnedVenueIds = {};
  final Set<String> _allOwnedGooglePlaceIds = {};

  ListsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

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
    final queryParams = <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (q != null && q.isNotEmpty) 'q': q,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (radiusKm != null) 'radius_km': radiusKm,
      if (scope != null) 'scope': scope,
      if (containsVenueId != null) 'contains_venue_id': containsVenueId,
      if (containsEventId != null) 'contains_event_id': containsEventId,
      if (containsGooglePlaceId != null)
        'contains_google_place_id': containsGooglePlaceId,
    };

    final response = await _dio.get(
      ApiConstants.myLists,
      queryParameters: queryParams,
    );

    return UserListsResponse.fromJson(response.data as Map<String, dynamic>);
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
    final queryParams = <String, dynamic>{
      if (cityId != null && cityId.isNotEmpty) 'city_id': cityId,
      'limit': limit,
      'offset': offset,
      if (includeCollaborative != null)
        'include_collaborative': includeCollaborative,
      if (sessionToken != null && sessionToken.isNotEmpty)
        'session_token': sessionToken,
      if (locale != null && locale.isNotEmpty) 'locale': locale,
      if (scope != null) 'scope': scope,
    };

    final response = await _dio.get(
      ApiConstants.myListsMapPins,
      queryParameters: queryParams,
    );

    return ListsMapPinsResponse.fromJson(response.data as Map<String, dynamic>);
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
    // ISO date (YYYY-MM-DD) — the endpoint takes calendar dates, not
    // timestamps. `from_date` is inclusive, `to_date` exclusive.
    String fmtDate(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    final queryParams = <String, dynamic>{
      if (cityId != null && cityId.isNotEmpty) 'city_id': cityId,
      'from_date': fmtDate(fromDate),
      'to_date': fmtDate(toDate),
      'limit': limit,
      'offset': offset,
      if (includeCollaborative != null)
        'include_collaborative': includeCollaborative,
      if (sessionToken != null && sessionToken.isNotEmpty)
        'session_token': sessionToken,
      if (locale != null && locale.isNotEmpty) 'locale': locale,
      if (scope != null) 'scope': scope,
    };

    final response = await _dio.get(
      ApiConstants.myListsCalendarEvents,
      queryParameters: queryParams,
    );

    return ListsCalendarEventsResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
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
    final queryParams = <String, dynamic>{
      'q': q,
      'limit': limit,
      'offset': offset,
      if (itemType != null) 'item_type': itemType.toJson(),
      if (includeCollaborative != null)
        'include_collaborative': includeCollaborative,
      if (locale != null && locale.isNotEmpty) 'locale': locale,
      if (scope != null) 'scope': scope,
    };

    final response = await _dio.get(
      ApiConstants.myListsSavedItemsSearch,
      queryParameters: queryParams,
    );

    return SavedSearchItemsResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
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
    final queryParams = <String, dynamic>{
      if (q != null && q.isNotEmpty) 'q': q,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (radiusKm != null) 'radius_km': radiusKm,
      if (searchRange != null) 'search_range': searchRange,
      if (scope != null) 'scope': scope,
      if (locationMode != null) 'location_mode': locationMode,
      if (adminBoundaryId != null) 'admin_boundary_id': adminBoundaryId,
    };

    final response = await _dio.get(
      ApiConstants.discoverLists,
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );
    return DiscoverListsResponse.fromJson(
      response.data as Map<String, dynamic>,
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
    final queryParams = <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (q != null && q.isNotEmpty) 'q': q,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (radiusKm != null) 'radius_km': radiusKm,
      if (searchRange != null) 'search_range': searchRange,
      if (scope != null) 'scope': scope,
    };

    final response = await _dio.get(
      ApiConstants.curatedLists,
      queryParameters: queryParams,
    );
    return UserListsResponse.fromJson(response.data as Map<String, dynamic>);
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
    final queryParams = <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (q != null && q.isNotEmpty) 'q': q,
      if (cityId != null) 'city_id': cityId,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (radiusKm != null) 'radius_km': radiusKm,
      if (searchRange != null) 'search_range': searchRange,
      if (locationSource != null) 'location_source': locationSource,
      if (sort != null) 'sort': sort,
      if (editorPick != null) 'editor_pick': editorPick,
      if (cityGuide != null) 'city_guide': cityGuide,
      if (verified != null) 'verified': verified,
    };

    final response = await _dio.get(
      ApiConstants.publicLists,
      queryParameters: queryParams,
      cancelToken: cancelToken,
    );

    return UserListsResponse.fromJson(response.data as Map<String, dynamic>);
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
    final response = await _dio.get(
      ApiConstants.publicListsByHandle(handle),
      queryParameters: {
        'limit': limit,
        'offset': offset,
        if (editorPick != null) 'editor_pick': editorPick,
        if (cityGuide != null) 'city_guide': cityGuide,
        if (cityId != null) 'city_id': cityId,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (radiusKm != null) 'radius_km': radiusKm,
        if (searchRange != null) 'search_range': searchRange,
        if (locationSource != null) 'location_source': locationSource,
      },
    );

    return UserListsResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<UserList> createList(UserListCreate request) async {
    final response = await _dio.post(
      ApiConstants.myLists,
      data: request.toJson(),
    );

    return UserList.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<UserList> getDefaultList() async {
    final response = await _dio.get(ApiConstants.myDefaultList);

    final list = UserList.fromJson(response.data as Map<String, dynamic>);

    // Cache default list ID
    _defaultListId = list.id;

    return list;
  }

  @override
  Future<UserList> getList(String listId) async {
    final response = await _dio.get(ApiConstants.list(listId));

    return UserList.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<UserList> updateList(String listId, UserListUpdate request) async {
    final response = await _dio.patch(
      ApiConstants.list(listId),
      data: request.toJson(),
    );

    return UserList.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<UserList> uploadListCover(String listId, String imagePath) async {
    MultipartFile imageFile;

    if (kIsWeb && imagePath.startsWith('blob:')) {
      final bytes = await _fetchBlobData(imagePath);
      // Detect mime type from magic bytes
      String mimeType = 'image/jpeg';
      String extension = 'jpg';
      if (bytes.length >= 8) {
        if (bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47) {
          mimeType = 'image/png';
          extension = 'png';
        } else if (bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46 &&
            bytes.length >= 12 &&
            bytes[8] == 0x57 &&
            bytes[9] == 0x45 &&
            bytes[10] == 0x42 &&
            bytes[11] == 0x50) {
          mimeType = 'image/webp';
          extension = 'webp';
        }
      }
      imageFile = MultipartFile.fromBytes(
        bytes,
        filename: 'cover.$extension',
        contentType: DioMediaType.parse(mimeType),
      );
    } else {
      imageFile = await MultipartFile.fromFile(imagePath);
    }

    final formData = FormData.fromMap({'file': imageFile});

    final response = await _dio.post(
      ApiConstants.listCoverUpload(listId),
      data: formData,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: ApiConstants.uploadTimeout,
        receiveTimeout: ApiConstants.uploadTimeout,
      ),
    );

    return UserList.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<UserList> uploadListCoverShareRender(
    String listId,
    Uint8List pngBytes,
  ) async {
    // PROD-3217 — always a PNG Uint8List captured offscreen from
    // ListZineCover; no blob:/file path variance (unlike uploadListCover).
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        pngBytes,
        filename: 'cover-share-render.png',
        contentType: DioMediaType.parse('image/png'),
      ),
    });

    final response = await _dio.post(
      ApiConstants.listCoverShareRender(listId),
      data: formData,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: ApiConstants.uploadTimeout,
        receiveTimeout: ApiConstants.uploadTimeout,
      ),
    );

    return UserList.fromJson(response.data as Map<String, dynamic>);
  }

  /// Fetch blob data from a blob URL (web only)
  Future<Uint8List> _fetchBlobData(String blobUrl) async {
    final response = await http.get(Uri.parse(blobUrl));
    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
    throw Exception('Failed to fetch blob data: ${response.statusCode}');
  }

  @override
  Future<void> deleteList(String listId) async {
    await _dio.delete(ApiConstants.list(listId));

    // Clear cache for this list
    _listEventIds.remove(listId);
    _listVenueIds.remove(listId);
    _listGooglePlaceIds.remove(listId);
    _listItemIds.remove(listId);
  }

  @override
  Future<UserListItemsResponse> listItems(
    String listId, {
    SavedItemType? itemType,
    int limit = 50,
    int offset = 0,
  }) async {
    final queryParams = <String, dynamic>{'limit': limit, 'offset': offset};

    if (itemType != null) {
      queryParams['item_type'] = itemType.toJson();
    }

    final response = await _dio.get(
      ApiConstants.listItems(listId),
      queryParameters: queryParams,
    );

    final result = UserListItemsResponse.fromJson(
      response.data as Map<String, dynamic>,
    );

    // Update local cache.
    // On the first page (offset == 0), clear and rebuild the cache.
    // On subsequent pages, append — so paginated callers accumulate
    // the full item set instead of wiping earlier pages.
    if (offset == 0) {
      _updateListCache(listId, result.items);
    } else {
      for (final item in result.items) {
        _addToListCache(listId, item);
      }
    }

    // If this is the default list, update default list cache
    if (listId == _defaultListId) {
      _updateDefaultListCache(result.items);
    }

    return result;
  }

  @override
  Future<UserListItemsSlimOut> listItemsSlim(
    String listId, {
    SavedItemType? itemType,
    int limit = 500,
    int offset = 0,
    ZineItemSort? sort,
  }) async {
    final queryParams = <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (itemType != null) 'item_type': itemType.toJson(),
      // Omitted on purpose when null — that is how the BE is asked for the
      // list's own stored order (including a `custom` arrangement).
      if (sort != null) 'sort': sort.wire,
    };

    final response = await _dio.get(
      ApiConstants.listItemsSlim(listId),
      queryParameters: queryParams,
    );

    return UserListItemsSlimOut.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<UserListItemAddResult> addItem(
    String listId,
    UserListItemCreate request,
  ) async {
    // Detect if this is Mode 2 (external data) - needs longer timeout
    // Mode 2 requires backend to create entity before adding to list
    final isExternalSave =
        request.eventData != null || request.placeData != null;
    final stopwatch = Stopwatch()..start();

    debugPrint(
      '[ListsApi.addItem] listId=$listId, mode=${isExternalSave ? "external" : "by-id"}',
    );

    try {
      final response = await _dio.post(
        ApiConstants.listItems(listId),
        data: request.toJson(),
        options: isExternalSave
            ? Options(
                sendTimeout: ApiConstants.listItemTimeout,
                receiveTimeout: ApiConstants.listItemTimeout,
              )
            : null,
      );

      debugPrint(
        '[ListsApi.addItem] SUCCESS in ${stopwatch.elapsedMilliseconds}ms',
      );

      final result = UserListItemAddResult.fromJson(
        response.data as Map<String, dynamic>,
      );

      _warmCachesAfterAdd(listId, result.item, request);

      return result;
    } catch (e) {
      debugPrint(
        '[ListsApi.addItem] FAILED in ${stopwatch.elapsedMilliseconds}ms: ${e.runtimeType}',
      );
      if (e is DioException) {
        debugPrint('[ListsApi.addItem] Status: ${e.response?.statusCode}');
        debugPrint('[ListsApi.addItem] Response: ${e.response?.data}');
        debugPrint('[ListsApi.addItem] Request data: ${request.toJson()}');
      }
      rethrow;
    }
  }

  @override
  Future<UserListItemAddResult> addItemToDefaultDestination(
    UserListItemCreate request,
  ) async {
    // Quicksave (PROD-3873): no list picker. The server resolves the caller's
    // typed save list and returns its id on the item. Same body/timeout rules
    // as [addItem]; the only difference is the missing path segment.
    final isExternalSave =
        request.eventData != null || request.placeData != null;
    final stopwatch = Stopwatch()..start();

    debugPrint(
      '[ListsApi.addItemToDefaultDestination] mode=${isExternalSave ? "external" : "by-id"}',
    );

    try {
      final response = await _dio.post(
        ApiConstants.defaultListItems,
        data: request.toJson(),
        options: isExternalSave
            ? Options(
                sendTimeout: ApiConstants.listItemTimeout,
                receiveTimeout: ApiConstants.listItemTimeout,
              )
            : null,
      );

      final result = UserListItemAddResult.fromJson(
        response.data as Map<String, dynamic>,
      );

      debugPrint(
        '[ListsApi.addItemToDefaultDestination] SUCCESS in '
        '${stopwatch.elapsedMilliseconds}ms → list=${result.item.listId}',
      );

      // The resolved list id lives on the returned item — warm the same caches
      // [addItem] does, keyed on the server's choice.
      _warmCachesAfterAdd(result.item.listId, result.item, request);
      return result;
    } catch (e) {
      debugPrint(
        '[ListsApi.addItemToDefaultDestination] FAILED in '
        '${stopwatch.elapsedMilliseconds}ms: ${e.runtimeType}',
      );
      if (e is DioException) {
        debugPrint(
          '[ListsApi.addItemToDefaultDestination] Status: ${e.response?.statusCode}',
        );
      }
      rethrow;
    }
  }

  /// Warm the per-list, default-list and global saved-id caches after a write.
  /// Shared by [addItem] and [addItemToDefaultDestination] so both save paths
  /// keep the "is it saved?" caches consistent.
  void _warmCachesAfterAdd(
    String listId,
    UserListItem item,
    UserListItemCreate request,
  ) {
    _addToListCache(listId, item);

    if (listId == _defaultListId) {
      if (item.eventId != null) {
        _defaultListEventIds.add(item.eventId!);
      }
      if (item.venueId != null) {
        _defaultListVenueIds.add(item.venueId!);
      }
    }

    if (item.eventId != null) {
      _allOwnedEventIds.add(item.eventId!);
    }
    if (item.venueId != null) {
      _allOwnedVenueIds.add(item.venueId!);
    }
    if (request.placeData?.googlePlaceId != null) {
      _allOwnedGooglePlaceIds.add(request.placeData!.googlePlaceId!);
    }
    if (item.googlePlaceId != null) {
      _allOwnedGooglePlaceIds.add(item.googlePlaceId!);
    }
  }

  @override
  Future<UserListItemWriteResult> updateItem(
    String listId,
    String itemId,
    UserListItemUpdate request,
  ) async {
    final response = await _dio.patch(
      ApiConstants.listItem(listId, itemId),
      data: request.toJson(),
    );

    return UserListItemWriteResult.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<void> removeItem(String listId, String itemId) async {
    await _dio.delete(ApiConstants.listItem(listId, itemId));

    // Incremental cache removal — fast, no extra API calls.
    // Remove the item from the per-list caches.
    _removeFromListCache(listId, itemId);
  }

  @override
  Future<BulkDeleteItemsResponse> bulkDeleteItems(
    String listId,
    List<String> itemIds,
  ) async {
    final response = await _dio.post(
      ApiConstants.listItemsBulkDelete(listId),
      data: {'item_ids': itemIds},
    );
    final parsed = BulkDeleteItemsResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
    for (final id in parsed.deleted) {
      _removeFromListCache(listId, id);
    }
    return parsed;
  }

  /// Remove a single item from per-list caches by its itemId.
  void _removeFromListCache(String listId, String itemId) {
    final itemIdMap = _listItemIds[listId];
    if (itemIdMap == null) return;

    // Find and remove the content key(s) that map to this itemId
    final keysToRemove = <String>[];
    for (final entry in itemIdMap.entries) {
      if (entry.value == itemId) {
        keysToRemove.add(entry.key);
      }
    }

    for (final key in keysToRemove) {
      itemIdMap.remove(key);
      _listEventIds[listId]?.remove(key);
      _listVenueIds[listId]?.remove(key);
      _listGooglePlaceIds[listId]?.remove(key);
    }
  }

  @override
  Future<void> reorderItems(String listId, List<String> itemIds) async {
    await _dio.put(
      ApiConstants.listItemsReorder(listId),
      data: {'item_ids': itemIds},
    );
  }

  @override
  bool isInList(
    String listId, {
    String? eventId,
    String? venueId,
    String? googlePlaceId,
  }) {
    if (eventId != null) {
      return _listEventIds[listId]?.contains(eventId) ?? false;
    }
    if (venueId != null) {
      return _listVenueIds[listId]?.contains(venueId) ?? false;
    }
    // Check googlePlaceId for external places
    if (googlePlaceId != null) {
      return _listGooglePlaceIds[listId]?.contains(googlePlaceId) ?? false;
    }
    return false;
  }

  @override
  bool isInDefaultList({String? eventId, String? venueId}) {
    if (eventId != null) {
      return _defaultListEventIds.contains(eventId);
    }
    if (venueId != null) {
      return _defaultListVenueIds.contains(venueId);
    }
    return false;
  }

  /// Update local cache for a specific list
  void _updateListCache(String listId, List<UserListItem> items) {
    // Clear existing cache for this list
    _listEventIds[listId] = {};
    _listVenueIds[listId] = {};
    _listGooglePlaceIds[listId] = {};
    _listItemIds[listId] = {};

    for (final item in items) {
      _addToListCache(listId, item);
    }
  }

  /// Add a single item to list cache
  void _addToListCache(String listId, UserListItem item) {
    // Initialize item ID cache for this list if needed
    _listItemIds.putIfAbsent(listId, () => {});

    if (item.eventId != null) {
      _listEventIds.putIfAbsent(listId, () => {});
      _listEventIds[listId]!.add(item.eventId!);
      // Cache eventId -> itemId mapping
      _listItemIds[listId]![item.eventId!] = item.id;
    }
    if (item.venueId != null) {
      _listVenueIds.putIfAbsent(listId, () => {});
      _listVenueIds[listId]!.add(item.venueId!);
      // Cache venueId -> itemId mapping
      _listItemIds[listId]![item.venueId!] = item.id;
    }
    // Cache googlePlaceId for external places
    if (item.googlePlaceId != null) {
      _listGooglePlaceIds.putIfAbsent(listId, () => {});
      _listGooglePlaceIds[listId]!.add(item.googlePlaceId!);
      // Cache googlePlaceId -> itemId mapping
      _listItemIds[listId]![item.googlePlaceId!] = item.id;
    }
  }

  /// Update default list cache from items
  void _updateDefaultListCache(List<UserListItem> items) {
    _defaultListEventIds.clear();
    _defaultListVenueIds.clear();

    for (final item in items) {
      if (item.eventId != null) {
        _defaultListEventIds.add(item.eventId!);
      }
      if (item.venueId != null) {
        _defaultListVenueIds.add(item.venueId!);
      }
    }
  }

  @override
  bool isInAnyOwnedList({String? eventId, String? venueId}) {
    if (eventId != null) {
      return _allOwnedEventIds.contains(eventId);
    }
    if (venueId != null) {
      return _allOwnedVenueIds.contains(venueId);
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
    final itemIdMap = _listItemIds[listId];
    if (itemIdMap == null) return null;

    if (eventId != null && itemIdMap.containsKey(eventId)) {
      return itemIdMap[eventId];
    }
    if (venueId != null && itemIdMap.containsKey(venueId)) {
      return itemIdMap[venueId];
    }
    if (googlePlaceId != null && itemIdMap.containsKey(googlePlaceId)) {
      return itemIdMap[googlePlaceId];
    }
    return null;
  }

  @override
  Set<String> get allOwnedEventIds => Set.unmodifiable(_allOwnedEventIds);

  @override
  Set<String> get allOwnedVenueIds => Set.unmodifiable(_allOwnedVenueIds);

  @override
  Set<String> get allOwnedGooglePlaceIds =>
      Set.unmodifiable(_allOwnedGooglePlaceIds);

  @override
  void addGooglePlaceIdToCache(String googlePlaceId) {
    _allOwnedGooglePlaceIds.add(googlePlaceId);
  }

  @override
  Future<void> loadAllOwnedItems() async {
    // Rebuild the global saved-state cache from the backend's bulk
    // saved-entity-ids endpoint (PROD-2844 / PROD-2845). ONE request replaces
    // the old per-list `GET /lists/{id}/items` fan-out (one call per owned
    // list, plus pagination). The three arrays are deduplicated server-side
    // and map 1:1 onto the id sets read by `isItemSavedProvider`.
    //
    // `include_collaborative=true` preserves prior behavior: the old code
    // fetched items from every list `listMyLists` returned, and that endpoint
    // defaults to including collaborative lists — so collaborated-list saves
    // stay "filled" after this migration.
    //
    // Coverage/truncation: the endpoint returns every item in every list
    // unpaginated, so the PROD-2138 "first N items per list" truncation bug
    // (which forced the fan-out + `maxItemsPerList` cap) can no longer recur.
    _allOwnedEventIds.clear();
    _allOwnedVenueIds.clear();
    _allOwnedGooglePlaceIds.clear();

    try {
      final response = await _dio.get(
        ApiConstants.savedEntityIds,
        queryParameters: const {'include_collaborative': true},
      );
      final result = SavedEntityIdsOut.fromJson(
        response.data as Map<String, dynamic>,
      );
      _allOwnedEventIds.addAll(result.eventIds);
      _allOwnedVenueIds.addAll(result.venueIds);
      _allOwnedGooglePlaceIds.addAll(result.googlePlaceIds);
    } catch (e, st) {
      // Best-effort cache warm — a failure here just leaves bookmark icons
      // outline until the next trigger (create/auth-flip/pull-to-refresh).
      // Surface it so the next person debugging a "bookmark not lit" issue
      // sees the cause immediately.
      debugPrint(
        '[loadAllOwnedItems] Failed to load saved entity ids: $e\n$st',
      );
    }
  }

  @override
  void clearCache() {
    _listEventIds.clear();
    _listVenueIds.clear();
    _listGooglePlaceIds.clear();
    _listItemIds.clear();
    _defaultListId = null;
    _defaultListEventIds.clear();
    _defaultListVenueIds.clear();
    _allOwnedEventIds.clear();
    _allOwnedVenueIds.clear();
    _allOwnedGooglePlaceIds.clear();
  }

  // ============================================================================
  // Import Methods
  // ============================================================================

  @override
  Future<ImportJobCreatedResponse> importGoogleMapsList(
    String url, {
    String? listName,
  }) async {
    final data = <String, dynamic>{'url': url};
    if (listName != null && listName.isNotEmpty) {
      data['list_name'] = listName;
    }

    final response = await _dio.post(
      ApiConstants.importGoogleMapsAsync,
      data: data,
    );

    return ImportJobCreatedResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  @override
  Future<ImportJobStatusResponse> getImportJobStatus(String jobId) async {
    final response = await _dio.get(ApiConstants.importJobStatus(jobId));

    return ImportJobStatusResponse.fromJson(
      response.data as Map<String, dynamic>,
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
    final queryParameters = <String, dynamic>{};
    if (ref != null) queryParameters['ref'] = ref;
    if (visitorId != null) queryParameters['visitor_id'] = visitorId;

    final response = await _dio.get(
      ApiConstants.publicList(listId),
      queryParameters: queryParameters.isNotEmpty ? queryParameters : null,
    );

    return PublicList.fromJson(response.data as Map<String, dynamic>);
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
    final queryParams = <String, dynamic>{'limit': limit, 'offset': offset};

    if (itemType != null) {
      queryParams['item_type'] = itemType.toJson();
    }
    if (ref != null) queryParams['ref'] = ref;
    if (visitorId != null) queryParams['visitor_id'] = visitorId;

    final response = await _dio.get(
      ApiConstants.publicListItems(listId),
      queryParameters: queryParams,
    );

    return PublicListItemsResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
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
    final queryParams = <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (itemType != null) 'item_type': itemType.toJson(),
      if (ref != null) 'ref': ref,
      if (visitorId != null) 'visitor_id': visitorId,
      // See [listItemsSlim] — null means "keep the list's own order".
      if (sort != null) 'sort': sort.wire,
    };

    final response = await _dio.get(
      ApiConstants.publicListItemsSlim(listId),
      queryParameters: queryParams,
    );

    return UserListItemsSlimOut.fromJson(response.data as Map<String, dynamic>);
  }

  // ============================================================================
  // Follow Methods
  // ============================================================================

  @override
  Future<void> followList(String listId) async {
    await _dio.post(ApiConstants.listFollow(listId));
  }

  @override
  Future<void> unfollowList(String listId) async {
    await _dio.delete(ApiConstants.listFollow(listId));
  }

  @override
  Future<FollowUserListResponse> getListFollowers(
    String listId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.listFollowers(listId),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return FollowUserListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );
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
    final queryParams = <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (q != null && q.isNotEmpty) 'q': q,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (radiusKm != null) 'radius_km': radiusKm,
      if (scope != null) 'scope': scope,
    };

    final response = await _dio.get(
      ApiConstants.myFollowedLists,
      queryParameters: queryParams,
    );

    final data = response.data as Map<String, dynamic>;
    final rawItems = data['items'] as List<dynamic>? ?? [];
    final items = rawItems.map((item) {
      final followEntry = item as Map<String, dynamic>;
      final listData = followEntry['list'] as Map<String, dynamic>;
      return UserList.fromJson(listData);
    }).toList();
    // Fall back to items.length if backend hasn't shipped `total` yet — keeps
    // Ver mais from looping on the old heuristic.
    final total = data['total'] as int? ?? items.length;
    return UserListsResponse(items: items, total: total);
  }

  // ============================================================================
  // Suggested Lists Methods
  // ============================================================================

  @override
  Future<List<SuggestedList>> getSuggestedLists({
    String? q,
    int limit = 40,
    int offset = 0,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    final queryParams = <String, dynamic>{
      'limit': limit,
      'offset': offset,
      if (q != null && q.isNotEmpty) 'q': q,
      if (locationMode != null) 'location_mode': locationMode,
      if (adminBoundaryId != null) 'admin_boundary_id': adminBoundaryId,
    };

    final response = await _dio.get(
      ApiConstants.suggestedLists,
      queryParameters: queryParams,
    );

    final data = response.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? [];

    return items
        .map((item) => SuggestedList.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<SuggestedList>> getGuestSuggestedLists({
    int limit = 40,
    double? latitude,
    double? longitude,
    String? locationMode,
    String? adminBoundaryId,
  }) async {
    final queryParams = <String, dynamic>{
      'limit': limit,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (locationMode != null) 'location_mode': locationMode,
      if (adminBoundaryId != null) 'admin_boundary_id': adminBoundaryId,
    };

    final response = await _dio.get(
      ApiConstants.guestSuggestedLists,
      queryParameters: queryParams,
    );

    final data = response.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? [];

    return items
        .map((item) => SuggestedList.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
