import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/entity_signal.dart';
import '../../models/saved_item.dart';
import 'api_client.dart';

/// API client for per-(user, entity) relationship signals (PROD-2930).
///
/// The chips on a venue/event detail page. The server owns the toggle — the
/// client sends an action and renders the returned [EntitySignal].
class SignalApi {
  final ApiClient _apiClient;

  SignalApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  String _signalPath(SignalEntityType type, String id) =>
      type == SignalEntityType.event
      ? ApiConstants.eventSignal(id)
      : ApiConstants.venueSignal(id);

  /// The caller's current signal for this entity, plus per-entity aggregates.
  Future<EntitySignal> getSignal(SignalEntityType type, String id) async {
    final response = await _dio.get(_signalPath(type, id));
    return EntitySignal.fromJson(response.data as Map<String, dynamic>);
  }

  /// The caller's own rated entities — "what did I like" (PROD-3779).
  ///
  /// Self-scoped: there is no handle variant, because a like is not public.
  /// The response is deliberately the saved list's shape, so liked and saved
  /// items merge without a second model — see [SavedListResponse]. Two fields
  /// read differently: `savedId` is really the SIGNAL row id (never pass it to
  /// the saved-item delete) and `createdAt` is `rated_at`, when the thumb was
  /// tapped.
  Future<SavedListResponse> getMySignals({
    String sentiment = 'liked',
    int limit = 100,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.mySignals,
      queryParameters: {
        'sentiment': sentiment,
        'limit': limit,
        'offset': offset,
      },
    );
    return SavedListResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// Apply a chip tap. Returns the resulting state (server-side toggle).
  ///
  /// [provenance] is an optional surface-attribution label (see
  /// [SignalProvenance]); when set it is sent so the backend can record where
  /// this tap came from (last-write-wins). Omitted from the body when null.
  Future<EntitySignal> postSignal(
    SignalEntityType type,
    String id,
    SignalAction action, {
    String? provenance,
  }) async {
    final response = await _dio.post(
      _signalPath(type, id),
      data: {
        'action': action.wire,
        if (provenance != null) 'provenance': provenance,
      },
    );
    return EntitySignal.fromJson(response.data as Map<String, dynamic>);
  }
}
