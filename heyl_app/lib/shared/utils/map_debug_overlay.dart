/// PROD-2971 — build the admin map **debug overlay** GeoJSON from a
/// [MapDebugArea]. ONE builder shared by both platforms (native + web) so the
/// overlay geometry + colours can never drift between them — each platform just
/// feeds the result into a single GeoJSON source styled by per-feature colour
/// (`['get', 'fill_color']` / `['get', 'line_color']` / `['get', 'line_width']`).
///
/// Shapes (distinct colours), all in geographic coords so they track the camera
/// for free (same trick as the user-location accuracy ring):
///   • retrieval circle — THE fetch area (orange). Its overhang past the visible
///     box is where most "missing/extra pin" bugs live.
///   • input viewport box — the visible rect (blue, v2 only).
///   • sargable bbox — the index pre-filter box (purple).
///   • grid cells — the world-selection grid (faint ink lines).
///   • v2 selection rect — the server selection viewport (green, v2 only).
///
/// The debug panel can toggle shapes individually — pass the enabled set as
/// [buildMapDebugOverlayGeoJson]'s `shapes`; null = all on. [kMapDebugShapeStyles]
/// is the single source of truth for each shape's key / label / colours, shared
/// by the builder AND the panel's legend so they can't drift.
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'geo_circle.dart' show accuracyCircleRing;
import '../../data/models/map_debug.dart';

/// PROD-3063: soft OBSERVABILITY bound on `debug.grid.cells` — not a draw cap.
/// The cell count is bounded by construction, verified against the backend
/// source (`api_map.py` `_build_debug` + `heyl/core/geo/grid.py`): the debug
/// block buckets the fetched pool into the RETRIEVAL lattice, whose cell size
/// scales with the search radius to target ~13 cells across the 2R box
/// (`DEFAULT_CELLS_PER_SIDE`, power-of-two snapped), and only OCCUPIED cells
/// are returned — so cells ≤ min(occupied lattice cells ≈ a few hundred after
/// snap, pool size ≤ ~600). Realistic payloads are ~10–170 cells; all are
/// line-only outline polygons, trivial to draw. This constant sits beyond any
/// legitimate payload: exceeding it means the backend's debug semantics
/// changed. We still draw EVERY cell (silently truncating a debug tool would
/// itself be a bug) and just log the drift in debug builds.
const int kMapDebugGridCellSoftBound = 1000;

/// The distinct overlay shapes, each individually toggleable in the panel.
enum MapDebugShape {
  retrievalCircle,
  viewportBox,
  sargableBbox,
  gridCells,
  selectionRect,
}

/// Styling + labelling for one overlay shape. `lineRgba`/`fillRgba` feed the
/// GeoJSON (`fillRgba == _noFill` → line-only); `legendColor` is the same colour
/// as an ARGB [Color] for the panel's legend swatch. Colocated so the two
/// representations can't drift.
class MapDebugShapeStyle {
  final MapDebugShape shape;

  /// Matches the feature's `shape` property on the wire.
  final String key;
  final String label;
  final String lineRgba;
  final String fillRgba;
  final double width;
  final Color legendColor;

  const MapDebugShapeStyle({
    required this.shape,
    required this.key,
    required this.label,
    required this.lineRgba,
    required this.fillRgba,
    required this.width,
    required this.legendColor,
  });
}

const String _noFill = 'rgba(0, 0, 0, 0)';

