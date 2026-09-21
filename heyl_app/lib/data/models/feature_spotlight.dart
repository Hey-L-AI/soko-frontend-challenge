/// Reason a feature spotlight was marked seen.
///
/// Wire values match the backend enum defined in PROD-2808 / PROD-2809:
/// `dismissed` or `cta_tapped`. Omit the field entirely to record "seen
/// but neither explicitly dismissed nor CTA'd".
enum FeatureSpotlightSeenReason {
  dismissed('dismissed'),
  ctaTapped('cta_tapped');

  const FeatureSpotlightSeenReason(this.wire);

  final String wire;
}

/// Response body for `GET /api/v1/app/users/me/feature-spotlights`.
///
/// * `seen` — spotlights this user has already dismissed / CTA-tapped.
/// * `disabled` — spotlights ops has killed globally (backoffice managed).
///
/// The client should treat the union of both as "do not show".
class FeatureSpotlightsState {
  const FeatureSpotlightsState({required this.seen, required this.disabled});

  final Set<String> seen;
  final Set<String> disabled;

  /// Feature ids the client should suppress — union of seen + disabled.
  Set<String> get suppressed => {...seen, ...disabled};

  factory FeatureSpotlightsState.fromJson(Map<String, dynamic> json) {
    Set<String> parseSet(dynamic raw) =>
        raw is List ? raw.whereType<String>().toSet() : <String>{};
    return FeatureSpotlightsState(
      seen: parseSet(json['seen']),
      disabled: parseSet(json['disabled']),
    );
  }

  static const empty = FeatureSpotlightsState(seen: {}, disabled: {});
}
