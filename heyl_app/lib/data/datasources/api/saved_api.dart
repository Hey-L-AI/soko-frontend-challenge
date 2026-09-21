import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Saved Items API
class SavedApi implements ISavedApi {
  final ApiClient _apiClient;

  // Local cache for quick isSaved checks
  final Set<String> _savedEventIds = {};
  final Set<String> _savedVenueIds = {};

  SavedApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<SavedListResponse> listSaved({
    String? type,
    int limit = 50,
    String? cursor,
  }) async {
    final queryParams = <String, dynamic>{'limit': limit};

    if (type != null && type != 'all') {
      queryParams['type'] = type;
    }
    if (cursor != null) {
      queryParams['cursor'] = cursor;
    }

    final response = await _dio.get(
      ApiConstants.mySaved,
      queryParameters: queryParams,
    );

    final result = SavedListResponse.fromJson(
      response.data as Map<String, dynamic>,
    );

    // Update local cache
    _updateCache(result.items);

    return result;
  }

  @override
  Future<SavedItem> saveItem(SavedCreateRequest request) async {
    final response = await _dio.post(
      ApiConstants.mySaved,
      data: request.toJson(),
    );

    final item = SavedItem.fromJson(response.data as Map<String, dynamic>);

    // Update local cache
    if (item.eventId != null) {
      _savedEventIds.add(item.eventId!);
    }
    if (item.venueId != null) {
      _savedVenueIds.add(item.venueId!);
    }

    return item;
  }

  @override
  Future<void> deleteSaved(String savedId) async {
    await _dio.delete(ApiConstants.mySavedItem(savedId));

    // Note: We don't update the local cache here because we don't know
    // which eventId/venueId corresponds to this savedId.
    // The cache will be refreshed on next listSaved() call.
  }

  @override
  bool isSaved({String? eventId, String? venueId}) {
    if (eventId != null) {
      return _savedEventIds.contains(eventId);
    }
    if (venueId != null) {
      return _savedVenueIds.contains(venueId);
    }
    return false;
  }

  /// Update local cache from list response
  void _updateCache(List<SavedItem> items) {
    for (final item in items) {
      if (item.eventId != null) {
        _savedEventIds.add(item.eventId!);
      }
      if (item.venueId != null) {
        _savedVenueIds.add(item.venueId!);
      }
    }
  }

  /// Clear local cache (call on logout)
  void clearCache() {
    _savedEventIds.clear();
    _savedVenueIds.clear();
  }
}
