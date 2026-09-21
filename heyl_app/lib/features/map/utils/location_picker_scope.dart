import 'dart:math' as math;

import '../../../data/models/models.dart';
import '../../../shared/widgets/map_marker_model.dart';
import '../../lists/models/search_scope.dart';
import 'map_boundary_scope.dart' as boundary_scope;
import 'point_in_polygon.dart';

/// Pure helpers for the map-based location-scope bottom sheet
/// (`LocationScopeSheet`). Extracted from the retired full-screen
/// `MapLocationPickerScreen` so the correctness-critical parts — camera seeding
/// and the confirm→scope mapping — stay unit-testable without booting the
/// Mapbox platform view (which can't run under `flutter test`).
///
/// The sheet is **area-first**: the neighbourhood/city under the centre pin (or
/// a searched area) is selected as a whole — its centroid + recommended radius +
/// stable boundary id + polygon. A plain **point + radius** is only a fallback
/// where the backend has no covering polygon (a specific POI, or anywhere
/// outside the boundary DB's coverage — Portugal today).

// Lisbon — global fallback centre when no user location is available.
const double kPickerDefaultLat = 38.7223;
const double kPickerDefaultLng = -9.1393;

/// Default camera zoom the sheet opens at (neighbourhood scale).
const double kPickerDefaultZoom = 14.0;

/// Below this zoom the selection is the containing **city** (municipality, L7);
/// at or above it, the tight **neighbourhood** (freguesia, L8). So zooming out
/// grows the selected area to the whole city and zooming in shrinks it back.
const double kCityLevelMaxZoom = 13.0;

/// Restored-radius cutoff (m) separating a city pick from a neighbourhood pick
/// (Lisboa ≈ 5.3 km vs a freguesia ≈ 0.8 km).
const double kCityRadiusCutoffMeters = 2500.0;

/// Seed zoom that puts the opening resolve at CITY level (below
/// [kCityLevelMaxZoom]), and its neighbourhood-level counterpart.
const double kRestoredCityZoom = 11.5;
const double kRestoredNeighbourhoodZoom = 14.5;

/// A seed camera zoom for a restored area of the given radius: a big (city)
/// radius lands below [kCityLevelMaxZoom] so the first resolve picks the city
/// level; a small (neighbourhood) radius lands above it. Only a seed — the
/// sheet fits the resolved bbox precisely afterwards.
double zoomForAreaRadius(double radiusMeters) =>
    radiusMeters >= kCityRadiusCutoffMeters
    ? kRestoredCityZoom
    : kRestoredNeighbourhoodZoom;

/// The camera zoom a REOPENED picker seeds for a restored area, so its opening
/// resolve lands on the level the user actually saved.
///
/// PROD — a saved city reopened at [kPickerDefaultZoom], which is *above*
/// [kCityLevelMaxZoom], so the opening resolve tiered the selection down to the
/// freguesia under the saved centroid: confirm "Lisboa" (5 258 m), reopen, and
/// the sheet offered "Select Avenidas Novas" (976 m) while the home page still
/// read "Lisboa". One innocent re-confirm narrowed the scope 5.4x.
///
/// The persisted `boundary_level` is the authority. Picks saved before it was
/// stored (level `unknown`) fall back to inferring the tier from the radius.
double seedZoomForRestoredArea(SearchScopeArea scope) =>
    switch (scope.boundaryLevel) {
      GeoBoundaryLevel.city => kRestoredCityZoom,
      GeoBoundaryLevel.neighborhood => kPickerDefaultZoom,
      _ => zoomForAreaRadius(scope.radiusMeters),
    };

/// **Behaviour B2 thresholds — see
/// `docs/features/location-scope-picker-selection-model.md` before changing.**
///
/// How much bigger than the neighbourhood the viewport must be before the
/// selection grows to the whole city — "you can see several neighbourhoods at
/// once". 2.0 is the literal reading of that: two neighbourhood-widths fit.
const double kCityPromoteHoodFactor = 2.0;

/// The same test once the CITY is already selected. Lower, so the selection
/// doesn't flap between tiers while panning near the boundary — every flip
/// re-labels the confirm button, which reads as the picker fighting the user.
const double kCityDemoteHoodFactor = 1.6;

/// Second promotion route: the viewport already shows the WHOLE municipality.
/// Needed where a freguesia is nearly as big as its município (Almada 1.2x,
/// Sines 1.3x, Funchal 1.3x) — there the neighbourhood test alone would demand
/// zooming far past the city before it fired.
const double kCityPromoteCityFactor = 1.0;

