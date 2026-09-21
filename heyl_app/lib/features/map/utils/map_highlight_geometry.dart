/// PROD-2993 — **does the camera actually need to move?**
///
/// The answer is usually *no*, and that is the whole point of this file.
///
/// The results grid is derived from the map viewport (it lists
/// `mapSettledSelectionProvider.visiblePins`), so **every card's pin is already
/// on the map** by construction. Re-framing on every scroll — the obvious
/// reading of the ticket — would therefore move the camera for no reason most of
/// the time, which is the documented "the map jigs around" anti-pattern and is
/// something no major map app does.
///
/// There is exactly one real problem: the drawer at `half` **covers** the bottom
/// of the map. The camera deliberately reserves only the drawer's *peek* chrome
/// (PROD-3043 decision #7 — it must not re-frame as the drawer is dragged), so
/// pins can legitimately sit **underneath** an opened drawer. Those, and only
/// those, need the camera's help.
///
/// So: highlight always, move only when a highlighted pin is hidden.
///
/// ## Why this can work in geographic space
///
/// The Map page's camera is **north-up** (bearing and pitch are disabled). In a
/// north-up Web Mercator projection, screen X is linear in longitude and screen
/// Y is linear in *Mercator* Y. So a horizontal band of the screen maps to a
/// horizontal band of Mercator Y, exactly — no camera matrix, no platform call,
/// no projection round-trip through the renderer. Both renderers already lean on
/// this (see `mapbox_map_native.dart` — "Longitude is linear in screen X
/// (north-up Web Mercator)").
///
/// That makes all of this pure, synchronous, and testable.
library;

import 'dart:math' as math;

import '../../../data/models/map_pin.dart' show MapPin;
import '../../../shared/widgets/map_marker_model.dart'
    show MapPinIconTokens, kMapSearchAreaMarginFraction;
import 'map_grid_selection.dart' show MapViewport;

/// Web-Mercator is undefined at the poles — the standard clamp.
const double _kMaxMercatorLat = 85.05112878;

/// Breathing room (px) left around the pins when the camera does re-frame, on
/// top of the chrome insets. Without it a pin lands flush against the drawer's
/// top edge or the shortcut chips and reads as clipped.
///
/// PROD-3626 — this is now a **floor**, not the margin itself. On its own it was
/// too small for both of the things a fit margin has to clear, and
/// [mapFitMarginsFor] is what derives the real value. Kept because it is still
/// the right minimum breathing room on a small viewport, where both derived
/// terms shrink below it.
const double kMapHighlightFitMarginPx = 24;

/// Normalised Web-Mercator Y in `[0, 1)` (0 = north edge, 1 = south edge).
double mercatorY(double lat) {
  final clamped = lat.clamp(-_kMaxMercatorLat, _kMaxMercatorLat);
  final s = math.sin(clamped * math.pi / 180.0);
  return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
}

/// Inverse of [mercatorY].
double latFromMercatorY(double y) {
  final n = math.pi * (1 - 2 * y);
  return (180.0 / math.pi) * math.atan(_sinh(n));
}

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

/// A geographic rectangle.
class LatLngBounds {
  final double south;
  final double west;
  final double north;
  final double east;

  const LatLngBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  bool contains(double lat, double lng) =>
      lat >= south && lat <= north && lng >= west && lng <= east;
}

/// PROD-3566 — the bounding box of [pins], or null when none of them has
/// coordinates.
///
/// Null is a real answer, not a failure: a list can hold only items that were
/// never geocoded, and the caller's correct response is to leave the camera
/// where it is rather than fly to an arbitrary point. A single pin yields a
/// degenerate (zero-span) box, which [fitCameraForBox] already handles by
/// centring at its max zoom.
///
/// Antimeridian-naive, like every other box on this page: a list spanning
/// ±180° would frame the long way round. No corpus we serve does, and the
/// alternative is a wrapping-aware camera the renderers don't accept anyway.
///
/// This is only the **projection** — dropping pins the backend never geocoded
/// and handing the rest to [boundsOf]. The min/max is deliberately not
/// repeated here: `MapPin` differs from [HighlightPoint] solely in that its
/// coordinates are nullable, and that is the whole of what this adds.
LatLngBounds? boundsOfPins(Iterable<MapPin> pins) => boundsOf([
  for (final p in pins)
    if (p.lat != null && p.lng != null) HighlightPoint(p.lat!, p.lng!),
]);

