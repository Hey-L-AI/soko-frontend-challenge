/// PROD-3833 — Web-Mercator maths for the Map page's **opening** camera,
/// computed in Dart so the first `/map/pins` request no longer has to wait for
/// Mapbox to exist.
///
/// Why this file exists: the opening viewport used to be obtainable only from a
/// live map — web bounced `setZoom(target) → getBounds() → setZoom(birth)`, and
/// native asked `coordinateBoundsForCamera(...)`. Both need a `Map` instance,
/// which needs the script, the style and the first tile set. That put a network
/// round trip's worth of latency in front of the request that draws the pins.
/// For a north-up map (bearing 0, pitch 0 — the Map page never rotates) the
/// same rectangle is ten lines of arithmetic.
///
/// **Conventions that are load-bearing** (all three were review findings):
///
///  * **512-pixel tiles.** Mapbox GL sizes the world as `512 · 2^zoom`
///    *logical* pixels. The 256-tile constant (`156543.03` m/px at z0) that
///    `zoomForRadius` uses belongs to the OSM/Google convention and is one zoom
///    level off from what Mapbox reports back. Do not mix them here.
///  * **Logical (CSS) pixels, no device-pixel-ratio factor.** Zoom is defined
///    against CSS px on web, and both renderers take their box from a
///    `LayoutBuilder`, which is already logical.
///  * **The padded convention.** [openingCameraState]'s centre is the centre of
///    the *visible* rect (the canvas minus the top chrome and the drawer), not
///    of the canvas. That is where the camera actually rests once the viewport
///    padding applies, and it is what the web renderer already reports.
library;

import 'dart:math' as math;

import '../widgets/map_marker_model.dart'
    show MapCameraState, kMapSearchAreaMarginFraction;

/// The latitude Web Mercator can represent — beyond it the projection runs to
/// infinity. Mapbox clamps to the same value, so a viewport computed here can
/// never claim to see further north/south than the map itself can.
const double kWebMercatorMaxLat = 85.051128779806604;

/// Mapbox GL's world width in logical pixels at [zoom] (512-px tiles).
double mapWorldPx(double zoom) => 512.0 * math.pow(2.0, zoom);

/// Web-Mercator projected Y from latitude, in radians-equivalent units
/// (`ln(tan(π/4 + φ/2))`, so the full world spans `2π`). Unnormalised — only
/// ever used for interpolation and for pixel offsets via [mapWorldPx], where a
/// consistent scale is all that matters. Mirror of the projection in
/// `map_grid_selection.dart`.
double mercYFromLat(double latDeg) {
  final clamped = latDeg.clamp(-kWebMercatorMaxLat, kWebMercatorMaxLat);
  final lat = clamped * math.pi / 180.0;
  return math.log(math.tan(math.pi / 4 + lat / 2));
}

/// Inverse of [mercYFromLat], clamped to the projection's usable range.
double latFromMercY(double y) {
  final lat = (2 * math.atan(math.exp(y)) - math.pi / 2) * 180.0 / math.pi;
  return lat.clamp(-kWebMercatorMaxLat, kWebMercatorMaxLat);
}

/// Wrap [lngDeg] into `[-180, 180)`.
///
/// Kept deliberately, rather than letting `centre ± halfSpan` run past ±180:
/// [MapCameraState.contains] reads a rectangle that crosses the antimeridian as
/// `swLng > neLng` and has a dedicated branch for it, so an unwrapped `181°`
/// would silently fail every containment test in the eastern sliver.
double normalizeLng(double lngDeg) {
  var lng = (lngDeg + 180.0) % 360.0;
  if (lng < 0) lng += 360.0;
  return lng - 180.0;
}

/// The camera state the Map page's opening view will settle into, computed
/// without a map instance.
///
/// [centerLat]/[centerLng] is the point the map opens on; [zoom] the target
/// (post-ease) zoom; [widthPx]/[heightPx] the map widget's box in logical
/// pixels; [paddingTop]/[paddingBottom] the chrome insets (top bar, results
/// drawer) that the search rectangle must exclude.
///
/// The returned rect is trimmed exactly as the renderers trim theirs: the
/// canvas minus the insets, then pulled in on all four sides by
/// [kMapSearchAreaMarginFraction] so items hugging the screen edge aren't
/// fetched. The returned centre equals the requested centre — see the padded
/// convention in this library's docs.
///
/// Returns null when the box has no usable area yet (first layout pass), so
/// callers can fall back rather than seed a degenerate rectangle.
MapCameraState? openingCameraState({
  required double centerLat,
  required double centerLng,
  required double zoom,
  required double widthPx,
  required double heightPx,
  double paddingTop = 0,
  double paddingBottom = 0,
}) {
  if (widthPx <= 0 || heightPx <= 0 || !zoom.isFinite) return null;

  // Clamp the insets the same way both renderers do, so chrome taller than the
  // canvas can't invert the rect.
  final top = paddingTop.clamp(0.0, heightPx - 1);
  final bottom = paddingBottom.clamp(0.0, heightPx - top - 1);
  final visHeight = heightPx - top - bottom;
  if (visHeight <= 0) return null;

  final marginX = widthPx * kMapSearchAreaMarginFraction;
  final marginY = visHeight * kMapSearchAreaMarginFraction;
  final halfWidthPx = (widthPx - 2 * marginX) / 2;
  final halfHeightPx = (visHeight - 2 * marginY) / 2;
  if (halfWidthPx <= 0 || halfHeightPx <= 0) return null;

  final worldPx = mapWorldPx(zoom);
  if (!worldPx.isFinite || worldPx <= 0) return null;
  final degPerPx = 360.0 / worldPx;
  final mercPerPx = (2 * math.pi) / worldPx;

  final centerMercY = mercYFromLat(centerLat);
  final north = latFromMercY(centerMercY + halfHeightPx * mercPerPx);
  final south = latFromMercY(centerMercY - halfHeightPx * mercPerPx);

  // A viewport wider than the world would wrap onto itself; clamp to a whole
  // world rather than emit a rect that claims to see the same meridian twice.
  final halfLngSpan = math.min(halfWidthPx * degPerPx, 180.0);

  return MapCameraState(
    centerLat: centerLat.clamp(-kWebMercatorMaxLat, kWebMercatorMaxLat),
    centerLng: normalizeLng(centerLng),
    zoom: zoom,
    neLat: north,
    neLng: normalizeLng(centerLng + halfLngSpan),
    swLat: south,
    swLng: normalizeLng(centerLng - halfLngSpan),
  );
}
