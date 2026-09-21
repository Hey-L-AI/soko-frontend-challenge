/// Axis-aligned lat/lng bounding box returned by the backend (currently on
/// `GeoCityDetail.bounding_box`). Used by the frontend to fit map views to
/// the whole area, regardless of where pins cluster.
///
/// All four corners are always present when a `BoundingBox` is returned —
/// the parent field is the place to express absence (nullable on the
/// container).
class BoundingBox {
  /// Max latitude (north edge).
  final double north;

  /// Min latitude (south edge).
  final double south;

  /// Max longitude (east edge).
  final double east;

  /// Min longitude (west edge).
  final double west;

  const BoundingBox({
    required this.north,
    required this.south,
    required this.east,
    required this.west,
  });

  factory BoundingBox.fromJson(Map<String, dynamic> json) {
    return BoundingBox(
      north: (json['north'] as num).toDouble(),
      south: (json['south'] as num).toDouble(),
      east: (json['east'] as num).toDouble(),
      west: (json['west'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'north': north,
    'south': south,
    'east': east,
    'west': west,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BoundingBox &&
        other.north == north &&
        other.south == south &&
        other.east == east &&
        other.west == west;
  }

  @override
  int get hashCode => Object.hash(north, south, east, west);

  @override
  String toString() =>
      'BoundingBox(n=$north, s=$south, e=$east, w=$west)';
}
