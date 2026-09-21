import 'package:flutter/material.dart';

import '../../data/models/map_debug.dart';
import '../utils/map_debug_overlay.dart' show MapDebugShape;
import 'map_marker_model.dart';

/// Stub implementation for unsupported platforms
/// This file is used when neither web nor native platforms are detected
class MapboxMapPlatform extends StatelessWidget {
  final List<MapMarker> markers;
  final ({double lat, double lng})? userDotLatLng;
  final ({double lat, double lng})? pickerPinLatLng;
  final MapBoundsConfig? fitBoundsOverride;
  final int fitBoundsToken;
  final double? centerLat;
  final double? centerLng;
  final double zoom;
  final bool fitMarkers;

  /// Mirrors the web/native signature — `(marker, pixel)` — so the
  /// shared widget's call sites don't need platform branches. Always
  /// no-op on the stub (no map → no tap).
  final void Function(MapMarker marker, Offset pixel)? onMarkerTap;
  final VoidCallback? onMapTapOutside;

  /// PROD-3109: canvas-tap-with-coordinates. No-op on the stub (no map).
  final void Function(double lat, double lng)? onMapTapLatLng;

  /// PROD-3109: picker boundary overlay. No-op on the stub.
  final Map<String, dynamic>? highlightBoundaryGeoJson;

  /// Picker drill-down: child-neighbourhood overlay. No-op on the stub.
  final Map<String, dynamic>? childBoundariesGeoJson;

  /// PROD-3109: hover coordinate callback. Web-only; no-op on the stub.
  final void Function(double lat, double lng)? onMapHoverLatLng;

  /// PROD-3109: pointer-leave callback. Web-only; no-op on the stub.
  final VoidCallback? onMapHoverExit;

  /// PROD-3109: hover-preview boundary overlay. Web-only; no-op on the stub.
  final Map<String, dynamic>? hoverBoundaryGeoJson;
  final ({double lat, double lng})? highlightPoint;

  /// See `MapboxMapWidget.highlightRadiusMeters`.
  final double? highlightRadiusMeters;
  final String? selectedMarkerId;
  final Set<String>? selectedMarkerIds;
  final void Function(MapMarker marker, Offset pixel)? onPinHoverEnter;
  final VoidCallback? onPinHoverExit;
  final bool interactive;
  final MapBoundsConfig? boundsConfig;
  final VoidCallback? onMapReady;
  final VoidCallback? onMapMoved;
  final bool isDark;
  final bool optimizeForSmallSize;

  /// Max zoom-in override (honoured on web + native, PROD-3001). No-op on
  /// the stub.
  final double? maxZoom;
  final MapCursorOverride? cursorOverride;
  final bool cluster;
  final int fitToMarkersToken;

  /// PROD-2042 Wave 2: monotonic counter bumped by the shell when the
  /// my-location button is tapped. Signals "ease camera to the
  /// current [centerLat]/[centerLng]/[zoom] now" — independent of
  /// whether those props changed value. Needed because after an
  /// initial fit-to-markers the prop value may already match the
  /// override target (user location), so a value-diff predicate
  /// wouldn't trigger an animation.
  final int centerToToken;

  /// PROD-2671: web-only category-pin rendering + settle-to-search. No-op
  /// on the stub (no map surface) — accepted so the shared widget's call
  /// site stays platform-agnostic.
  final bool categoryIcons;
  final Map<String, String> categoryIconAssets;

  /// PROD-3828: caption gate + per-surface icon-size curve for the category
  /// pins. No-op on the stub (no map surface).
  final bool showPinCaptions;
  final List<(double zoom, double size)>? pinIconSizeStops;

  /// PROD-2807: custom world-grid selection + overflow bubbles. No-op on the
  /// stub (no map surface).
  final bool customSelection;
  final MapCameraIdleCallback? onCameraIdle;

  /// PROD-2807 (#4): throttled live camera-move callback. No-op on the stub.
  final MapCameraIdleCallback? onCameraMove;

