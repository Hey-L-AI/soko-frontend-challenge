import 'dart:math' as math;

import '../../../data/models/bounding_box.dart';
import '../../lists/models/search_scope.dart';

/// PROD-2671 — where the Map page's camera should open.
///
/// The Map page opens on a **resolvable initial camera**: a centre point plus
/// a *search radius* (metres) that the zoom is derived from (so "show me a
/// ~5 km area" reads the same regardless of screen size). Today the only
/// source is the user's location (see `map_screen.dart` `_resolveInitialCamera`),
/// but this type is the seam for the **direction we're heading**: opening the
/// map at an explicit point + radius passed as an argument (e.g. from a saved
/// search's centre + its radius, a deep link, or a "search this area" hand-off).
/// When that lands, the router/caller constructs a [MapCameraTarget] and passes
/// it to `MapScreen(initialCamera: ...)`; everything downstream (fetch centre,
/// zoom) already flows from it.
class MapCameraTarget {
  const MapCameraTarget({
    required this.lat,
    required this.lng,
    this.radiusMeters = kDefaultMapRadiusMeters,
  });

  final double lat;
  final double lng;

  /// The search radius (metres) the initial view should frame. Drives the
  /// opening zoom via [zoomForRadius].
  final double radiusMeters;

  /// Value equality. PROD-4124 — `MapScreen.didUpdateWidget` compares the
  /// incoming camera against the previous one to decide whether a deep link
  /// actually moved it; the route rebuilds this object on every rebuild, so
  /// identity would report a move that never happened.
  @override
  bool operator ==(Object other) =>
      other is MapCameraTarget &&
      other.lat == lat &&
      other.lng == lng &&
      other.radiusMeters == radiusMeters;

  @override
  int get hashCode => Object.hash(lat, lng, radiusMeters);
}

/// Default search radius (metres) when no explicit radius is supplied — matches
/// `MapQuery.radiusMeters`'s default so the opening view frames the same area
/// the first `/map/pins` fetch queries.
const double kDefaultMapRadiusMeters = 5000;

/// Framing target for an explicit Search Center (C). The map consumes both
/// city picks and map-picked areas: an area carries its own center + radius,
/// while a city frames its bbox (or a city-scale fallback). Auto scopes are U,
/// so they intentionally return null and let location seeding handle them.
MapCameraTarget? cameraTargetForSearchScope(SearchScope? scope) =>
    switch (scope) {
      SearchScopeArea(
        :final centerLat,
        :final centerLng,
        :final radiusMeters,
        isAuto: false,
      ) =>
        MapCameraTarget(
          lat: centerLat,
          lng: centerLng,
          radiusMeters: radiusMeters,
        ),
      SearchScopeCountryCity(:final city, isAuto: false)
          when city.hasCoordinates =>
        city.boundingBox != null
            ? cameraTargetForBounds(city.boundingBox!)
            : MapCameraTarget(
                lat: city.latitude!,
                lng: city.longitude!,
                radiusMeters: _kCityFallbackRadiusMeters,
              ),
      _ => null,
    };

/// City-scale framing radius when a selected city has no bounding box.
///
/// This is a **camera-framing** radius (how zoomed-out the map opens), not a
/// **search** radius, so it stays client-owned and is deliberately NOT a
/// `SEARCH_RANGE_CONFIG` tier — zoom/framing is the client's job (location-scope
/// Decision 11), whereas the tier authority (`SearchRange`) governs the metres a
/// query filters by. PROD-3201 folded the search-radius literals onto the tier
/// mirror but left this framing default here on purpose.
const double _kCityFallbackRadiusMeters = 10000;

/// PROD-2671 — a [MapCameraTarget] that frames a city's [bbox]: centred on the
/// bbox centroid with a radius covering its larger half-extent (+15 % padding),
/// so [zoomForRadius] opens the map on the whole city. Used when the user has
/// picked a city scope (`cityScopeProvider`). [padding] tunes the breathing
/// room; the radius is clamped to a sane map range.
MapCameraTarget cameraTargetForBounds(
  BoundingBox bbox, {
  double padding = 1.15,
}) {
  final centerLat = (bbox.north + bbox.south) / 2;
  final centerLng = (bbox.east + bbox.west) / 2;
  final halfHeightM = (bbox.north - bbox.south).abs() / 2 * 111320.0;
  final halfWidthM =
      (bbox.east - bbox.west).abs() /
      2 *
      111320.0 *
      math.cos(centerLat * math.pi / 180.0).abs();
  final radius = (math.max(halfHeightM, halfWidthM) * padding).clamp(
    100.0,
    200000.0,
  );
  return MapCameraTarget(lat: centerLat, lng: centerLng, radiusMeters: radius);
}

