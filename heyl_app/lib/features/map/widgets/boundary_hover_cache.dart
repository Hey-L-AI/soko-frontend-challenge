import '../../../data/models/models.dart';
import '../utils/point_in_polygon.dart';

/// Session cache of resolved boundaries for hover. Positive-only: stores every
/// boundary that has geometry, so a cursor over a known area highlights with no
/// network. Plus a cell-change throttle that stops re-resolving the same coarse
/// spot — it NEVER suppresses a cache hit and is NEVER consulted by click.
class BoundaryHoverCache {
  final List<GeoBoundary> _boundaries = [];
  String? _lastAttemptCell;

  /// Coarse ~111 m cell (3 decimals) for the resolve throttle.
  static String _cell(double lat, double lng) =>
      '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';

  void add(GeoBoundary b) {
    if (b.geometry == null) return; // can't point-in-polygon a capped boundary
    if (_boundaries.any((e) => e.id == b.id)) return;
    _boundaries.add(b);
  }

  /// Tightest cached boundary containing the point, or null.
  GeoBoundary? lookup(double lat, double lng) {
    GeoBoundary? best;
    for (final b in _boundaries) {
      final bb = b.bbox;
      if (lat > bb.north || lat < bb.south || lng > bb.east || lng < bb.west) {
        continue; // bbox pre-reject
      }
      if (!pointInPolygon(lat, lng, b.geometry!)) continue;
      if (best == null || _tighter(b, best)) best = b;
    }
    return best;
  }

  /// True when [a] is tighter than [b]: higher admin level, then smaller bbox area.
  bool _tighter(GeoBoundary a, GeoBoundary b) {
    if (a.adminLevel != b.adminLevel) return a.adminLevel > b.adminLevel;
    return _bboxArea(a) < _bboxArea(b);
  }

  double _bboxArea(GeoBoundary b) =>
      (b.bbox.north - b.bbox.south).abs() * (b.bbox.east - b.bbox.west).abs();

  /// True iff the coarse cell changed since the last attempt; records it.
  bool shouldResolve(double lat, double lng) {
    final cell = _cell(lat, lng);
    if (cell == _lastAttemptCell) return false;
    _lastAttemptCell = cell;
    return true;
  }
}