/// Hysteresis partner of [kCityPromoteCityFactor].
const double kCityDemoteCityFactor = 0.85;

/// How many times over the viewport contains [box]: 1.0 means it fits exactly,
/// 2.0 that two of them fit side by side, below 1.0 that it doesn't fit.
///
/// Compared in DEGREES rather than metres on purpose. The metre-per-degree
/// longitude factor is `cos(latitude)`, and the viewport and the boundary it is
/// framing sit in the same latitude band, so the factor cancels — the ratio is
/// exact to well under a percent without any projection maths.
///
/// Returns 0 for a degenerate box or viewport, which reads as "doesn't fit" and
/// so keeps the tighter selection — the conservative direction.
double viewportFitFactor(MapCameraState camera, GeoBounds box) {
  double lngSpan(double east, double west) {
    final span = east - west;
    return span < 0 ? span + 360 : span; // viewport crossing the antimeridian
  }

  final viewLat = (camera.neLat - camera.swLat).abs();
  final viewLng = lngSpan(camera.neLng, camera.swLng);
  final boxLat = (box.north - box.south).abs();
  final boxLng = lngSpan(box.east, box.west);
  if (viewLat <= 0 || viewLng <= 0 || boxLat <= 0 || boxLng <= 0) return 0;
  // `min` of the two axes: the box only "fits N times over" if it does so in
  // BOTH dimensions. Taking the max would call a long thin area contained when
  // it spills off the top and bottom of the screen.
  return math.min(viewLat / boxLat, viewLng / boxLng);
}

/// **The selection rule — behaviours B1 and B2.** Which administrative level
/// the centre resolves to for the CURRENT viewport: the tight [neighbourhood]
/// while it fills the frame, its whole [city] once the frame has grown past it.
///
/// Read `docs/features/location-scope-picker-selection-model.md` before
/// changing any of this — the thresholds encode product decisions, not
/// implementation detail.
///
/// **Why the viewport and not the zoom.** This replaced a fixed zoom cutoff
/// (`boundaryForZoom`, z13). Zoom is absolute; neighbourhoods are not. Measured
/// on production, a município is anywhere from **1.2x to 8.9x** its freguesias
/// — so no single zoom can mean "one neighbourhood fills the screen" everywhere.
/// At z13 the sheet shows ~5.2 km: that is ~2.4 Braga freguesias (city — right)
/// but only 41 % of ONE Almada freguesia (city — plainly wrong, and it is what
/// made a saved "Almada" pick behave unlike a saved "Braga" one). Measuring the
/// viewport against the shape it is framing is scale-free and fixes both ends.
///
/// [cityCurrentlySelected] supplies the hysteresis: the thresholds relax once
/// the city is the active pick, so panning near the transition does not flap.
GeoBoundary? boundaryForViewport({
  GeoBoundary? neighbourhood,
  GeoBoundary? city,
  required MapCameraState camera,
  bool cityCurrentlySelected = false,
}) {
  if (neighbourhood == null) return city;
  if (city == null) return neighbourhood;
  final hoodFit = viewportFitFactor(camera, neighbourhood.bbox);
  final cityFit = viewportFitFactor(camera, city.bbox);
  final hoodThreshold = cityCurrentlySelected
      ? kCityDemoteHoodFactor
      : kCityPromoteHoodFactor;
  final cityThreshold = cityCurrentlySelected
      ? kCityDemoteCityFactor
      : kCityPromoteCityFactor;
  final wantsCity = hoodFit >= hoodThreshold || cityFit >= cityThreshold;
  return wantsCity ? city : neighbourhood;
}

/// The area to select at [zoom]: the tight [neighbourhood] when zoomed in, its
/// containing [city] when zoomed out (below [cityMaxZoom]). Falls back to
/// whichever level is present.
///
/// **Superseded for live camera settles by [boundaryForViewport]** (which knows
/// the viewport's real size). Still the rule where no viewport exists yet: the
/// opening resolve, and [restoredBoundaryFor]'s fallback when a saved boundary
/// id can no longer be matched. Both run before the map has reported bounds.
GeoBoundary? boundaryForZoom({
  GeoBoundary? neighbourhood,
  GeoBoundary? city,
  required double zoom,
  double cityMaxZoom = kCityLevelMaxZoom,
}) {
  if (zoom < cityMaxZoom) return city ?? neighbourhood;
  return neighbourhood ?? city;
}

