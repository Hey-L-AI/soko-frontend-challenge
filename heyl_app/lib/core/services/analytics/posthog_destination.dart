import '../posthog_service.dart';
import 'analytics_destination.dart';

/// PostHog destination adapter.
///
/// The simplest adapter — all events use the same `capture()` call.
/// PostHogService already enriches events with environment and platform.
class PostHogDestination implements AnalyticsDestination {
  final PostHogService _posthog;

  PostHogDestination(this._posthog);

  @override
  String get name => 'posthog';

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {
    await _posthog.capture(event, properties: _castProperties(properties));
  }

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {
    await _posthog.identify(userId, userProperties: _castProperties(traits));
    await _posthog.reloadFeatureFlags();
  }

  @override
  Future<void> reset() async {
    // Awaited: `trackLogout()` awaits this, and the next event must already
    // carry the re-registered super properties (environment, visitor_id,
    // entry_id).
    await _posthog.reset();
  }

  /// Cast dynamic values to Object for the PostHog SDK.
  /// Filters out null values since PostHog properties expect non-null Object.
  Map<String, Object>? _castProperties(Map<String, dynamic> props) {
    if (props.isEmpty) return null;
    final result = <String, Object>{};
    for (final entry in props.entries) {
      if (entry.value != null) {
        result[entry.key] = entry.value as Object;
      }
    }
    return result.isEmpty ? null : result;
  }
}
