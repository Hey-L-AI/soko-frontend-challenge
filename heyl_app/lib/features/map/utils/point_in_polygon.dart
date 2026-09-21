/// Ray-casting point-in-polygon over a GeoJSON `Polygon` / `MultiPolygon`.
/// GeoJSON coordinates are `[lng, lat]`. Even-odd rule: a point inside an
/// outer ring but inside one of its holes is OUTSIDE. Pure — no Flutter deps.
bool pointInPolygon(double lat, double lng, Map<String, dynamic> geometry) {
  final type = geometry['type'] as String?;
  final coords = geometry['coordinates'] as List<dynamic>?;
  if (coords == null) return false;
  if (type == 'Polygon') return _inPolygon(lat, lng, coords);
  if (type == 'MultiPolygon') {
    for (final poly in coords) {
      if (_inPolygon(lat, lng, poly as List<dynamic>)) return true;
    }
    return false;
  }
  return false;
}

/// [rings]: first ring is the outer boundary; the rest are holes.
bool _inPolygon(double lat, double lng, List<dynamic> rings) {
  if (rings.isEmpty) return false;
  if (!_inRing(lat, lng, rings.first as List<dynamic>)) return false;
  for (var i = 1; i < rings.length; i++) {
    if (_inRing(lat, lng, rings[i] as List<dynamic>)) return false; // in a hole
  }
  return true;
}

/// Standard ray-casting on a single ring of `[lng, lat]` vertices.
bool _inRing(double lat, double lng, List<dynamic> ring) {
  var inside = false;
  final n = ring.length;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final pi = (ring[i] as List<dynamic>);
    final pj = (ring[j] as List<dynamic>);
    final xi = (pi[0] as num).toDouble(); // lng
    final yi = (pi[1] as num).toDouble(); // lat
    final xj = (pj[0] as num).toDouble();
    final yj = (pj[1] as num).toDouble();
    final intersect = ((yi > lat) != (yj > lat)) &&
        (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}
