import '../../providers/location_provider.dart';
import '../widgets/map_marker_model.dart';

/// Appends a `MapMarker.userLocation` to [markers] when GPS is available.
/// Skipped for IP-fallback so the blue dot only renders for a real fix.
///
/// `MapMarker.userLocation` is excluded from the fit-to-markers bbox at
/// `mapbox_map_web.dart:700`, so the dot never distorts initial framing
/// or fit-all reset — callers can safely add it alongside primary pins.
///
/// PROD-2017 introduced the pattern (single-pin + multi-pin zine item
/// builders); PROD-2042 promoted the duplicated inline copies to this
/// shared helper.
void appendUserLocationMarker(List<MapMarker> markers, LocationState location) {
  final loc = location.lastLocation;
  if (loc == null || location.isIpFallback) return;
  markers.add(
    MapMarker.userLocation(
      lat: loc.lat,
      lng: loc.lon,
      accuracyM: loc.accuracyM,
    ),
  );
}