  /// PROD-2671: when false (e.g. the Map page — no tooltip), a pin tap fires
  /// `onMarkerTap` immediately without easing the camera. No-op on the stub.
  final bool centerOnMarkerTap;

  /// PROD-2971: admin-only searched-area debug overlay (retrieval circle,
  /// sargable bbox, grid cells, v2 selection rect). No-op on the stub.
  final MapDebugArea? debugOverlay;

  /// PROD-2971: which overlay shapes to draw (null = all). No-op on the stub.
  final Set<MapDebugShape>? debugOverlayShapes;

  /// DEBUG-only search-area overlay (web-only). No-op on the stub.
  final MapSearchAreaOverlay? debugSearchArea;

  /// PROD-3124: dot hints — GeoJSON FeatureCollection of small category-
  /// coloured circles drawn BENEATH every pin layer for retrieved-but-not-
  /// pinned results. Null → the layer stays empty. Map page only.
  final Map<String, dynamic>? dotHintsGeoJson;

  /// PROD-3124 dot tap — see the facade doc. Lowest tap priority.
  final void Function(String id, String entity, double lat, double lng)?
  onDotHintTap;

  /// PROD-2671: chrome insets for the visible-area search geometry (web-only).
  /// No-op on the stub.
  final double viewportPaddingTop;
  final double viewportPaddingBottom;

  /// PROD-2993: global caption `text-offset` multiplier (Map page). No-op on the
  /// stub. See [MapPinIconTokens.captionOffsetExpression].
  final double captionSizeMul;

  /// PROD-2993: fires ONLY when the **user** drives the camera — a drag, a
  /// wheel/pinch zoom — never when we move it ourselves.
  ///
  /// [onMapMoved] cannot answer this: it fires identically for a user's pan and
  /// for our own `easeTo`. Telling the two apart by *timing* (assume anything
  /// inside our animation window is ours) is the classic failure of this UI
  /// pattern — it silently misreads a user who grabs the map mid-animation,
  /// which is exactly when they are most likely to. Both platforms expose a real
  /// signal instead, so we use it. No-op on the stub.
  final VoidCallback? onUserGesture;

  const MapboxMapPlatform({
    super.key,
    this.markers = const [],
    this.userDotLatLng,
    this.pickerPinLatLng,
    this.fitBoundsOverride,
    this.fitBoundsToken = 0,
    this.centerLat,
    this.centerLng,
    this.zoom = 13,
    this.fitMarkers = false,
    this.onMarkerTap,
    this.onMapTapOutside,
    this.onMapTapLatLng,
    this.highlightBoundaryGeoJson,
    this.childBoundariesGeoJson,
    this.onMapHoverLatLng,
    this.onMapHoverExit,
    this.hoverBoundaryGeoJson,
    this.highlightPoint,
    this.highlightRadiusMeters,
    this.selectedMarkerId,
    this.selectedMarkerIds,
    this.onPinHoverEnter,
    this.onPinHoverExit,
    this.interactive = true,
    this.boundsConfig,
    this.onMapReady,
    this.onMapMoved,
    this.isDark = false,
    this.optimizeForSmallSize = false,
    this.maxZoom,
    this.cursorOverride,
    this.cluster = false,
    this.fitToMarkersToken = 0,
    this.centerToToken = 0,
    this.categoryIcons = false,
    this.categoryIconAssets = const {},
    this.showPinCaptions = true,
    this.pinIconSizeStops,
    this.customSelection = false,
    this.onCameraIdle,
    this.onCameraMove,
    this.centerOnMarkerTap = true,
    this.debugOverlay,
    this.debugOverlayShapes,
    this.debugSearchArea,
    this.dotHintsGeoJson,
    this.onDotHintTap,
    this.viewportPaddingTop = 0,
    this.viewportPaddingBottom = 0,
    this.captionSizeMul = 1.0,
    this.onUserGesture,
  });

  @override
  Widget build(BuildContext context) {
    // Return empty container on unsupported platforms
    return const SizedBox.shrink();
  }
}
