import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/memory_twin_api.dart';
import 'api_client.dart';

/// Dio-backed `IMemoryTwinApi`.
class MemoryTwinApi implements IMemoryTwinApi {
  final ApiClient _apiClient;

  MemoryTwinApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<MemoryTwinResponse> getTwin() async {
    final response = await _dio.get(ApiConstants.myMemory);
    return MemoryTwinResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<BulkClearResponse> clearAll() async {
    final response = await _dio.delete(
      ApiConstants.myMemoryClear,
      queryParameters: {'confirm': true},
    );
    return BulkClearResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteFact(String factId) async {
    final path = ApiConstants.myMemoryFactById.replaceFirst(
      '{fact_id}',
      Uri.encodeComponent(factId),
    );
    await _dio.delete(path);
  }

  @override
  Future<void> deleteObservation(String observationId) async {
    final path = ApiConstants.myMemoryObservationById.replaceFirst(
      '{observation_id}',
      Uri.encodeComponent(observationId),
    );
    await _dio.delete(path);
  }

  @override
  Future<void> deleteDimension(String dimensionName) async {
    final path = ApiConstants.myMemoryDimensionByName.replaceFirst(
      '{dimension_name}',
      Uri.encodeComponent(dimensionName),
    );
    await _dio.delete(path);
  }

  @override
  Future<void> suppressChip({
    required String dimension,
    String? family,
    required String value,
  }) async {
    await _dio.post(
      ApiConstants.myMemoryChipSuppress,
      data: {
        'dimension': dimension,
        if (family != null) 'family': family,
        'value': value,
      },
    );
  }

  @override
  Future<int> nudgeChip({
    required String dimension,
    String? family,
    required String value,
    required bool increase,
  }) async {
    final response = await _dio.post(
      ApiConstants.myMemoryChipNudge,
      data: {
        'dimension': dimension,
        if (family != null) 'family': family,
        'value': value,
        'direction': increase ? 'up' : 'down',
      },
    );
    final data = response.data as Map<String, dynamic>?;
    return (data?['nudge_level'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<int>> exportJson() async {
    final response = await _dio.get<List<int>>(
      ApiConstants.myMemoryExport,
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data ?? const [];
  }

  @override
  Future<TellUsResult> tellUs(String text) async {
    final response = await _dio.post(
      ApiConstants.myMemoryTellUs,
      data: {'text': text},
    );
    return TellUsResult.fromJson(response.data as Map<String, dynamic>);
  }
}
