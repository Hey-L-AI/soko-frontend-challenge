import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/feed_impression.dart';
import 'api_client.dart';

/// Fire-and-forget client for `POST /feed/impressions` (seen-suppression).
/// Best-effort: never throws, never blocks the UI. The backend upserts per
/// (item_type, item_id) per user, so a duplicate POST is harmless.
class FeedImpressionsApi {
  final ApiClient _apiClient;
  FeedImpressionsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  Future<void> post(List<FeedImpressionIn> impressions) async {
    if (impressions.isEmpty) return;
    try {
      await _dio.post(
        ApiConstants.feedImpressions,
        data: {
          'impressions': impressions.map((e) => e.toJson()).toList(),
          'sent_at': DateTime.now().toUtc().toIso8601String(),
        },
      );
    } catch (_) {
      // Fire-and-forget: suppression is best-effort — never surface or retry.
    }
  }
}
