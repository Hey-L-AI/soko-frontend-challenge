import 'package:flutter/foundation.dart';

import '../backend_analytics_service.dart';
import 'analytics_destination.dart';

/// Backend API destination adapter.
///
/// Uses the generic `POST /api/v1/app/analytics/track` endpoint to dispatch
/// all events. The backend validates event names against its registry and
/// auto-injects common fields.
///
/// [BackendAnalyticsService] handles sessionId/visitorId injection.
class BackendDestination implements AnalyticsDestination {
  final BackendAnalyticsService _backend;

  BackendDestination(this._backend);

  @override
  String get name => 'backend';

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {
    // Only deployed (release) builds emit backend analytics. `flutter run`
    // is always debug, so local runs against any backend (staging or prod)
    // are skipped — keeps the events table clean of developer traffic.
    // Render staging/prod deploys both build with --release, so they emit.
    if (!kReleaseMode) {
      if (kDebugMode) {
        debugPrint('[BackendDestination] skipped (non-release): $event');
      }
      return;
    }
    await _backend.trackGeneric(event, properties);
  }

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {
    // Backend doesn't need explicit identify — uses session ID
  }

  @override
  Future<void> reset() async {
    // Backend doesn't need reset — session ID handles identity
  }
}
