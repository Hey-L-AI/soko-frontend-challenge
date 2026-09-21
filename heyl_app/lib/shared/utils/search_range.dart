/// Client mirror of the backend **`SEARCH_RANGE_CONFIG`** — the single radius
/// authority (`heyl/core/geo/range.py`, PROD-3156), exposed at
/// `GET /api/v1/app/geo/ranges`.
///
/// The backend owns the authoritative tier→metres mapping and resolves a
/// [key] server-side wherever an endpoint accepts a `search_range` tier (the
/// list endpoints). This enum exists for the surfaces the backend can NOT
/// resolve for the client:
///
/// - **Raw-radius endpoints** that never gained a tier param (`/places/search`)
///   still need concrete metres — use [radiusMeters] of the matching tier
///   instead of a bare literal.
/// - **Client-owned map-zoom snapping** (`map_zoom_level.dart`) is client-side
///   by design (only the client knows its viewport — location-scope Decision
///   11), so it reads the tier metres from here rather than hardcoding them.
///
/// Keep this in lockstep with the backend table. `search_range_test.dart`
/// asserts these values against a captured `/geo/ranges` response so drift is
/// caught in CI rather than in production.
///
/// Part of epic PROD-3180 (Location Scope Consistency), Phase 6 / PROD-3201.
enum SearchRange {
  nearMe('near_me', 400),
  walking('walking', 1200),
  neighborhood('neighborhood', 3000),
  district('district', 5000),
  town('town', 8000),
  wideArea('wide_area', 15000),
  city('city', 20000),
  metro('metro', 30000);

  const SearchRange(this.key, this.radiusMeters);

  /// The backend tier name — the exact string sent as the `search_range`
  /// query param and returned in `GeoRangeOut.search_range`.
  final String key;

  /// The tier radius in metres, mirroring `GeoRangeOut.radius_meters`.
  final double radiusMeters;

  /// The tier radius in kilometres, for the `radius_km`-shaped endpoints.
  double get radiusKm => radiusMeters / 1000;
}