/// The part of [viewport] the user can actually **see** — the full map rect
/// minus the chrome painted over it.
///
/// [topInsetPx] is the search field + shortcut-chips row; [bottomInsetPx] is the
/// drawer at its CURRENT height (not its peek height — that is precisely the
/// difference this function exists to capture). [mapHeightPx] is the map's own
/// box height, which both insets are measured in.
///
/// Returns null when the chrome has eaten the whole map (a very short viewport,
/// a huge text scale) — the caller then has no basis to judge occlusion and must
/// leave the camera alone rather than guess.
LatLngBounds? visibleMapBounds({
  required MapViewport viewport,
  required double mapHeightPx,
  required double topInsetPx,
  required double bottomInsetPx,
}) {
  if (mapHeightPx <= 0) return null;
  final usableTop = topInsetPx;
  final usableBottom = mapHeightPx - bottomInsetPx;
  if (usableBottom <= usableTop) return null;

  // Screen Y ↔ Mercator Y is linear (north-up), so the band maps straight over.
  final mercNorth = mercatorY(viewport.neLat); // smaller y
  final mercSouth = mercatorY(viewport.swLat); // larger y
  final span = mercSouth - mercNorth;
  if (span <= 0) return null;

  final mercVisibleTop = mercNorth + (usableTop / mapHeightPx) * span;
  final mercVisibleBottom = mercNorth + (usableBottom / mapHeightPx) * span;

  return LatLngBounds(
    north: latFromMercatorY(mercVisibleTop),
    south: latFromMercatorY(mercVisibleBottom),
    // No horizontal chrome — the map is full-bleed left-to-right.
    west: viewport.swLng,
    east: viewport.neLng,
  );
}

/// One highlighted pin's position.
class HighlightPoint {
  final double lat;
  final double lng;
  const HighlightPoint(this.lat, this.lng);
}

/// The bounding box of [points], or null when there are none.
///
/// A single point yields a zero-area box — legal, and the renderers' `fitBounds`
/// handles it (they clamp with `maxZoom`); it simply centres on that point.
LatLngBounds? boundsOf(Iterable<HighlightPoint> points) {
  double? s, w, n, e;
  for (final p in points) {
    s = (s == null || p.lat < s) ? p.lat : s;
    n = (n == null || p.lat > n) ? p.lat : n;
    w = (w == null || p.lng < w) ? p.lng : w;
    e = (e == null || p.lng > e) ? p.lng : e;
  }
  if (s == null) return null;
  return LatLngBounds(south: s, west: w!, north: n!, east: e!);
}

/// Mapbox GL uses 512 px tiles: the whole world spans `512 · 2^z` px at zoom z.
const double _kTileSizePx = 512.0;

/// A camera position.
class MapCameraTargetLatLngZoom {
  final double lat;
  final double lng;
  final double zoom;
  const MapCameraTargetLatLngZoom({
    required this.lat,
    required this.lng,
    required this.zoom,
  });
}

/// PROD-3498 — sane zoom bounds for a location-search fit. The lower bound
/// stops a country-sized boundary from slamming the camera to a world view
/// (and pulling a 50 km-capped `/map/pins` fetch over an area it can't
/// meaningfully cover); the upper bound stops a one-block area from landing
/// at building level.
const double kMapLocationFitMinZoom = 9.0;
const double kMapLocationFitMaxZoom = 15.0;

