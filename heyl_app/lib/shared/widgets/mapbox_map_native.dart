import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../core/config/environment.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/map_debug.dart';
import '../utils/geo_circle.dart';
import '../utils/map_debug_overlay.dart';
import '../utils/map_dot_hints_render.dart';
import '../utils/map_mercator.dart';
import 'map_marker_model.dart';

/// PROD-1978: lightweight Sentry breadcrumb helper so a future regression
/// in the map mount/dispose lifecycle is loud and traceable. Kept to
/// `info` level — surfaces only in event payloads when something else
/// errors.
void _mapBreadcrumb(String message, {Map<String, Object?>? data}) {
  Sentry.addBreadcrumb(
    Breadcrumb(
      message: message,
      category: 'map.native',
      type: 'info',
      data: data,
    ),
  );
}

// PROD-1978: Source + layer identifiers for the clustered GeoJSON path.
// Mirrors the web side's names so the two implementations are easy to
// reason about together.
// PROD-3124: dot hints — one source + one circle layer, installed FIRST in
// the cluster install pass so it paints beneath every pin layer. Mirror of
// the web side.
const String _dotHintsSourceId = 'heyl-dot-hints';
const String _dotHintsLayerId = 'heyl-dot-hints';

const String _clusterSourceId = 'heyl-pins';
const String _clusterLayerId = 'heyl-clusters';
const String _clusterCountLayerId = 'heyl-cluster-count';
const String _unclusteredLayerId = 'heyl-unclustered';
// PROD-2671/PROD-2807: category-icon symbol layer drawn on top of the (now
// transparent) unclustered circle hit-target. Mirror of the web side's
// `_unclusteredIconLayerId`.
const String _unclusteredIconLayerId = 'heyl-unclustered-icons';
// Pin CAPTIONS (name + secondary facet) live in their OWN symbol layer stacked
// directly ABOVE the icon layer, so a nearer pin's teardrop never paints over a
// farther pin's caption (a single icon+text layer draws each feature's icon and
// text together in z-order, letting a later icon occlude an earlier caption).
// Captions still avoid each other (`text-allow-overlap` default false +
// `text-optional`). Mirror of the web side's `_unclusteredCaptionLayerId`.
const String _unclusteredCaptionLayerId = 'heyl-unclustered-captions';
// PROD-2671: user-location accuracy ring (geodesic fill polygon) — restores the
// ring removed by PROD-2016. Rendered above the pins, below the dot annotation.
const String _userAccuracySourceId = 'heyl-user-accuracy';
const String _userAccuracyFillLayerId = 'heyl-user-accuracy-fill';
const String _userAccuracyLineLayerId = 'heyl-user-accuracy-line';

// The map-location-picker center-of-search pin — a single Soko teardrop
// (`assets/pins/pin-search.png`) rendered as a PointAnnotation on its own
// manager, driven by [pickerPinLatLng]. Mirror of the web side's picker-pin
// symbol layer; bottom-anchored so the tip sits on the point.
const String _pickerPinAssetPath = 'assets/pins/pin-search.png';
// Source PNG is 334×464; ~0.10 renders the pin ~46 pt tall, matching web.
const double _pickerPinIconSize = 0.1;

// PROD-2971: admin-only searched-area debug overlay. One GeoJSON source of
// polygons (retrieval circle / boxes / grid / selection rect), coloured
// per-feature via `['get', ...]` expressions so a single fill + line layer
// renders every shape. Rendered above the pins for visibility.
const String _mapDebugSourceId = 'heyl-map-debug';
const String _mapDebugFillLayerId = 'heyl-map-debug-fill';
const String _mapDebugLineLayerId = 'heyl-map-debug-line';

// PROD-3109: map-location-picker highlighted boundary. One GeoJSON source holds
// the selected neighborhood MultiPolygon or a small geodesic circle around a
// tapped point; a fill + line layer render both.
const String _pickerBoundarySourceId = 'heyl-picker-boundary';
const String _pickerBoundaryFillLayerId = 'heyl-picker-boundary-fill';
const String _pickerBoundaryLineLayerId = 'heyl-picker-boundary-line';
// Soko red (ARGB): fill @ ~15% alpha, solid line.
const int _pickerBoundaryFillColorArgb = 0x26C76274;
const int _pickerBoundaryLineColorArgb = 0xF2C76274;
const double _pickerPointFallbackRadiusMeters = 150;

// PROD (picker drill-down): the tappable child-neighbourhood layer drawn
// BENEATH the selected-boundary highlight — a subtle grid of a city's
// freguesias the user can tap to drill into. Lighter fill + thinner line so the
// bolder selected outline reads on top.
const String _pickerChildrenSourceId = 'heyl-picker-children';
const String _pickerChildrenFillLayerId = 'heyl-picker-children-fill';
const String _pickerChildrenLineLayerId = 'heyl-picker-children-line';
// Transparent fill (the city fill already tints the area — an additive child
// fill just washes it out uniformly); the dark sokoInk dividers carve the
// tappable freguesias. Tappability is hit-tested in Dart, not via the fill.
const int _pickerChildrenFillColorArgb = 0x00000000; // transparent
const int _pickerChildrenLineColorArgb = 0x9944131D; // sokoInk @ ~60%

/// PROD-2671 cluster-focus: the steady-state opacity expression shared by the
/// single-pin icon + caption layers, the stack layers, and the count label —
/// dims non-focused features when focus is active. Reads the per-feature `dim`
/// prop (default false when absent) → 0.25 for dimmed, 1.0 otherwise. OPACITY
/// ONLY — dimmed features stay tappable (the transparent hit-target circle is
/// untouched). 0.25 is a first pass — candidate for on-device tuning. Mirror
/// of the web side. Extracted to a builder (PROD-3000) so the opening reveal
/// fade can wrap it in a multiplier and restore it verbatim afterwards.
List<Object> _pinDimOpacityExpr() => <Object>[
  'case',
  <Object>[
    'boolean',
    <Object>['get', 'dim'],
    false,
  ],
  0.25,
  1.0,
];

/// PROD-2989 × PROD-3000: the STEADY-STATE opacity expression for the
/// single-pin icon + caption layers — the product of (1) the focus-dim above,
/// (2) the per-pin reveal-animation multiplier (`anim_o`, stamped per frame by
/// the reveal loop; absent → 1.0), and (3) the "seen" fade
/// ([MapPinIconTokens.viewedIconOpacity] when the per-feature `viewed` prop is
/// true; absent → 1.0). Mirror of web's `revealIconOpacity` (same three
/// factors, same order). Extracted so the whole-layer fallback fade wraps and
/// restores THIS full product — restoring anything less would silently wipe
/// the other factors after the reveal (see
/// docs/learnings/restore-style-animation-hidden-steady-state-coupling.md).
/// The stack layers + count label deliberately keep the bare
/// [_pinDimOpacityExpr] (bubbles carry no `viewed`/`anim_o`).
List<Object> _pinRevealOpacityExpr() => <Object>[
  '*',
  _pinDimOpacityExpr(),
  <Object>[
    'coalesce',
    <Object>['get', 'anim_o'],
    1,
  ],
  <Object>[
    'case',
    <Object>[
      'boolean',
      <Object>['get', 'viewed'],
      false,
    ],
    MapPinIconTokens.viewedIconOpacity,
    1.0,
  ],
];

const String _emptyFeatureCollectionJson =
    '{"type":"FeatureCollection","features":[]}';

/// Native (iOS/Android) implementation using Mapbox Maps Flutter SDK
class MapboxMapPlatform extends StatefulWidget {
  final List<MapMarker> markers;
  final ({double lat, double lng})? userDotLatLng;

  /// When set, renders the picker's center-of-search Soko teardrop pin
  /// (`assets/pins/pin-search.png`) at this point on its own PointAnnotation
  /// manager, independent of [markers]. Mirror of [userDotLatLng]. Null → none.
  final ({double lat, double lng})? pickerPinLatLng;
  // req3: imperative "fit these bounds now" (bumped by [fitBoundsToken]), kept
  // separate from [boundsConfig] so the recenter step never collides with it.
  final MapBoundsConfig? fitBoundsOverride;
  final int fitBoundsToken;
  final double? centerLat;
  final double? centerLng;
  final double zoom;
  final bool fitMarkers;

  /// Fires on every pin tap with the marker AND its pixel-offset
  /// within the map container (used by the shell to anchor the
  /// tooltip). Internal to `mapbox_map_widget.dart`; consumers wire
  /// their own callback via `MapboxMapWidget.onMarkerTap` (which the
  /// shell adapts to the consumer-facing `OnMarkerTap` signature).
  final void Function(MapMarker marker, Offset pixel)? onMarkerTap;

  /// PROD-2016: fires when the user taps the canvas WITHOUT hitting
  /// any pin or cluster. Used by the shell to close the tooltip on
  /// tap-outside. Internal.
  final VoidCallback? onMapTapOutside;

  /// PROD-3109: fires on every canvas tap with the tapped geographic
  /// coordinate `(lat, lng)` — the map location picker uses it to resolve the
  /// tapped neighborhood.
  final void Function(double lat, double lng)? onMapTapLatLng;

  /// PROD-3109: GeoJSON geometry (MultiPolygon) of the selected neighborhood to
  /// outline. Null clears the overlay. Takes precedence over [highlightPoint].
  final Map<String, dynamic>? highlightBoundaryGeoJson;

  /// Picker drill-down: a GeoJSON FeatureCollection of a selected city's child
  /// neighbourhoods, drawn as a light tappable layer BENEATH
  /// [highlightBoundaryGeoJson]. Null/empty clears it. The tap hit-test happens
  /// in Dart (via [onMapTapLatLng]); this is display only.
  final Map<String, dynamic>? childBoundariesGeoJson;

  /// PROD-3109: hover coordinate callback. Web-only; no-op on native.
  final void Function(double lat, double lng)? onMapHoverLatLng;

  /// PROD-3109: fires when pointer leaves the canvas. Web-only; no-op on native.
  final VoidCallback? onMapHoverExit;

  /// PROD-3109: hover-preview boundary overlay. Web-only; no-op on native.
  final Map<String, dynamic>? hoverBoundaryGeoJson;

  /// PROD-3109: fallback highlight (a small circle at this point) when no
  /// boundary polygon is available. Ignored when [highlightBoundaryGeoJson] is
  /// set.
  final ({double lat, double lng})? highlightPoint;

  /// PROD-3109 — radius (metres) for the [highlightPoint] circle. The picker
  /// passes the radius the confirmed scope will actually STORE, so the drawn
  /// circle is the selection rather than a decoration. Null keeps the legacy
  /// fixed fallback.
  ///
  /// Zooming changes this WITHOUT moving [highlightPoint], so every redraw
  /// check that looks at the point must look at this too — otherwise the
  /// circle silently keeps the old radius.
  final double? highlightRadiusMeters;

  /// PROD-2016: id of the currently-selected marker. Mirrors the web
  /// side — stamped onto the matching GeoJSON feature so the
  /// unclustered layer's `case` expression renders the enlarged
  /// radius.
  final String? selectedMarkerId;

  /// PROD-2205: multi-pin variant. Every marker whose id is in this
  /// set also gets `selected: true` stamped, in addition to anything
  /// matched by [selectedMarkerId]. Mirror of the web side.
  final Set<String>? selectedMarkerIds;

  /// PROD-2016 (web only — native ignores). Touch devices don't fire
  /// mouseenter, so these are no-ops here; declared so the platform
  /// constructors match.
  final void Function(MapMarker marker, Offset pixel)? onPinHoverEnter;
  final VoidCallback? onPinHoverExit;
  final bool interactive;
  final MapBoundsConfig? boundsConfig;
  final VoidCallback? onMapReady;
  final VoidCallback? onMapMoved;
  final bool isDark;
  // PROD-595: Memory optimizations for small maps (not critical on native, but API-consistent)
  final bool optimizeForSmallSize;

  /// Optional max zoom-in override. PROD-3001: now HONOURED on native via
  /// `setBounds(CameraBoundsOptions(maxZoom:))` at map creation (was ignored —
  /// native ran to Mapbox's ~22). Null → uncapped on native (embedded surfaces;
  /// their 14/16 defaults are a web-side PROD-595 memory optimization).
  final double? maxZoom;
  // Web-only cursor override (ignored on native)
  final MapCursorOverride? cursorOverride;
  // PROD-1978: clustering opt-in. Currently a no-op on native (Phase 2
  // wires up the GeoJsonSource + style-layer migration); accepted here
  // so the public API matches the web side and consumers don't need
  // platform branches.
  final bool cluster;
  // PROD-1978 follow-up: any change to this counter re-runs the fit
  // logic. See web doc-comment for full rationale.
  final int fitToMarkersToken;

  /// PROD-2042 Wave 2: monotonic counter bumped by the shell when the
  /// my-location button is tapped. Signals "fly camera to the
  /// current [centerLat]/[centerLng]/[zoom] now" — independent of
  /// whether those props changed value. Mirror of the web side.
  final int centerToToken;

  /// PROD-2671: category-pin rendering (facet-colour PNG teardrops + inline
  /// captions). Implemented on native — PNGs registered via `addStyleImage`
  /// (raw PNG bytes; see learnings/mapbox-native-addstyleimage-wants-png-bytes.md),
  /// rendered by the split icon+caption symbol layers. Mirror of the web side.
  final bool categoryIcons;
  final Map<String, String> categoryIconAssets;

  /// PROD-3828: add the inline pin-caption layer. Opt-out (default true) —
  /// see [MapboxMapWidget.showPinCaptions] for why that direction.
  final bool showPinCaptions;

  /// PROD-3828: per-surface zoom→`icon-size` curve; null →
  /// [MapPinIconTokens.iconSizeStops]. Threaded into the icon-size
  /// expressions, the caption offset and the Dart-side tap hit-test alike.
  final List<(double zoom, double size)>? pinIconSizeStops;

  /// PROD-2807: custom world-grid selection + `+k` overflow bubbles.
  /// Wired on native: `cluster:false` source + `overflow_count`-filtered
  /// bubble layers + stack-of-5 member teardrops + bubble-tap zoom, mirroring
  /// the web layer set. The engine (`map_grid_selection.dart`) + the
  /// marker/`overflowCount` model are platform-agnostic.
  final bool customSelection;
  final MapCameraIdleCallback? onCameraIdle;

  /// PROD-2807 (#4): throttled live camera-move callback for instant
  /// mid-gesture re-selection. Wired on native via `onCameraChanged` +
  /// an in-flight guard (`_maybeEmitCameraMove`), mirroring the web `move`
  /// wiring (web throttles at a fixed 50 ms instead — an accepted
  /// cadence difference).
  final MapCameraIdleCallback? onCameraMove;

  /// PROD-2671: when false (e.g. the Map page — no tooltip), a pin tap fires
  /// `onMarkerTap` **immediately** without easing the camera to centre the pin.
  /// Default true preserves the PROD-2046 tooltip-placement ease + deferred fire.
  final bool centerOnMarkerTap;

  /// PROD-2971: admin-only searched-area debug overlay. When non-null, the map
  /// draws the retrieval circle / sargable bbox / grid cells / v2 selection rect
  /// (distinct colours) from the `/map/pins` `debug.area` block; null → no
  /// overlay. Shapes are geographic polygons so they track the camera for free.
  final MapDebugArea? debugOverlay;

  /// PROD-2971: which overlay shapes to draw (null = all).
  final Set<MapDebugShape>? debugOverlayShapes;

  /// DEBUG-only search-area overlay. Accepted for signature parity; **not wired
  /// on native** (the Map page + its debug tab are web-gated today).
  final MapSearchAreaOverlay? debugSearchArea;

  /// PROD-3124: dot hints — GeoJSON FeatureCollection of small category-
  /// coloured circles drawn BENEATH every pin layer for retrieved-but-not-
  /// pinned results. Null → the layer stays empty. Map page only.
  final Map<String, dynamic>? dotHintsGeoJson;

  /// PROD-3124 dot tap — see the facade doc. Lowest tap priority.
  final void Function(String id, String entity, double lat, double lng)?
  onDotHintTap;

  /// PROD-2671: chrome insets (top bar + results drawer, logical px) that overlap
  /// the full-bleed map. When set (Map page), the camera state reported to
  /// `onCameraIdle`/`onCameraMove` describes the VISIBLE rectangle (canvas minus
  /// these insets, minus a border margin) so the `/map/pins` query + pin
  /// selection cover only what the user sees; they also drive `setCamera` padding
  /// so the map frames within that area. Both default 0 → full-canvas behaviour.
  final double viewportPaddingTop;
  final double viewportPaddingBottom;

  /// PROD-2993: global caption `text-offset` multiplier — see the facade doc on
  /// [MapboxMapWidget.captionSizeMul] and [MapPinIconTokens.captionOffsetExpression].
  /// `1.0` (no enlargement) everywhere but the narrow half-drawer highlight.
  final double captionSizeMul;

  /// PROD-2993: fires ONLY when the **user** drives the camera (drag, wheel or
  /// pinch zoom) — never when we move it ourselves. See the stub for why a
  /// timing heuristic is not good enough.
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
    this.showPinCaptions = true,
    this.pinIconSizeStops,
    this.categoryIconAssets = const {},
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
  State<MapboxMapPlatform> createState() => _MapboxMapPlatformState();
}

