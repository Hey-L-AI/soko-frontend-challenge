import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/library_feed.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

class LibraryApi implements ILibraryApi {
  LibraryApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;
  Dio get _dio => _apiClient.dio;

  /// Query map for `GET /users/me/library`. Empty optional fields are
  /// omitted so we do not send `cursor=` / `q=` noise.
  @visibleForTesting
  static Map<String, dynamic> getQueryParameters({
    int limit = 20,
    String sort = 'recent',
    String? cursor,
    String? types,
    String? q,
    String? membership,
    String? when,
    String? fromDate,
    String? toDate,
    String? direction,
  }) {
    return {
      'limit': limit,
      'sort': sort,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (types != null && types.isNotEmpty) 'types': types,
      if (q != null && q.isNotEmpty) 'q': q,
      if (membership != null && membership.isNotEmpty) 'membership': membership,
      if (when != null && when.isNotEmpty) 'when': when,
      if (fromDate != null && fromDate.isNotEmpty) 'from_date': fromDate,
      if (toDate != null && toDate.isNotEmpty) 'to_date': toDate,
      if (direction != null && direction.isNotEmpty) 'direction': direction,
    };
  }

  @override
  Future<LibraryFeedOut> getLibrary({
    int limit = 20,
    String? cursor,
    String? types,
    String sort = 'recent',
    String? q,
    String? membership,
    String? when,
    String? fromDate,
    String? toDate,
    String? direction,
  }) async {
    final response = await _dio.get(
      ApiConstants.myLibrary,
      queryParameters: getQueryParameters(
        limit: limit,
        sort: sort,
        cursor: cursor,
        types: types,
        q: q,
        membership: membership,
        when: when,
        fromDate: fromDate,
        toDate: toDate,
        direction: direction,
      ),
    );
    return LibraryFeedOut.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<LibraryPinOut> pinLibraryItem({
    required LibraryFeedItemType type,
    required String id,
  }) async {
    final response = await _dio.put(ApiConstants.myLibraryPin(type.wire, id));
    return LibraryPinOut.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<LibraryPinOut> unpinLibraryItem({
    required LibraryFeedItemType type,
    required String id,
  }) async {
    final response = await _dio.delete(
      ApiConstants.myLibraryPin(type.wire, id),
    );
    return LibraryPinOut.fromJson(response.data as Map<String, dynamic>);
  }
}