/// Single source of truth for the shape styling (builder + legend).
const List<MapDebugShapeStyle> kMapDebugShapeStyles = [
  MapDebugShapeStyle(
    shape: MapDebugShape.retrievalCircle,
    key: 'retrieval_circle',
    label: 'Retrieval circle',
    lineRgba: 'rgba(249, 115, 22, 0.95)',
    fillRgba: 'rgba(249, 115, 22, 0.07)',
    width: 2.0,
    legendColor: Color(0xF2F97316), // orange
  ),
  MapDebugShapeStyle(
    shape: MapDebugShape.viewportBox,
    key: 'viewport_box',
    label: 'Viewport box',
    lineRgba: 'rgba(37, 99, 235, 0.90)',
    fillRgba: _noFill,
    width: 1.5,
    legendColor: Color(0xE62563EB), // blue
  ),
  MapDebugShapeStyle(
    shape: MapDebugShape.sargableBbox,
    key: 'sargable_bbox',
    label: 'Sargable bbox',
    lineRgba: 'rgba(147, 51, 234, 0.80)',
    fillRgba: _noFill,
    width: 1.5,
    legendColor: Color(0xCC9333EA), // purple
  ),
  MapDebugShapeStyle(
    shape: MapDebugShape.gridCells,
    key: 'grid_cell',
    label: 'Grid cells',
    lineRgba: 'rgba(17, 24, 39, 0.22)',
    fillRgba: _noFill,
    width: 0.6,
    legendColor: Color(0x38111827), // faint ink
  ),
  MapDebugShapeStyle(
    shape: MapDebugShape.selectionRect,
    key: 'selection_rect',
    label: 'Selection rect',
    lineRgba: 'rgba(34, 197, 94, 0.95)',
    fillRgba: 'rgba(34, 197, 94, 0.06)',
    width: 2.0,
    legendColor: Color(0xF222C55E), // green
  ),
];

MapDebugShapeStyle _style(MapDebugShape shape) =>
    kMapDebugShapeStyles.firstWhere((s) => s.shape == shape);

/// One GeoJSON `Polygon` feature from a closed `[lng,lat]` ring, styled from a
/// shape's [MapDebugShapeStyle] (read by the layers via `get` expressions).
Map<String, dynamic> _polygonFeature(
  List<List<double>> ring,
  MapDebugShapeStyle style,
) => <String, dynamic>{
  'type': 'Feature',
  'geometry': <String, dynamic>{
    'type': 'Polygon',
    'coordinates': <dynamic>[ring],
  },
  'properties': <String, dynamic>{
    'shape': style.key,
    'fill_color': style.fillRgba,
    'line_color': style.lineRgba,
    'line_width': style.width,
  },
};

/// A closed rectangle ring (`[lng,lat]`, last == first) from bounds.
List<List<double>> _rectRing({
  required double latMin,
  required double latMax,
  required double lngMin,
  required double lngMax,
}) => <List<double>>[
  [lngMin, latMin],
  [lngMax, latMin],
  [lngMax, latMax],
  [lngMin, latMax],
  [lngMin, latMin],
];

// Geometry sanity guards — a malformed debug payload must never paint a
// screen-filling fill or throw. Skip a shape whose coords are out of range,
// whose box is inverted/zero-area, or whose circle radius is non-positive or
// absurdly large (the fetch radius is API-clamped to ≤50 km; 200 km is a
// generous ceiling that still rejects pathological values).
const double _maxCircleRadiusMeters = 200000;

bool _validLat(double v) => v.isFinite && v >= -90 && v <= 90;
bool _validLng(double v) => v.isFinite && v >= -180 && v <= 180;

bool _validBox(double latMin, double latMax, double lngMin, double lngMax) =>
    _validLat(latMin) &&
    _validLat(latMax) &&
    _validLng(lngMin) &&
    _validLng(lngMax) &&
    latMax > latMin &&
    lngMax > lngMin;

bool _validCircle(DebugLatLng center, double radiusMeters) =>
    _validLat(center.lat) &&
    _validLng(center.lng) &&
    radiusMeters.isFinite &&
    radiusMeters > 0 &&
    radiusMeters <= _maxCircleRadiusMeters;