/// PROD-3566 — the lower bound for a **list** fit, which is a different
/// problem from a location fit.
///
/// [kMapLocationFitMinZoom]'s reasoning does not transfer: it exists partly
/// because a location search still fetches through a 50 km-capped
/// `/map/pins`, so framing wider than the fetch would show an area the map
/// can't cover. A list sends `ignore_radius` precisely so the WHOLE corpus
/// comes back however far it spans — "a curated list may span cities and
/// should show whole" — and at z9 a phone shows roughly 45 km, so a
/// Lisbon-to-Porto Zine would frame almost none of itself.
///
/// Still floored rather than unbounded: one pin with broken coordinates (the
/// classic 0,0) would otherwise drag the box across the planet. z2 caps the
/// damage at a continent-scale view, which is honest for a genuinely global
/// list and visibly wrong for a bad one.
const double kMapListFitMinZoom = 2.0;

/// PROD-3626 — the margins one fit needs, per edge, in logical px.
///
/// [top]/[bottom] are what a caller adds **on top of** its chrome insets;
/// [horizontal] is the whole margin (the map is full-bleed left-to-right).
class MapFitMargins {
  final double top;
  final double bottom;
  final double horizontal;
  const MapFitMargins({
    required this.top,
    required this.bottom,
    required this.horizontal,
  });
}

/// PROD-3626 — **the margin a fit must leave so a framed pin is both drawn and
/// actually selected.**
///
/// The bug this exists to kill: [kMapHighlightFitMarginPx] was used raw as the
/// margin on every edge, and 24 px is smaller than *both* of the things a fit
/// margin has to clear. Two independent mechanisms, one root cause — the fit
/// framed pins to a boundary that the rest of the page then disagreed with.
///
///  1. **The pin is not selected at all.** The camera rect the renderers report
///     to `onCameraIdle` — which becomes `MapQuery.sw/ne`, which is what
///     `mapSelectionProvider` runs `viewport.contains` against, and what the
///     debug "selection rect" draws — is the canvas minus the chrome insets
///     **and then pulled [kMapSearchAreaMarginFraction] further in on all four
///     sides** (PROD-2671, `_visibleRectCameraState` in both platform impls).
///     That inset is a *fraction*, so on a phone it is ~26 px vertically —
///     larger than the 24 px the fit was leaving. A pin framed exactly at the
///     old margin therefore landed **outside the selection rect and was never
///     plotted**. Measured on a 393×852 canvas framing a Lisbon→Porto list: the
///     northern pin's anchor at y=174.0 against a rect starting at y=176.1.
///     This is why pins went *missing* rather than merely clipped, and no
///     amount of extra padding alone would have fixed it — the two numbers have
///     to be derived from the same place, which is what this function does.
///
///  2. **The pin's art is under the chrome.** [fitCameraForBox] frames pin
///     *anchor coordinates*, but a pin is drawn as bottom-anchored art
///     ([MapPinIconTokens.sourceHeightPx] × the zoom's icon size) extending
///     **upward** from its anchor. At the widest icon stop that is 44 px — so
///     an anchor 24 px below the search bar puts 20 px of pin behind it.
///
/// Hence: per edge, the max of the selection inset, the rendered art extent in
/// that direction, and [kMapHighlightFitMarginPx] as the small-viewport floor.
///
/// **Deliberately not label-aware.** A caption extends to the right by an
/// unbounded text width; sizing the margin to it would let one long name
/// ("Bolhão a Gosto - Comida Tradicional") zoom the whole corpus out and crowd
/// every other pin. Zé's call, 2026-08-03: **pin art always fully visible,
/// labels may clip.** The caption is offset *up by one pin height*, so it never
/// extends above the art and the top margin covers it either way.
///
/// [selectionBottomInsetPx] is the inset the **renderer** was given
/// (`searchAreaBottomInset` — the drawer's *peek* height), which is what sizes
/// the selection rect. It is not always the caller's own bottom chrome: a fit
/// run while the drawer is open pads for the taller occluded height, and the
/// extra slack is harmless.
///
/// [iconSizeMul] scales the art term for callers that fit while every pin is
/// enlarged ([kMapHighlightSizeMul], the narrow half-drawer). Defaults to 1.
MapFitMargins mapFitMarginsFor({
  required double mapWidthPx,
  required double mapHeightPx,
  required double topChromeInsetPx,
  required double selectionBottomInsetPx,
  double iconSizeMul = 1.0,
}) {
  // The strip the renderer measures its fractional inset against.
  final visibleHeight =
      mapHeightPx - topChromeInsetPx - selectionBottomInsetPx;
  // Land pins STRICTLY inside the selection rect, not exactly on its edge.
  // Matching it precisely is what the old code effectively did on the axes
  // where it happened to be big enough, and a pin sitting on the boundary is
  // one rounding difference — between our Mercator maths and the renderer's own
  // unproject — away from being dropped again. 1 px is imperceptible and
  // decisive.
  const strictlyInsidePx = 1.0;
  final selectionInsetY =
      (visibleHeight > 0 ? visibleHeight : mapHeightPx) *
          kMapSearchAreaMarginFraction +
      strictlyInsidePx;
  final selectionInsetX =
      mapWidthPx * kMapSearchAreaMarginFraction + strictlyInsidePx;

  // Worst case across the zoom curve: the fit's own zoom is its output, so
  // picking the widest stop keeps this non-circular (and a list fit lands in
  // the zoomed-out arm, where that stop is the one in force anyway).
  final maxIconSize = MapPinIconTokens.iconSizeStops
      .map((s) => s.$2)
      .reduce(math.max);
  // …and the per-pin score multiplier rides the SAME `icon_scale` property
  // (PROD-2947), so a top-ranked pin draws 1.15× the stop. Sizing to the stop
  // alone leaves the most relevant pin — the one most likely to be worth
  // seeing — with its art still under the chrome. Read from the function
  // rather than hardcoded so a re-tuned curve carries through.
  final maxScoreScale = MapPinIconTokens.scoreSizeMultiplier(1.0);
  final artScale = maxIconSize * maxScoreScale * iconSizeMul;
  // Bottom-anchored: the art is entirely ABOVE the anchor, so only the top
  // edge owes it height. Left/right owe half a width.
  final artTop = MapPinIconTokens.sourceHeightPx * artScale;
  final artHalfWidth = MapPinIconTokens.sourceWidthPx * artScale / 2;

  double atLeastFloor(double a, double b) =>
      math.max(math.max(a, b), kMapHighlightFitMarginPx);

  return MapFitMargins(
    top: atLeastFloor(artTop, selectionInsetY),
    // Nothing is drawn below the anchor, so the bottom owes only the selection.
    bottom: atLeastFloor(0, selectionInsetY),
    horizontal: atLeastFloor(artHalfWidth, selectionInsetX),
  );
}

