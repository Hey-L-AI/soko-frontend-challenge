import 'search_range.dart';

/// The explicit zoom bands shared by picker and map recenter interactions.
///
/// These are the client-owned, small-area levels from the location-scope
/// design. Each one maps to the corresponding backend `SEARCH_RANGE_CONFIG`
/// tier when a point (rather than an administrative boundary) is selected.
enum MapZoomLevel { neighborhood, walking, nearMe }

/// The start of the street-scale `walking` level.
const double kMapZoomWalkingStart = 14;

/// The start of the closest `near_me` level.
const double kMapZoomNearMeStart = 17.5;

/// Resolves a raw Mapbox zoom to its named small-area search level.
MapZoomLevel mapZoomLevelFor(double zoom) {
  if (zoom >= kMapZoomNearMeStart) return MapZoomLevel.nearMe;
  if (zoom >= kMapZoomWalkingStart) return MapZoomLevel.walking;
  return MapZoomLevel.neighborhood;
}

extension MapZoomLevelSearchRange on MapZoomLevel {
  /// The backend `SEARCH_RANGE_CONFIG` tier this zoom band maps to. The
  /// zoom→tier mapping is client-owned; the tier's identity and metres live in
  /// [SearchRange] (the single mirror of the backend authority).
  SearchRange get searchRange => switch (this) {
    MapZoomLevel.neighborhood => SearchRange.neighborhood,
    MapZoomLevel.walking => SearchRange.walking,
    MapZoomLevel.nearMe => SearchRange.nearMe,
  };

  /// Backend `SEARCH_RANGE_CONFIG` key for this level.
  String get searchRangeKey => searchRange.key;

  /// Radius for a point-selected search at this level, in metres.
  double get radiusMeters => searchRange.radiusMeters;
}
