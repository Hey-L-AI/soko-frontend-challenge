import '../../models/feature_spotlight.dart';

/// Client for the once-only in-app feature spotlight framework (PROD-2808).
///
/// Server is the source of truth for "user X has seen feature Y" so a
/// spotlight does not re-trigger on a different device or after a reinstall.
/// Ops can also globally kill any spotlight via the backoffice — the client
/// receives that as the `disabled` array on the state response and skips
/// those spotlights without ever calling `markSeen`.
///
/// The client keeps a local read-through cache for instant first-paint
/// decisions.
abstract class IFeatureSpotlightsApi {
  /// Fetch the current feature-spotlight state for the signed-in user.
  ///
  /// Returns [FeatureSpotlightsState.empty] if the endpoint is not yet
  /// deployed (404). Callers can still make forward progress against the
  /// local cache in that case.
  Future<FeatureSpotlightsState> fetchState();

  /// Mark a feature spotlight as seen for the current user. Idempotent —
  /// primary key on `(user_profile_id, feature_id)` server-side. Returns
  /// 204 No Content on success. [reason] is optional per the OpenAPI
  /// contract; omit for "seen but not explicitly dismissed/CTA'd".
  ///
  /// Silently swallows 404 responses (endpoint not yet deployed).
  Future<void> markSeen(String featureId, {FeatureSpotlightSeenReason? reason});
}