class _MapboxMapPlatformState extends State<MapboxMapPlatform>
    with WidgetsBindingObserver {
  /// PROD-3828: the zoom→`icon-size` curve this surface renders with — the
  /// per-consumer override, else the Map-page default. THE single read point:
  /// the icon-size expressions, the caption offset and the Dart-side tap
  /// hit-test all go through here, so a surface's captions and tap targets
  /// can't drift from its art. Mirror of the web side.
  List<(double, double)> get _pinStops =>
      widget.pinIconSizeStops ?? MapPinIconTokens.iconSizeStops;

  /// PROD-3828: per-feature selection enlargement for the icon layers.
  ///
  /// Under [MapboxMapPlatform.categoryIcons] the unclustered circle is fully
  /// transparent, so the `selected` property's only readers — `circle-radius`
  /// and `circle-stroke-*` — paint nothing and the highlight vanishes. This
  /// gives the property a reader on the icon layers instead.
  ///
  /// Multiplied INTO the existing `icon_scale` factor rather than wrapped
  /// around the zoom interpolate: a `["zoom"]` expression must stay top-level,
  /// and folding it in here means selection composes with score × highlight ×
  /// focus like every other multiplier riding `icon_scale`. Mirror of web's
  /// `_selectedScaleExpr`.
  List<Object> get _selectedScaleExpr => <Object>[
    'case',
    <Object>[
      'boolean',
      <Object>['get', 'selected'],
      false,
    ],
    kMapPinSelectedSizeMul,
    1,
  ];

  MapboxMap? _mapboxMap;
  // PROD-2671: the one-time initial fit + `onMapReady` signal run on the FIRST
  // style load only (see [_onStyleLoaded]) — not on later style reloads.
  bool _didInitialSetup = false;
  // PROD-2016: only `CircleAnnotationManager` survives — it renders
  // the user-location dot. Venue/event pins moved to the GeoJsonSource
  // + style-layer path; the legacy `_pointManager` / `_iconManager`
  // (PointAnnotationManager) were deleted alongside the web DOM-overlay.
  CircleAnnotationManager? _circleManager;
  // req2: a SEPARATE manager for the picker's viewport-gated user dot, so it is
  // isolated from [_circleManager] (which `_renderMarkers` clears on every
  // marker change — the picker's pin moves as the camera pans). Update-in-place
  // avoids a delete/create flicker each camera idle.
  CircleAnnotationManager? _pickerDotManager;
  CircleAnnotation? _userDotAnnotation;
  // The picker center-of-search pin — its own PointAnnotation manager, isolated
  // from marker rendering exactly like [_pickerDotManager]. Image bytes are
  // loaded once and cached for update-in-place moves.
  PointAnnotationManager? _pickerPinManager;
  PointAnnotation? _pickerPinAnnotation;
  Uint8List? _pickerPinImageBytes;
  Cancelable? _circleTapCancelable;
  bool _mapReady = false;

  // Tracks user-location circle annotations so taps can be resolved
  // back to a MapMarker for the legacy `onMarkerTap` callback.
  final Map<String, CircleAnnotation> _circleAnnotations = {};
  final Map<String, MapMarker> _markerLookup = {};

  // Default location (Lisbon)
  static const double _defaultLat = 38.7223;
  static const double _defaultLng = -9.1393;

  /// PROD-2046 Option A — programmatic-ease guard. When we pan the
  /// map to centre on a tapped pin, the resulting camera changes
  /// would otherwise fire `onMapMoved` and the shell would close any
  /// previously-open tooltip mid-ease. Set true around the ease,
  /// cleared when the deferred tooltip-show fires.
  bool _suppressMoveCallback = false;

  /// PROD-2671: guards against overlapping `onCameraMove` reads. Each read
  /// (`getCameraState` + `coordinateBoundsForCamera`) is a platform-channel
  /// round-trip, so a fast pan is throttled to at most one in-flight read —
  /// the next camera-change event is dropped until the current read resolves.
  bool _cameraMoveInFlight = false;

  /// Pending tooltip-show timer (PROD-2046 part 2). The tooltip only
  /// appears AFTER the camera ease completes so it never renders at
  /// a stale position. A subsequent tap cancels this and schedules a
  /// new one.
  Timer? _pendingTooltipShow;

  /// Latest map viewport size in logical pixels — captured from a
  /// LayoutBuilder around the MapWidget so the pin-tap ease handler
  /// can compute its target screen position synchronously without
  /// needing `mapboxMap.getSize()`. Stored as separate width/height
  /// doubles to avoid the `Size` name collision between
  /// `dart:ui` and `mapbox_maps_flutter`'s pigeon-generated `Size`.
  double? _viewportWidth;
  double? _viewportHeight;

  /// PROD-2046 Option A — same constants as the web side.
  /// `_pinTargetYFraction`: where the tapped pin lands after the ease
  /// (y as fraction of viewport height). Must match the shell's
  /// expectation in `_PinTooltipOverlay`.
  static const double _pinTargetYFraction = 0.55;
  static const int _pinEaseDurationMs = 250;

  /// Extra time the move-suppress flag is held AFTER the tooltip
  /// shows. Mirror of the web constant — guards against trailing
  /// camera-change events arriving after the nominal ease duration
  /// and dismissing the tooltip we just opened.
  static const int _moveSuppressTailMs = 100;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[MapboxMapPlatform Native] App resumed');
    }
  }

  void _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;
    // A fresh map/style → ALL style-layer installs must re-run. A theme switch
    // (or any MapWidget recreation) rebuilds the platform view with a NEW style
    // but WITHOUT disposing this State, so these install flags would otherwise
    // stay stale-true — leaving `_updateClusterSource` writing to a 'heyl-pins'
    // source no longer in the style ("Source 'heyl-pins' is not in style").
    // Reset them so the installs below re-run against the new style.
    _clusterLayersInstalled = false;
    _userAccuracyInstalled = false;
    _mapDebugInstalled = false;
    _pickerBoundaryInstalled = false;
    _pickerChildrenInstalled = false;
    // PROD-3004: the new style's layers are born at whatever the layer
    // definitions say, so the "did it change?" cache MUST be dropped in step with
    // the install flags. Leave it set and `_applySymbolZOrder` would skip a write
    // it actually needed, silently stranding the map on the wrong ordering.
    _appliedSymbolZOrder = null;
    // PROD-2993: same for the caption-offset cache — the caption layers are
    // (re)installed at `widget.captionSizeMul`, so a stale cache would make
    // `_applyCaptionOffset` skip a needed write.
    _appliedCaptionSizeMul = null;
    debugPrint(
      '[MapboxMapPlatform Native] Map created, interactive: ${widget.interactive}',
    );

    // PROD-3001: honour the per-instance zoom-in cap (previously ignored on
    // native — it ran to Mapbox's ~22 while web capped). The Map page passes
    // 20 (decision 2026-07-10: no user benefit past ~20); embedded surfaces
    // pass null and stay uncapped on native (their PROD-595 14/16 caps are a
    // web-side memory optimization — see MapboxMapWidget.maxZoom).
    if (widget.maxZoom != null) {
      await mapboxMap.setBounds(CameraBoundsOptions(maxZoom: widget.maxZoom));
    }

    // Hide all ornaments (logo, attribution, scale bar, compass) to match web
    await mapboxMap.logo.updateSettings(LogoSettings(enabled: false));
    await mapboxMap.attribution.updateSettings(
      AttributionSettings(enabled: false),
    );
    await mapboxMap.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
    await mapboxMap.compass.updateSettings(CompassSettings(enabled: false));

    // Configure gestures - enable all pan/zoom gestures when interactive
    await mapboxMap.gestures.updateSettings(
      GesturesSettings(
        scrollEnabled: widget.interactive,
        pinchToZoomEnabled: widget.interactive,
        pinchPanEnabled:
            widget.interactive, // Enable pinch-to-pan (two-finger drag)
        rotateEnabled: false,
        pitchEnabled: false,
        doubleTapToZoomInEnabled: widget.interactive,
        doubleTouchToZoomOutEnabled: false,
        quickZoomEnabled:
            widget.interactive, // Enable quick zoom (double-tap and hold)
        scrollDecelerationEnabled:
            widget.interactive, // Smooth scroll deceleration
        pinchToZoomDecelerationEnabled:
            widget.interactive, // Smooth zoom deceleration
      ),
    );

    // PROD-2016: pin rendering is entirely on the GeoJsonSource + style
    // layers. `_circleManager` is retained only for the user-location
    // dot (single point, doesn't cluster, doesn't need the source-layer
    // pipeline). Legacy `_pointManager` / `_iconManager` deleted.
    _circleManager = await mapboxMap.annotations
        .createCircleAnnotationManager();
    // req2: created after [_circleManager] so the picker dot renders above
    // any marker circles; isolated so marker re-renders don't clear it.
    _pickerDotManager = await mapboxMap.annotations
        .createCircleAnnotationManager();
    // Picker center-of-search pin manager — created after the dot manager so
    // the teardrop renders above the user dot; isolated from marker re-renders.
    _pickerPinManager = await mapboxMap.annotations
        .createPointAnnotationManager();
    _circleTapCancelable = _circleManager?.tapEvents(onTap: _onCircleClicked);

    _mapBreadcrumb(
      'Map created',
      data: {
        'markers': widget.markers.length,
        'interactive': widget.interactive,
      },
    );
    // NOTE: sources/layers + the first marker render happen in [_onStyleLoaded],
    // NOT here. On a COLD first load the style loads async AFTER onMapCreated, so
    // installing 'heyl-pins' here silently misses the style ("Source 'heyl-pins'
    // is not in style") and NO pins render until a re-entry warms the style
    // cache. `onStyleLoadedListener` fires when the style is actually ready.
  }

  /// PROD-2671: install the GeoJSON sources + style layers and do the first
  /// render when the **style is loaded** (cold or warm). This is the correct
  /// moment — `onMapCreated` fires before the style is ready on a cold start.
  /// Fires again on any later style (re)load; the per-source install guards
  /// make re-runs cheap.
  void _onStyleLoaded(StyleLoadedEventData _) async {
    if (_mapboxMap == null) return;

    // PROD-2999 (Map page): arm the opening zoom-in settle SYNCHRONOUSLY,
    // before any awaited style work below — Mapbox can deliver the initial
    // idle during those awaits, and an unarmed `_onMapIdle` would treat it as
    // a normal settle at the BIRTH zoom (broad first fetch) with no later
    // idle guaranteed to start the settle (pins would stay hidden). Codex
    // review finding (P1). The padding-deferral counterpart lives after the
    // installs below.
    if (widget.customSelection && !_didOpenSettle) {
      _awaitingOpenEase = true;
    }

    // PROD-2671: register the per-category PNG pins BEFORE the layers reference
    // them via `['get','icon']` / `stack_icon_<i>`. Only the Map page passes
    // `categoryIcons: true` + assets; every other surface skips this and keeps
    // the plain colored-circle rendering. Idempotent + fully guarded so a bad
    // image can never break the map.
    if (widget.categoryIcons && widget.categoryIconAssets.isNotEmpty) {
      await _registerCategoryIcons();
    }

    // PROD-2016: cluster source-layer path is the only pin pipeline.
    await _installClusterSourceAndLayers();
    _mapReady = true;
    await _renderMarkers();

    // PROD-2671: accuracy ring AFTER the first pin render so a ring failure can
    // never block pins (renders above pins, below the dot). Both calls are
    // self-contained (try/catch inside) — non-fatal to the map.
    await _installUserAccuracyLayer();
    await _updateUserAccuracyCircle();
    // Picker drill-down: child polygons FIRST so they sit beneath the selected
    // boundary highlight (Mapbox draws later layers on top).
    await _installPickerChildrenLayer();
    await _updatePickerChildren();
    // PROD-3109: map-picker boundary overlay (no-op unless a highlight is set).
    await _installPickerBoundaryLayer();
    await _updatePickerBoundary();
    // req2: draw the picker's viewport-gated user dot (no-op unless set).
    await _syncUserDot();
    // Draw the picker's center-of-search pin (no-op unless set).
    await _syncPickerPin();
    // PROD-2971: admin debug overlay, installed last (renders above pins). Draw
    // immediately in case debugOverlay is already set at style-load (hot reload).
    await _installMapDebugLayer();
    await _updateMapDebugOverlay();

    // PROD-2999 (Map page): the settle was armed at the TOP of this handler
    // (before the awaits). Chrome-aware camera padding is DEFERRED past the
    // settle (applied in `_startOpenSettle`'s completion), exactly like web —
    // a mid-ease `setCamera(padding:)` would fight the opening animation.
    // Non-Map surfaces (or a style reload after the settle already ran) apply
    // it immediately; no-op without insets.
    if (!widget.customSelection || _openSettled) {
      _applyViewportPadding();
    }

    _mapBreadcrumb(
      'Style loaded — sources installed',
      data: {'markers': widget.markers.length},
    );

    // One-time initial fit + ready signal — skip on later style reloads so a
    // theme switch doesn't yank the user's camera.
    if (_didInitialSetup) return;
    _didInitialSetup = true;
    if (widget.boundsConfig?.hasBbox == true) {
      await _fitToBbox();
    } else if (widget.fitMarkers && widget.markers.isNotEmpty) {
      await _fitToMarkers();
    }
    widget.onMapReady?.call();
  }

  void _onCircleClicked(CircleAnnotation annotation) {
    // PROD-3002 note: today this only serves the user-location dot (the sole
    // CircleAnnotationManager annotation left) and is intentionally inert —
    // it forwards `onMarkerTap`, which every consumer no-ops for
    // non-`MapPin` markers. Kept as harmless wiring; the dot is deliberately
    // not interactive (same as web, where a dot tap is a plain tap-outside).
    //
    // Find the marker associated with this annotation
    for (final entry in _circleAnnotations.entries) {
      if (entry.value.id == annotation.id) {
        final marker = _markerLookup[entry.key];
        if (marker != null) {
          // PROD-2016: legacy PointAnnotation path doesn't carry the
          // pixel-offset of the tap (we only have the annotation). The
          // shell falls back to its fixed-bottom-center position when
          // offset is `Offset.zero`. This whole path is retired in
          // PROD-2016 commit 5 (cluster path migration); not worth
          // computing projection here.
          widget.onMarkerTap?.call(marker, Offset.zero);
        }
        break;
      }
    }
  }

  void _onMapTap(MapContentGestureContext context) async {
    // PROD-3109: every canvas tap carries its geographic coordinate (Position
    // is ordered lng, lat). Fires before hit-testing — the picker has no pins.
    final pos = context.point.coordinates;
    widget.onMapTapLatLng?.call(pos.lat.toDouble(), pos.lng.toDouble());

    // PROD-2016: cluster path first — if the tap hit a cluster bubble
    // or an unclustered pin layer, the cluster handler consumes it
    // (zoom or onMarkerTap respectively).
    if (_clusterLayersInstalled) {
      final consumed = await _handleClusterTap(context.touchPosition);
      if (consumed) return;
    }

    // PROD-3002: nothing hit → "tap outside", exactly like web. The r24
    // transparent hit circles are the (screen-space, zoom-stable) forgiving
    // tap target on both platforms. A ground-distance (~30m) nearest-marker
    // fallback used to live here as a safety net for user-location-dot taps
    // — removed: those taps no-op downstream anyway (consumers ignore
    // non-MapPin markers), and the degree threshold scaled with zoom
    // (~50px at z18, ~800px at z22), so a tap on "empty" map near a pin
    // opened that pin / eased the camera to it.
    widget.onMapTapOutside?.call();
  }

  void _onCameraChanged(CameraChangedEventData event) {
    // PROD-3000: the reveal's "don't animate mid-pan" gate — deliberately set
    // BEFORE the suppression check (web's movestart/moveend anim listeners are
    // likewise raw, ungated map listeners). Cleared on idle.
    _cameraMoving = true;
    // PROD-4104: the opening ease has actually started moving the camera, so
    // the next idle is its completion and not a stale one. Also set before the
    // suppression check — the opening ease runs fully suppressed.
    if (_awaitingEaseSettle) _easeCameraMoved = true;
    // PROD-2046: skip the consumer notify while our own pin-tap ease
    // is in flight — otherwise the shell would dismiss the tooltip we
    // just opened.
    if (_suppressMoveCallback) return;
    widget.onMapMoved?.call();
    // PROD-2671: live mid-gesture viewport → `onCameraMove` (settle-to-search
    // still fires separately on idle). Throttled via `_cameraMoveInFlight`.
    _maybeEmitCameraMove();
  }

  /// PROD-2671: forward the live camera to `onCameraMove` while the user
  /// pans/zooms, so the Map page can re-select the shown set mid-gesture
  /// (mirrors the web throttled `move` listener). Guarded so overlapping
  /// platform-channel reads can't stack up during a fast drag.
  void _maybeEmitCameraMove() {
    if (widget.onCameraMove == null || _cameraMoveInFlight) return;
    _cameraMoveInFlight = true;
    _readCameraState().then((cam) {
      _cameraMoveInFlight = false;
      if (cam != null && mounted && !_suppressMoveCallback) {
        widget.onCameraMove!(cam);
      }
    });
  }

  /// PROD-2671: the map settled (native analog of the web `moveend`) —
  /// forward the resting camera to `onCameraIdle` so the Map page runs
  /// settle-to-search. Suppressed while our own pin-tap ease is in flight
  /// (the tail on `_suppressMoveCallback` outlasts the ease's idle event,
  /// so tapping a pin doesn't trigger a spurious refetch).
  void _onMapIdle(MapIdleEventData event) {
    // PROD-3000: camera settled — new pins may animate again (mirror of the
    // web `moveend` anim listener; unconditional, like the flag's setter).
    _cameraMoving = false;
    // PROD-2999 (Map page): the FIRST idle after load starts the opening
    // zoom-in settle (mirror of the web `idle` listener arming). Checked
    // before the suppression/null gates — the settle must run exactly once
    // regardless of consumer wiring.
    if (_awaitingOpenEase && !_didOpenSettle) {
      _startOpenSettle();
      return;
    }
    // PROD-4104: the opening ease has finished — reveal now rather than waiting
    // out the fixed tail. Gated on [_easeCameraMoved] so a stale idle queued
    // before the animation started cannot reveal pins mid-fly-in. Returns for
    // the same reason the pre-PROD-4104 code did nothing here: this idle is our
    // own animation settling, not a user gesture, so it owes no `onCameraIdle`.
    if (_awaitingEaseSettle && _easeCameraMoved) {
      _awaitingEaseSettle = false;
      _completeOpenSettle();
      return;
    }
    if (widget.onCameraIdle == null || _suppressMoveCallback) return;
    _readCameraState().then((cam) {
      if (cam != null && mounted) widget.onCameraIdle!(cam);
    });
  }

  // ── PROD-2999: opening zoom-in settle (Map page, mirror of web) ──────────
  //
  // Web's Map page is born zoomed out (target − kMapOpenSettleZoomDelta),
  // pre-emits the EXACT target-zoom viewport as the first settle (so the
  // first `/map/pins` fetch is already the zoomed-in query — no broad→zoomed
  // swap), then eases in over kMapOpenSettleMs with pins hidden until the
  // ease completes. This is the native port. One deliberate difference: web
  // captures the target viewport with a synchronous setZoom bounce (no paint
  // between); native's camera channel is async, so instead we compute the
  // hypothetical target-zoom bounds with `coordinateBoundsForCamera` (no
  // camera move at all) and trim them to the visible rect numerically in
  // Web-Mercator space — exact for this north-up map (rotate disabled).
  // At settle-completion the pins stagger in per-pin (PROD-3000,
  // `_runOpeningReveal` — mirror of web's reveal loop).

  /// Set once the opening settle has run (fires exactly once per map).
  bool _didOpenSettle = false;

  /// Armed at style-load (Map page only); the first idle starts the settle.
  bool _awaitingOpenEase = false;

  /// PROD-4104 — true from the moment the opening ease is ISSUED until the idle
  /// that ends it has been consumed. The reveal used to ride a fixed
  /// `kMapOpenSettleMs + 150 + _moveSuppressTailMs` timer, so pins that were
  /// already loaded still waited 250 ms past the animation.
  bool _awaitingEaseSettle = false;

  /// PROD-4104 — has the camera actually MOVED since the ease was issued?
  ///
  /// Load-bearing, and the reason this is not simply "the next idle". `easeTo`
  /// is a pigeon call whose Dart Future resolves on **dispatch**, not on
  /// completion (verified in mapbox_maps_flutter 2.18.0: both the Android and
  /// iOS handlers return as soon as they hand off to the native animator). So
  /// an idle already queued when the ease is issued can arrive BEFORE the
  /// animation starts, and revealing on it would paint pins mid-fly-in — the
  /// exact thing the hide gate exists to prevent. Requiring an intervening
  /// `_onCameraChanged` makes the idle provably post-animation.
  bool _easeCameraMoved = false;

  /// False until the opening settle finishes — pins stay hidden until then so
  /// a single final set is revealed (staggered in per-pin by PROD-3000's
  /// reveal). Non-Map surfaces leave it irrelevant (the hide gate is on
  /// `customSelection`).
  bool _openSettled = false;

  /// On the first idle after load: pre-emit the target-zoom viewport, then
  /// ease from the zoomed-out birth camera to the target zoom, revealing the
  /// pins once it settles. Mirror of the web `_startOpenSettle`.
  void _startOpenSettle() async {
    if (_didOpenSettle || !mounted || _mapboxMap == null) return;
    _didOpenSettle = true;
    _awaitingOpenEase = false;
    final map = _mapboxMap!;
    final targetZoom = widget.zoom;

    // Suppress move/idle consumer callbacks for the whole sequence so the
    // ease isn't read as a user pan (which would set `_userPanned` and cancel
    // the in-flight fetch). Our own direct `widget.onCameraIdle` call below
    // is NOT gated by this flag, so the up-front query still fires.
    _suppressMoveCallback = true;

    // (a) Pre-emit the EXACT target-zoom viewport (visible-rect trimmed) as
    // one settle — the first `/map/pins` fetch is already the zoomed-in query.
    // PROD-3833: synchronous now (pure maths, no platform channel). It should
    // also be a no-op in the common case — `MapScreen` seeds this same
    // rectangle before the map is built, so the settle lands inside
    // `onCameraSettled`'s drift tolerance and commits nothing.
    MapCameraState? targetView;
    try {
      targetView = _targetZoomCameraState(targetZoom);
    } catch (_) {
      targetView = null;
    }
    if (targetView != null && mounted) widget.onCameraIdle?.call(targetView);

    // (b) Ease to the target zoom (consumer callbacks stay suppressed).
    // Still fire-and-forget — awaiting it would NOT wait for the animation (see
    // [_easeCameraMoved]); completion is detected via the camera-changed + idle
    // pair below, with the delay at (c) as a fallback.
    _awaitingEaseSettle = true;
    _easeCameraMoved = false;
    try {
      map.easeTo(
        CameraOptions(
          center: Point(
            coordinates: Position(
              widget.centerLng ?? _defaultLng,
              widget.centerLat ?? _defaultLat,
            ),
          ),
          zoom: targetZoom,
        ),
        MapAnimationOptions(duration: kMapOpenSettleMs),
      );
    } catch (_) {
      // A failed ease just leaves the camera at birth zoom; the reveal below
      // still runs and the next user gesture re-settles normally.
    }

    // (c) Fallback only. If the camera-changed + idle pair never arrives — a
    // failed ease, a map disposed mid-animation, a platform that swallows the
    // events — the pins must still be revealed rather than left hidden forever.
    // Kept at the old fixed value so the worst case of PROD-4104 is exactly the
    // previous behaviour. [_completeOpenSettle] is idempotent, so whichever
    // path fires first wins and the other is a no-op.
    Future.delayed(
      const Duration(
        milliseconds: kMapOpenSettleMs + 150 + _moveSuppressTailMs,
      ),
      _completeOpenSettle,
    );
  }

  /// PROD-4104 — the opening animation has settled: stop suppressing, apply the
  /// deferred chrome inset, and reveal the pins.
  ///
  /// Idempotent, and that is the whole contract: it is raced by the real settle
  /// (camera-changed + idle) and by the fallback timer, and exactly one of them
  /// may do the work. The order of the four steps is unchanged from the
  /// timer-only version — `_applyViewportPadding` re-raises suppression and
  /// releases it on its own `_moveSuppressTailMs` tail, so clearing the flag
  /// just before it is still correct.
  void _completeOpenSettle() {
    if (!mounted || _openSettled) return;
    _openSettled = true;
    _awaitingEaseSettle = false;
    _suppressMoveCallback = false;
    // Apply the chrome inset now that the opening animation is done
    // (deferred at style-load — mirror of web; manages its own
    // suppression tail).
    _applyViewportPadding();
    // First real render: every pin is new → each lands invisible and
    // staggers in on its own fade+scale+lift schedule (PROD-3000 per-pin
    // reveal, mirror of web). Failure-safe — degrades to the whole-layer
    // fade, then to an instant one-paint reveal.
    _runOpeningReveal();
    // PROD-3124: dots were held empty through the opening reveal (same
    // gate as the pins) — release them now; their fade delay keeps them
    // after the pins.
    _syncDotHints();
  }

  /// PROD-2999: the [MapCameraState] the camera WILL have at [targetZoom]
  /// (same centre), visible-rect trimmed — computed without moving the camera.
  ///
  /// PROD-3833 — now pure arithmetic ([openingCameraState]) rather than an
  /// awaited `coordinateBoundsForCamera` round trip, so `MapScreen` can compute
  /// the identical rectangle before any map exists and seed the first
  /// `/map/pins` with it.
  ///
  /// **This also fixes a real web/native divergence.** The previous version
  /// computed the UNPADDED canvas bounds and trimmed to the inset sub-rect,
  /// whose centre sits `(top − bottom) / 2` px off the canvas centre — roughly
  /// 380 m at z14 with the current chrome. Its doc comment claimed that
  /// matched web "exactly"; it did not. Web calls `_applyViewportPadding()` in
  /// `_onMapLoaded` (`mapbox_map_web.dart`), i.e. BEFORE the first `idle`
  /// starts the opening settle, so its `unproject`-ed rect is centred on the
  /// requested centre. Native defers padding past the settle
  /// (`_onStyleLoaded`), so only the arithmetic can close the gap. The padded
  /// convention is also where this camera genuinely lands, since
  /// `_startOpenSettle`'s completion applies the padding.
  MapCameraState? _targetZoomCameraState(double targetZoom) {
    return openingCameraState(
      centerLat: widget.centerLat ?? _defaultLat,
      centerLng: widget.centerLng ?? _defaultLng,
      zoom: targetZoom,
      // Cached from this widget's own LayoutBuilder — logical px, which is what
      // Mapbox's zoom is defined against.
      widthPx: _viewportWidth ?? 0,
      heightPx: _viewportHeight ?? 0,
      paddingTop: widget.viewportPaddingTop,
      paddingBottom: widget.viewportPaddingBottom,
    );
  }

  // ── PROD-3000 phase 1: whole-layer opening fade (FALLBACK path) ──────────
  //
  // The primary opening reveal is the per-pin staggered animation below
  // (phase 2, `_runRevealLoop`). This whole-layer fade — the whole pin+caption
  // layer set fading in together over [kMapRevealFadeMs] — is kept as
  // `_runOpeningReveal`'s failure fallback: still a graceful reveal when the
  // per-pin path can't run, itself degrading to an instant one-paint reveal
  // on any further error. Scope mirror of web: ONLY the single-pin icon +
  // caption layers animate; cluster bubbles, stacked teardrops and count
  // labels appear plain, and the user-location dot lives on a separate
  // manager.

  /// Scale the icon/caption layers' steady-state opacity expression (the
  /// dim×anim_o×viewed product, [_pinRevealOpacityExpr]) by [t]
  /// (0 = invisible, 1 = steady state) — `['*', steadyExpr, t]`. Untyped
  /// escape hatch, same precedent as the transition setters in
  /// `_installClusterSourceAndLayers`.
  Future<void> _setOpeningRevealOpacity(double t) async {
    final map = _mapboxMap;
    if (map == null) return;
    final List<Object> expr = <Object>['*', _pinRevealOpacityExpr(), t];
    await map.style.setStyleLayerProperty(
      _unclusteredIconLayerId,
      'icon-opacity',
      expr,
    );
    // PROD-3828: only when the caption layer was actually added — this method
    // is NOT individually try/caught (its caller catches), so a throw here
    // would abort the whole opening reveal.
    if (!widget.showPinCaptions) return;
    await map.style.setStyleLayerProperty(
      _unclusteredCaptionLayerId,
      'text-opacity',
      expr,
    );
  }

  /// Restore the plain steady-state expressions (exactly what the layers were
  /// created with — the full dim×anim_o×viewed product, NOT anything less,
  /// which would wipe the other factors). The two calls are try/caught
  /// independently — pins must never stick dim because one layer's restore
  /// failed.
  Future<void> _restoreOpeningRevealOpacity() async {
    final map = _mapboxMap;
    if (map == null) return;
    try {
      await map.style.setStyleLayerProperty(
        _unclusteredIconLayerId,
        'icon-opacity',
        _pinRevealOpacityExpr(),
      );
    } catch (_) {}
    if (widget.showPinCaptions) {
      try {
        await map.style.setStyleLayerProperty(
          _unclusteredCaptionLayerId,
          'text-opacity',
          _pinRevealOpacityExpr(),
        );
      } catch (_) {}
    }
  }

  /// FALLBACK opening reveal (see the section comment above): land the final
  /// pin set invisibly, then fade the icon + caption layers in over
  /// [kMapRevealFadeMs] (cubic ease-out). Failure-safe at every stage: any
  /// error degrades to an instant one-paint reveal, and the steady-state
  /// expressions are restored no matter what — pins can never end up stuck
  /// dim or invisible.
  Future<void> _runOpeningRevealFade() async {
    // Surfaces without the icon/caption layers (plain colored-circle pins)
    // have nothing to fade — keep the instant reveal. Unreachable today
    // (the settle only arms on the Map page, which is categoryIcons-only),
    // but guards the layer ids against a future non-icon settle consumer.
    if (_mapboxMap == null || !widget.categoryIcons) {
      await _renderMarkers();
      return;
    }
    var dimmed = false;
    try {
      await _setOpeningRevealOpacity(0);
      dimmed = true;
    } catch (_) {
      // The multiplier may have landed on one layer and failed on the other
      // — restore immediately so nothing sticks invisible; the reveal
      // degrades to the instant paint below.
      await _restoreOpeningRevealOpacity();
    }
    if (!dimmed) {
      await _renderMarkers();
      return;
    }
    try {
      // The final pin set (fetched during the opening ease, held back by the
      // `_openSettled` gate) lands while the layers are invisible.
      await _renderMarkers();
      // Await-loop rather than Timer.periodic: each step is two platform-
      // channel calls, so pacing off the previous step's completion means
      // steps can never overlap or pile up. ~12 steps at ~29ms.
      const stepMs = 29;
      final clock = Stopwatch()..start();
      while (mounted && clock.elapsedMilliseconds < kMapRevealFadeMs) {
        final t = clock.elapsedMilliseconds / kMapRevealFadeMs;
        final inv = 1 - t;
        await _setOpeningRevealOpacity(1 - inv * inv * inv);
        await Future<void>.delayed(const Duration(milliseconds: stepMs));
      }
    } catch (_) {
      // A failed step just leaves the last multiplier in place; the restore
      // below snaps straight to steady state.
    } finally {
      await _restoreOpeningRevealOpacity();
    }
  }

  // ── PROD-3000 phase 2: per-pin staggered reveal (Map page, mirror of web) ─
  //
  // Each NEW individual pin fades + scales up + lifts on its own randomly-
  // staggered schedule (shared curves/tokens in `map_marker_model.dart`).
  // Web drives this with a 16 ms full-`setData` loop; re-sending the whole
  // collection per frame re-tiles the native source over the platform
  // channel, so native instead PARTIALLY updates only the animating features
  // per frame via `updateGeoJSONSourceFeatures` (matched by the feature-level
  // GeoJSON `id`). Because a partial update replaces the WHOLE feature, each
  // frame's feature carries its complete props (see [_pinFeatureProps]) with
  // the `anim_*` values stamped on top. Post-pan refetches reuse the same
  // machinery (diff vs [_shownPinIds]); pins that appear mid-pan are
  // baselined without animating, exactly like web.

  /// Pin ids currently rendered (individual pins only). The baseline the
  /// diff-animate compares each new render against — new ids animate in, ids
  /// that persist stay put.
  Set<String> _shownPinIds = <String>{};

  /// Animating pins → the clock ms at which each one's animation starts.
  /// Present only while a pin is mid-reveal; pruned as they finish / leave.
  final Map<String, int> _pinAppearAt = <String, int>{};

  /// Monotonic clock shared by all pin reveals (so overlapping batches align).
  final Stopwatch _animClock = Stopwatch()..start();
  final math.Random _rng = math.Random();

  /// Light haptic as each pin touches down, throttled so a dense reveal is a
  /// patter and not a buzz. Shared with web (where it no-ops) so the two
  /// renderers can't drift — see [MapPinLandingHaptics].
  final MapPinLandingHaptics _landingHaptics = MapPinLandingHaptics();

  /// True while the camera is mid-move (user pan/zoom or a programmatic
  /// ease). New pins that appear while moving are baselined but NOT animated —
  /// they slide in with the map; the next settle animates the refetch's new
  /// pins. Set in `_onCameraChanged`, cleared in `_onMapIdle`.
  bool _cameraMoving = false;

  /// Re-entry guard for [_runRevealLoop] (a running loop picks up newly-armed
  /// pins from [_pinAppearAt] on its next frame).
  bool _revealLoopRunning = false;

  /// One-shot: arm the next render regardless of [_cameraMoving]. Set for the
  /// OPENING reveal — that moment is definitionally settled, but the deferred
  /// viewport padding applied just before it is itself a (suppressed) camera
  /// write whose `camera-changed` event arrives asynchronously and can land
  /// right before the arm, reading as "mid-move" — which silently baselined
  /// the opening pins without animation. Web has no such hole: its
  /// `setPadding` fires move/moveend synchronously, so the flag has already
  /// toggled back by render time.
  bool _forceNextRevealArm = false;

  /// Icon base size (px) at the reveal's zoom — converts the lift px into
  /// icon-size units (Mapbox multiplies `icon-offset` by `icon-size`). Read
  /// once per loop run (reveals only arm while the camera is settled, so the
  /// zoom is stable for their duration); web reads it per frame only because
  /// that read is free there.
  double _revealBaseIconSize = MapPinIconTokens.iconSizeForZoom(14);

  /// Diff-arm: give every genuinely-new individual pin a random start within
  /// the stagger window (settled camera only), refresh the baseline, prune
  /// gone ids. Called by `_updateClusterSource` before it writes the source,
  /// so the write already carries the armed pins' `local = 0` (invisible)
  /// stamps. Mirror of web's `_renderPinsDiffAnimate` arming block.
  void _armNewPinReveals() {
    final currentIds = <String>{};
    for (final m in widget.markers) {
      if (m.type == MapMarkerType.userLocation) continue;
      if (m.overflowCount != null) continue; // bubbles never animate
      currentIds.add(m.id);
    }
    if (!_cameraMoving || _forceNextRevealArm) {
      final now = _animClock.elapsedMilliseconds;
      for (final id in currentIds) {
        if (!_shownPinIds.contains(id)) {
          _pinAppearAt[id] =
              now + (_rng.nextDouble() * kMapRevealStaggerMs).round();
        }
      }
    }
    _forceNextRevealArm = false;
    _shownPinIds = currentIds;
    _pinAppearAt.removeWhere((id, _) => !currentIds.contains(id));
  }

  /// The per-frame partial-update loop: writes each animating pin's full
  /// feature (props + current `anim_*`) via `updateGeoJSONSourceFeatures`,
  /// paced off the previous frame's completion (steps can never pile up on
  /// the channel), and exits once every animation has finished. Failure-safe:
  /// any error clears the animation state and snaps to a plain full render —
  /// pins can never stick invisible.
  Future<void> _runRevealLoop() async {
    if (_revealLoopRunning) return;
    _revealLoopRunning = true;
    var frames = 0;
    var channelMsTotal = 0;
    var channelMsMax = 0;
    try {
      final map = _mapboxMap;
      if (map == null) return;
      try {
        final cam = await map.getCameraState();
        _revealBaseIconSize = MapPinIconTokens.iconSizeForZoom(
          cam.zoom,
          stops: _pinStops,
        );
      } catch (_) {
        _revealBaseIconSize = MapPinIconTokens.iconSizeForZoom(
          widget.zoom,
          stops: _pinStops,
        );
      }
      while (mounted && _mapboxMap != null && _pinAppearAt.isNotEmpty) {
        final clock = _animClock.elapsedMilliseconds;
        final feats = <Feature>[];
        final finished = <String>[];
        for (final entry in _pinAppearAt.entries) {
          final m = _markerLookup[entry.key];
          if (m == null) {
            // Marker left mid-animation (refetch) — nothing to draw.
            finished.add(entry.key);
            continue;
          }
          if (clock >= entry.value + kMapRevealFadeMs) {
            // Final frame: stamped at local = 1.0 (exactly settled values),
            // THEN pruned — so the feature's last written state matches the
            // coalesce defaults a later full rewrite falls back to.
            finished.add(entry.key);
            // …and that settled frame IS the touchdown. (The `m == null` branch
            // above also finishes a pin, but that one left mid-air — no land.)
            _landingHaptics.pinLanded(clock);
          }
          final props = _pinFeatureProps(
            m,
            isSelected:
                (widget.selectedMarkerId != null &&
                    m.id == widget.selectedMarkerId) ||
                (widget.selectedMarkerIds?.contains(m.id) ?? false),
          );
          _stampRevealProps(props, m.id);
          feats.add(
            Feature(
              id: m.id,
              geometry: Point(coordinates: Position(m.lng, m.lat)),
              properties: props,
            ),
          );
        }
        finished.forEach(_pinAppearAt.remove);
        if (feats.isNotEmpty) {
          final sw = Stopwatch()..start();
          await map.style.updateGeoJSONSourceFeatures(
            _clusterSourceId,
            'reveal-anim',
            feats,
          );
          sw.stop();
          frames++;
          channelMsTotal += sw.elapsedMilliseconds;
          if (sw.elapsedMilliseconds > channelMsMax) {
            channelMsMax = sw.elapsedMilliseconds;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      if (kDebugMode && frames > 0) {
        // Headroom signal: avg/max ms a frame's partial update spends on the
        // platform channel. Well under 16 ms avg = comfortable on slower
        // devices too; near/over it = the animation is channel-bound.
        debugPrint(
          'map reveal: $frames frames, channel avg '
          '${(channelMsTotal / frames).toStringAsFixed(1)}ms, '
          'max ${channelMsMax}ms',
        );
      }
    } catch (_) {
      // Degrade: abandon the animation and snap everything to its settled
      // state with a plain full render (anim props absent → coalesce
      // defaults). The user sees pins pop — never pins stuck invisible.
      _pinAppearAt.clear();
      try {
        await _updateClusterSource();
      } catch (_) {}
    } finally {
      _revealLoopRunning = false;
      // Pins armed while the loop was unwinding (rare race: a refetch landed
      // between the empty-check and here) still animate.
      if (mounted && _pinAppearAt.isNotEmpty) {
        _runRevealLoop();
      }
    }
  }

  /// The opening reveal (settle-completion entry point): render the final pin
  /// set — the diff-arm inside `_updateClusterSource` marks every pin new →
  /// they land invisible (`local = 0` stamps) and the loop staggers them in.
  /// If the per-pin path fails outright, fall back to the phase-1 whole-layer
  /// fade, which does its own render and is itself failure-safe.
  Future<void> _runOpeningReveal() async {
    try {
      // Force-arm: see [_forceNextRevealArm] — the padding write just before
      // this can leave `_cameraMoving` momentarily true, which would baseline
      // the opening pins without animation.
      _forceNextRevealArm = true;
      await _renderMarkers();
      if (widget.customSelection && _pinAppearAt.isNotEmpty) {
        _runRevealLoop();
      }
    } catch (_) {
      _forceNextRevealArm = false;
      _pinAppearAt.clear();
      await _runOpeningRevealFade();
    }
  }

  /// Reads the current camera + visible bounds into a [MapCameraState]
  /// (the platform-agnostic shape the Map page consumes). Returns null if
  /// the map isn't ready or a platform-channel read fails.
  Future<MapCameraState?> _readCameraState() async {
    final map = _mapboxMap;
    if (map == null) return null;
    try {
      // PROD-2671 (Map page): report the VISIBLE rectangle (canvas minus the
      // top-bar + drawer chrome, pulled a margin in) so the query + selection
      // cover only what the user sees — mirrors the web `_visibleRectCameraState`.
      final top = widget.viewportPaddingTop;
      final bottom = widget.viewportPaddingBottom;
      if (top > 0 || bottom > 0) {
        final visible = await _visibleRectCameraState(map, top, bottom);
        if (visible != null) return visible;
        // Size not cached yet → fall through to the full-bounds path below.
      }
      final cam = await map.getCameraState();
      final bounds = await map.coordinateBoundsForCamera(
        CameraOptions(
          center: cam.center,
          zoom: cam.zoom,
          bearing: cam.bearing,
          pitch: cam.pitch,
          padding: cam.padding,
        ),
      );
      final center = cam.center.coordinates;
      final ne = bounds.northeast.coordinates;
      final sw = bounds.southwest.coordinates;
      return MapCameraState(
        centerLat: center.lat.toDouble(),
        centerLng: center.lng.toDouble(),
        zoom: cam.zoom,
        neLat: ne.lat.toDouble(),
        neLng: ne.lng.toDouble(),
        swLat: sw.lat.toDouble(),
        swLng: sw.lng.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  /// PROD-2671 (native parity with the web `_visibleRectCameraState`): the camera
  /// state for the VISIBLE rectangle — the canvas with the [top]/[bottom] chrome
  /// insets removed, then pulled [kMapSearchAreaMarginFraction] further in on all
  /// four sides, so the `/map/pins` query + pin selection cover only the
  /// unobstructed area (not the strips behind the top bar + results drawer).
  /// Corners come from `coordinateForPixel` (native's pixel→coord, the analog of
  /// web `unproject`) over the inset pixel rect, using the LayoutBuilder-cached
  /// viewport size. Assumes a north-up map (no bearing/pitch on the Map page).
  /// Returns null if the viewport size isn't cached yet (→ caller falls back to
  /// full bounds).
  Future<MapCameraState?> _visibleRectCameraState(
    MapboxMap map,
    double top,
    double bottom,
  ) async {
    final w = _viewportWidth;
    final h = _viewportHeight;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    // Clamp so a drawer/chrome taller than the canvas can't invert the rect.
    final usableTop = top.clamp(0.0, h - 1);
    final usableBottom = bottom.clamp(0.0, h - usableTop - 1);
    final visTop = usableTop;
    final visBottom = h - usableBottom;
    final visHeight = visBottom - visTop;
    final marginX = w * kMapSearchAreaMarginFraction;
    final marginY = visHeight * kMapSearchAreaMarginFraction;
    final xLeft = marginX;
    final xRight = w - marginX;
    final yTop = visTop + marginY;
    final yBottom = visBottom - marginY;
    final cam = await map.getCameraState();
    // Top-left pixel → NW corner (max lat, min lng); bottom-right → SE corner
    // (min lat, max lng). NE/SW compose from those.
    final topLeft = await map.coordinateForPixel(
      ScreenCoordinate(x: xLeft, y: yTop),
    );
    final bottomRight = await map.coordinateForPixel(
      ScreenCoordinate(x: xRight, y: yBottom),
    );
    final centerPt = await map.coordinateForPixel(
      ScreenCoordinate(x: (xLeft + xRight) / 2, y: (yTop + yBottom) / 2),
    );
    final nw = topLeft.coordinates;
    final se = bottomRight.coordinates;
    final c = centerPt.coordinates;
    return MapCameraState(
      centerLat: c.lat.toDouble(),
      centerLng: c.lng.toDouble(),
      zoom: cam.zoom,
      neLat: nw.lat.toDouble(),
      neLng: se.lng.toDouble(),
      swLat: se.lat.toDouble(),
      swLng: nw.lng.toDouble(),
    );
  }

  /// PROD-2671 (native parity): apply chrome-aware camera padding so the map
  /// centres/frames within the visible area (above the drawer, below the top
  /// bar). Native has no synchronous `setPadding`, and `setCamera` fires a
  /// camera-change **asynchronously**, so we hold [_suppressMoveCallback] with a
  /// short tail (`_moveSuppressTailMs`) around it — a padding shift is not a user
  /// pan and must not cancel the in-flight fetch or emit a settle. Reads the
  /// current camera first and re-sends centre/zoom so only padding changes.
  /// No-op when no insets are set (every non-Map surface).
  void _applyViewportPadding() {
    final map = _mapboxMap;
    if (map == null || !_mapReady) return;
    final top = widget.viewportPaddingTop;
    final bottom = widget.viewportPaddingBottom;
    if (top <= 0 && bottom <= 0) return;
    _suppressMoveCallback = true;
    () async {
      try {
        final cam = await map.getCameraState();
        await map.setCamera(
          CameraOptions(
            center: cam.center,
            zoom: cam.zoom,
            bearing: cam.bearing,
            pitch: cam.pitch,
            padding: MbxEdgeInsets(top: top, left: 0, bottom: bottom, right: 0),
          ),
        );
      } catch (_) {
        // Padding is a nicety; a failure just leaves the camera unpadded.
      } finally {
        // Release suppression after a beat so the trailing async camera-change
        // from setCamera doesn't read as a user pan.
        Timer(const Duration(milliseconds: _moveSuppressTailMs), () {
          if (mounted) _suppressMoveCallback = false;
        });
      }
    }();
  }

  /// PROD-2046 Option A — pans the camera so that [marker] lands at
  /// the fixed screen target `(viewport.width / 2, viewport.height *
  /// _pinTargetYFraction)`, then fires `widget.onMarkerTap` AFTER the
  /// ease completes (PROD-2046 part 2 — tooltip never renders
  /// mid-animation).
  ///
  /// Falls back to firing `onMarkerTap` immediately at the marker's
  /// current projected position if the map / viewport size aren't
  /// ready yet (defensive — shouldn't happen in practice).
  Future<void> _easeAndShowTooltip(MapMarker marker) async {
    final map = _mapboxMap;
    // PROD-2671: Map page (no tooltip) → fire onMarkerTap IMMEDIATELY and do
    // NOT ease the camera. The tooltip-placement ease + deferred timer are only
    // for surfaces that render a tooltip; on the Map page they just move the
    // map and make the tap flaky (the deferred fire could be cancelled).
    if (!widget.centerOnMarkerTap) {
      if (map == null) {
        widget.onMarkerTap?.call(marker, Offset.zero);
        return;
      }
      var pixel = Offset.zero;
      try {
        final screen = await map.pixelForCoordinate(
          Point(coordinates: Position(marker.lng, marker.lat)),
        );
        pixel = Offset(screen.x.toDouble(), screen.y.toDouble());
      } catch (_) {}
      widget.onMarkerTap?.call(marker, pixel);
      return;
    }
    final w = _viewportWidth;
    final h = _viewportHeight;
    if (map == null || w == null || h == null) {
      if (map == null) return;
      final screen = await map.pixelForCoordinate(
        Point(coordinates: Position(marker.lng, marker.lat)),
      );
      widget.onMarkerTap?.call(
        marker,
        Offset(screen.x.toDouble(), screen.y.toDouble()),
      );
      return;
    }

    final pinTargetY = h * _pinTargetYFraction;
    final targetX = w / 2;

    // Compute the geographic centre that will put the marker at the
    // target screen position: shift the current centre in screen
    // coords by (pin - target), then unproject.
    final pinPoint = Point(coordinates: Position(marker.lng, marker.lat));
    final pinScreen = await map.pixelForCoordinate(pinPoint);

    final cameraState = await map.getCameraState();
    final centerScreen = await map.pixelForCoordinate(cameraState.center);

    final newCenterScreen = ScreenCoordinate(
      x: centerScreen.x.toDouble() - (pinScreen.x.toDouble() - targetX),
      y: centerScreen.y.toDouble() - (pinScreen.y.toDouble() - pinTargetY),
    );
    final newCenter = await map.coordinateForPixel(newCenterScreen);

    // Cancel any in-flight ease's deferred tooltip — only the latest
    // tap should show its tooltip.
    _pendingTooltipShow?.cancel();
    // PROD-2046: close the currently-open tooltip (if any) BEFORE
    // the ease starts so the user doesn't see the old card floating
    // in place while the map pans to the new pin. The shell reopens
    // the tooltip after the ease completes with the new marker's
    // content. No-op on first tap (no tooltip open).
    widget.onMapTapOutside?.call();
    _suppressMoveCallback = true;
    // Fire-and-forget the flyTo. The tooltip-show timer below mirrors
    // the ease duration; clearing the suppress flag there matches the
    // user-perceived "ease finished" moment.
    unawaited(
      map.flyTo(
        CameraOptions(center: newCenter),
        MapAnimationOptions(duration: _pinEaseDurationMs),
      ),
    );
    _pendingTooltipShow = Timer(
      const Duration(milliseconds: _pinEaseDurationMs),
      () {
        _pendingTooltipShow = null;
        if (!mounted) return;
        // Show the tooltip first, then clear the suppress flag a bit
        // later — guards against a trailing camera-change event from
        // the ease closing the tooltip we just opened.
        widget.onMarkerTap?.call(marker, Offset(targetX, pinTargetY));
        Future.delayed(const Duration(milliseconds: _moveSuppressTailMs), () {
          if (mounted) _suppressMoveCallback = false;
        });
      },
    );
  }

  Future<void> _renderMarkers() async {
    if (!_mapReady || _mapboxMap == null) return;

    // PROD-2016: cluster path is the only rendering pipeline now.
    // Venue/event pins flow through the GeoJsonSource + style layers;
    // user-location markers go through the CircleAnnotationManager
    // (single point, no clustering, simpler).
    await _circleManager?.deleteAll();
    _circleAnnotations.clear();
    _markerLookup.clear();
    for (final m in widget.markers) {
      _markerLookup[m.id] = m;
      if (m.type == MapMarkerType.userLocation) {
        await _addMarker(m);
      }
    }
    await _updateClusterSource();
    await _applySymbolZOrder();
    await _updateUserAccuracyCircle();
  }

  /// PROD-3004: the last `symbol-z-order` we wrote to the style, or null if we
  /// haven't written to THIS style yet. Reset wherever [_clusterLayersInstalled]
  /// is — a new style's layers are born at their definition's value, so a stale
  /// cache here would make [_applySymbolZOrder] skip a write it needed.
  String? _appliedSymbolZOrder;

  static SymbolZOrder _symbolZOrderEnum(String value) =>
      value == 'viewport-y' ? SymbolZOrder.VIEWPORT_Y : SymbolZOrder.AUTO;

  /// PROD-3004: the flat-pool tie-break gate — identical to web's
  /// `_applySymbolZOrder`, and the reason the two platforms now agree.
  ///
  /// Both sort keys are defined statically on their layers; this flips
  /// `symbol-z-order` between `auto` (scores vary → the keys drive caption
  /// priority + icon z-order, PROD-2940) and `viewport-y` (flat pool → Mapbox
  /// ignores the keys; icons get true viewport-Y depth, captions fall back to
  /// source order). `viewport-y` MASKS the key rather than requiring us to unset
  /// it, which is what makes this expressible on native at all — the SDK can't
  /// unset a layout property. See [mapSymbolZOrder].
  ///
  /// Writes only on change: a layout-property write re-lays out the symbol
  /// bucket, and flatness flips rarely (in practice, only when relevance scoring
  /// turns on — PROD-2985). GL JS no-ops an unchanged `setLayoutProperty`; the
  /// native SDK does not, hence the cache.
  Future<void> _applySymbolZOrder() async {
    final map = _mapboxMap;
    if (map == null || !_clusterLayersInstalled || !widget.categoryIcons) {
      return;
    }
    final zOrder = mapSymbolZOrder(widget.markers);
    if (zOrder == _appliedSymbolZOrder) return;
    try {
      for (final layerId in <String>[
        _unclusteredIconLayerId,
        // PROD-3828: only when the caption layer was actually added. Unlike
        // web, this loop's `try` wraps ALL layers — a throw on a missing
        // caption layer would also skip the applied-value cache below and
        // re-attempt the write on every marker update.
        if (widget.showPinCaptions) _unclusteredCaptionLayerId,
      ]) {
        await map.style.setStyleLayerProperty(
          layerId,
          'symbol-z-order',
          zOrder,
        );
      }
      _appliedSymbolZOrder = zOrder;
    } catch (_) {
      // Style/layer not ready. Leave the cache unset so the next marker update
      // retries; the layer definition's initial value stands meanwhile.
      _appliedSymbolZOrder = null;
    }
  }

  /// PROD-2993: the last `captionSizeMul` we wrote to the style, or null if we
  /// haven't written to THIS style yet. Dropped alongside [_clusterLayersInstalled]
  /// (see `_onMapCreated`) — a new style's caption layers are born at their
  /// definition's value, so a stale cache would skip a needed write.
  double? _appliedCaptionSizeMul;

  /// PROD-2993: re-apply the caption `text-offset` so it tracks the pin's size
  /// when the results-highlight enlargement ([MapboxMapPlatform.captionSizeMul])
  /// turns on or off (the narrow half-drawer open/close). The layers are BORN
  /// with the right value; this handles the later change. A layout-property write
  /// only — it moves no camera, so it can't re-enter Dart mid-layout. Writes only
  /// on change: the native SDK does NOT no-op an unchanged layout write, and a
  /// caption re-lift re-lays out the symbol bucket. Mirror of web's twin.
  Future<void> _applyCaptionOffset() async {
    final map = _mapboxMap;
    if (map == null || !_clusterLayersInstalled || !widget.categoryIcons) {
      return;
    }
    if (widget.captionSizeMul == _appliedCaptionSizeMul) return;
    final offset = MapPinIconTokens.captionOffsetExpression(
      sizeMul: widget.captionSizeMul,
      stops: _pinStops,
    );
    // The lone-pin caption always; the stack's count-label caption only when the
    // custom-selection stack layout re-pointed it into a right-side caption.
    final layerIds = <String>[
      // PROD-3828: only when the caption layer was actually added.
      if (widget.showPinCaptions) _unclusteredCaptionLayerId,
      if (widget.customSelection) _clusterCountLayerId,
    ];
    try {
      for (final layerId in layerIds) {
        await map.style.setStyleLayerProperty(layerId, 'text-offset', offset);
      }
      _appliedCaptionSizeMul = widget.captionSizeMul;
    } catch (_) {
      // Style/layer not ready. Leave the cache unset so the next change retries;
      // the layer definition's initial value stands meanwhile.
      _appliedCaptionSizeMul = null;
    }
  }

  /// PROD-2671: install the user-location **accuracy ring** — a GeoJSON fill +
  /// outline polygon, empty until [_updateUserAccuracyCircle] populates it.
  Future<void> _installUserAccuracyLayer() async {
    final map = _mapboxMap;
    if (map == null || _userAccuracyInstalled) return;
    // Non-fatal: the accuracy ring is secondary — a failure here must never
    // break pin rendering or the map lifecycle.
    try {
      await map.style.addSource(
        GeoJsonSource(
          id: _userAccuracySourceId,
          data: _emptyFeatureCollectionJson,
        ),
      );
      await map.style.addLayer(
        FillLayer(
          id: _userAccuracyFillLayerId,
          sourceId: _userAccuracySourceId,
          fillColor: kAccuracyRingFillColorArgb,
        ),
      );
      await map.style.addLayer(
        LineLayer(
          id: _userAccuracyLineLayerId,
          sourceId: _userAccuracySourceId,
          lineColor: kAccuracyRingLineColorArgb,
          lineWidth: kAccuracyRingLineWidth,
        ),
      );
      _userAccuracyInstalled = true;
    } catch (e) {
      _mapBreadcrumb('accuracy ring install failed', data: {'error': '$e'});
    }
  }

  /// PROD-2671: set (or clear) the accuracy-ring polygon from the user-location
  /// marker's `accuracyM`. Drawn only for an imprecise fix (≥ threshold); a
  /// precise fix (or no user marker) leaves the ring empty.
  Future<void> _updateUserAccuracyCircle() async {
    final map = _mapboxMap;
    if (map == null || !_userAccuracyInstalled) return;
    MapMarker? user;
    for (final m in widget.markers) {
      if (m.type == MapMarkerType.userLocation) {
        user = m;
        break;
      }
    }
    final acc = user?.accuracyM;
    final features = <Map<String, dynamic>>[];
    if (user != null && acc != null && acc >= kAccuracyRingMinMeters) {
      final ring = accuracyCircleRing(user.lat, user.lng, acc);
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <dynamic>[ring],
        },
        'properties': <String, dynamic>{},
      });
    }
    final json = jsonEncode(<String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    });
    // Non-fatal (see [_installUserAccuracyLayer]).
    try {
      await map.style.setStyleSourceProperty(
        _userAccuracySourceId,
        'data',
        json,
      );
    } catch (e) {
      _mapBreadcrumb('accuracy ring update failed', data: {'error': '$e'});
    }
  }

  /// PROD-3109: install the map-picker boundary source + a fill (below) and line
  /// (above) layer. Empty until [_updatePickerBoundary] fills it. Non-fatal.
  Future<void> _installPickerBoundaryLayer() async {
    final map = _mapboxMap;
    if (map == null || _pickerBoundaryInstalled) return;
    try {
      await map.style.addSource(
        GeoJsonSource(
          id: _pickerBoundarySourceId,
          data: _emptyFeatureCollectionJson,
        ),
      );
      await map.style.addLayer(
        FillLayer(
          id: _pickerBoundaryFillLayerId,
          sourceId: _pickerBoundarySourceId,
          fillColor: _pickerBoundaryFillColorArgb,
        ),
      );
      await map.style.addLayer(
        LineLayer(
          id: _pickerBoundaryLineLayerId,
          sourceId: _pickerBoundarySourceId,
          lineColor: _pickerBoundaryLineColorArgb,
          lineWidth: 2.0,
        ),
      );
      _pickerBoundaryInstalled = true;
    } catch (e) {
      _mapBreadcrumb('picker boundary install failed', data: {'error': '$e'});
    }
  }

  /// PROD-3109: set (or clear) the picker boundary polygon. Uses
  /// [MapboxMapPlatform.highlightBoundaryGeoJson] when present, else a small
  /// geodesic circle around [MapboxMapPlatform.highlightPoint], else empty.
  Future<void> _updatePickerBoundary() async {
    final map = _mapboxMap;
    if (map == null || !_pickerBoundaryInstalled) return;
    final geometry = widget.highlightBoundaryGeoJson;
    final point = widget.highlightPoint;

    final features = <Map<String, dynamic>>[];
    if (geometry != null) {
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': geometry,
        'properties': <String, dynamic>{},
      });
    } else if (point != null) {
      final ring = accuracyCircleRing(
        point.lat,
        point.lng,
        widget.highlightRadiusMeters ?? _pickerPointFallbackRadiusMeters,
      );
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <dynamic>[ring],
        },
        'properties': <String, dynamic>{},
      });
    }

    final json = jsonEncode(<String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    });
    try {
      await map.style.setStyleSourceProperty(
        _pickerBoundarySourceId,
        'data',
        json,
      );
    } catch (e) {
      _mapBreadcrumb('picker boundary update failed', data: {'error': '$e'});
    }
  }

  /// Picker drill-down: install the child-neighbourhood source + a light fill
  /// (below) and thin line (above) layer. Installed before the boundary layer so
  /// it renders beneath the selected highlight. Empty until
  /// [_updatePickerChildren] fills it. Non-fatal.
  Future<void> _installPickerChildrenLayer() async {
    final map = _mapboxMap;
    if (map == null || _pickerChildrenInstalled) return;
    try {
      await map.style.addSource(
        GeoJsonSource(
          id: _pickerChildrenSourceId,
          data: _emptyFeatureCollectionJson,
        ),
      );
      await map.style.addLayer(
        FillLayer(
          id: _pickerChildrenFillLayerId,
          sourceId: _pickerChildrenSourceId,
          fillColor: _pickerChildrenFillColorArgb,
        ),
      );
      await map.style.addLayer(
        LineLayer(
          id: _pickerChildrenLineLayerId,
          sourceId: _pickerChildrenSourceId,
          lineColor: _pickerChildrenLineColorArgb,
          lineWidth: 1.2,
        ),
      );
      _pickerChildrenInstalled = true;
    } catch (e) {
      _mapBreadcrumb('picker children install failed', data: {'error': '$e'});
    }
  }

  /// Picker drill-down: set (or clear) the tappable child polygons from
  /// [MapboxMapPlatform.childBoundariesGeoJson] (already a FeatureCollection).
  Future<void> _updatePickerChildren() async {
    final map = _mapboxMap;
    if (map == null || !_pickerChildrenInstalled) return;
    final fc = widget.childBoundariesGeoJson;
    final json = jsonEncode(
      fc ??
          const <String, dynamic>{
            'type': 'FeatureCollection',
            'features': <dynamic>[],
          },
    );
    try {
      await map.style.setStyleSourceProperty(
        _pickerChildrenSourceId,
        'data',
        json,
      );
    } catch (e) {
      _mapBreadcrumb('picker children update failed', data: {'error': '$e'});
    }
  }

  /// PROD-2971: install the admin debug-overlay source + a fill + line layer,
  /// both coloured per-feature via `['get', ...]` expressions so one pair of
  /// layers renders every shape. Empty until [_updateMapDebugOverlay] fills it.
  /// Non-fatal — a failure here must never break pin rendering.
  Future<void> _installMapDebugLayer() async {
    final map = _mapboxMap;
    if (map == null || _mapDebugInstalled) return;
    try {
      await map.style.addSource(
        GeoJsonSource(id: _mapDebugSourceId, data: _emptyFeatureCollectionJson),
      );
      await map.style.addLayer(
        FillLayer(
          id: _mapDebugFillLayerId,
          sourceId: _mapDebugSourceId,
          fillColorExpression: <Object>['get', 'fill_color'],
        ),
      );
      await map.style.addLayer(
        LineLayer(
          id: _mapDebugLineLayerId,
          sourceId: _mapDebugSourceId,
          lineColorExpression: <Object>['get', 'line_color'],
          lineWidthExpression: <Object>['get', 'line_width'],
        ),
      );
      _mapDebugInstalled = true;
    } catch (e) {
      _mapBreadcrumb('map debug overlay install failed', data: {'error': '$e'});
    }
  }

  /// PROD-2971: rebuild the debug overlay from `widget.debugOverlay` (or clear
  /// it when null). The shared [buildMapDebugOverlayGeoJson] builds the geometry
  /// so native + web can't drift.
  Future<void> _updateMapDebugOverlay() async {
    final map = _mapboxMap;
    if (map == null || !_mapDebugInstalled) return;
    final json = jsonEncode(
      buildMapDebugOverlayGeoJson(
        widget.debugOverlay,
        shapes: widget.debugOverlayShapes,
      ),
    );
    try {
      await map.style.setStyleSourceProperty(_mapDebugSourceId, 'data', json);
    } catch (e) {
      _mapBreadcrumb('map debug overlay update failed', data: {'error': '$e'});
    }
  }

  /// PROD-3124: install the dot-hints source + circle layer (mirror of the
  /// web side). One layer paints all colours via `['get', 'dot_color']`;
  /// radius tracks the dots' zoom curve ([dotRadiusStopsFlat]); opacity
  /// starts at 0 — [_syncDotHints] fades it in per data sync (the
  /// progressive reveal). Non-fatal — a failure here must never break pin
  /// rendering. Idempotent.
  Future<void> _installDotHintsLayer() async {
    final map = _mapboxMap;
    if (map == null || _dotHintsInstalled) return;
    try {
      await map.style.addSource(
        GeoJsonSource(id: _dotHintsSourceId, data: _emptyFeatureCollectionJson),
      );
      await map.style.addLayer(
        CircleLayer(
          id: _dotHintsLayerId,
          sourceId: _dotHintsSourceId,
          circleColorExpression: <Object>['get', 'dot_color'],
          circleRadiusExpression: <Object>[
            'interpolate',
            <Object>['linear'],
            <Object>['zoom'],
            ...dotRadiusStopsFlat(),
          ],
          circleOpacity: 0.0,
          // sokoInk — int form of [kDotHintStrokeColor] (typed layer wants ARGB).
          circleStrokeColor: 0xFF44131D,
          circleStrokeWidth: kDotHintStrokePx,
          circleStrokeOpacity: 0.0,
        ),
      );
      _dotHintsInstalled = true;
      await _syncDotHints();
    } catch (e) {
      _mapBreadcrumb('dot hints install failed', data: {'error': '$e'});
    }
  }

  /// PROD-3124: push the current dot hints into the source and run the
  /// progressive reveal — snap the layer invisible (zero-duration
  /// transition), swap the data, then fade fill + stroke to
  /// [kDotHintOpacity] after [kDotFadeDelayMs] over [kDotFadeDurationMs].
  /// Paint-property transitions: the GL engine tweens, no Dart frames. Pins
  /// paint instantly on the same settle, so they always land first. Gated on
  /// the Map page's opening reveal like the pins ([_openSettled]).
  Future<void> _syncDotHints() async {
    final map = _mapboxMap;
    if (map == null || !_dotHintsInstalled) return;
    final hide = widget.customSelection && !_openSettled;
    final data = hide ? null : widget.dotHintsGeoJson;
    final features = (data?['features'] as List<dynamic>?) ?? const <dynamic>[];
    // PROD-3656: a removal-only delta (dots auto-promoted to pins) swaps the
    // data and leaves the opacity alone — see [isDotHintRemovalOnly].
    final ids = dotHintIdsOf(data);
    final removalOnly =
        _dotHintsRevealed && isDotHintRemovalOnly(_dotHintIds, ids);
    // PROD-3690: a dot must never disappear before its own pin has finished
    // landing. Hold the whole swap — a removal-only delta means nothing else is
    // changing, so there is nothing else to miss. `_dotHintIds` is deliberately
    // NOT updated here: the deferred re-sync must still see the full delta.
    if (removalOnly && _deferDotRemovalForReveal(_dotHintIds.difference(ids))) {
      return;
    }
    _dotRemovalTimer?.cancel();
    _dotHintIds = ids;
    try {
      if (!removalOnly) {
        await _setDotHintOpacity(opacity: 0, durationMs: 0, delayMs: 0);
      }
      await map.style.setStyleSourceProperty(
        _dotHintsSourceId,
        'data',
        data == null ? _emptyFeatureCollectionJson : jsonEncode(data),
      );
      if (!removalOnly && features.isNotEmpty) {
        await _setDotHintOpacity(
          opacity: kDotHintOpacity,
          durationMs: kDotFadeDurationMs,
          delayMs: kDotFadeDelayMs,
        );
      }
      _dotHintsRevealed = features.isNotEmpty;
    } catch (e) {
      // The layer's actual state is now unknown — force a full reveal next time.
      _dotHintsRevealed = false;
      _mapBreadcrumb('dot hints sync failed', data: {'error': '$e'});
    }
  }

  /// PROD-3656 — the ids currently in the dot source, and whether the layer has
  /// been faded in for them. Together they decide whether the next sync can skip
  /// the reveal ([isDotHintRemovalOnly]).
  Set<String> _dotHintIds = const {};
  bool _dotHintsRevealed = false;

  /// PROD-3690 — pending deferred dot removal (see [_deferDotRemovalForReveal]).
  Timer? _dotRemovalTimer;

  /// PROD-3690 — should this removal-only dot delta wait for a pin to land?
  ///
  /// A promoted dot becomes a pin, and the pin animates in over
  /// [kMapRevealFadeMs] starting at a stagger-randomised moment. Removing the
  /// dot the instant the promotion lands would blink it away *under* a pin that
  /// hasn't appeared yet. `_pinAppearAt` holds an entry from the moment a pin is
  /// armed until the reveal loop prunes it at `start + kMapRevealFadeMs` — which
  /// is exactly the touchdown the landing haptic marks — so its keys are "pins
  /// still coming in".
  ///
  /// Returns true (and schedules the re-sync) when at least one [removed] id is
  /// mid-reveal. The wait is computed from the actual outstanding animations
  /// rather than a fixed delay, so it is self-limiting.
  ///
  /// Mirrors the web renderer's copy deliberately — same rule, same tokens, so
  /// the two platforms can't drift.
  bool _deferDotRemovalForReveal(Set<String> removed) {
    if (removed.isEmpty) return false;
    final now = _animClock.elapsedMilliseconds;
    var waitMs = 0;
    for (final id in removed) {
      final start = _pinAppearAt[id];
      if (start == null) continue;
      final remaining = start + kMapRevealFadeMs - now;
      if (remaining > waitMs) waitMs = remaining;
    }
    if (waitMs <= 0) return false;
    _dotRemovalTimer?.cancel();
    _dotRemovalTimer = Timer(Duration(milliseconds: waitMs), () {
      if (mounted) _syncDotHints();
    });
    return true;
  }

  /// Set the dot layer's fill + stroke opacity with a paint transition of
  /// [durationMs]/[delayMs] (0/0 = snap). The transition property is set
  /// BEFORE the value so the change animates with the intended timing (same
  /// untyped escape hatch as the `circle-*-transition` setters below).
  Future<void> _setDotHintOpacity({
    required double opacity,
    required int durationMs,
    required int delayMs,
  }) async {
    final map = _mapboxMap;
    if (map == null) return;
    final transition = <String, Object>{
      'duration': durationMs,
      'delay': delayMs,
    };
    await map.style.setStyleLayerProperty(
      _dotHintsLayerId,
      'circle-opacity-transition',
      transition,
    );
    await map.style.setStyleLayerProperty(
      _dotHintsLayerId,
      'circle-stroke-opacity-transition',
      transition,
    );
    await map.style.setStyleLayerProperty(
      _dotHintsLayerId,
      'circle-opacity',
      opacity,
    );
    await map.style.setStyleLayerProperty(
      _dotHintsLayerId,
      'circle-stroke-opacity',
      opacity,
    );
  }

  // ============================================================
  // PROD-1978: clustered source-layer path (native parity)
  // ============================================================
  //
  // Mirrors the web side. `mapbox_maps_flutter` v2.18 exposes typed
  // `GeoJsonSource`, `CircleLayer`, `SymbolLayer` via `mapboxMap.style`.
  // Cluster expansion zoom is requested via
  // `mapboxMap.getGeoJsonClusterExpansionZoom(sourceId, clusterFeatureMap)`.
  // Cluster + leaf taps are routed through the existing
  // `onTapListener: _onMapTap` — we call `queryRenderedFeatures` at the
  // tap point filtered by the cluster layer ids.

  /// True once the source + layers have been added. Guards against
  /// double-install when `_onMapCreated` re-runs (e.g. theme switch).
  bool _clusterLayersInstalled = false;
  bool _userAccuracyInstalled = false;
  bool _mapDebugInstalled = false;
  bool _dotHintsInstalled = false;
  bool _pickerBoundaryInstalled = false;
  bool _pickerChildrenInstalled = false;

  Future<void> _installClusterSourceAndLayers() async {
    final map = _mapboxMap;
    if (map == null || _clusterLayersInstalled) return;

    // PROD-3124: dot hints go in FIRST — Mapbox paints in layer-insertion
    // order, so installing before every pin layer below structurally
    // guarantees dots can never cover a pin, caption, or bubble. Mirror of
    // the web side.
    await _installDotHintsLayer();

    // PROD-2807: in custom-selection mode WE compute the "clusters" ourselves
    // (the `+k` overflow bubbles are markers carrying `overflowCount`), so
    // Mapbox's built-in clustering is OFF and the bubble layers key off our own
    // `overflow_count` property. Otherwise (every other consumer) Mapbox
    // clusters natively via `point_count`. Mirror of the web side.
    final bool nativeCluster = !widget.customSelection;
    // The property that flags a "bubble" feature + carries its count. Native
    // clustering → Mapbox's `point_count`; custom selection → our stamped
    // `overflow_count`. Drives the bubble layers' filter, radius, and label.
    final String bubbleCountKey = widget.customSelection
        ? 'overflow_count'
        : 'point_count';

    // GeoJsonSource takes data as a JSON string. Build an initial empty
    // FeatureCollection; `_updateClusterSource` will fill it on the
    // first `_renderMarkers` pass.
    final initialData = _buildPinsGeoJsonString(const <MapMarker>[]);
    await map.style.addSource(
      GeoJsonSource(
        id: _clusterSourceId,
        data: initialData,
        cluster: nativeCluster,
        clusterRadius: MapClusterTokens.sourceClusterRadius,
        clusterMaxZoom: MapClusterTokens.sourceClusterMaxZoom,
        // PROD-1993: per-type counts on each cluster — drives a
        // homogeneous-vs-mixed color decision in the cluster paint
        // below. Mirror of the web side. Only meaningful under native
        // clustering; custom-selection bubbles carry their own
        // event/place breakdown as feature props.
        clusterProperties: nativeCluster
            ? <String, dynamic>{
                'event_count': <dynamic>[
                  '+',
                  <dynamic>[
                    'case',
                    <dynamic>[
                      '==',
                      <dynamic>['get', 'item_type'],
                      'event',
                    ],
                    1,
                    0,
                  ],
                ],
                'place_count': <dynamic>[
                  '+',
                  <dynamic>[
                    'case',
                    <dynamic>[
                      '==',
                      <dynamic>['get', 'item_type'],
                      'place',
                    ],
                    1,
                    0,
                  ],
                ],
              }
            : null,
      ),
    );

    // Cluster bubble color (PROD-1993): mirror the unclustered pin
    // colors when the cluster is homogeneous — pure-place → Soko Blue,
    // pure-event → Soko Green — and fall back to the neutral Soko Pink
    // for mixed clusters (or markers without a category).
    final clusterTextColor = _colorToAARRGGBB(
      AppColors.mapClusterText.toARGB32(),
    );
    final clusterColorExpression = <Object>[
      'case',
      <Object>[
        'all',
        <Object>[
          '>',
          <Object>['get', 'event_count'],
          0,
        ],
        <Object>[
          '>',
          <Object>['get', 'place_count'],
          0,
        ],
      ],
      _colorHexString(AppColors.mapClusterFill.toARGB32()),
      <Object>[
        '>',
        <Object>['get', 'event_count'],
        0,
      ],
      _colorHexString(AppColors.mapPinEvent.toARGB32()),
      <Object>[
        '>',
        <Object>['get', 'place_count'],
        0,
      ],
      _colorHexString(AppColors.mapPinVenue.toARGB32()),
      _colorHexString(AppColors.mapClusterFill.toARGB32()),
    ];
    await map.style.addLayer(
      CircleLayer(
        id: _clusterLayerId,
        sourceId: _clusterSourceId,
        filter: ['has', bubbleCountKey],
        circleColorExpression: clusterColorExpression,
        circleRadiusExpression: [
          'step',
          ['get', bubbleCountKey],
          MapClusterTokens.bubbleRadiusSmall,
          MapClusterTokens.mediumAt,
          MapClusterTokens.bubbleRadiusMedium,
          MapClusterTokens.largeAt,
          MapClusterTokens.bubbleRadiusLarge,
        ],
        circleStrokeColor: 0xFFFFFFFF,
        circleStrokeWidth: 2.0,
      ),
    );

    // Bubble count label: custom selection stamps a ready-made `+k` string
    // (`overflow_label`); native clustering uses Mapbox's built-in
    // `point_count_abbreviated` ("10k" etc.).
    await map.style.addLayer(
      SymbolLayer(
        id: _clusterCountLayerId,
        sourceId: _clusterSourceId,
        filter: ['has', bubbleCountKey],
        textFieldExpression: widget.customSelection
            ? ['get', 'overflow_label']
            : ['get', 'point_count_abbreviated'],
        textSize: 12.0,
        textColor: clusterTextColor,
      ),
    );

    // Unclustered pin — small filled circle, no label on top. Soko/Ink
    // border. Color via `match` expression on `category` (event = green,
    // venue = blue, else per-feature color or semantic default).
    await map.style.addLayer(
      CircleLayer(
        id: _unclusteredLayerId,
        sourceId: _clusterSourceId,
        filter: [
          '!',
          ['has', bubbleCountKey],
        ],
        // Semantic colour by item type. PROD-2205-followup dropped
        // the prior `case selected → mapPinSelected (yellow)` wrapper
        // — selection is now differentiated by radius + stroke
        // instead. Mirror of the web side.
        circleColorExpression: <Object>[
          'match',
          <Object>['get', 'item_type'],
          'event',
          _colorHexString(AppColors.mapPinEvent.toARGB32()),
          'place',
          _colorHexString(AppColors.mapPinVenue.toARGB32()),
          // Coalesce to per-feature `color` (if provided), otherwise
          // the semantic default.
          <Object>[
            'coalesce',
            <Object>['get', 'color'],
            _colorHexString(AppColors.mapPinDefault.toARGB32()),
          ],
        ],
        // PROD-2016 + PROD-2205-followup: enlarge the selected pin
        // via a `case` expression keyed on the per-feature `selected`
        // property stamped by the shell. Values come from
        // MapPinTokens so they stay in sync with the web side.
        circleRadiusExpression: <Object>[
          'case',
          <Object>[
            'boolean',
            <Object>['get', 'selected'],
            false,
          ],
          MapPinTokens.selectedRadius,
          MapPinTokens.unselectedRadius,
        ],
        // PROD-2042 Wave 2: selected pin always renders on top of
        // overlapping unselected pins.
        circleSortKeyExpression: <Object>[
          'case',
          <Object>[
            'boolean',
            <Object>['get', 'selected'],
            false,
          ],
          1,
          0,
        ],
        // PROD-2205-followup r2: selected stroke is a per-category
        // mix of `0.7 · pin fill + 0.3 · sokoPink` (pre-computed in
        // AppColors). Softer than the prior flat white, still high-
        // contrast against the basemap, and visually related to each
        // pin's semantic fill. The unselected default stays Soko/Ink
        // for subtle separation from the basemap. Mirror of the web
        // side.
        circleStrokeColorExpression: <Object>[
          'case',
          <Object>[
            'boolean',
            <Object>['get', 'selected'],
            false,
          ],
          <Object>[
            'match',
            <Object>['get', 'item_type'],
            'event',
            _colorHexString(AppColors.mapPinEventSelectedStroke.toARGB32()),
            'place',
            _colorHexString(AppColors.mapPinVenueSelectedStroke.toARGB32()),
            // Legacy / per-feature colour fallback.
            _colorHexString(AppColors.mapPinDefaultSelectedStroke.toARGB32()),
          ],
          _colorHexString(AppColors.sokoInk.toARGB32()),
        ],
        // PROD-2205-followup: stroke thickens on selection
        // (0.5 → 3 px). Paired with the radius bump above this is
        // the primary "you are here" cue now that the yellow fill
        // is gone.
        circleStrokeWidthExpression: <Object>[
          'case',
          <Object>[
            'boolean',
            <Object>['get', 'selected'],
            false,
          ],
          MapPinTokens.selectedStrokeWidth,
          MapPinTokens.unselectedStrokeWidth,
        ],
      ),
    );

    // PROD-2042 Wave 2 + PROD-2205-followup: animate the radius +
    // stroke transitions. The typed CircleLayer constructor doesn't
    // expose `circle*Transition` in mapbox_maps_flutter 2.18, so set
    // them via the untyped escape hatch (the underlying native SDK
    // supports them). Mirror of the web side's `circle-*-transition`
    // paint properties.
    await map.style.setStyleLayerProperty(
      _unclusteredLayerId,
      'circle-radius-transition',
      <String, Object>{'duration': 150, 'delay': 0},
    );
    await map.style.setStyleLayerProperty(
      _unclusteredLayerId,
      'circle-stroke-width-transition',
      <String, Object>{'duration': 150, 'delay': 0},
    );
    await map.style.setStyleLayerProperty(
      _unclusteredLayerId,
      'circle-stroke-color-transition',
      <String, Object>{'duration': 150, 'delay': 0},
    );

    // Note: the previous unclustered-label SymbolLayer ("A", "B", …) is
    // intentionally not added — single pins render unlabelled per the
    // latest design. Mirrors the web side.

    // PROD-2671/PROD-2807: category-icon mode — render per-category PNG
    // teardrops on top via a symbol layer, and make the unclustered circle
    // transparent (it stays in place purely as the tap hit target, so all the
    // tap wiring above keeps working). Off by default → every other consumer
    // keeps the colored-circle pins. Mirror of the web side.
    if (widget.categoryIcons) {
      // Scale pins with zoom so they don't dominate the basemap when zoomed
      // out yet stay a legible tap target up close. Used by the stack-of-5
      // layers (the single-pin layer takes [scoredIconSizeExpr] below, which
      // adds the reveal animation on top of the same curve).
      //
      // PROD-2993 (D14): the stacks honour the per-feature `icon_scale` too, so
      // the results-highlight enlargement covers them as well as the pins.
      // Bubbles historically omitted the property, so the `coalesce` default of
      // 1.0 keeps every pre-existing caller byte-identical. Folded INTO each
      // interpolate stop — a `["zoom"]` expression must stay top-level, so
      // Mapbox rejects `["*", <zoom interpolate>, …]`. Mirror of the web side.
      final List<Object> stackScale = <Object>[
        'coalesce',
        <Object>['get', 'icon_scale'],
        1,
      ];
      final List<Object> iconSizeExpr = <Object>[
        'interpolate',
        <Object>['linear'],
        <Object>['zoom'],
        for (final (zoom, size) in _pinStops) ...[
          zoom,
          <Object>['*', size, stackScale],
        ],
      ];

      // PROD-2671 cluster-focus: dim non-focused features when focus is
      // active — see [_pinDimOpacityExpr] (extracted for PROD-3000's opening
      // fade). In 2.24.2 SymbolLayer exposes typed `iconOpacityExpression`
      // / `textOpacityExpression` (→ `icon-opacity` / `text-opacity` paint).
      final List<Object> dimOpacityExpr = _pinDimOpacityExpr();

      // PROD-2989 + PROD-3000: the single-pin icon + caption layers' opacity
      // is the dim×anim_o×viewed product — see [_pinRevealOpacityExpr]
      // (mirror of web's `revealIconOpacity`). Applied ONLY to the
      // individual-pin icon + caption layers below (the stack layers + count
      // label keep the bare [dimOpacityExpr], so `+k` bubbles are unaffected).
      final List<Object> revealOpacityExpr = _pinRevealOpacityExpr();

      // PROD-3000: per-pin reveal-animation multipliers, stamped per frame by
      // the reveal loop onto animating features (absent → no change via
      // `coalesce`). `anim_s` folds INTO each icon-size interpolate stop (a
      // `["zoom"]` expression must stay top-level, so Mapbox rejects wrapping
      // the whole expression in `["*", …]`); `anim_off` is in icon-size units
      // (Mapbox multiplies icon-offset by icon-size), so the driver
      // size-compensates for the px it wants. Mirror of the web side.
      final List<Object> animScale = <Object>[
        'coalesce',
        <Object>['get', 'anim_s'],
        1,
      ];
      final List<Object> revealIconOffset = <Object>[
        'coalesce',
        <Object>['get', 'anim_off'],
        <Object>[
          'literal',
          <double>[0, 0],
        ],
      ];

      // PROD-2947 (FE-1): per-feature pool-relevance size multiplier (0.85–1.15;
      // absent → 1.0), folded into each interpolate stop of a single-pin-only
      // size expression — a `["zoom"]` interpolate must stay top-level, so
      // Mapbox rejects wrapping it in `["*", <zoom interpolate>, …]`. The stack
      // layers keep the plain [iconSizeExpr] (bubbles aren't score-styled).
      final List<Object> scoreScale = <Object>[
        'coalesce',
        <Object>['get', 'icon_scale'],
        1,
      ];
      // PROD-3828: selection enlargement — a fourth factor on the SINGLE-pin
      // layer only. Deliberately not applied to the `+k` stack layers
      // (`iconSizeExpr` above): "selected" is meaningless for a bubble
      // standing in for several markers, and stacks are `customSelection`-only
      // (Map page) anyway. No-op on the Map page, which passes neither
      // `selectedMarkerId` nor `selectedMarkerIds`, so `selected` is never
      // stamped and the `case` always takes its `1` default.
      final List<Object> selectedScale = _selectedScaleExpr;
      final List<Object> scoredIconSizeExpr = <Object>[
        'interpolate',
        <Object>['linear'],
        <Object>['zoom'],
        for (final (zoom, size) in _pinStops) ...[
          zoom,
          // PROD-3000: reveal `anim_s` folds into each stop (see above);
          // PROD-2947: score multiplier likewise. Mirror of web's
          // `revealIconSize`.
          <Object>['*', size, animScale, scoreScale, selectedScale],
        ],
      ];

      // Make the unclustered circle an invisible hit target: no fill, no
      // stroke, widened radius so it roughly covers the icon. The typed
      // CircleLayer above already installed the circle; flip its opacity to 0
      // and grow the radius via the untyped escape hatch (paint/layout props
      // the constructor set, now overridden). Mirror of the web
      // `setPaintProperty` calls.
      await map.style.setStyleLayerProperty(
        _unclusteredLayerId,
        'circle-opacity',
        0.0,
      );
      await map.style.setStyleLayerProperty(
        _unclusteredLayerId,
        'circle-stroke-opacity',
        0.0,
      );
      // PROD-2671: the teardrop is now BOTTOM-anchored (tip on the point, body
      // reaching up), so lift the hit circle ~20px and widen it to r24 to sit
      // over the visible pin body instead of the empty space below the tip.
      // Constant screen-px, tuned for the reading zoom (on-device candidate).
      // Mirror of the web `setPaintProperty` calls.
      await map.style.setStyleLayerProperty(
        _unclusteredLayerId,
        'circle-radius',
        24.0,
      );
      await map.style.setStyleLayerProperty(
        _unclusteredLayerId,
        'circle-translate',
        <double>[0, -20],
      );
      await map.style.setStyleLayerProperty(
        _unclusteredLayerId,
        'circle-translate-anchor',
        'viewport',
      );

      // Single-pin ICON layer — teardrop art only. Captions live in a SEPARATE
      // layer added directly above (see below), so a nearer pin's icon can no
      // longer paint over a farther pin's caption.
      await map.style.addLayer(
        SymbolLayer(
          id: _unclusteredIconLayerId,
          sourceId: _clusterSourceId,
          filter: <Object>[
            '!',
            <Object>['has', bubbleCountKey],
          ],
          iconImageExpression: <Object>['get', 'icon'],
          // PROD-2940: score-driven ICON draw order — a higher-scored pin's
          // teardrop draws ON TOP. Paired with the caption layer's sort-key below
          // so the caption-winner (highest score) is also the icon-on-top; both
          // key off the same stamped `sort_key = 1 − score`. INVERSE direction
          // from the caption layer, by design: this layer is `iconAllowOverlap:
          // true`, where Mapbox draws the HIGHER sort-key on top, so the key is
          // `1 − sort_key = score`.
          //
          // PROD-3004: set statically — same as web now. Whether the key is
          // HONOURED is `symbolZOrder`'s job (`_applySymbolZOrder`), below: a flat
          // pool sets `viewport-y`, which masks the key and gives real viewport-Y
          // depth. The old note here claimed native was stuck with source order
          // because the SDK can't unset a layout prop. True, but beside the point:
          // we never needed to unset it. See [mapSymbolZOrder].
          symbolSortKeyExpression: <Object>[
            '-',
            1,
            <Object>[
              'coalesce',
              <Object>['get', 'sort_key'],
              1,
            ],
          ],
          // PROD-3004: initial value must be correct at creation — the source is
          // populated right after, so waiting for the first `_renderMarkers` would
          // paint a frame in the wrong order. `_applySymbolZOrder` keeps it in step
          // from then on.
          symbolZOrder: _symbolZOrderEnum(mapSymbolZOrder(widget.markers)),
          // PROD-2947 (FE-1): score-scaled size (folds the per-feature
          // `icon_scale` into the zoom interpolate); stacks keep `iconSizeExpr`.
          iconSizeExpression: scoredIconSizeExpr,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
          // PROD-2671: BOTTOM anchor so the teardrop's tip sits ON the
          // coordinate (standard map-pin convention) — the tip marks the
          // location and the pin no longer drifts/floats as zoom scales it.
          iconAnchor: IconAnchor.BOTTOM,
          // PROD-3000: reveal lift — px converted to icon-size units by the
          // driver. Mirror of web's `revealIconOffset`.
          iconOffsetExpression: revealIconOffset,
          // PROD-2671 cluster-focus dim × PROD-3000 reveal fade ×
          // PROD-2989 viewed fade.
          iconOpacityExpression: revealOpacityExpr,
        ),
      );

      // PROD-3828: the caption layer is now GATED. It used to be added
      // unconditionally whenever `categoryIcons` was on, which meant a
      // consumer with no `pinTitle`/`pinSubtitle` still paid for an empty
      // `format` label and its placement work. Per-consumer flag rather than
      // inferring from a null title — see [MapboxMapPlatform.showPinCaptions].
      if (widget.showPinCaptions) {
        // Single-pin CAPTION layer — name + secondary facet, stacked ABOVE the
        // icon layer so captions always render on top of every pin (never occluded
        // by a neighbouring teardrop). Same source + filter as the icons; captions
        // still avoid each OTHER (`text-allow-overlap` default false +
        // `text-optional`). `text-field` is a `format` expression (name over
        // secondary facet) — passed as a raw expression list; the SDK JSON-encodes
        // the whole layout so the nested option-maps round-trip. Uses Open Sans
        // (Mapbox stock glyphs); the design's Zalando Sans isn't in the style glyph
        // set — a known font divergence, mirror of the web side.
        await map.style.addLayer(
          SymbolLayer(
            id: _unclusteredCaptionLayerId,
            sourceId: _clusterSourceId,
            filter: <Object>[
              '!',
              <Object>['has', bubbleCountKey],
            ],
            textFieldExpression: <Object>[
              'format',
              <Object>[
                'coalesce',
                <Object>['get', 'pin_title'],
                '',
              ],
              <String, Object>{
                'text-font': <Object>[
                  'literal',
                  <String>['Open Sans Semibold', 'Arial Unicode MS Bold'],
                ],
              },
              // PROD-3830: conditional separator — see the twin note in
              // `mapbox_map_web.dart`. A title-only caption used to render
              // "Title\n", reserving an empty second line and inflating the
              // collision box; the list maps (no facet ⇒ no subtitle) would
              // hit that on every caption.
              <Object>[
                'case',
                <Object>['has', 'pin_subtitle'],
                '\n',
                '',
              ],
              <Object>[
                'coalesce',
                <Object>['get', 'pin_subtitle'],
                '',
              ],
              <String, Object>{
                'font-scale': 0.9,
                'text-font': <Object>[
                  'literal',
                  <String>['Open Sans Regular', 'Arial Unicode MS Regular'],
                ],
              },
            ],
            textSize: 13.0,
            // PROD-2671 (Figma 6949-21685): caption to the RIGHT of the teardrop,
            // top-aligned with the pin top (title over secondary facet), ~6px
            // clear of the pin. Mirror of the web side — `TOP_LEFT` anchors the
            // block's top-left; the offset is a ZOOM-INTERPOLATED expression (via
            // `textOffsetExpression`, not the constant `textOffset`) so it tracks
            // the pin's scaled size at every zoom instead of drifting off the pin
            // when zoomed out. It is measured from the geometry point (like the
            // icon anchor), so splitting icon/text into two layers keeps the exact
            // position. See [MapPinIconTokens.captionOffsetExpression].
            textAnchor: TextAnchor.TOP_LEFT,
            textOffsetExpression: MapPinIconTokens.captionOffsetExpression(
              sizeMul: widget.captionSizeMul,
              stops: _pinStops,
            ),
            textJustify: TextJustify.LEFT,
            textOptional: true,
            // PROD-2940: score-driven caption placement priority. `text-allow-overlap`
            // is false (captions avoid each other), so the LOWER sort-key wins the
            // collision → the higher-scored pin keeps its caption. Key = the raw
            // stamped `sort_key = 1 − score` (NOT inverted — opposite of the icon
            // layer, because this layer's overlap rule is opposite).
            //
            // PROD-3004: because `textAllowOverlap` is false, this layer's
            // `canOverlap` is FALSE → it NEVER sorts by viewport-Y. With the key
            // masked (flat pool) it falls back to SOURCE order — same as web, which
            // is exactly the parity we're after. Mirror of the web layer.
            symbolSortKeyExpression: <Object>[
              'coalesce',
              <Object>['get', 'sort_key'],
              1,
            ],
            symbolZOrder: _symbolZOrderEnum(mapSymbolZOrder(widget.markers)),
            textMaxWidth: 12.0,
            textColor: _colorToAARRGGBB(AppColors.sokoInk.toARGB32()),
            textHaloColor: 0xFFFFFFFF,
            textHaloWidth: 1.0,
            // PROD-2671 cluster-focus: fade non-focused captions in step with
            // their icon (same `dim`/`anim_o`/`viewed` source props). Captions
            // fade with the reveal but don't scale/lift — web parity.
            textOpacityExpression: revealOpacityExpr,
          ),
        );
      }

      // Stack-of-5 cluster visual (custom selection only). The circle bubble
      // stays as a transparent tap hit target (its tap zooms to decluster); on
      // top we draw up to 5 member teardrops shifted 3 px up-and-left per layer
      // (`iconTranslate` = constant screen px, independent of icon-size), most-
      // relevant on top, and re-point the count label to a right-side title.
      // Mirror of the web side.
      if (widget.customSelection) {
        await map.style.setStyleLayerProperty(
          _clusterLayerId,
          'circle-opacity',
          0.0,
        );
        await map.style.setStyleLayerProperty(
          _clusterLayerId,
          'circle-stroke-opacity',
          0.0,
        );
        // PROD-2671: the stack teardrops are BOTTOM-anchored too (tips near the
        // centroid, bodies reaching up), so lift the transparent bubble hit
        // target ~20px to sit over the visible stack. Mirror of the single-pin
        // hit-circle shift + the web side.
        await map.style.setStyleLayerProperty(
          _clusterLayerId,
          'circle-translate',
          <double>[0, -20],
        );
        await map.style.setStyleLayerProperty(
          _clusterLayerId,
          'circle-translate-anchor',
          'viewport',
        );
        // Add back-to-front so stack_icon_0 (most relevant) ends up topmost:
        // layer 4 first … layer 0 last.
        for (var i = 4; i >= 0; i--) {
          final d = -3.0 * i;
          await map.style.addLayer(
            SymbolLayer(
              id: 'heyl-stack-$i',
              sourceId: _clusterSourceId,
              filter: <Object>['has', 'stack_icon_$i'],
              iconImageExpression: <Object>['get', 'stack_icon_$i'],
              iconSizeExpression: iconSizeExpr,
              iconAllowOverlap: true,
              iconIgnorePlacement: true,
              // PROD-2671: BOTTOM anchor so each stacked teardrop plants its tip
              // at the centroid (the 3px-per-layer fan reaches up-left),
              // matching the single-pin convention. Mirror of the web side.
              iconAnchor: IconAnchor.BOTTOM,
              // Constant screen-pixel translate (not tied to icon-size) — the
              // native equivalent of the web `icon-translate` paint property.
              iconTranslate: <double>[d, d],
              // PROD-2671 cluster-focus: fade non-focused overflow bubbles'
              // stacked member teardrops.
              iconOpacityExpression: dimOpacityExpr,
            ),
          );
        }
        // Re-point the count label at the "X venues / Y events" title (falls
        // back to "+k" until the Map page wires it), to the right of the stack,
        // in Soko Ink. The typed count layer set text-field/size/color already;
        // override the layout/paint props the stack layout needs via the
        // untyped escape hatch. Mirror of the web `setLayoutProperty` calls.
        await map.style.setStyleLayerProperty(
          _clusterCountLayerId,
          'text-field',
          <Object>[
            'coalesce',
            <Object>['get', 'bubble_title'],
            <Object>['get', 'overflow_label'],
          ],
        );
        // PROD-2671: position the cluster's "X venues / Y events" title EXACTLY
        // like a single pin's caption — `top-left` anchor + the same
        // zoom-tracked offset expression + the same text-size (13) — so the
        // stack's front teardrop (i=0, translate 0, bottom-anchored on the
        // centroid) carries a caption identical to a lone pin's. (Was
        // `left`-anchored with a small constant offset → sat too low and too
        // close to the stack.) Mirror of the web side.
        await map.style.setStyleLayerProperty(
          _clusterCountLayerId,
          'text-anchor',
          'top-left',
        );
        await map.style.setStyleLayerProperty(
          _clusterCountLayerId,
          'text-size',
          MapPinIconTokens.captionTextSizePx,
        );
        await map.style.setStyleLayerProperty(
          _clusterCountLayerId,
          'text-offset',
          MapPinIconTokens.captionOffsetExpression(
            sizeMul: widget.captionSizeMul,
            stops: _pinStops,
          ),
        );
        await map.style.setStyleLayerProperty(
          _clusterCountLayerId,
          'text-justify',
          'left',
        );
        await map.style.setStyleLayerProperty(
          _clusterCountLayerId,
          'text-allow-overlap',
          true,
        );
        await map.style.setStyleLayerProperty(
          _clusterCountLayerId,
          'text-color',
          _colorHexString(AppColors.sokoInk.toARGB32()),
        );
        // PROD-2671 cluster-focus: fade non-focused overflow bubbles' count
        // labels along with their stacked teardrops. The typed count-layer
        // constructor doesn't take `textOpacityExpression` after the fact, so
        // set the `text-opacity` paint prop via the untyped escape hatch,
        // mirroring the `text-*` overrides above and the web
        // `setPaintProperty` call.
        await map.style.setStyleLayerProperty(
          _clusterCountLayerId,
          'text-opacity',
          dimOpacityExpr,
        );
      }
    }

    _clusterLayersInstalled = true;
  }

  Future<void> _updateClusterSource() async {
    final map = _mapboxMap;
    if (map == null || !_clusterLayersInstalled) return;
    // PROD-2999 (Map page): keep the pins HIDDEN until the opening zoom-in
    // settle finishes, so a single final set is revealed (no mid-zoom swap).
    // The pins are still fetched during the zoom; they're just not drawn yet.
    // The user-location dot lives on a separate manager and stays visible.
    // Mirror of the web gate in `_updateClusterSource`.
    if (widget.customSelection && !_openSettled) {
      await map.style.setStyleSourceProperty(
        _clusterSourceId,
        'data',
        _buildPinsGeoJsonString(const <MapMarker>[]),
      );
      return;
    }
    // PROD-3000 (Map page): diff-arm BEFORE building the json, so genuinely-
    // new pins are written already invisible (`local = 0` stamps) and the
    // reveal loop staggers them in. Every other consumer renders plain —
    // mirror of web's `customSelection`-gated `_renderPinsDiffAnimate`.
    if (widget.customSelection) _armNewPinReveals();
    final json = _buildPinsGeoJsonString(widget.markers);
    // The library exposes `setStyleSourceProperty(sourceId, prop, value)`
    // for mutating an existing source in-place. `data` accepts either a
    // URL string or an inlined GeoJSON string.
    await map.style.setStyleSourceProperty(_clusterSourceId, 'data', json);
    if (widget.customSelection && _pinAppearAt.isNotEmpty) {
      // Fire-and-forget: re-entry-guarded; a running loop just picks the
      // newly-armed pins up on its next frame.
      _runRevealLoop();
    }
  }

  String _buildPinsGeoJsonString(List<MapMarker> markers) {
    final features = <Map<String, dynamic>>[];
    final selectedId = widget.selectedMarkerId;
    final selectedIds = widget.selectedMarkerIds;
    for (final m in markers) {
      // User-location is rendered via its own CircleAnnotation path.
      // Skip it from the cluster source so we don't cluster the user
      // dot with venues / events.
      if (m.type == MapMarkerType.userLocation) continue;
      // PROD-2016 / PROD-2205: enlarged-radius hint. Stamped on the
      // tooltip-target marker AND every marker in the consumer-
      // supplied set (multi-venue event highlight).
      final isSelected =
          (selectedId != null && m.id == selectedId) ||
          (selectedIds != null && selectedIds.contains(m.id));
      // PROD-2807: an overflow bubble (`overflowCount` set) is rendered by the
      // bubble layers, not as a pin — stamp `overflow_count` (+ a ready `+k`
      // label) and the event/place breakdown the bubble-colour expression
      // reads (event-only → green, venue-only → blue, mixed → pink). Mirror of
      // the web side.
      final Map<String, dynamic> props;
      if (m.overflowCount != null) {
        props = <String, dynamic>{
          'id': m.id,
          'overflow_count': m.overflowCount,
          'overflow_label': '+${m.overflowCount}',
          // PROD-2671: pre-localized "X venues / Y events" title (set by the
          // Map page); the count label falls back to the "+k" string until
          // that's wired.
          if (m.pinTitle != null) 'bubble_title': m.pinTitle,
          'event_count':
              (m.category == MapMarkerCategory.event || m.category == null)
              ? 1
              : 0,
          'place_count':
              (m.category == MapMarkerCategory.venue || m.category == null)
              ? 1
              : 0,
          // PROD-2671 cluster-focus: `overflow_terminal` routes the bubble
          // tap to focus instead of zoom; `dim` drives the fade-others
          // opacity. Read with a `false` default by the layer expressions.
          // Mirror of the web side.
          'overflow_terminal': m.overflowTerminal,
          'dim': m.dimmed,
          // PROD-2993 (D14): stacks grow with the pins while the results
          // highlight is on. Read by the `heyl-stack-<i>` layers' `icon-size`
          // (which coalesces a missing value to 1.0, so a 1.0 here is a no-op).
          // Mirror of the web side.
          'icon_scale': m.scoreSizeMul,
        };
        // PROD-2671: stack-of-5 — one member pin-key per layer (front-first),
        // consumed by the `heyl-stack-<i>` symbol layers.
        final stack = m.stackIcons;
        if (stack != null) {
          for (var i = 0; i < stack.length && i < 5; i++) {
            props['stack_icon_$i'] = stack[i];
          }
        }
      } else {
        props = _pinFeatureProps(m, isSelected: isSelected);
        // PROD-3000: a pin mid-reveal keeps its CURRENT animation state even
        // through a full source rewrite (didUpdateWidget refetches, etc.) —
        // otherwise the rewrite would snap it fully visible mid-animation.
        _stampRevealProps(props, m.id);
      }
      features.add(<String, dynamic>{
        'type': 'Feature',
        // PROD-3000: top-level GeoJSON id — the reveal loop's partial updates
        // (`updateGeoJSONSourceFeatures`) match features by this id.
        'id': m.id,
        'geometry': {
          'type': 'Point',
          'coordinates': [m.lng, m.lat],
        },
        'properties': props,
      });
    }
    return jsonEncode(<String, dynamic>{
      'type': 'FeatureCollection',
      'features': features,
    });
  }

  /// The full property map for an INDIVIDUAL pin feature (bubbles are built
  /// inline in [_buildPinsGeoJsonString]). Extracted (PROD-3000) because the
  /// reveal loop's partial updates replace the whole feature, so every frame's
  /// feature must carry the complete props, not just the `anim_*` values.
  Map<String, dynamic> _pinFeatureProps(
    MapMarker m, {
    required bool isSelected,
  }) {
    return <String, dynamic>{
      'id': m.id,
      // PROD-1993 wire: `place` / `event` (matches backend `item_type`).
      if (m.category != null) 'item_type': m.category!.wire,
      if (m.label != null) 'label': m.label,
      if (m.color != null) 'color': _colorHexString(m.color!.toARGB32()),
      // PROD-2671: category-icon key for the symbol layer's
      // `['get','icon']` expression (categoryIcons mode only).
      if (m.iconImage != null) 'icon': m.iconImage,
      // PROD-2671: inline pin label — name over secondary facet. Absent
      // until the Map page wires localized labels, so the layer degrades
      // to icon-only.
      if (m.pinTitle != null) 'pin_title': m.pinTitle,
      if (m.pinSubtitle != null) 'pin_subtitle': m.pinSubtitle,
      'isSelected': m.isSelected,
      if (isSelected) 'selected': true,
      // PROD-2671 cluster-focus: dim non-focused pins when focus is
      // active. Read with a `false` default by the layer expressions.
      // Mirror of the web side.
      'dim': m.dimmed,
      // PROD-2989: faded once the item's detail sheet has been opened
      // this visit. Read with a `false` default by `revealOpacityExpr`.
      // Mirror of web.
      'viewed': m.viewed,
      // PROD-2947 (FE-1): pool-relevance size multiplier (1.0 = baseline).
      // Bubbles omit it → `icon-size` coalesces to 1.0. Mirror of web.
      'icon_scale': m.scoreSizeMul,
      // PROD-2940: `sort_key = 1 − score` drives BOTH native sort-keys — the
      // caption layer (lower wins placement) and the icon layer (inverse:
      // higher = drawn on top). Mirror of the web `sort_key` stamp. (Bubbles
      // carry the default 0.0 but are filtered out of both single-pin layers.)
      'sort_key': m.captionSortKey,
    };
  }

  /// PROD-3000: stamp the pin's CURRENT reveal-animation values (`anim_o`,
  /// `anim_s`, `anim_off`) onto [props] if it's mid-reveal — no-op for settled
  /// pins (the layer expressions `coalesce` to the settled defaults). A pin
  /// whose start is still in the future gets `local = 0` → invisible until
  /// its stagger slot arrives. Mirror of web's per-frame stamping in
  /// `_startAnimLoop`.
  void _stampRevealProps(Map<String, dynamic> props, String id) {
    final start = _pinAppearAt[id];
    if (start == null) return;
    final clock = _animClock.elapsedMilliseconds;
    final local = ((clock - start) / kMapRevealFadeMs).clamp(0.0, 1.0);
    final s = mapRevealScale(local);
    props['anim_o'] = mapRevealOpacity(local);
    props['anim_s'] = s;
    // icon-offset is multiplied by icon-size, so convert the px we want into
    // icon-size units at the reveal's zoom.
    props['anim_off'] = <double>[
      0,
      mapRevealLiftPx(local) / (_revealBaseIconSize * (s < 0.05 ? 0.05 : s)),
    ];
  }

  /// PROD-2671: load each category PNG from assets and register it with the
  /// style under its key via `addStyleImage`. Best-effort per image — a failed
  /// pin is skipped so it can never break the map. Native analog of the web
  /// side's `_registerCategoryIcons` (web uses `map.addImage` +
  /// `MapboxStyleImage`).
  ///
  /// **Passes the raw PNG-encoded bytes** to `MbxImage`, exactly as the
  /// mapbox_maps_flutter `addStyleImage` example does (`style_example.dart` —
  /// `rootBundle.load(png).buffer.asUint8List()`): the native SDK decodes the
  /// PNG itself, which sidesteps the `MbxImage.data` "premultiplied RGBA"
  /// contract entirely. Handing it a decoded `rawRgba` buffer (straight OR
  /// premultiplied) rendered NO icon on iOS — only the label placed (the icons
  /// were the missing half of the first device build). We still decode once to
  /// read the intrinsic pixel size for the `MbxImage` width/height.
  Future<void> _registerCategoryIcons() async {
    final map = _mapboxMap;
    if (map == null) return;
    for (final entry in widget.categoryIconAssets.entries) {
      final key = entry.key;
      try {
        if (await map.style.hasStyleImage(key)) continue;
        final data = await rootBundle.load(entry.value);
        final pngBytes = data.buffer.asUint8List();
        // Decode only to read the intrinsic dimensions; the bytes handed to the
        // SDK stay PNG-encoded.
        final codec = await ui.instantiateImageCodec(pngBytes);
        final frame = await codec.getNextFrame();
        final imgWidth = frame.image.width;
        final imgHeight = frame.image.height;
        frame.image.dispose();
        if (!mounted || _mapboxMap == null) return;
        // Re-check after the awaits — a concurrent pass may have registered it.
        if (await map.style.hasStyleImage(key)) continue;
        await map.style.addStyleImage(
          key,
          1.0, // pixel ratio — the shared icon-size zoom interp handles sizing.
          MbxImage(width: imgWidth, height: imgHeight, data: pngBytes),
          false, // sdf: full-colour teardrops, not tintable template icons.
          const <ImageStretches>[],
          const <ImageStretches>[],
          null,
        );
      } catch (e) {
        // Skip a pin that fails to load/decode; the rest still register.
        _mapBreadcrumb(
          'category icon register failed',
          data: {'key': key, 'error': '$e'},
        );
      }
    }
  }

  /// Convert a Flutter [Color]/ARGB32 int to a `#RRGGBB` Mapbox-friendly
  /// hex (alpha stripped — opacity is a separate paint property).
  static String _colorHexString(int argb) {
    final rgb = argb & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  /// Convert an ARGB32 int to the 0xAARRGGBB int that the Mapbox Flutter
  /// SDK expects for `circleColor` / `textColor`. The SDK's `.toRGBA()`
  /// extension on int already handles the conversion to the string form
  /// it sends to native, so we just pass the ARGB int through.
  static int _colorToAARRGGBB(int argb) => argb;

  /// Handle a tap inside the cluster path. Returns true if the tap was
  /// consumed (cluster bubble or leaf pin), false if it should fall
  /// through to other tap handlers.
  Future<bool> _handleClusterTap(ScreenCoordinate point) async {
    final map = _mapboxMap;
    if (map == null || !_clusterLayersInstalled) return false;

    // PROD-3000 regression fix (Map page): the custom-selection surfaces use
    // a Dart-side SCREEN-SPACE hit test instead of `queryRenderedFeatures` —
    // the page's hit circles are fully transparent (`circle-opacity: 0`,
    // PROD-2671) and the native SDK's query never returns them (web's GL JS
    // does, so web is unaffected). Until PROD-3002 removed the ground-distance
    // nearest-marker fallback, that fallback had been silently doing ALL the
    // tapping on native — its removal exposed the dead query and killed pin +
    // bubble taps. Confirmed by bisect: taps work at 7a1e33bf~1 (fallback
    // present), dead from 7a1e33bf onward, regardless of the reveal changes.
    // PROD-3828 update: "every other consumer keeps the query path below
    // (their circles are visible)" was true only while the Map page was the
    // sole `categoryIcons` surface. A `categoryIcons: true` +
    // `customSelection: false` surface ALSO has transparent circles, so it
    // takes the symbol-layer branch further down rather than the circle query.
    // The native-cluster branch still needs the queried feature for
    // `getGeoJsonClusterExpansionZoom`, which is why the cluster query stays
    // where it is.
    if (widget.customSelection) {
      return _handleCustomSelectionTap(map, point);
    }

    final clusterHits = await map.queryRenderedFeatures(
      RenderedQueryGeometry.fromScreenCoordinate(point),
      RenderedQueryOptions(layerIds: [_clusterLayerId]),
    );
    final clusterHit = clusterHits.whereType<QueriedRenderedFeature>().toList();
    if (clusterHit.isNotEmpty) {
      final feature = clusterHit.first.queriedFeature.feature;
      // PROD-2671 cluster-focus: a TERMINAL overflow bubble (co-located /
      // unsplittable) does NOT zoom — tapping it routes to the app so the
      // shell can enter cluster-focus (fade the rest, scope the drawer to its
      // members). Resolve the bubble marker by id and fire onMarkerTap. Read
      // the props defensively (they cross the platform channel as a JSON-ish
      // map); default false when absent. Mirror of the web side.
      if (widget.customSelection) {
        final propsAny = feature['properties'];
        if (propsAny is Map && propsAny['overflow_terminal'] == true) {
          final id = propsAny['id'];
          if (id is String) {
            final bubble = _markerLookup[id];
            if (bubble != null) {
              widget.onMarkerTap?.call(bubble, Offset.zero);
              return true;
            }
          }
        }
      }
      await _zoomIntoCluster(feature);
      return true;
    }

    // PROD-3828 — WHICH layer answers a pin tap.
    //
    // `categoryIcons` sets the unclustered CIRCLE layer to `circle-opacity: 0`
    // / `circle-stroke-opacity: 0` (it survives only as a legacy hit target),
    // and the native Mapbox SDK **excludes fully-transparent circles from
    // `queryRenderedFeatures`** — the same trap PROD-3000 hit on the Map page
    // (`docs/learnings/mapbox-native-transparent-circles-not-queryable.md`).
    // Web is unaffected: GL JS hit-tests geometry regardless of paint.
    //
    // So on a `categoryIcons` surface the circle query below returns nothing,
    // every tap falls through, and tooltips + `onMarkerTap` are silently dead
    // on iOS and Android. Hit-test the VISIBLE icon symbol layer instead —
    // visible symbol layers do query fine on native, which is exactly what the
    // Map page's caption taps already rely on (`_querySymbolMarker`, below).
    //
    // The circle path stays for every non-`categoryIcons` consumer, whose
    // circles are visible and therefore queryable.
    if (widget.categoryIcons) {
      // Padded by [MapPinIconTokens.pinHitMarginPx] so the tap target is the
      // rendered pin plus a forgiveness margin — the same target web gets from
      // its margin-padded query box, and the Map page from `pinHitDistance`.
      // An exact-point query here would make small teardrops noticeably harder
      // to hit on device than on web.
      final iconMarker = await _querySymbolMarker(
        map,
        point,
        _unclusteredIconLayerId,
        padPx: MapPinIconTokens.pinHitMarginPx,
      );
      if (iconMarker != null) {
        await _easeAndShowTooltip(iconMarker);
        return true;
      }
      // Caption tap = pin tap, same rule as the custom-selection path: the
      // caption is visible rendered text, so it queries fine too. Only when
      // the layer actually exists.
      if (widget.showPinCaptions) {
        final captionMarker = await _querySymbolMarker(
          map,
          point,
          _unclusteredCaptionLayerId,
        );
        if (captionMarker != null) {
          await _easeAndShowTooltip(captionMarker);
          return true;
        }
      }
      return false;
    }

    final pinHits = await map.queryRenderedFeatures(
      RenderedQueryGeometry.fromScreenCoordinate(point),
      RenderedQueryOptions(layerIds: [_unclusteredLayerId]),
    );
    final pinHit = pinHits.whereType<QueriedRenderedFeature>().toList();
    if (pinHit.isNotEmpty) {
      final feature = pinHit.first.queriedFeature.feature;
      final propsAny = feature['properties'];
      if (propsAny is Map) {
        final id = propsAny['id'];
        if (id is String) {
          final marker = _markerLookup[id];
          if (marker != null) {
            // PROD-2046 Option A: pan to a fixed screen target, THEN
            // open the tooltip — the helper fires `onMarkerTap` once
            // the ease completes (no mid-animation tooltips).
            await _easeAndShowTooltip(marker);
            return true;
          }
        }
      }
    }
    return false;
  }

  /// PROD-3000 regression fix: geometric tap hit-test for the Map page, in
  /// Dart (the page's hit circles are transparent and the native SDK's query
  /// never returns them — see the caller). One batched `pixelsForCoordinates`
  /// channel call projects every marker to screen px (SDK-exact: includes
  /// camera padding and projection), then per kind:
  ///   • pins — the rendered icon rectangle + a small forgiveness margin,
  ///     zoom-tracking ([MapPinIconTokens.pinHitDistance]; mirrors web's
  ///     padded icon-layer query). Replaced the constant r24 circle, which
  ///     was ~2× the pin at working zooms.
  ///   • bubbles — the 21/29/36 count-stepped radius (+2 px stroke), lifted
  ///     by the circles' `circle-translate [0, -20]` (viewport-anchored →
  ///     a constant screen offset), same as the circles render.
  /// Bubbles win over pins (the bubble layer is queried first on the web
  /// path); within a kind, nearest wins.
  Future<bool> _handleCustomSelectionTap(
    MapboxMap map,
    ScreenCoordinate tap,
  ) async {
    // The user-location dot is deliberately not tappable (a dot tap is a
    // plain tap-outside — PROD-3002); bubbles + pins are.
    final markers = widget.markers
        .where((m) => m.type != MapMarkerType.userLocation)
        .toList();
    if (markers.isEmpty) return false;
    final List<ScreenCoordinate?> px;
    try {
      px = await map.pixelsForCoordinates([
        for (final m in markers) Point(coordinates: Position(m.lng, m.lat)),
      ]);
    } catch (_) {
      // Projection failed → treat as tap-outside (the pre-fix behavior);
      // never crash the tap path.
      return false;
    }
    // Pin hit rectangles scale with zoom (the icon-size interpolation) —
    // read the camera once per tap. A failed read falls back to the mid
    // working-range zoom (14 → 0.3×) rather than dropping the tap.
    double zoom;
    try {
      zoom = (await map.getCameraState()).zoom;
    } catch (_) {
      zoom = 14.0;
    }
    MapMarker? hitBubble;
    var hitBubbleD = double.infinity;
    MapMarker? hitPin;
    var hitPinD = double.infinity;
    final n = markers.length < px.length ? markers.length : px.length;
    for (var i = 0; i < n; i++) {
      final p = px[i];
      if (p == null) continue; // off-screen / unprojectable
      final m = markers[i];
      final overflow = m.overflowCount;
      if (overflow != null) {
        final dx = p.x - tap.x;
        // The bubble hit circles render lifted 20 px up (`circle-translate
        // [0,-20]`, viewport anchor) so they sit over the stacked teardrops
        // rather than the empty space below the centroid.
        final dy = (p.y - 20.0) - tap.y;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d <= _bubbleHitRadiusPx(overflow) && d < hitBubbleD) {
          hitBubble = m;
          hitBubbleD = d;
        }
      } else {
        // Pin: rendered-rectangle hit test (bottom-anchored icon + a small
        // forgiveness margin, zoom-tracking). Distance is to the rect's
        // centre — nearest wins between overlapping pins.
        final d = MapPinIconTokens.pinHitDistance(
          tapX: tap.x,
          tapY: tap.y,
          anchorX: p.x,
          anchorY: p.y,
          zoom: zoom,
          stops: _pinStops,
        );
        if (d != null && d < hitPinD) {
          hitPin = m;
          hitPinD = d;
        }
      }
    }
    if (hitBubble != null) {
      // PROD-2671 cluster-focus: a TERMINAL bubble (co-located/unsplittable)
      // routes to the app so the shell can enter cluster-focus (fade the
      // rest, scope the drawer to its members); a splittable bubble zooms in
      // ~+2 so the world-grid re-selects and splits it. Mirror of the web
      // side + the query path's branches.
      if (hitBubble.overflowTerminal) {
        widget.onMarkerTap?.call(hitBubble, Offset.zero);
        return true;
      }
      await _zoomTowardBubble(hitBubble);
      return true;
    }
    if (hitPin != null) {
      // PROD-2046 Option A: pan to a fixed screen target, THEN open the
      // tooltip — the helper fires `onMarkerTap` once the ease completes.
      await _easeAndShowTooltip(hitPin);
      return true;
    }
    // Caption tap = pin tap (user feedback): no teardrop/bubble under the
    // finger → hit-test the CAPTION symbol layer. Unlike the transparent hit
    // circles (which the native query never returns — the PROD-3000 note
    // above), captions are visible rendered text, so `queryRenderedFeatures`
    // does hit-test their glyph boxes. Geometric bubble/pin hits keep
    // priority — this runs only when both missed.
    if (widget.categoryIcons && widget.showPinCaptions) {
      final captionMarker = await _querySymbolMarker(
        map,
        tap,
        _unclusteredCaptionLayerId,
      );
      if (captionMarker != null) {
        await _easeAndShowTooltip(captionMarker);
        return true;
      }
    }
    // Bubble-caption tap = bubble tap: the "X venues / Y events" title
    // beside a `+k` stack (the re-pointed count label layer) routes exactly
    // like tapping the bubble — terminal → cluster-focus via the app,
    // splittable → zoom to split. Visible text, so queryable (same rule as
    // the pin captions above).
    final bubbleMarker = await _querySymbolMarker(
      map,
      tap,
      _clusterCountLayerId,
    );
    if (bubbleMarker != null && bubbleMarker.overflowCount != null) {
      if (bubbleMarker.overflowTerminal) {
        widget.onMarkerTap?.call(bubbleMarker, Offset.zero);
      } else {
        await _zoomTowardBubble(bubbleMarker);
      }
      return true;
    }
    // PROD-3124: dot-hint tap — LOWEST priority (pins/bubbles/captions all
    // missed). Geometric test against the dot coordinates (native circle
    // layers aren't reliably queryable), mirror of the web's layer query.
    final dotHit = await _hitTestDotHint(map, tap);
    if (dotHit != null) {
      widget.onDotHintTap?.call(
        dotHit.id,
        dotHit.entity,
        dotHit.lat,
        dotHit.lng,
      );
      try {
        await map.flyTo(
          CameraOptions(
            center: Point(coordinates: Position(dotHit.lng, dotHit.lat)),
            zoom: kDotHintFocusZoom,
          ),
          MapAnimationOptions(duration: 500),
        );
      } catch (_) {
        // A failed ease is a no-op; the promotion above still applied.
      }
      return true;
    }
    return false;
  }

  /// The dot hint under [tap] (within [kDotHintHitRadiusPx], nearest wins),
  /// or null. Projects the current dots via `pixelsForCoordinates` — same
  /// approach as the pin hit test above. Never throws.
  Future<MapDotHint?> _hitTestDotHint(
    MapboxMap map,
    ScreenCoordinate tap,
  ) async {
    final dots = dotHintsFromFeatureCollection(widget.dotHintsGeoJson);
    if (dots.isEmpty) return null;
    final List<ScreenCoordinate?> px;
    try {
      px = await map.pixelsForCoordinates([
        for (final d in dots) Point(coordinates: Position(d.lng, d.lat)),
      ]);
    } catch (_) {
      return null;
    }
    MapDotHint? hit;
    var hitD = double.infinity;
    final n = dots.length < px.length ? dots.length : px.length;
    for (var i = 0; i < n; i++) {
      final p = px[i];
      if (p == null) continue;
      final dx = p.x - tap.x;
      final dy = p.y - tap.y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d <= kDotHintHitRadiusPx && d < hitD) {
        hit = dots[i];
        hitD = d;
      }
    }
    return hit;
  }

  /// Resolve the marker whose rendered SYMBOL (caption text / bubble title)
  /// on [layerId] is under [tap], via `queryRenderedFeatures`. Null when
  /// nothing is under the point (or the query fails — a failed query is a
  /// plain tap-outside, never a crash).
  /// PROD-3828: [padPx] dilates the query into a box of that half-extent
  /// around [tap], instead of testing the single point. Defaults to 0 (exact
  /// hit) — the caption and bubble-count layers want that, since their glyph
  /// boxes are already large. The PIN ICON layer passes
  /// [MapPinIconTokens.pinHitMarginPx] so its tap target matches what web and
  /// the Map page's geometric path already give: the rendered pin plus a small
  /// forgiveness margin. Without it a tap a few px beside a small teardrop
  /// would miss on iOS/Android while landing fine on web — a platform split
  /// that only shows up once a surface turns `categoryIcons` on.
  Future<MapMarker?> _querySymbolMarker(
    MapboxMap map,
    ScreenCoordinate tap,
    String layerId, {
    double padPx = 0,
  }) async {
    final geometry = padPx <= 0
        ? RenderedQueryGeometry.fromScreenCoordinate(tap)
        : RenderedQueryGeometry.fromScreenBox(
            ScreenBox(
              min: ScreenCoordinate(x: tap.x - padPx, y: tap.y - padPx),
              max: ScreenCoordinate(x: tap.x + padPx, y: tap.y + padPx),
            ),
          );
    final List<QueriedRenderedFeature?> hits;
    try {
      hits = await map.queryRenderedFeatures(
        geometry,
        RenderedQueryOptions(layerIds: [layerId]),
      );
    } catch (_) {
      return null;
    }
    for (final hit in hits) {
      if (hit == null) continue;
      final propsAny = hit.queriedFeature.feature['properties'];
      if (propsAny is! Map) continue;
      final id = propsAny['id'];
      if (id is! String) continue;
      final marker = _markerLookup[id];
      if (marker != null) return marker;
    }
    return null;
  }

  /// The bubble hit circle's rendered radius (px) for an `overflow_count` —
  /// the same 21/29/36 step the layer's `circle-radius` expression uses,
  /// plus its 2 px stroke.
  double _bubbleHitRadiusPx(int count) {
    final double r = count >= MapClusterTokens.largeAt
        ? MapClusterTokens.bubbleRadiusLarge
        : count >= MapClusterTokens.mediumAt
        ? MapClusterTokens.bubbleRadiusMedium
        : MapClusterTokens.bubbleRadiusSmall;
    return r + 2.0;
  }

  /// Ease in toward a (splittable) `+k` bubble: zoom +2 clamped to 18 — the
  /// finer zoom re-runs the world-grid selection and re-splits the bubble.
  /// Move callbacks deliberately NOT suppressed: the trailing idle must fire
  /// settle-to-search so the pool refetches. Same behavior as
  /// `_zoomIntoCluster`'s custom-selection branch (which serves the query
  /// path); duplicated here because the geometric path starts from the
  /// MARKER, not a queried feature.
  Future<void> _zoomTowardBubble(MapMarker bubble) async {
    final map = _mapboxMap;
    if (map == null) return;
    try {
      final cam = await map.getCameraState();
      final z = cam.zoom;
      final targetZoom = z + 2.0 > 18.0 ? 18.0 : z + 2.0;
      await map.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(bubble.lng, bubble.lat)),
          zoom: targetZoom,
        ),
        MapAnimationOptions(duration: 400),
      );
    } catch (_) {
      // A failed ease is a no-op tap; the next tap retries.
    }
  }

  Future<void> _zoomIntoCluster(Map<String?, Object?> clusterFeature) async {
    final map = _mapboxMap;
    if (map == null) return;
    try {
      // Pull the bubble/cluster centre from the feature geometry — needed by
      // both the custom-selection and native-cluster paths below.
      final geom = clusterFeature['geometry'];
      if (geom is! Map) return;
      final coords = geom['coordinates'];
      if (coords is! List || coords.length < 2) return;
      final lng = (coords[0] as num).toDouble();
      final lat = (coords[1] as num).toDouble();

      // PROD-2807: our own `+k` overflow bubble → there's no Mapbox cluster to
      // expand (`cluster:false`), so just ease in toward its centre and bump
      // the zoom by ~+2 (clamped ≤18). The finer zoom re-runs the world-grid
      // selection and re-splits the bubble. We deliberately do NOT suppress the
      // move callbacks: the ease's trailing idle must fire settle-to-search so
      // the pool refetches and the grid re-selects. Mirror of the web side.
      if (widget.customSelection) {
        final cam = await map.getCameraState();
        final z = cam.zoom;
        final targetZoom = z + 2.0 > 18.0 ? 18.0 : z + 2.0;
        await map.flyTo(
          CameraOptions(
            center: Point(coordinates: Position(lng, lat)),
            zoom: targetZoom,
          ),
          MapAnimationOptions(duration: 400),
        );
        return;
      }

      final ext = await map.getGeoJsonClusterExpansionZoom(
        _clusterSourceId,
        clusterFeature,
      );
      final raw = ext.value;
      if (raw == null) return;
      // `value` is a JSON-encoded number — sometimes wrapped in extra
      // quoting depending on the platform channel. Parse defensively.
      double? zoom;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is num) zoom = decoded.toDouble();
      } catch (_) {
        zoom = double.tryParse(raw);
      }
      if (zoom == null) return;

      await map.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(lng, lat)),
          zoom: zoom,
        ),
        MapAnimationOptions(duration: 400),
      );
    } catch (e) {
      debugPrint(
        '[MapboxMapPlatform Native] cluster expansion zoom failed: $e',
      );
    }
  }

  /// PROD-2016: the only marker type still rendered via the legacy
  /// annotation manager is the user-location dot — every other type
  /// (`place`, `letter`, `pin`) flows through the cluster source-layer
  /// path now. The pre-PROD-2016 implementation handled all four
  /// types here against `_pointManager` / `_iconManager`; those
  /// managers + their branches have been deleted.
  Future<void> _addMarker(MapMarker marker) async {
    if (_circleManager == null) return;
    if (marker.type != MapMarkerType.userLocation) return;

    final point = Point(coordinates: Position(marker.lng, marker.lat));
    final annotation = await _circleManager!.create(
      CircleAnnotationOptions(
        geometry: point,
        circleRadius: 7, // 14 px diameter — matches the chat compact map.
        circleColor: 0xFF3B82F6, // Blue #3B82F6
        circleStrokeWidth: 2,
        circleStrokeColor: 0xFFFFFFFF,
      ),
    );
    _circleAnnotations[marker.id] = annotation;
    _markerLookup[marker.id] = marker;
  }

  /// req2: render/update/clear the picker's viewport-gated user dot on its own
  /// [_pickerDotManager]. Updates the existing annotation in place when only the
  /// position changed (no delete/create flicker); clears it when the prop is null.
  Future<void> _syncUserDot() async {
    final mgr = _pickerDotManager;
    if (mgr == null) return;
    final dot = widget.userDotLatLng;
    if (dot == null) {
      if (_userDotAnnotation != null) {
        await mgr.deleteAll();
        _userDotAnnotation = null;
      }
      return;
    }
    final geometry = Point(coordinates: Position(dot.lng, dot.lat));
    final existing = _userDotAnnotation;
    if (existing == null) {
      _userDotAnnotation = await mgr.create(
        CircleAnnotationOptions(
          geometry: geometry,
          circleRadius: 7, // 14 px diameter — matches the marker user dot.
          circleColor: 0xFF3B82F6, // Blue #3B82F6
          circleStrokeWidth: 2,
          circleStrokeColor: 0xFFFFFFFF,
        ),
      );
    } else {
      existing.geometry = geometry;
      await mgr.update(existing);
    }
  }

  /// Render/update/clear the picker's center-of-search pin on its own
  /// [_pickerPinManager]. Mirror of [_syncUserDot]: updates in place when only
  /// the position changed (no delete/create flicker), clears it when the prop
  /// is null. The PNG bytes are loaded once and cached. Best-effort — a failed
  /// image load simply leaves the pin undrawn.
  Future<void> _syncPickerPin() async {
    final mgr = _pickerPinManager;
    if (mgr == null) return;
    final pin = widget.pickerPinLatLng;
    if (pin == null) {
      if (_pickerPinAnnotation != null) {
        await mgr.deleteAll();
        _pickerPinAnnotation = null;
      }
      return;
    }
    // Load + cache the teardrop bytes on first use; bail if the asset is
    // missing so the picker still functions without the pin art.
    var bytes = _pickerPinImageBytes;
    if (bytes == null) {
      try {
        final data = await rootBundle.load(_pickerPinAssetPath);
        bytes = data.buffer.asUint8List();
        _pickerPinImageBytes = bytes;
      } catch (_) {
        return;
      }
    }
    final geometry = Point(coordinates: Position(pin.lng, pin.lat));
    final existing = _pickerPinAnnotation;
    if (existing == null) {
      _pickerPinAnnotation = await mgr.create(
        PointAnnotationOptions(
          geometry: geometry,
          image: bytes,
          iconSize: _pickerPinIconSize,
          // Tip of the teardrop sits on the coordinate.
          iconAnchor: IconAnchor.BOTTOM,
        ),
      );
    } else {
      existing.geometry = geometry;
      await mgr.update(existing);
    }
  }

  /// Fit the camera to an explicit lat/lng bbox passed via
  /// [MapBoundsConfig.north]/[south]/[east]/[west]. Used by callers that
  /// want a fixed area shown (e.g. the whole selected city) regardless of
  /// where markers cluster.
  Future<void> _fitToBbox() async {
    final config = widget.boundsConfig;
    if (config == null) return;
    await _fitToBboxConfig(config);
  }

  /// req3: fit an explicit [MapBoundsConfig] (used by the imperative recenter
  /// step, which passes [MapboxMapPlatform.fitBoundsOverride] instead of
  /// [boundsConfig]).
  Future<void> _fitToBboxConfig(MapBoundsConfig config) async {
    if (_mapboxMap == null || !config.hasBbox) return;

    final coordinates = [
      Point(coordinates: Position(config.west!, config.south!)),
      Point(coordinates: Position(config.east!, config.north!)),
    ];

    final camera = await _mapboxMap!.cameraForCoordinatesPadding(
      coordinates,
      CameraOptions(),
      MbxEdgeInsets(
        top: config.paddingTop?.toDouble() ?? config.padding.toDouble(),
        left: config.paddingLeft?.toDouble() ?? config.padding.toDouble(),
        bottom: config.paddingBottom?.toDouble() ?? config.padding.toDouble(),
        right: config.paddingRight?.toDouble() ?? config.padding.toDouble(),
      ),
      config.maxZoom,
      null,
    );

    await _mapboxMap!.flyTo(
      camera,
      MapAnimationOptions(duration: config.duration),
    );
  }

  Future<void> _fitToMarkers() async {
    if (_mapboxMap == null || widget.markers.isEmpty) return;

    // PROD-1978: skip user-location markers in the bounds math — the
    // user can be anywhere and including their dot would skew the
    // camera away from the list pins.
    final placed = widget.markers
        .where((m) => m.type != MapMarkerType.userLocation)
        .toList();
    if (placed.isEmpty) return;

    // PROD-3003: degenerate-bbox guard — a single pin (or co-located pins)
    // yields a zero-area bbox, and `cameraForCoordinatesPadding` on that can
    // dive to the SDK's max zoom when `config.maxZoom` is unset. Short-circuit
    // to a plain ease at a sane zoom instead. Port of the web guard
    // (`mapbox_map_web.dart` `_fitToMarkers`), same 6-dp coordinate rounding.
    final config = widget.boundsConfig ?? const MapBoundsConfig();
    final uniqueCoords = <String>{};
    for (final m in placed) {
      uniqueCoords.add(
        '${m.lng.toStringAsFixed(6)},${m.lat.toStringAsFixed(6)}',
      );
    }
    if (uniqueCoords.length <= 1) {
      final m = placed.first;
      await _mapboxMap!.easeTo(
        CameraOptions(
          center: Point(coordinates: Position(m.lng, m.lat)),
          zoom: config.maxZoom ?? 14,
        ),
        MapAnimationOptions(duration: config.duration),
      );
      return;
    }

    // Calculate bounds
    double minLat = placed.first.lat;
    double maxLat = placed.first.lat;
    double minLng = placed.first.lng;
    double maxLng = placed.first.lng;

    for (final marker in placed) {
      minLat = math.min(minLat, marker.lat);
      maxLat = math.max(maxLat, marker.lat);
      minLng = math.min(minLng, marker.lng);
      maxLng = math.max(maxLng, marker.lng);
    }

    // Add some padding to bounds
    final latPadding = (maxLat - minLat) * 0.1;
    final lngPadding = (maxLng - minLng) * 0.1;

    // Create coordinate bounds
    final coordinates = [
      Point(coordinates: Position(minLng - lngPadding, minLat - latPadding)),
      Point(coordinates: Position(maxLng + lngPadding, maxLat + latPadding)),
    ];

    final camera = await _mapboxMap!.cameraForCoordinatesPadding(
      coordinates,
      CameraOptions(),
      MbxEdgeInsets(
        top: config.paddingTop?.toDouble() ?? config.padding.toDouble(),
        left: config.paddingLeft?.toDouble() ?? config.padding.toDouble(),
        bottom: config.paddingBottom?.toDouble() ?? config.padding.toDouble(),
        right: config.paddingRight?.toDouble() ?? config.padding.toDouble(),
      ),
      config.maxZoom,
      null,
    );

    await _mapboxMap!.flyTo(
      camera,
      MapAnimationOptions(duration: config.duration),
    );
  }

  @override
  void didUpdateWidget(MapboxMapPlatform oldWidget) {
    super.didUpdateWidget(oldWidget);

    // PROD-3828: [showPinCaptions] and [pinIconSizeStops] are INSTALL-TIME
    // ONLY — exactly like `categoryIcons`, `categoryIconAssets` and
    // `customSelection` before them, none of which are reconciled here either.
    // They are read when the style layers are installed and baked into the
    // layer expressions.
    //
    // Changing one after the map is up would desync those baked expressions
    // from the LIVE readers: the tap hit-test reads the size curve per tap,
    // and the caption tap/query paths read the caption flag per event. That
    // is precisely the "captions and hit targets drift away from the rendered
    // art" failure this ticket exists to prevent — so it is asserted rather
    // than left to chance.
    //
    // Asserted, not reconciled: these are per-surface CONFIGURATION (pass a
    // constant), not state. Reconciling them in this method would be
    // speculative code with no consumer; the assert turns a silent visual
    // desync into a loud failure in debug and costs nothing in release.
    assert(
      widget.showPinCaptions == oldWidget.showPinCaptions,
      'showPinCaptions changed after the map was built. It is install-time '
      'only: the caption layer is added (or skipped) when the style layers '
      'are installed, while the caption tap/query paths read the live flag — '
      'so changing it desyncs them. Pass a constant per surface.',
    );
    assert(
      listEquals(widget.pinIconSizeStops, oldWidget.pinIconSizeStops),
      'pinIconSizeStops changed after the map was built. It is install-time '
      'only: the icon-size and caption-offset expressions bake the curve when '
      'the layers are installed, while the tap hit-test reads it live — so '
      'changing it makes tap targets stop matching the rendered pins. Pass a '
      'constant per surface.',
    );

    if (!_mapReady) return;

    // req3: imperative recenter "fit both" — a token bump means fit these bounds
    // now and STOP: the recenter press only changes camera props, and the later
    // center-ease branch would otherwise immediately override the bbox fit
    // (fit-both clears the shell's _focusOverride, flipping the effective centre).
    if (widget.fitBoundsToken != oldWidget.fitBoundsToken &&
        widget.fitBoundsOverride?.hasBbox == true) {
      _fitToBboxConfig(widget.fitBoundsOverride!);
      return;
    }

    // Check if markers changed
    final markersChanged =
        widget.markers.length != oldWidget.markers.length ||
        !_areMarkersEqual(widget.markers, oldWidget.markers);

    // PROD-2016: selection change re-stamps the GeoJSON source so the
    // unclustered layer's `case` expression on `circle-radius` picks
    // up the new selected feature. Mirror of the web side.
    // PROD-2205: same for the multi-pin set (zine item-page paging
    // changes which subset is highlighted yellow).
    final selectionChanged =
        widget.selectedMarkerId != oldWidget.selectedMarkerId ||
        !setEquals(widget.selectedMarkerIds, oldWidget.selectedMarkerIds);

    // PROD-1978: a fit-all button tap doesn't change the markers — it
    // only flips the parent's `_shouldFitMarkers` (→ `widget.fitMarkers`)
    // from false → true. Treat that transition as another trigger for
    // re-fitting, otherwise the camera never moves to fit the markers
    // (this was the symptom on testeeee-gigante-do-ja where fit-all
    // landed on Lisbon instead of the global span — the easeTo-to-
    // items.first branch below was running instead).
    final fitMarkersTurnedOn = widget.fitMarkers && !oldWidget.fitMarkers;

    // PROD-1978 follow-up: after a manual pan/zoom the
    // `_shouldFitMarkers` parent state stays `true`, so the next
    // fit-all click produces no rising edge. A monotonic token gives
    // an unambiguous "re-fit now" signal even without prop changes.
    final tokenBumped = widget.fitToMarkersToken != oldWidget.fitToMarkersToken;

    if (markersChanged || selectionChanged) {
      _renderMarkers();
    }

    // Viewport-gated user dot (req2): re-sync on its own manager whenever the
    // picker toggles the dot point, independent of the markers list.
    if (widget.userDotLatLng != oldWidget.userDotLatLng) {
      _syncUserDot();
    }

    // The picker's center-of-search pin moves as the user taps / pans; re-sync
    // on its own manager whenever the point changes (or clears).
    if (widget.pickerPinLatLng != oldWidget.pickerPinLatLng) {
      _syncPickerPin();
    }

    // PROD-2993: the results-highlight enlargement (narrow half-drawer) grew or
    // shrank every pin — re-lift the captions to match. Layout-only; no camera.
    if (widget.captionSizeMul != oldWidget.captionSizeMul) {
      _applyCaptionOffset();
    }

    // PROD-2971: redraw the admin debug overlay when its data changes (a new
    // `/map/pins` response yields a fresh instance; null↔non-null toggles it) or
    // when the visible-shapes set changes (panel legend toggle).
    if (!identical(oldWidget.debugOverlay, widget.debugOverlay) ||
        !setEquals(oldWidget.debugOverlayShapes, widget.debugOverlayShapes)) {
      _updateMapDebugOverlay();
    }

    // PROD-3124: re-sync + fade in the dot hints when the settled provider
    // hands a new FeatureCollection (identity check — the provider only
    // rebuilds on settle, so this never fires on unrelated rebuilds).
    if (!identical(oldWidget.dotHintsGeoJson, widget.dotHintsGeoJson)) {
      _syncDotHints();
    }

    // PROD-3109: redraw the picker boundary when the polygon or fallback point
    // changes (a new selection, or a clear).
    if (!identical(
          oldWidget.highlightBoundaryGeoJson,
          widget.highlightBoundaryGeoJson,
        ) ||
        oldWidget.highlightPoint != widget.highlightPoint ||
        oldWidget.highlightRadiusMeters != widget.highlightRadiusMeters) {
      _updatePickerBoundary();
    }

    // Picker drill-down: redraw the tappable child polygons when the city's
    // children arrive or clear (identity check — the sheet hands a new
    // FeatureCollection only when the active city changes).
    if (!identical(
      oldWidget.childBoundariesGeoJson,
      widget.childBoundariesGeoJson,
    )) {
      _updatePickerChildren();
    }

    // PROD-2671 (Map page): re-apply camera padding when the chrome insets
    // change — the bottom drawer peek publishes just after load, and grows when
    // a filter panel opens. Suppressed internally so it doesn't refetch.
    // PROD-2999: DEFERRED while the opening zoom-in settle is running (mirror
    // of the web guard) — a mid-ease `setCamera(padding:)` would fight the
    // opening animation, and its short suppression tail would unmask the
    // 800 ms ease (read as a user pan → cancels the first fetch). The settle's
    // completion applies the latest insets itself.
    if ((widget.viewportPaddingTop != oldWidget.viewportPaddingTop ||
            widget.viewportPaddingBottom != oldWidget.viewportPaddingBottom) &&
        (!widget.customSelection || _openSettled)) {
      _applyViewportPadding();
    }

    // PROD-2042 Wave 2: my-location button bumps `centerToToken` so
    // we fly to the new center even when the prop value hasn't
    // changed. Handled FIRST so token-bumped flies win over the
    // declarative fit branch below when the shell flipped
    // `fitMarkers` off in the same frame. Mirror of the web side.
    final centerTokenBumped = widget.centerToToken != oldWidget.centerToToken;

    if (centerTokenBumped &&
        widget.centerLat != null &&
        widget.centerLng != null) {
      // PROD-3003: easeTo at the shared recenter duration — mirror of web
      // (was a 300 ms flyTo arc; the direct ease matches web's feel).
      _mapboxMap?.easeTo(
        CameraOptions(
          center: Point(
            coordinates: Position(widget.centerLng!, widget.centerLat!),
          ),
          zoom: widget.zoom,
        ),
        MapAnimationOptions(duration: kMapRecenterEaseMs),
      );
    } else if (markersChanged || fitMarkersTurnedOn || tokenBumped) {
      if (widget.boundsConfig?.hasBbox == true) {
        _fitToBbox();
      } else if (widget.markers.isNotEmpty &&
          (widget.fitMarkers || tokenBumped)) {
        // PROD-2042 Wave 2: token bumps are imperative re-fit requests
        // — honour them even when the declarative `fitMarkers` prop is
        // false (modal pinned a single card; fit-all should still
        // re-frame to ALL pins, not stay zoomed on the selected one).
        _fitToMarkers();
      }
    }

    // React to bbox changes (e.g. the /lists hub user picks a new city).
    final oldBbox = oldWidget.boundsConfig;
    final newBbox = widget.boundsConfig;
    if (newBbox?.hasBbox == true &&
        (oldBbox?.north != newBbox?.north ||
            oldBbox?.south != newBbox?.south ||
            oldBbox?.east != newBbox?.east ||
            oldBbox?.west != newBbox?.west)) {
      _fitToBbox();
    }

    // Check if center changed (value-diff path — distinct from the
    // centerToToken-driven path above which fires on any token bump).
    if (!centerTokenBumped &&
        (widget.centerLat != oldWidget.centerLat ||
            widget.centerLng != oldWidget.centerLng)) {
      if (widget.centerLat != null && widget.centerLng != null) {
        // PROD-3003: easeTo at the shared recenter duration — mirror of web.
        _mapboxMap?.easeTo(
          CameraOptions(
            center: Point(
              coordinates: Position(widget.centerLng!, widget.centerLat!),
            ),
            zoom: widget.zoom,
          ),
          MapAnimationOptions(duration: kMapRecenterEaseMs),
        );
      }
    }

    // Check if interactivity changed
    if (widget.interactive != oldWidget.interactive) {
      _mapboxMap?.gestures.updateSettings(
        GesturesSettings(
          scrollEnabled: widget.interactive,
          pinchToZoomEnabled: widget.interactive,
          pinchPanEnabled: widget.interactive,
          rotateEnabled: false,
          pitchEnabled: false,
          doubleTapToZoomInEnabled: widget.interactive,
          doubleTouchToZoomOutEnabled: false,
          quickZoomEnabled: widget.interactive,
          scrollDecelerationEnabled: widget.interactive,
          pinchToZoomDecelerationEnabled: widget.interactive,
        ),
      );
    }
  }

  bool _areMarkersEqual(List<MapMarker> a, List<MapMarker> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _circleTapCancelable?.cancel();
    _pendingTooltipShow?.cancel();
    _dotRemovalTimer?.cancel();
    // PROD-1978: source + layers belong to the map's style, which is
    // torn down when the MapWidget unmounts. Just clear the local flag
    // so a subsequent `_onMapCreated` re-installs cleanly.
    _clusterLayersInstalled = false;
    _mapBreadcrumb('Map disposed');
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Option A (app-wide Soko basemap): a single theme-independent style for
    // both light + dark. See EnvironmentConfig.mapboxActiveStyle (the stock
    // light/dark styles are kept there as the fallback target).
    final styleUri = EnvironmentConfig.mapboxActiveStyle;

    // Create gesture recognizers to allow map to receive gestures in a Stack
    // EagerGestureRecognizer immediately claims all pointer events, ensuring the map
    // receives all touch input including two-finger pan without scaling
    final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers =
        widget.interactive
        ? <Factory<OneSequenceGestureRecognizer>>{
            Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
          }
        : <Factory<OneSequenceGestureRecognizer>>{};

    // PROD-2046: capture viewport size so the pin-tap ease handler
    // can compute its screen target synchronously.
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        _viewportHeight = constraints.maxHeight;
        return MapWidget(
          // PROD-2671: the key MUST NOT depend on `markers.length`. The
          // marker COUNT changes constantly on the settle-to-search Map page
          // (pins load, then live re-selection on every camera move/settle);
          // if the count were in the key, Flutter would destroy + recreate
          // the whole platform MapWidget on each change, re-seeding the camera
          // from `cameraOptions` — which showed up on-device as the map
          // reloading on open, snapping back on pan/zoom, and never rendering
          // pins. Marker changes are already applied in place via
          // `didUpdateWidget → _renderMarkers`, so the map is built once and
          // only re-created on a style/theme change (`isDark`).
          key: ValueKey('mapbox-native-${widget.isDark}'),
          styleUri: styleUri,
          cameraOptions: CameraOptions(
            center: Point(
              coordinates: Position(
                widget.centerLng ?? _defaultLng,
                widget.centerLat ?? _defaultLat,
              ),
            ),
            // PROD-2999 (Map page): born zoomed OUT so the opening ease to the
            // target zoom is a real settle animation (mirror of web). Other
            // surfaces open at the exact requested zoom.
            zoom: widget.customSelection
                ? widget.zoom - kMapOpenSettleZoomDelta
                : widget.zoom,
          ),
          gestureRecognizers: gestureRecognizers,
          onMapCreated: _onMapCreated,
          // PROD-2671: install sources/layers + first render on STYLE load, not
          // map-created (cold-start race — the style isn't ready in onMapCreated).
          onStyleLoadedListener: _onStyleLoaded,
          onTapListener: _onMapTap,
          onCameraChangeListener: _onCameraChanged,
          // PROD-2671: settle-to-search — fires when the camera comes to
          // rest (the native analog of the web `moveend`).
          onMapIdleListener: _onMapIdle,
          // PROD-2993: the **real** "the user did this" signal. Unlike
          // `onCameraChangeListener` (which fires for our own animations too),
          // these two fire ONLY for user gestures — a pan and a pinch/zoom
          // respectively. Together they cover every way a user can drive this
          // camera (rotation and pitch are disabled on the Map page).
          //
          // The web analog is `movestart`'s `originalEvent`. Both exist so we
          // never have to *guess* from timing whether a camera move was ours —
          // a guess that necessarily misreads the user grabbing the map in the
          // middle of one of our animations.
          onScrollListener: widget.onUserGesture == null
              ? null
              : (_) => widget.onUserGesture!.call(),
          onZoomListener: widget.onUserGesture == null
              ? null
              : (_) => widget.onUserGesture!.call(),
        );
      },
    );
  }
}