/// The boundary a REOPENED picker should re-select, given what
/// `GET /geo/boundary/at` returned at the restored centre.
///
/// **Identity wins over zoom.** The saved scope names the exact boundary the
/// user confirmed ([savedBoundaryId]); whenever the resolve still contains it —
/// as the leaf freguesia, or as that leaf's inline municipality — *that* is the
/// selection, whatever the seed zoom happened to be. Zoom-tiering the opening
/// resolve is a guess about what the user meant; the stored id is a record of
/// it, and re-deriving over the top is what silently turned a saved "Lisboa"
/// into "Avenidas Novas".
///
/// Only an id the resolve doesn't contain — a legacy pick that stored none, a
/// boundary that changed id, a centroid that now resolves elsewhere — falls
/// back to [boundaryForZoom]. Cold opens (no restore) pass a null id and are
/// unaffected.
GeoBoundary? restoredBoundaryFor({
  required GeoBoundary resolved,
  required String? savedBoundaryId,
  required double zoom,
}) {
  if (savedBoundaryId != null && savedBoundaryId.isNotEmpty) {
    if (resolved.id == savedBoundaryId) return resolved;
    final municipality = resolved.municipality;
    if (municipality != null && municipality.id == savedBoundaryId) {
      return municipality;
    }
  }
  return boundaryForZoom(
    neighbourhood: resolved,
    city: resolved.municipality,
    zoom: zoom,
  );
}

/// Collapse a boundary's children to a single tappable tier.
///
/// OSM tags BOTH a município's real freguesias AND informal bairros at
/// `admin_level 8`, so `/geo/boundary/{id}/children` returns a mix of two
/// nesting levels — e.g. for Lisboa it returns 93 polygons where "Alfama" (a
/// bairro) sits *inside* its freguesia. The picker only wants the **outermost**
/// tier (city → freguesias), never a sub-division inside a division. Drops any
/// child whose centroid falls inside a strictly-larger sibling's polygon; the
/// freguesias that tile the city survive (their centroids aren't inside any
/// larger sibling). Order is preserved. Null-geometry children can't be
/// containers but are still tested (via their centroid) and kept when top-level.
List<GeoBoundary> outermostChildren(List<GeoBoundary> children) {
  double bboxArea(GeoBoundary b) =>
      (b.bbox.north - b.bbox.south).abs() * (b.bbox.east - b.bbox.west).abs();
  return children.where((c) {
    final ca = bboxArea(c);
    final containedByLarger = children.any((o) {
      if (identical(o, c)) return false;
      final og = o.geometry;
      if (og == null) return false; // can't contain without a polygon
      if (bboxArea(o) <= ca) return false; // only a strictly larger sibling
      return pointInPolygon(c.centroidLat, c.centroidLon, og);
    });
    return !containedByLarger;
  }).toList();
}

/// The API's accepted `radius_meters` window.
const double kMinRadiusMeters = 100.0;
const double kMaxRadiusMeters = 50000.0;

double clampRadiusMeters(double m) =>
    m.clamp(kMinRadiusMeters, kMaxRadiusMeters);

/// Floor for a radius the user frames **in the location picker** (PROD-4291,
/// Zé 2026-09-08). Below this the results get too thin to be a useful scope.
///
/// ⚠️ **Deliberately separate from [kMinRadiusMeters], and it must stay that
/// way.** The obvious implementation — raising that constant to 3000 — is
/// wrong: it is the shared API-window clamp for *every* location surface, and
/// two `SearchRange` tiers sit below this floor, `nearMe` (400 m) and
/// `walking` (1200 m). A blanket floor would silently delete both. The ruling
/// was "floor the picker, don't interfere with nearMe/walking", so the floor
/// lives here, applied only where the picker derives a radius from the frame
/// the user chose.
const double kMinPickerRadiusMeters = 3000.0;

/// [clampRadiusMeters] with the picker's own floor.
///
/// Applied where the picker *produces* a point radius rather than at apply
/// time, so the highlight circle the user is dragging already shows the floor —
/// the control stops shrinking instead of silently disagreeing with what it
/// draws.
double clampPickerRadiusMeters(double m) =>
    m.clamp(kMinPickerRadiusMeters, kMaxRadiusMeters);

/// The canonical Search Center for a covered administrative area (a centre-
/// resolved boundary or a boundary search hit): its centroid + recommended
/// radius + stable id + polygon. Delegates to the shared producer so every
/// location surface represents an area identically.
SearchScopeArea areaScopeForBoundary(GeoBoundary boundary) =>
    boundary_scope.searchScopeAreaForBoundary(boundary);

