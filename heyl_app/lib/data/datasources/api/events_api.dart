import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Events API
class EventsApi implements IEventsApi {
  final ApiClient _apiClient;

  EventsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  @override
  Future<EventListResponse> listEvents({
    String? city,
    String? startDate,
    String? endDate,
    int limit = 100,
    String? cursor,
  }) async {
    final queryParams = <String, dynamic>{
      'limit': limit,
    };

    if (city != null && city.isNotEmpty) {
      queryParams['city'] = city;
    }
    if (startDate != null) {
      queryParams['start_date'] = startDate;
    }
    if (endDate != null) {
      queryParams['end_date'] = endDate;
    }
    if (cursor != null) {
      queryParams['cursor'] = cursor;
    }

    final response = await _dio.get(
      ApiConstants.events,
      queryParameters: queryParams,
    );

    return EventListResponse.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<EventDetailResponse> getEvent(String eventId, {String? startDate, String? endDate}) async {
    final queryParams = <String, dynamic>{};

    if (startDate != null) {
      queryParams['start_date'] = startDate;
    }
    if (endDate != null) {
      queryParams['end_date'] = endDate;
    }

    final response = await _dio.get(
      ApiConstants.event(eventId),
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );

    return EventDetailResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