/// PROD-3498 — **the camera that frames an arbitrary geographic box**, for a
/// location selected from the v2 search dropdown (Decision #19: camera only).
///
/// Same north-up Mercator maths as [fitCameraFor] and the same reason for
/// existing — this page must never hand a bbox to the renderers' `boundsConfig`
/// (they refit whenever `boundsConfig.hasBbox && markersChanged`, and the Map
/// page rebuilds markers on every camera move, so the camera would drive itself
/// from its own output; see `map_screen.dart`'s `_centerToToken` doc).
///
/// It differs from [fitCameraFor] in one deliberate way: **it may zoom IN.**
/// [fitCameraFor] treats the user's current zoom as a ceiling because a results
/// highlight is not a reason to overrule them. A location *selection* is the
/// opposite — picking "Alvalade" from a country-wide view must zoom in, that IS
/// the request. The zoom is instead clamped to
/// [kMapLocationFitMinZoom]/[kMapLocationFitMaxZoom].
///
/// Like [fitCameraFor] it centres the box in the **visible band** (the drawer
/// covers the bottom), not in the raw map box. Returns null when the box or the
/// available space is degenerate — the caller then centres on the box's centre
/// at a default zoom instead.
MapCameraTargetLatLngZoom? fitCameraForBox({
  required LatLngBounds box,
  required double mapWidthPx,
  required double mapHeightPx,
  required double padTopPx,
  required double padBottomPx,
  required double padHorizontalPx,
  double minZoom = kMapLocationFitMinZoom,
  double maxZoom = kMapLocationFitMaxZoom,
}) {
  if (mapWidthPx <= 0 || mapHeightPx <= 0) return null;

  final availW = mapWidthPx - 2 * padHorizontalPx;
  final availH = mapHeightPx - padTopPx - padBottomPx;
  if (availW <= 0 || availH <= 0) return null;

  final xWest = (box.west + 180.0) / 360.0;
  final xEast = (box.east + 180.0) / 360.0;
  final yNorth = mercatorY(box.north);
  final ySouth = mercatorY(box.south);

  final dx = (xEast - xWest).abs();
  final dy = (ySouth - yNorth).abs();

  // The widest world (deepest zoom) that still fits the box in the available
  // pixels. A zero span on an axis constrains nothing; a point box constrains
  // neither, so the zoom lands on the clamp's upper end (as close in as we're
  // willing to go for a location pick).
  double worldPx = double.infinity;
  if (dx > 0) worldPx = math.min(worldPx, availW / dx);
  if (dy > 0) worldPx = math.min(worldPx, availH / dy);

  final double zoom;
  if (worldPx.isInfinite) {
    zoom = maxZoom;
  } else {
    final z = math.log(worldPx / _kTileSizePx) / math.ln2;
    if (!z.isFinite) return null;
    zoom = z.clamp(minZoom, maxZoom);
  }

  final world = _kTileSizePx * math.pow(2, zoom).toDouble();
  final xCentre = (xWest + xEast) / 2;
  final yCentre = (yNorth + ySouth) / 2;

  final bandCentreFractionY =
      ((padTopPx + (mapHeightPx - padBottomPx)) / 2) / mapHeightPx;
  final camY = yCentre + (0.5 - bandCentreFractionY) * (mapHeightPx / world);

  return MapCameraTargetLatLngZoom(
    lat: latFromMercatorY(camY.clamp(0.0, 1.0)),
    lng: xCentre * 360.0 - 180.0,
    zoom: zoom,
  );
}

