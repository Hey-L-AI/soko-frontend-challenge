import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import 'api_client.dart';

/// API client for the v2 map search bar's past-searches history
/// (PROD-3495 backend / PROD-3499 UI).
///
/// Four endpoints under `/api/v1/app/map/search-history`, all real-user-only
/// (guest tokens and anonymous callers get 401 — callers gate on auth and
/// never reach here as guests):
/// - `record(...)` — upsert an EXECUTED selection; re-selection bumps recency
///   and refreshes the display fields.
/// - `list()` — newest 10 entries, served as-is (staleness is resolved on
///   tap, Decision #21).
/// - `deleteEntry(id)` — per-entry delete (404 when already gone).
/// - `clearAll()` — idempotent clear.
class MapSearchHistoryApi {
  final ApiClient _apiClient;

  MapSearchHistoryApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Record an executed selection; returns the stored (created or
  /// recency-bumped) entry.
  ///
  /// Shape rules (422 otherwise): keyword requires [queryText] and must not
  /// carry [targetId]; every other type requires [targetId].
  Future<MapSearchHistoryEntry> record({
    required MapSearchHistoryType type,
    String? targetId,
    String? queryText,
    required String displayLabel,
    String? imageUrl,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post(
      ApiConstants.mapSearchHistory,
      data: {
        'type': type.wire,
        if (targetId != null) 'target_id': targetId,
        if (queryText != null) 'query_text': queryText,
        'display_label': displayLabel,
        if (imageUrl != null) 'image_url': imageUrl,
      },
      cancelToken: cancelToken,
    );
    return MapSearchHistoryEntry.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// The caller's past searches, newest first, at most 10. Entries with a
  /// type this client version doesn't know are skipped (forward compat).
  Future<List<MapSearchHistoryEntry>> list({CancelToken? cancelToken}) async {
    final response = await _dio.get(
      ApiConstants.mapSearchHistory,
      cancelToken: cancelToken,
    );
    final data = response.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];
    return items
        .cast<Map<String, dynamic>>()
        .where(
          (j) => MapSearchHistoryType.fromWire(j['type'] as String?) != null,
        )
        .map(MapSearchHistoryEntry.fromJson)
        .toList();
  }

  /// Delete one entry. Throws a [DioException] with status 404 when the id
  /// doesn't exist or isn't the caller's — callers treat that as already
  /// gone.
  Future<void> deleteEntry(String entryId, {CancelToken? cancelToken}) async {
    await _dio.delete(
      ApiConstants.mapSearchHistoryEntry(entryId),
      cancelToken: cancelToken,
    );
  }

  /// Clear the whole history. Idempotent — 204 also when already empty.
  Future<void> clearAll({CancelToken? cancelToken}) async {
    await _dio.delete(ApiConstants.mapSearchHistory, cancelToken: cancelToken);
  }
}
