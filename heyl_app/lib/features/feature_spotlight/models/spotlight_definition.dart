/// Compile-time definition of a feature spotlight.
///
/// Registered in [kFeatureSpotlights]. The registry ships in the Flutter
/// binary and is the sole source of truth — the backend has no catalog,
/// so adding, removing, or renaming a spotlight is a Flutter-only change
/// (PROD-2809).
class SpotlightDefinition {
  const SpotlightDefinition({
    required this.id,
    required this.surface,
    required this.titleKey,
    required this.bodyKey,
    required this.ctaLabelKey,
    this.illustrationAsset,
  });

  /// Stable identifier persisted server-side and in local cache. Example:
  /// `reminders_v1`. Bumping the trailing `_vN` re-triggers the spotlight
  /// for everyone.
  ///
  /// Must match `^[a-z0-9][a-z0-9_-]{0,99}$` — server-enforced on the
  /// backoffice write path (PROD-2809). Enforced client-side by the
  /// registry test suite; use [isValidFeatureId] to check ad-hoc.
  final String id;

  /// Human-readable surface tag emitted with analytics. Example:
  /// `event_detail`, `chat`, `list_page`.
  final String surface;

  /// ARB key resolving to the spotlight title.
  final String titleKey;

  /// ARB key resolving to the spotlight body copy.
  final String bodyKey;

  /// ARB key resolving to the primary CTA label.
  final String ctaLabelKey;

  /// Optional asset path (PNG/SVG) for an inline illustration. Falls back
  /// to text-only when null. Populated once PROD-2810 design assets land.
  final String? illustrationAsset;

  /// Returns true when [id] matches the server-enforced `feature_id`
  /// regex `^[a-z0-9][a-z0-9_-]{0,99}$` (PROD-2809). Lowercase
  /// alphanumerics with underscores/hyphens, 1–100 chars, must start
  /// with `[a-z0-9]`.
  static bool isValidFeatureId(String id) => _featureIdPattern.hasMatch(id);

  static final RegExp _featureIdPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,99}$');
}
