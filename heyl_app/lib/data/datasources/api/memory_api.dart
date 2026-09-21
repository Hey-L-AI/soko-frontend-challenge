import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Memory API
class MemoryApi implements IMemoryApi {
  final ApiClient _apiClient;

  // Cache the memory for getMemoryItems
  UserMemory? _cachedMemory;
  String? _cachedLocale;

  MemoryApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<UserMemory> getMemory({String? locale}) async {
    final queryParams = <String, dynamic>{};
    if (locale != null && locale.isNotEmpty) {
      queryParams['locale'] = locale;
    }

    final response = await _dio.get(
      ApiConstants.myMemory,
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );

    _cachedMemory =
        UserMemory.fromJson(response.data as Map<String, dynamic>);
    _cachedLocale = locale;
    return _cachedMemory!;
  }

  @override
  Future<List<MemoryItem>> getMemoryItems({String? locale}) async {
    // Invalidate cache if locale changed or no cache exists
    if (_cachedMemory == null || _cachedLocale != locale) {
      await getMemory(locale: locale);
    }

    return _cachedMemory?.memoryItems ?? [];
  }

  @override
  Future<MessageResponse> deleteMemoryItem(
      MemoryItemDeleteRequest request) async {
    final response = await _dio.delete(
      ApiConstants.myMemoryItems,
      data: request.toJson(),
    );

    // Clear cache so next fetch gets updated data
    _cachedMemory = null;

    return MessageResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<MessageResponse> ingestMemory(MemoryIngestRequest request) async {
    final response = await _dio.post(
      ApiConstants.myMemoryIngest,
      data: request.toJson(),
    );

    // Clear cache so next fetch gets updated data
    _cachedMemory = null;

    return MessageResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<List<int>> exportMemory({String? locale}) async {
    final queryParams = <String, dynamic>{};
    if (locale != null && locale.isNotEmpty) {
      queryParams['locale'] = locale;
    }

    final response = await _dio.get<List<int>>(
      ApiConstants.myMemoryExport,
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
      options: Options(responseType: ResponseType.bytes),
    );

    return response.data ?? [];
  }

  /// Clear cached memory (call on logout)
  @override
  void clearCache() {
    _cachedMemory = null;
    _cachedLocale = null;
  }
}
