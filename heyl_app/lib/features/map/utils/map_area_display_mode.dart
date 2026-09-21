import '../../../shared/utils/geo_circle.dart';
import '../../../shared/utils/map_zoom_level.dart';

/// Visual representation for the Map page's settled search area.
///
/// This is deliberately display-only. Phase 4 chooses whether a surface queries
/// `around` or `contain`; until then the polygon is context while the map keeps
/// querying its existing center + radius area.
enum MapAreaDisplayMode { polygon, radius }

/// City and neighbourhood framing is the band between the shared walking and
/// near-me camera steps. Wider framing has no stable local area to outline;
/// tighter framing is a street/spot search where a circle is more honest.
bool mapZoomWantsPolygon(double zoom) =>
    zoom >= kMapZoomWalkingStart && zoom < kMapZoomNearMeStart;

/// Chooses a polygon only when the current zoom calls for one and the backend
/// supplied geometry. The backend only exposes curated geometry, so its
/// presence is the app-side curation gate.
MapAreaDisplayMode mapAreaDisplayModeFor({
  required double zoom,
  required Map<String, dynamic>? boundaryGeometry,
  MapAreaDisplayMode? override,
}) => mapZoomWantsPolygon(zoom) && boundaryGeometry != null
    ? (override ?? MapAreaDisplayMode.polygon)
    : MapAreaDisplayMode.radius;

/// A person may choose the radius view only after the current camera resolved
/// a curated polygon. It keeps the control honest: no unavailable/uncurated
/// boundary can be selected.
bool canToggleMapAreaDisplay({
  required double zoom,
  required Map<String, dynamic>? boundaryGeometry,
}) => mapZoomWantsPolygon(zoom) && boundaryGeometry != null;

/// GeoJSON geometry for the current display mode. A missing/capped polygon
/// falls back to a real geodesic search circle, never a blank map.
Map<String, dynamic> mapAreaDisplayGeometry({
  required double zoom,
  required double centerLat,
  required double centerLng,
  required double radiusMeters,
  Map<String, dynamic>? boundaryGeometry,
  MapAreaDisplayMode? override,
}) {
  if (mapAreaDisplayModeFor(
        zoom: zoom,
        boundaryGeometry: boundaryGeometry,
        override: override,
      ) ==
      MapAreaDisplayMode.polygon) {
    return boundaryGeometry!;
  }

  return <String, dynamic>{
    'type': 'Polygon',
    'coordinates': <dynamic>[
      accuracyCircleRing(centerLat, centerLng, radiusMeters),
    ],
  };
}
