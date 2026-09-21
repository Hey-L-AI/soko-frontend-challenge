import 'dart:math' as math;

import '../../../shared/widgets/map_marker_model.dart';

/// A bounding box (as a [MapBoundsConfig]) that frames two points — used by the
/// picker's "fit both the search pin and the user dot" recenter step.
///
/// Antimeridian-naive on longitude: the two points here are always close
/// (a search centre and the device's own location), so a simple min/max is
/// correct in practice.
///
/// Guards against a degenerate (zero-area) box when the two points coincide —
/// e.g. the search pin sits exactly on the user's location. The imperative fit
/// path (`_fitToBboxConfig`) only checks `hasBbox`, not span, so a zero-area box
/// would zoom unpredictably; [minSpanDeg] (~100 m) expands tiny boxes around
/// their centre before framing.
MapBoundsConfig boundsForTwoPoints({
  required double aLat,
  required double aLng,
  required double bLat,
  required double bLng,
  int padding = 64,
  double maxZoom = 16,
  int duration = 500,
  double minSpanDeg = 0.0009,
}) {
  var north = math.max(aLat, bLat);
  var south = math.min(aLat, bLat);
  var east = math.max(aLng, bLng);
  var west = math.min(aLng, bLng);
  if (north - south < minSpanDeg) {
    final mid = (north + south) / 2;
    north = mid + minSpanDeg / 2;
    south = mid - minSpanDeg / 2;
  }
  if (east - west < minSpanDeg) {
    final mid = (east + west) / 2;
    east = mid + minSpanDeg / 2;
    west = mid - minSpanDeg / 2;
  }
  return MapBoundsConfig(
    north: north,
    south: south,
    east: east,
    west: west,
    padding: padding,
    maxZoom: maxZoom,
    duration: duration,
  );
}

/// Great-circle distance in metres (haversine) between two lat/lng points.
double distanceMeters(double aLat, double aLng, double bLat, double bLng) {
  const earthRadius = 6371000.0;
  final dLat = _radians(bLat - aLat);
  final dLng = _radians(bLng - aLng);
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_radians(aLat)) *
          math.cos(_radians(bLat)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(h)));
}

double _radians(double degrees) => degrees * math.pi / 180.0;

/// The two-step recenter states: frame both points, or zoom in on the user.
enum RecenterStep { fitBoth, zoomUser }

/// Strict toggle used across consecutive programmatic recenter presses.
RecenterStep nextRecenterStep(RecenterStep current) =>
    current == RecenterStep.fitBoth
    ? RecenterStep.zoomUser
    : RecenterStep.fitBoth;

/// The zoom one +/- button tap should land on, or **null when the tap cannot
/// move the camera** — already at the floor/ceiling, or a step so small it
/// would be a no-op.
///
/// Null matters as much as the number. The map surfaces drive these buttons
/// through the same imperative "ease to this centre at this zoom" token the
/// my-location button uses, and an area-first picker re-resolves its selection
/// on every camera settle. Bumping that token for a zoom the camera already
/// holds would ease nowhere and then charge a redundant boundary resolve for
/// it, so a dead tap has to be dead all the way down.
double? steppedZoom({
  required double current,
  required double delta,
  required double minZoom,
  required double maxZoom,
  double epsilon = 0.01,
}) {
  final target = (current + delta).clamp(minZoom, maxZoom).toDouble();
  return (target - current).abs() < epsilon ? null : target;
}