/// **The camera that frames [points] inside the un-occluded strip of the map.**
///
/// Deliberately hand-rolled instead of handing a bbox to the renderers'
/// `fitBounds`. On this page that would be a trap: both platforms refit whenever
/// `boundsConfig.hasBbox` **and the marker list changed** — and the Map page's
/// markers are rebuilt on *every camera move* (live re-selection, PROD-2807 #4).
/// A persistent `boundsConfig` would therefore refit the camera on its own
/// output, forever. Driving the camera purely by an imperative token has no such
/// coupling — and the maths is pure, so it can be tested rather than eyeballed.
///
/// Two deliberate properties:
///
///  * **It never zooms IN.** [currentZoom] is the ceiling. The user chose that
///    zoom; a highlight is not a reason to overrule them, and a tightly-clustered
///    pair of pins would otherwise slam the camera to street level. The camera
///    only ever pans, or widens when it genuinely must.
///  * **It centres the points in the VISIBLE band, not in the map box.** The
///    drawer covers the bottom, so centring in the box would park the pins
///    underneath it — which is the exact bug this whole feature exists to fix.
///
/// Returns null when there is nothing to frame or the chrome has eaten the map.
MapCameraTargetLatLngZoom? fitCameraFor({
  required List<HighlightPoint> points,
  required double mapWidthPx,
  required double mapHeightPx,
  required double padTopPx,
  required double padBottomPx,
  required double padHorizontalPx,
  required double currentZoom,
}) {
  final b = boundsOf(points);
  if (b == null || mapWidthPx <= 0 || mapHeightPx <= 0) return null;

  final availW = mapWidthPx - 2 * padHorizontalPx;
  final availH = mapHeightPx - padTopPx - padBottomPx;
  if (availW <= 0 || availH <= 0) return null;

  // Normalised world coordinates in [0, 1].
  final xWest = (b.west + 180.0) / 360.0;
  final xEast = (b.east + 180.0) / 360.0;
  final yNorth = mercatorY(b.north);
  final ySouth = mercatorY(b.south);

  final dx = (xEast - xWest).abs();
  final dy = (ySouth - yNorth).abs();

  // The widest world (i.e. the deepest zoom) that still fits the box in the
  // available pixels. A zero span on an axis puts no constraint on it — a single
  // point constrains neither, so the zoom simply stays put.
  double worldPx = double.infinity;
  if (dx > 0) worldPx = math.min(worldPx, availW / dx);
  if (dy > 0) worldPx = math.min(worldPx, availH / dy);

  final double zoom;
  if (worldPx.isInfinite) {
    zoom = currentZoom;
  } else {
    final z = math.log(worldPx / _kTileSizePx) / math.ln2;
    // Never zoom IN past where the user already is — see the doc above.
    zoom = z.isFinite ? math.min(z, currentZoom) : currentZoom;
  }

  // With the zoom settled, place the camera so the points land in the band the
  // user can actually see.
  final world = _kTileSizePx * math.pow(2, zoom).toDouble();
  final xCentre = (xWest + xEast) / 2;
  final yCentre = (yNorth + ySouth) / 2;

  // Where the middle of the visible band sits, as a fraction of the map box.
  final bandCentreFractionY =
      ((padTopPx + (mapHeightPx - padBottomPx)) / 2) / mapHeightPx;

  // The camera's centre is the middle of the FULL box (fraction 0.5). Offset it
  // so `yCentre` lands on the band's centre instead. `mapHeightPx / world` is
  // the box's height in normalised world units.
  final camY = yCentre + (0.5 - bandCentreFractionY) * (mapHeightPx / world);

  // No horizontal chrome, so the box centre and the band centre coincide.
  return MapCameraTargetLatLngZoom(
    lat: latFromMercatorY(camY.clamp(0.0, 1.0)),
    lng: xCentre * 360.0 - 180.0,
    zoom: zoom,
  );
}

