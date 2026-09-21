/// Base interface for all analytics destinations.
///
/// Each destination (PostHog, Firebase, Backend API, Sentry) implements this
/// interface. The [UnifiedAnalyticsService] dispatches events to destinations
/// based on the routing defined in [eventRegistry].
abstract class AnalyticsDestination {
  /// Human-readable name for debug logging (e.g., 'posthog', 'firebase').
  String get name;

  /// Send a tracked event with optional properties.
  ///
  /// Fire-and-forget — implementations must never throw.
  Future<void> track(String event, Map<String, dynamic> properties);

  /// Identify a user (link anonymous → authenticated).
  ///
  /// [traits] are optional person/user properties.
  Future<void> identify(String userId, Map<String, dynamic> traits);

  /// Reset identity (clear user association). Called on logout.
  Future<void> reset();
}