/// The Search Center for an uncovered point (outside boundary coverage, or a
/// resolved POI): centre + radius, no boundary id (never poisons containment).
SearchScopeArea pointScope({
  required ({double lat, double lng}) center,
  required double radiusMeters,
  String name = '',
}) => SearchScopeArea(
  centerLat: center.lat,
  centerLng: center.lng,
  radiusMeters: clampRadiusMeters(radiusMeters),
  displayName: name,
  boundaryId: null,
);

/// Stage a resolved search prediction into a scope: a boundary hit → its whole
/// area; a point/POI → its centre + the backend's recommended radius. A `point`
/// result never carries a boundary id, so a provider place-id can't land in the
/// containment-reserved field.
SearchScopeArea areaScopeFromResolved(ResolvedArea area) {
  if (area.kind == AreaKind.boundary)
    return areaScopeForBoundary(area.boundary);
  final b = area.boundary;
  return pointScope(
    center: (lat: b.centroidLat, lng: b.centroidLon),
    radiusMeters: b.recommendedRadiusM.toDouble(),
    name: boundary_scope.boundaryPlaceLabel(b),
  );
}

/// Camera center a scope can seed, most-granular first. Null when the scope
/// carries no usable coordinate (country-only, or a Google city not yet
/// resolved).
({double lat, double lng})? scopeCenter(SearchScope? scope) => switch (scope) {
  SearchScopeArea(:final centerLat, :final centerLng) => (
    lat: centerLat,
    lng: centerLng,
  ),
  SearchScopeCountryCity(:final city)
      when city.latitude != null && city.longitude != null =>
    (lat: city.latitude!, lng: city.longitude!),
  _ => null,
};

/// Initial camera center: previous pick → cached location → fresh GPS → Lisbon.
({double lat, double lng}) resolvePickerCenter({
  ({double lat, double lng})? previousScopeCenter,
  LocationSnapshot? lastKnown,
  ({double lat, double lng})? freshGps,
}) {
  if (previousScopeCenter != null) return previousScopeCenter;
  if (lastKnown != null) return (lat: lastKnown.lat, lng: lastKnown.lon);
  if (freshGps != null) return freshGps;
  return (lat: kPickerDefaultLat, lng: kPickerDefaultLng);
}

/// A `MapBoundsConfig` framing the circle of [radiusMeters] around [center].
///
/// The inverse of the picker's viewport→radius derivation, used to REOPEN on a
/// previously-confirmed point scope at the zoom the user actually chose.
/// Without it the sheet opened at a fixed [kPickerDefaultZoom] no matter how
/// wide the saved radius was, and the first settle then overwrote the saved
/// radius with one derived from that fixed zoom — so a 27 km pick came back as
/// a neighbourhood.
///
/// Point scopes only. A boundary scope deliberately does NOT auto-fit (see the
/// restore branch in `LocationScopeSheet.initState`): fitting a neighbourhood
/// can drop below the city-zoom threshold and flip the selection up to the
/// whole city.
MapBoundsConfig boundsConfigForRadius({
  required ({double lat, double lng}) center,
  required double radiusMeters,
  int padding = 48,
  double maxZoom = 15,
}) {
  const metresPerDegLat = 111320.0;
  final r = clampRadiusMeters(radiusMeters);
  final dLat = r / metresPerDegLat;
  final cosLat = math.cos(center.lat * math.pi / 180.0).abs();
  final dLng = r / (metresPerDegLat * (cosLat < 1e-6 ? 1e-6 : cosLat));
  return MapBoundsConfig(
    north: (center.lat + dLat).clamp(-90.0, 90.0),
    south: (center.lat - dLat).clamp(-90.0, 90.0),
    east: center.lng + dLng,
    west: center.lng - dLng,
    padding: padding,
    maxZoom: maxZoom,
  );
}

/// A `MapBoundsConfig` fitting a searched area's bbox, or null when the bbox is
/// degenerate (caller should center on the centroid instead). Used only for the
/// deliberate one-shot recenter after a worldwide-search result is picked.
MapBoundsConfig? boundsConfigForArea(
  GeoBoundary b, {
  double minSpanDeg = boundary_scope.kMinBboxSpanDeg,
}) {
  if (boundary_scope.isDegenerateBbox(b.bbox, minSpanDeg: minSpanDeg)) {
    return null;
  }
  return MapBoundsConfig(
    north: b.bbox.north,
    south: b.bbox.south,
    east: b.bbox.east,
    west: b.bbox.west,
    padding: 48,
    maxZoom: 15,
  );
}
