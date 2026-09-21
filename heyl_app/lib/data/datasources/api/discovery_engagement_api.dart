import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/discovery_engagement.dart';
import 'api_client.dart';

/// Fire-and-forget client for `POST /api/v1/app/discovery/engagement`
/// (PROD-4257 — discovery-session engagement ledger).
///
/// Best-effort, exactly like [FeedImpressionsApi]: never throws, never blocks
/// the UI. The endpoint is 202 fire-and-forget, signed-in gated (a guest post
/// is accepted and no-ops), and best-effort per row server-side, so a dropped
/// batch is harmless — the next flush carries fresh events.
class DiscoveryEngagementApi {
  final ApiClient _apiClient;
  DiscoveryEngagementApi({required ApiClient apiClient})
    : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Posts one session batch. [sessionId] stitches the visit; [events] are the
  /// ordered engagement rows. [visitorId] is the anonymous cross-state
  /// uniqueness key when known.
  Future<void> post(
    String sessionId,
    List<DiscoveryEngagementEventIn> events, {
    String? visitorId,
  }) async {
    if (events.isEmpty) return;
    try {
      await _dio.post(
        ApiConstants.discoveryEngagement,
        data: {
          'session_id': sessionId,
          'events': events.map((e) => e.toJson()).toList(),
          if (visitorId != null) 'visitor_id': visitorId,
          'sent_at': DateTime.now().toUtc().toIso8601String(),
        },
      );
    } catch (_) {
      // Fire-and-forget: engagement capture is best-effort — never surface or
      // retry. A failed flush drops those rows; the ledger is append-only and
      // the next flush carries new ones.
    }
  }
}