/// Web-Mercator zoom that frames a circle of [radiusMeters] (its full diameter)
/// across a viewport [viewportWidthPx] wide at latitude [lat].
///
/// Derivation: metres-per-pixel at zoom z is `156543.03 * cos(lat) / 2^z`, so to
/// fit the diameter `2·R` across `W` pixels we solve
/// `z = log2(156543.03 · cos(lat) · W / (2 · R))`. Same formula the chat map's
/// adaptive zoom uses; clamped to a sane map range.
double zoomForRadius(
  double radiusMeters,
  double lat,
  double viewportWidthPx, {
  double minZoom = 3.0,
  double maxZoom = 18.0,
}) {
  if (radiusMeters <= 0 || viewportWidthPx <= 0) return 13.0;
  final cosLat = math.cos(lat * math.pi / 180.0);
  final z =
      math.log(156543.03 * cosLat * viewportWidthPx / (2 * radiusMeters)) /
      math.ln2;
  if (z.isNaN || z.isInfinite) return 13.0;
  return z.clamp(minZoom, maxZoom);
}

/// PROD-2992 — where the pin-focus camera should land, vertically: the focused
/// pin sits this fraction of the map box down from its top edge (0 = top,
/// 1 = bottom). Kept well above `0.5` deliberately — the detail sheet opens at
/// `initialSize = 0.6` (`showDsDraggableSheet`), so its top edge sits at ~0.40
/// of the screen; centring the pin (0.5) would tuck it behind the sheet. `0.25`
/// centres it in the clear strip between the top chrome (~0.13) and the sheet
/// edge (~0.40). Tunable at the web-test checkpoint.
const double kMapPinFocusPinScreenFraction = 0.25;

/// PROD-2992 — the pin-focus **target zoom**: zoom in by +2, capped at 16, and
/// never zoom out. Already past 16 → unchanged (`15 → 16`, `13 → 15`,
/// `16.5 → 16.5`).
double pinFocusTargetZoom(double currentZoom) =>
    currentZoom >= 16.0 ? currentZoom : math.min(currentZoom + 2.0, 16.0);

/// PROD-2992 — the camera **centre latitude** that places a pin at [pinLat] at
/// [pinScreenFraction] down from the top of a [mapHeightPx]-tall map box, at
/// [zoom]. Longitude is unchanged (the camera centres on the pin horizontally),
/// so only the latitude needs shifting.
///
/// **Mapbox GL renders 512-px tiles**, so the world spans `512·2^zoom` px and
/// metres-per-pixel at the equator is `earthCircumference/(512·2^zoom)` =
/// `78271.52/2^zoom` (× cos(lat)). This MUST be the 512-tile constant, not the
/// 256-tile `156543.03` — using the latter doubles the lift and shoves the pin
/// off the top of the map. Matches `_kTileSizePx` in `map_highlight_geometry`,
/// which `fitCameraFor` uses. (Note: [zoomForRadius] above uses the 256-tile
/// constant and is correspondingly ~1 zoom level imprecise — fine for "frame a
/// ~5 km area", but precise pin placement needs the true 512-tile resolution.)
/// The vertical offset spans only a few hundred metres at these zooms, so the
/// flat `111320 m/°` latitude approximation is well within tolerance.
double pinFocusCenterLat({
  required double pinLat,
  required double mapHeightPx,
  required double zoom,
  double pinScreenFraction = kMapPinFocusPinScreenFraction,
}) {
  if (mapHeightPx <= 0) return pinLat;
  // 78271.517 = earthCircumference (40075016.686 m) / 512.
  final metresPerPixel =
      78271.517 * math.cos(pinLat * math.pi / 180.0) / math.pow(2, zoom);
  // The camera centre sits at screen fraction 0.5; the pin at `pinScreenFraction`
  // (above centre when < 0.5). To lift the pin up by that gap, the centre must be
  // that many metres SOUTH of the pin (smaller latitude).
  final metresPinIsAboveCentre =
      (0.5 - pinScreenFraction) * mapHeightPx * metresPerPixel;
  return pinLat - metresPinIsAboveCentre / 111320.0;
}