/// Build the debug-overlay `FeatureCollection` (as a plain map) from [area],
/// including only the shapes in [shapes] (null = all). Returns an empty
/// collection when [area] is null or nothing is drawable — callers feed that
/// straight into the platform's GeoJSON source.
Map<String, dynamic> buildMapDebugOverlayGeoJson(
  MapDebugArea? area, {
  Set<MapDebugShape>? shapes,
}) {
  final features = <Map<String, dynamic>>[];
  bool on(MapDebugShape s) => shapes == null || shapes.contains(s);

  if (area != null) {
    // Retrieval circle — the fetch area (draw first so it sits under the boxes).
    final circle = area.retrievalCircle;
    if (on(MapDebugShape.retrievalCircle) &&
        circle != null &&
        _validCircle(circle.center, circle.radiusMeters)) {
      features.add(
        _polygonFeature(
          accuracyCircleRing(
            circle.center.lat,
            circle.center.lng,
            circle.radiusMeters,
          ),
          _style(MapDebugShape.retrievalCircle),
        ),
      );
    }

    // Visible viewport box (v2 only).
    final viewport = area.input?.viewportRect;
    if (on(MapDebugShape.viewportBox) &&
        viewport != null &&
        _validBox(
          viewport.sw.lat,
          viewport.ne.lat,
          viewport.sw.lng,
          viewport.ne.lng,
        )) {
      features.add(
        _polygonFeature(
          _rectRing(
            latMin: viewport.sw.lat,
            latMax: viewport.ne.lat,
            lngMin: viewport.sw.lng,
            lngMax: viewport.ne.lng,
          ),
          _style(MapDebugShape.viewportBox),
        ),
      );
    }

    // Sargable pre-filter bbox.
    final bbox = area.sargableBbox;
    if (on(MapDebugShape.sargableBbox) &&
        bbox != null &&
        _validBox(bbox.latMin, bbox.latMax, bbox.lngMin, bbox.lngMax)) {
      features.add(
        _polygonFeature(
          _rectRing(
            latMin: bbox.latMin,
            latMax: bbox.latMax,
            lngMin: bbox.lngMin,
            lngMax: bbox.lngMax,
          ),
          _style(MapDebugShape.sargableBbox),
        ),
      );
    }

    // World-grid cells (line-only, faint). Count is bounded by construction
    // (occupied retrieval-lattice cells ∩ pool — see
    // [kMapDebugGridCellSoftBound]); the guard below observes contract drift
    // without ever truncating the draw.
    if (on(MapDebugShape.gridCells)) {
      final cellCount = area.grid?.cells.length ?? 0;
      if (kDebugMode && cellCount > kMapDebugGridCellSoftBound) {
        debugPrint(
          'map debug overlay: grid.cells=$cellCount exceeds the '
          'by-construction bound ($kMapDebugGridCellSoftBound) — backend '
          'selection semantics may have drifted (PROD-3063).',
        );
      }
      final gridStyle = _style(MapDebugShape.gridCells);
      for (final cell in area.grid?.cells ?? const <MapDebugGridCell>[]) {
        if (!_validBox(
          cell.box.latMin,
          cell.box.latMax,
          cell.box.lngMin,
          cell.box.lngMax,
        )) {
          continue;
        }
        features.add(
          _polygonFeature(
            _rectRing(
              latMin: cell.box.latMin,
              latMax: cell.box.latMax,
              lngMin: cell.box.lngMin,
              lngMax: cell.box.lngMax,
            ),
            gridStyle,
          ),
        );
      }
    }

    // v2 selection rectangle (draw last so it reads on top).
    final selection = area.selectionViewport?.rect;
    if (on(MapDebugShape.selectionRect) &&
        selection != null &&
        _validBox(
          selection.sw.lat,
          selection.ne.lat,
          selection.sw.lng,
          selection.ne.lng,
        )) {
      features.add(
        _polygonFeature(
          _rectRing(
            latMin: selection.sw.lat,
            latMax: selection.ne.lat,
            lngMin: selection.sw.lng,
            lngMax: selection.ne.lng,
          ),
          _style(MapDebugShape.selectionRect),
        ),
      );
    }
  }

  return <String, dynamic>{'type': 'FeatureCollection', 'features': features};
}
