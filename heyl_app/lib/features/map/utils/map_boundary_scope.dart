import '../../../data/models/area_prediction.dart';
import '../../../data/models/geo_boundary.dart';
import '../../../features/lists/models/search_scope.dart';

/// Minimum bbox span (degrees) below which fitting the box is unsafe — the
/// caller should centre on the centroid instead. ~55 m at the equator.
const double kMinBboxSpanDeg = 0.0005;

/// True when a bbox is too small to safely fit (points / synthetic boxes).
///
/// Shared by the location picker (which hands the box to the renderers'
/// `fitBounds`) and the v2 map search executor (which frames it by hand — the
/// Map page must never use `boundsConfig`; see `fitCameraForBox`).
bool isDegenerateBbox(GeoBounds b, {double minSpanDeg = kMinBboxSpanDeg}) =>
    (b.north - b.south).abs() < minSpanDeg ||
    (b.east - b.west).abs() < minSpanDeg;

/// Use map-ready coordinates embedded by deep search; only legacy/local area
/// predictions need the existing resolve endpoint.
Future<ResolvedArea?> resolveSearchPrediction(
  AreaPrediction prediction,
  Future<ResolvedArea?> Function() resolve,
) async {
  final embedded = prediction.resolvedArea;
  if (embedded != null) return embedded;
  return resolve();
}

/// The single, most-specific place name shown across the UI for an
/// administrative boundary — e.g. "Avenidas Novas" or "Sines", not the full
/// "Avenidas Novas, Lisboa, Portugal" hierarchy (user feedback: the parent
/// city + country were redundant noise, especially when leaf and parent
/// coincide, as in "Sines, Sines, Portugal").
///
/// This is the label persisted on a map-derived [SearchScopeArea], so the
/// action-bar pill, chat search indicator and picker all name the same place
/// with just its leaf name.
String boundaryPlaceLabel(GeoBoundary boundary) => boundary.name;

/// Converts a resolved administrative boundary into the canonical Search
/// Center representation. Geometry is an in-memory display cache only; stable
/// boundary identity, centre and tier radius are the durable data.
///
/// [isAuto] marks the area as auto-resolved (Decision 13 — "Auto → C follows
/// U": the neighbourhood the live user location falls inside) rather than an
/// explicit map-picker pick. It drives the "Auto" affordance and keeps
/// isExplicit-derived behaviour (e.g. Near-You's "Near you" vs "Near X" title)
/// correct.
SearchScopeArea searchScopeAreaForBoundary(
  GeoBoundary boundary, {
  bool isAuto = false,
}) => SearchScopeArea(
  centerLat: boundary.centroidLat,
  centerLng: boundary.centroidLon,
  radiusMeters: boundary.recommendedRadiusM.toDouble(),
  boundaryId: boundary.id,
  boundaryVersion: boundary.version,
  boundaryLevel: boundary.level,
  boundaryGeometry: boundary.geometry,
  displayName: boundaryPlaceLabel(boundary),
  city: boundary.city,
  isAuto: isAuto,
);
