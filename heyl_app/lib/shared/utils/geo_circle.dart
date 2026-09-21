import 'dart:math' as math;

/// PROD-2671 — the user-location **accuracy ring** is drawn as a real geodesic
/// circle polygon (a Mapbox `fill` layer), NOT a pixel-radius circle. A polygon
/// in geographic coordinates scales correctly with zoom on both web and native
/// — which the old DOM-overlay ring (removed by PROD-2016) did by recomputing
/// pixels on every zoom; a source-layer polygon gets that for free.
///
/// The ring is only meaningful when the fix is imprecise; below this radius we
/// don't draw it (a precise GPS fix would be a dot-sized ring). Matches the
/// original approximate-location feature's ≥50 m gate.
const double kAccuracyRingMinMeters = 50;

/// Semi-transparent blue accuracy-ring styling (matches the original DOM ring):
/// fill `rgba(59,130,246,0.12)`, outline `rgba(59,130,246,0.3)`.
const int kAccuracyRingFillColorArgb = 0x1F3B82F6; // alpha 0x1F ≈ 12%
const int kAccuracyRingLineColorArgb = 0x4D3B82F6; // alpha 0x4D ≈ 30%
const double kAccuracyRingLineWidth = 1.5;

/// A closed ring of `[lng, lat]` points approximating a circle of [radiusMeters]
/// around ([lat], [lng]) — the outer ring of a GeoJSON `Polygon`. Uses a local
/// equirectangular approximation (fine at accuracy-circle scales: metres–km).
/// The ring is explicitly closed (last point == first).
List<List<double>> accuracyCircleRing(
  double lat,
  double lng,
  double radiusMeters, {
  int segments = 64,
}) {
  const earthRadius = 6378137.0; // WGS-84 semi-major axis (metres)
  final latRad = lat * math.pi / 180.0;
  final cosLat = math.cos(latRad).abs();
  final ring = <List<double>>[];
  for (var i = 0; i <= segments; i++) {
    final theta = 2 * math.pi * (i % segments) / segments;
    final dxMeters = radiusMeters * math.cos(theta);
    final dyMeters = radiusMeters * math.sin(theta);
    final dLat = (dyMeters / earthRadius) * (180.0 / math.pi);
    // Guard the poles (cosLat → 0) so we never divide by ~zero.
    final dLng = cosLat < 1e-9
        ? 0.0
        : (dxMeters / (earthRadius * cosLat)) * (180.0 / math.pi);
    ring.add([lng + dLng, lat + dLat]);
  }
  return ring;
}