/// PROD-2993 D11(c) — **re-frame the camera when the drawer shrinks.**
///
/// The visible strip of map at `half` sits *above* the map's true centre (the
/// drawer eats the bottom). At `peek` the visible area is much taller and its
/// centre is far lower. So handing the same camera centre to both leaves the
/// thing the user was studying drifting up the screen the moment the drawer
/// closes.
///
/// This returns the camera centre that keeps [viewport]'s **currently visible
/// strip** centred once the chrome becomes [nextBottomInsetPx] tall instead of
/// [bottomInsetPx].
///
/// Only the latitude moves — no horizontal chrome changes, so longitude is
/// already centred. Returns null when either state is degenerate.
double? recenteredLatForChrome({
  required MapViewport viewport,
  required double mapHeightPx,
  required double topInsetPx,
  required double bottomInsetPx,
  required double nextBottomInsetPx,
}) {
  final current = visibleMapBounds(
    viewport: viewport,
    mapHeightPx: mapHeightPx,
    topInsetPx: topInsetPx,
    bottomInsetPx: bottomInsetPx,
  );
  if (current == null) return null;
  if (mapHeightPx <= 0) return null;

  // Where the user's attention actually is: the middle of the strip they can see.
  final focusMercY = (mercatorY(current.north) + mercatorY(current.south)) / 2;

  // Where the middle of the NEXT visible strip will sit, as a fraction of the
  // map box (0 = top edge, 1 = bottom edge).
  final nextUsableTop = topInsetPx;
  final nextUsableBottom = mapHeightPx - nextBottomInsetPx;
  if (nextUsableBottom <= nextUsableTop) return null;
  final nextFocusFraction =
      ((nextUsableTop + nextUsableBottom) / 2) / mapHeightPx;

  // The camera centre is the middle of the FULL map box (fraction 0.5). Shift it
  // so that `focusMercY` lands at `nextFocusFraction` instead.
  final mercNorth = mercatorY(viewport.neLat);
  final mercSouth = mercatorY(viewport.swLat);
  final span = mercSouth - mercNorth;
  if (span <= 0) return null;

  final centreMercY = focusMercY + (0.5 - nextFocusFraction) * span;
  return latFromMercatorY(centreMercY.clamp(0.0, 1.0));
}
