import 'dart:async';
import 'dart:js_interop';
// PROD-2993: `getProperty` (to read a Mapbox camera event's `originalEvent`,
// which is the only reliable "the user did this" signal) lives here, not in
// `dart:js_interop`.
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:web/web.dart' as web;

import '../../core/config/environment.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/map_debug.dart';
import '../../features/chat/widgets/mapbox_web_interop.dart';
import '../utils/geo_circle.dart';
import '../utils/map_debug_overlay.dart';
import '../utils/map_dot_hints_render.dart';
import 'map_marker_model.dart';

/// PROD-1978: lightweight Sentry breadcrumb helper so a future regression
/// in the map mount/dispose lifecycle is loud and traceable. Kept to
/// `info` level — surfaces only in event payloads when something else
/// errors, doesn't generate noise on its own.
void _mapBreadcrumb(String message, {Map<String, Object?>? data}) {
  Sentry.addBreadcrumb(
    Breadcrumb(message: message, category: 'map.web', type: 'info', data: data),
  );
}

/// Web implementation of MapboxMapWidget using Mapbox GL JS
/// Mapbox is lazy-loaded on first use to save 393KB from initial page load
class MapboxMapPlatform extends StatefulWidget {
  final List<MapMarker> markers;
  final ({double lat, double lng})? userDotLatLng;

  /// When set, renders the picker's center-of-search Soko teardrop pin
  /// (`assets/pins/pin-search.png`) at this point on a dedicated symbol layer,
  /// independent of [markers]. Mirrors [userDotLatLng]. Null → no picker pin.
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
  /// shell adapts).
  final void Function(MapMarker marker, Offset pixel)? onMarkerTap;

  /// PROD-2016: fires when the user taps the canvas WITHOUT hitting a
  /// pin or cluster. Used by the shell to close the tooltip on
  /// tap-outside. Distinct from `onMarkerTap` (which only fires on
  /// pin hits). Internal — no consumer-facing wiring.
  final VoidCallback? onMapTapOutside;

  /// PROD-3109: fires on every canvas tap with the tapped geographic
  /// coordinate `(lat, lng)`. Used by the map location picker to resolve the
  /// tapped neighborhood. Fires alongside `onMapTapOutside` when the tap misses
  /// all pins.
  final void Function(double lat, double lng)? onMapTapLatLng;

  /// PROD-3109: GeoJSON geometry (MultiPolygon) of the selected neighborhood to
  /// outline. Null clears the overlay. Takes precedence over [highlightPoint].
  final Map<String, dynamic>? highlightBoundaryGeoJson;

  /// Picker drill-down: a GeoJSON FeatureCollection of a selected city's child
  /// neighbourhoods, drawn as a light tappable layer beneath
  /// [highlightBoundaryGeoJson]. Null/empty clears it. Tap hit-testing happens
  /// in Dart (via [onMapTapLatLng]); this is display only.
  final Map<String, dynamic>? childBoundariesGeoJson;

  /// PROD-3109: fires on every canvas hover with the hovered geographic
  /// coordinate `(lat, lng)`. Web/desktop only; null on native/stub.
  final void Function(double lat, double lng)? onMapHoverLatLng;

  /// PROD-3109: fires when the pointer leaves the map canvas. Web/desktop only;
  /// null on native/stub.
  final VoidCallback? onMapHoverExit;

  /// PROD-3109: GeoJSON geometry (MultiPolygon) of the neighborhood under the
  /// hover cursor to outline as a preview. Null clears it. Web/desktop only.
  final Map<String, dynamic>? hoverBoundaryGeoJson;

  /// PROD-3109: fallback highlight when no boundary polygon is available — a
  /// small circle at this point. Ignored when [highlightBoundaryGeoJson] is set.
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

  /// PROD-2016: id of the currently-selected marker (tooltip target).
  /// The platform widget stamps `selected: true` onto the matching
  /// GeoJSON feature so the unclustered layer's `case` expression
  /// renders the enlarged radius.
  final String? selectedMarkerId;

  /// PROD-2205: multi-pin variant. Every marker whose id is in this
  /// set also gets `selected: true` stamped, in addition to anything
  /// matched by [selectedMarkerId]. Null / empty means no extra
  /// selection.
  final Set<String>? selectedMarkerIds;

  /// PROD-2016 (web): fires on hover-enter over an unclustered pin
  /// (desktop only; touch devices don't fire mouseenter). The shell
  /// opens the tooltip as if the pin had been tapped. Internal.
  final void Function(MapMarker marker, Offset pixel)? onPinHoverEnter;

  /// PROD-2016 (web): fires on hover-exit from an unclustered pin.
  /// Shell starts a 150 ms grace timer before closing the tooltip
  /// (lets the user move the cursor onto the tooltip itself).
  final VoidCallback? onPinHoverExit;
  final bool interactive;
  final MapBoundsConfig? boundsConfig;
  final VoidCallback? onMapReady;
  final VoidCallback? onMapMoved;
  final bool
  isDark; // Note: Web auto-detects theme, this is for API consistency
  // PROD-595: Memory optimizations for small/thumbnail maps
  // When true: uses lower maxZoom (14), skips fog effect, reduces GPU memory footprint
  final bool optimizeForSmallSize;

  /// Optional override for the map's max zoom-in level. When null, the default
  /// applies (14 for small maps, 16 for full maps — a tile-memory cap from
  /// PROD-595). The Map page raises it so users can zoom to street/building
  /// level. Web-only today; native is uncapped (Mapbox default ~22).
  final double? maxZoom;
  // Web cursor override zones to prevent grab cursor bleeding to Flutter overlays
  final MapCursorOverride? cursorOverride;
  // PROD-1978: render markers as a Mapbox GeoJSON source-layer with
  // clustering instead of per-pin DOM overlays. Gate is enforced one
  // level up (`MapboxMapWidget` AND-s this with the PostHog flag).
  final bool cluster;
  // PROD-1978 follow-up: any change to this counter re-runs the fit
  // logic (`_fitToBbox` if a bbox is set, else `_fitToMarkers`). Lets
  // a "fit all" button work even when the declarative `fitMarkers`
  // prop didn't toggle false→true between rebuilds.
  final int fitToMarkersToken;

  /// PROD-2042 Wave 2: monotonic counter bumped by the shell when the
  /// my-location button is tapped. Signals "ease camera to the
  /// current [centerLat]/[centerLng]/[zoom] now" — independent of
  /// whether those props changed value. Needed because after an
  /// initial fit-to-markers the prop value may already match the
  /// override target (user location), so a value-diff predicate
  /// wouldn't trigger an animation.
  final int centerToToken;

  /// PROD-2671: render unclustered pins as per-category PNG teardrops via
  /// a Mapbox symbol layer (`icon-image`) instead of the default colored
  /// circles. Opt-in; a consumer that leaves this false keeps the circle
  /// rendering untouched. (PROD-3830 turns it on for the chat, list, zine
  /// and detail maps too — it is no longer Map-page-only.)
  final bool categoryIcons;

  /// PROD-2671: category-key → asset path for the PNG pins to register
  /// (via `addImage`) when [categoryIcons] is true. Each `MapMarker`'s
  /// `iconImage` must match one of these keys.
  final Map<String, String> categoryIconAssets;

  /// PROD-3828: add the inline pin-caption layer. Opt-out (default true) —
  /// see [MapboxMapWidget.showPinCaptions] for why that direction.
  final bool showPinCaptions;

  /// PROD-3828: per-surface zoom→`icon-size` curve; null →
  /// [MapPinIconTokens.iconSizeStops]. Threaded into the icon-size
  /// expressions, the caption offset and the tap hit-test box alike.
  final List<(double zoom, double size)>? pinIconSizeStops;

  /// PROD-2807: use the app's **custom world-grid selection** instead of
  /// Mapbox's built-in clustering. Requires [cluster] (the GeoJSON-source
  /// path). The source is created with `cluster:false`; the "cluster"
  /// layers render our own `+k` overflow bubbles (markers carrying
  /// [MapMarker.overflowCount]) keyed off `overflow_count`; a bubble tap
  /// zooms in to decluster. Opt-in (Map page only); every other consumer
  /// keeps native Mapbox clustering untouched.
  final bool customSelection;

  /// PROD-2671: fires when the map settles after a pan/zoom (`moveend`),
  /// carrying the camera centre/zoom/bounds. Drives settle-to-search on
  /// the Map page. Distinct from [onMapMoved] (which also fires mid-pan).
  final MapCameraIdleCallback? onCameraIdle;

  /// PROD-2807 (#4): fires (throttled) on every `move` during a gesture,
  /// carrying the live camera state. Drives instant mid-gesture re-selection
  /// on the Map page. Distinct from [onCameraIdle] (settle only) and
  /// [onMapMoved] (no camera state).
  final MapCameraIdleCallback? onCameraMove;

  /// PROD-2671: when false (e.g. the Map page — no tooltip), a pin tap fires
  /// `onMarkerTap` immediately without easing the camera to centre the pin.
  /// Default true preserves the PROD-2046 tooltip-placement ease.
  final bool centerOnMarkerTap;

  /// PROD-2971: admin-only searched-area debug overlay. When non-null, draws
  /// the retrieval circle / sargable bbox / grid cells / v2 selection rect
  /// (distinct colours) from the `/map/pins` `debug.area` block; null → no
  /// overlay. Geographic polygons, so they track the camera for free.
  final MapDebugArea? debugOverlay;

  /// PROD-2971: which overlay shapes to draw (null = all).
  final Set<MapDebugShape>? debugOverlayShapes;

  /// DEBUG-only: the `/map/pins` search area (radius circle + v2 viewport
  /// rectangle) to draw as a translucent soko-red overlay. Null = no overlay.
  /// Installed on-demand (only once non-null) so it has zero footprint until
  /// toggled on from the debug tab. See [_syncDebugSearchArea].
  final MapSearchAreaOverlay? debugSearchArea;

  /// PROD-3124: dot hints — GeoJSON FeatureCollection of small category-
  /// coloured circles drawn BENEATH every pin layer for retrieved-but-not-
  /// pinned results. Null → the layer stays empty. Identity-stable between
  /// settles (built by a provider); [didUpdateWidget] re-syncs + re-runs the
  /// fade-in on `!identical`. See [_installDotHintsLayer]/[_syncDotHints].
  final Map<String, dynamic>? dotHintsGeoJson;

  /// PROD-3124 dot tap — see the facade doc. Lowest tap priority.
  final void Function(String id, String entity, double lat, double lng)?
  onDotHintTap;

  /// PROD-2671: logical-px insets of the on-screen chrome that overlaps the
  /// full-bleed map — the top bar (search + shortcut chips) and the bottom
  /// results drawer. When set (Map page), the camera state reported to
  /// `onCameraIdle`/`onCameraMove` describes the **visible rectangle** (canvas
  /// minus these insets) instead of the full canvas, so the `/map/pins` query +
  /// pin selection cover only what the user sees (not the strips behind the
  /// chrome). They also drive persistent Mapbox camera padding so the map
  /// centres + frames within the visible area. Both default 0 → every other map
  /// surface keeps full-canvas behaviour untouched.
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

// PROD-1978: Source + layer identifiers for the clustered GeoJSON path.
// Kept as top-level constants so dispose() can remove them by name even
// when the state class has been garbage-collected mid-rebuild.
const String _clusterSourceId = 'heyl-pins';
const String _clusterLayerId = 'heyl-clusters';
const String _clusterCountLayerId = 'heyl-cluster-count';
const String _unclusteredLayerId = 'heyl-unclustered';
// PROD-2671: symbol layer drawing per-category PNG pins on top of the
// (then-transparent) unclustered circle layer. Only added in
// `categoryIcons` mode.
const String _unclusteredIconLayerId = 'heyl-unclustered-icons';
// Pin CAPTIONS (name + secondary facet) live in their OWN symbol layer, stacked
// directly ABOVE the icon layer, so a nearer pin's teardrop never paints over a
// farther pin's caption (a single icon+text layer draws each feature's icon and
// text together in z-order, letting a later icon occlude an earlier caption —
// Mapbox has no per-layer knob for "labels above all icons", so we split the
// layers). Captions still avoid each other (`text-allow-overlap` default false +
// `text-optional`), so the "no text on top of text" rule is preserved, and the
// relevance `symbol-sort-key` now rides on this layer.
const String _unclusteredCaptionLayerId = 'heyl-unclustered-captions';
const String _userLocationSourceId = 'heyl-user';
const String _userLocationLayerId = 'heyl-user-dot';
// PROD-2671: the approximate-location accuracy ring — a geodesic fill polygon
// (scales with zoom) installed BEHIND the dot. Restores the ring removed by
// PROD-2016 (previously a pixel-recompute DOM overlay).
const String _userAccuracySourceId = 'heyl-user-accuracy';
const String _userAccuracyFillLayerId = 'heyl-user-accuracy-fill';
const String _userAccuracyLineLayerId = 'heyl-user-accuracy-line';
// The map-location-picker center-of-search pin — a single Soko teardrop
// (`assets/pins/pin-search.png`) on its own symbol source/layer, driven by
// [pickerPinLatLng]. Bottom-anchored so the teardrop tip sits on the point.
// Kept off the cluster/category-pin machinery, exactly like the user dot.
const String _pickerPinSourceId = 'heyl-picker-pin';
const String _pickerPinLayerId = 'heyl-picker-pin-icon';
const String _pickerPinImageKey = 'pin-search';
const String _pickerPinAssetPath = 'assets/pins/pin-search.png';
// Source PNG is 334×464; ~0.10 renders the pin ~46 px tall on screen.
const double _pickerPinIconSize = 0.1;
// DEBUG-only: the `/map/pins` search-area overlay (radius circle + v2 viewport
// rectangle). Installed on-demand (only once the debug tab toggles it on) and
// rendered on TOP of every other layer so the area reads clearly over the pins.
const String _debugAreaSourceId = 'heyl-debug-area';
const String _debugAreaFillLayerId = 'heyl-debug-area-fill';
const String _debugAreaLineLayerId = 'heyl-debug-area-line';

// PROD-3109: map-location-picker highlighted boundary. One GeoJSON source holds
// either the selected neighborhood MultiPolygon or (fallback) a small geodesic
// circle around a tapped point; a fill (below) + line (above) render both.
const String _pickerBoundarySourceId = 'heyl-picker-boundary';
const String _pickerBoundaryFillLayerId = 'heyl-picker-boundary-fill';
const String _pickerBoundaryLineLayerId = 'heyl-picker-boundary-line';
// PROD-3109: hover boundary (lighter, installed BENEATH the committed boundary).
const String _pickerHoverSourceId = 'heyl-picker-hover';
const String _pickerHoverFillLayerId = 'heyl-picker-hover-fill';
const String _pickerHoverLineLayerId = 'heyl-picker-hover-line';
// Picker drill-down: tappable child neighbourhoods, installed BENEATH the hover
// + committed pairs so the selected outline always reads on top.
const String _pickerChildrenSourceId = 'heyl-picker-children';
const String _pickerChildrenFillLayerId = 'heyl-picker-children-fill';
const String _pickerChildrenLineLayerId = 'heyl-picker-children-line';
// Radius of the fallback point circle (no boundary polygon available).
const double _pickerPointFallbackRadiusMeters = 150;

// PROD-2971: admin-only searched-area debug overlay. One GeoJSON source of
// polygons coloured per-feature via `['get', ...]` paint expressions, so a
// single fill + line layer renders the retrieval circle / boxes / grid /
// selection rect. Rendered above the pins.
const String _mapDebugSourceId = 'heyl-map-debug';
const String _mapDebugFillLayerId = 'heyl-map-debug-fill';
const String _mapDebugLineLayerId = 'heyl-map-debug-line';

// PROD-3124: dot hints — one source + one circle layer, installed FIRST in
// the cluster install pass so it paints beneath every pin layer.
const String _dotHintsSourceId = 'heyl-dot-hints';
const String _dotHintsLayerId = 'heyl-dot-hints';

class _MapboxMapPlatformState extends State<MapboxMapPlatform>
    with WidgetsBindingObserver {
  /// PROD-3828: the zoom→`icon-size` curve this surface renders with — the
  /// per-consumer override, else the Map-page default. THE single read point:
  /// the icon-size expressions, the caption offset and the tap hit-test all go
  /// through here, so a surface's captions and tap targets can't drift from
  /// its art.
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
  /// focus exactly like every other multiplier riding `icon_scale`.
  List<dynamic> get _selectedScaleExpr => <dynamic>[
    'case',
    <dynamic>[
      'boolean',
      <dynamic>['get', 'selected'],
      false,
    ],
    kMapPinSelectedSizeMul,
    1,
  ];

  static int _viewCounter = 0;
  late final String _viewId;
  MapboxMap? _map;
  bool _mapLoaded = false;
  bool _mapboxReady = false;
  bool _mapboxLoadFailed = false;
  web.HTMLDivElement? _container;
  JSFunction? _moveEndCallback;
  // PROD-2671: separate `moveend`-only listener that reads the camera
  // state and forwards it to `widget.onCameraIdle` (settle-to-search).
  JSFunction? _cameraIdleCallback;
  // PROD-2807 (#4): `move` listener that forwards the LIVE camera state to
  // `widget.onCameraMove` (throttled) so the selection can re-run mid-gesture.
  JSFunction? _cameraMoveCallback;
  // PROD-2993: `movestart` listener that fires `onUserGesture` only for
  // user-originated camera events (those carrying `originalEvent`).
  JSFunction? _userGestureCallback;
  int _lastCameraMoveEmitMs = 0;
  static const int _cameraMoveThrottleMs = 50;

  /// PROD-4104 — one-shot `moveend` for the OPENING ease. The reveal used to
  /// ride a fixed `kMapOpenSettleMs + 150` timer, so pins that were already
  /// loaded still waited 150 ms past the animation. This fires on the real
  /// settle; the timer survives only as a fallback.
  JSFunction? _openSettleMoveEndCb;

  JSFunction? _visibilityCallback;
  JSFunction? _cursorMoveCallback;
  Timer? _resizeDebounce;

  /// PROD-2046 Option A — when we programmatically ease the map to
  /// centre on a tapped pin, the resulting `move` / `moveend` events
  /// would otherwise fire `onMapMoved` and close the tooltip we're
  /// about to show. Set true around the ease, cleared after the
  /// scheduled tooltip-show fires.
  bool _suppressMoveCallback = false;

  /// Pending tooltip-show timer (PROD-2046 part 2). The tooltip only
  /// appears AFTER the camera-ease completes so it never renders at a
  /// stale position. A subsequent pin tap cancels this timer and
  /// schedules a new one — so a fast double-tap on different pins
  /// just shows the most recent one's tooltip.
  Timer? _pendingTooltipShow;

  /// Vertical fraction of the viewport where a tapped pin should land
  /// after the programmatic ease (PROD-2046). 0.55 = slightly below
  /// centre, leaving room above for the tooltip card. Must mirror the
  /// shell's expectation in `_PinTooltipOverlay._resolvePosition` —
  /// the shell uses the destination pixel as the tooltip's anchor.
  static const double _pinTargetYFraction = 0.55;

  /// Ease animation duration for the pin-tap pan, in ms.
  static const int _pinEaseDurationMs = 250;

  /// Extra time the move-suppress flag is held AFTER the tooltip
  /// shows. Mapbox's trailing `moveend` event can land a few ms past
  /// the nominal ease duration; clearing the suppress flag in the
  /// same callback that shows the tooltip race-condition'd with that
  /// trailing event and dismissed the tooltip on arrival. 100 ms is
  /// enough headroom for the platform jitter without being perceptible
  /// — once it elapses, user-initiated pans close the tooltip normally.
  static const int _moveSuppressTailMs = 100;

  // Default location (Lisbon)
  static const double _defaultLat = 38.7223;
  static const double _defaultLng = -9.1393;

  /// PROD-595 / PROD-3833 — how long a disposed map's WebGL context is assumed
  /// to need before a new one may be allocated.
  static const Duration _kContextCleanupWindow = Duration(milliseconds: 200);

  /// When the most recent map on this page tore down. Static because the
  /// contention is between *different* map instances (leaving one surface and
  /// entering another), not within one. Null until the first dispose — which is
  /// exactly the case that no longer pays the delay.
  static DateTime? _lastDisposedAt;

  /// The remainder of [_kContextCleanupWindow] still owed, or zero.
  Duration _pendingContextCleanupWait() {
    final last = _lastDisposedAt;
    if (last == null) return Duration.zero;
    final elapsed = DateTime.now().difference(last);
    if (elapsed.isNegative) return _kContextCleanupWindow; // clock moved back
    final remaining = _kContextCleanupWindow - elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _viewId = 'mapbox-interactive-${_viewCounter++}';
    _loadMapboxAndInitialize();
  }

  /// Load Mapbox JS library dynamically, then initialize the map.
  ///
  /// PROD-595: a startup delay lets a previously-disposed map's WebGL context
  /// finish cleaning up before we allocate a new one, so navigating between map
  /// surfaces doesn't spike memory with two live contexts.
  ///
  /// PROD-3833: that delay is now paid only when there is actually something to
  /// wait for. It used to be an unconditional 200 ms on **every** mount,
  /// including the first map of the session, where no context exists to clean
  /// up — 200 ms of the map's cold open spent guarding against nothing, in
  /// front of the 393 KB script fetch. Now it waits out only the remainder of
  /// the window since the last dispose.
  Future<void> _loadMapboxAndInitialize() async {
    try {
      final wait = _pendingContextCleanupWait();
      if (wait > Duration.zero) {
        await Future.delayed(wait);
        if (!mounted) return;
        debugPrint(
          '[MapboxMapPlatform] Startup delay complete, loading Mapbox',
        );
      }

      // Load Mapbox JS/CSS on demand (saves 393KB from initial load)
      await loadMapbox();

      if (!mounted) return;

      // Register view factory BEFORE setting _mapboxReady
      // This ensures the HtmlElementView can be rendered immediately
      _registerViewFactory();
      _setupVisibilityListener();

      // Now trigger rebuild to show the map
      setState(() {
        _mapboxReady = true;
      });
    } catch (e) {
      debugPrint('[MapboxMapPlatform] Failed to load Mapbox: $e');
      if (mounted) {
        setState(() {
          _mapboxLoadFailed = true;
        });
      }
    }
  }

  @override
  void didChangeMetrics() {
    // Container size may have changed (window resize, rotation) - call resize
    _scheduleResize();
  }

  /// Debounced resize to avoid excessive calls during resize drag.
  /// PROD-2016: legacy DOM-overlay markers needed per-pin position
  /// recalculation on resize. Cluster path renders on the WebGL
  /// canvas — Mapbox handles repositioning automatically.
  void _scheduleResize() {
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 100), () {
      if (mounted && _map != null && _mapLoaded) {
        _map!.resize();
      }
    });
  }

  /// Listen for browser visibility changes (tab switching)
  void _setupVisibilityListener() {
    _visibilityCallback = ((web.Event e) {
      if (web.document.visibilityState == 'visible') {
        // Tab became visible - resize map to fix any corruption
        _scheduleResize();
      }
    }).toJS;
    web.document.addEventListener('visibilitychange', _visibilityCallback!);
  }

  void _registerViewFactory() {
    // Set access token
    mapboxAccessToken = EnvironmentConfig.mapboxAccessToken;

    // PROD-595: Apply global memory optimizations
    applyMemoryOptimizations();

    // Inject CSS for styling
    _injectCSS();

    // Create container div
    _container = web.document.createElement('div') as web.HTMLDivElement;
    _container!.id = _viewId;
    _container!.style.width = '100%';
    _container!.style.height = '100%';
    _container!.style.position = 'relative';

    // PROD-2016: every map consumer now uses the cluster source-layer
    // path — markers live on the WebGL canvas, no DOM overlay div.
    // The legacy `_markersContainer` allocation block was retired
    // here.

    // Register the view factory
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) {
      // Initialize map after container is in DOM. When the host widget
      // mounts/disposes/remounts in quick succession (e.g. while the
      // list-page zine view's pager re-keys on first-item-added), this
      // deferred callback can fire AFTER dispose() has nulled `_container`
      // — force-unwrapping then threw NullCheckOperatorException every
      // frame, dirtying layout and freezing the UI. Guard both checks.
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!mounted || _container == null) return;
        _initializeMap(_container!);
      });
      return _container!;
    });
  }

  void _injectCSS() {
    // Check if CSS already injected
    final existingStyle = web.document.getElementById('mapbox-markers-css');
    if (existingStyle != null) return;

    // Create and inject CSS for markers and hide controls
    final style = web.document.createElement('style') as web.HTMLStyleElement;
    style.id = 'mapbox-markers-css';
    style.textContent = '''
      .mapboxgl-ctrl-logo,
      .mapboxgl-ctrl-attrib,
      .mapboxgl-ctrl-bottom-left,
      .mapboxgl-ctrl-bottom-right {
        display: none !important;
      }

      .heyl-map-marker {
        position: absolute;
        pointer-events: auto;
        cursor: pointer;
        transform: translate(-50%, -50%);
        transition: transform 0.1s ease-out;
      }

      .heyl-map-marker:hover {
        transform: translate(-50%, -50%) scale(1.1);
      }

      .heyl-marker-user {
        width: 20px;
        height: 20px;
        display: flex;
        align-items: center;
        justify-content: center;
      }

      .heyl-marker-user-dot {
        width: 14px;
        height: 14px;
        background: #3B82F6;
        border-radius: 50%;
        border: 2px solid white;
        box-shadow: 0 2px 6px rgba(0,0,0,0.3);
      }

      /* Lovable spec: Place markers use white background with Soko icon */
      .heyl-marker-place {
        width: 28px;
        height: 28px;
        background: white;
        border-radius: 50%;
        border: 2px solid rgba(0,0,0,0.1);
        box-shadow: 0 2px 8px rgba(0,0,0,0.2);
        display: flex;
        align-items: center;
        justify-content: center;
        overflow: hidden;
      }

      .heyl-marker-place-selected {
        transform: translate(-50%, -50%) scale(1.2);
        box-shadow: 0 4px 12px rgba(0,0,0,0.3);
      }

      .heyl-marker-place svg,
      .heyl-marker-place img {
        width: 20px;
        height: 20px;
        object-fit: contain;
      }

      /* Lovable spec: Letter markers (A, B, C) use pink/rose color (#C76274) */
      .heyl-marker-letter {
        min-width: 28px;
        height: 28px;
        background: #C76274;
        border-radius: 50%;
        border: 2px solid white;
        box-shadow: 0 2px 8px rgba(0,0,0,0.3);
        display: flex;
        align-items: center;
        justify-content: center;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        font-size: 14px;
        font-weight: 600;
        color: white;
      }

      .heyl-marker-letter-selected {
        transform: translate(-50%, -50%) scale(1.2);
        box-shadow: 0 4px 12px rgba(199, 98, 116, 0.5);
      }

      .heyl-marker-pin {
        width: 32px;
        height: 40px;
        display: flex;
        flex-direction: column;
        align-items: center;
      }

      /* Lovable spec: Pin markers use pink/rose color (#C76274) */
      .heyl-marker-pin-head {
        width: 24px;
        height: 24px;
        background: #C76274;
        border-radius: 50% 50% 50% 0;
        transform: rotate(-45deg);
        border: 2px solid white;
        box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      }

      .heyl-marker-pin-stem {
        width: 2px;
        height: 12px;
        background: rgba(0,0,0,0.3);
        margin-top: -4px;
      }

      .heyl-marker-accuracy-circle {
        position: absolute;
        border-radius: 50%;
        background: rgba(59, 130, 246, 0.12);
        border: 1.5px solid rgba(59, 130, 246, 0.3);
        pointer-events: none;
        transform: translate(-50%, -50%);
        transition: width 0.3s ease-out, height 0.3s ease-out;
      }

    ''';
    web.document.head?.appendChild(style);
  }

  void _initializeMap(web.HTMLDivElement container) {
    if (_map != null) return;

    // PROD-1978 fold-in (PR #432 punch list): empty the container before
    // mounting a new Mapbox map. Without this, stale children from a
    // previous instance survive into the new instance and Mapbox logs
    // `Map container element should be empty` on every init. Safe to
    // do because we own the container — the markers overlay (when
    // present) is re-appended below.
    while (container.firstChild != null) {
      container.removeChild(container.firstChild!);
    }

    final targetLat = widget.centerLat ?? _defaultLat;
    final targetLng = widget.centerLng ?? _defaultLng;
    // Map page: birth zoomed out so the opening `easeTo` to the target zoom is a
    // real animation that composites the map + reveals the pins (see
    // `_startOpenSettle`). Other surfaces open at the exact requested zoom.
    final birthZoom = widget.customSelection
        ? (widget.zoom - kMapOpenSettleZoomDelta)
        : widget.zoom;

    // Option A (app-wide Soko basemap): a single theme-independent Mapbox
    // Standard (v3) style. See EnvironmentConfig.mapboxActiveStyle (stock
    // light/dark styles remain the fallback target). We intentionally drop the
    // `?optimize=true` param here: it targets classic vector styles, whereas a
    // Standard style has no top-level layers to trim (they live in its import).
    final mapStyle = EnvironmentConfig.mapboxActiveStyle;

    try {
      // PROD-595: Use lower maxZoom for small maps to reduce tile memory (~150-200MB vs ~400-500MB).
      // A per-instance override (widget.maxZoom) lets a surface raise the cap —
      // the Map page does so for street/building-level exploration.
      final maxZoom =
          widget.maxZoom ?? (widget.optimizeForSmallSize ? 14.0 : 16.0);

      // Create map options with theme-aware style and memory optimizations.
      //
      // PROD-1978 Phase 4 fix: `interactive` is always passed as `true`
      // at the Mapbox level, even when widget.interactive is false.
      // Reason: Mapbox's top-level `interactive: false` strips ALL input
      // handlers — including click. With the static-toggle UX, users
      // need to be able to tap a cluster to drill in even while the map
      // is in its static (non-pan, non-zoom) state. So we keep
      // click+marker handlers attached and only gate the pan/zoom
      // gestures via the individual `dragPan`/`scrollZoom`/
      // `touchZoomRotate` flags + a cursor override below.
      final options = createMapOptions(
        container: container,
        style: mapStyle,
        lng: targetLng,
        lat: targetLat,
        zoom: birthZoom,
        pitch: 0,
        bearing: 0,
        interactive: true,
        scrollZoom: widget.interactive,
        dragPan: widget.interactive,
        dragRotate: false,
        doubleClickZoom: false,
        touchZoomRotate: widget.interactive,
        attributionControl: false,
        // PROD-595: Memory optimization options
        maxZoom: maxZoom, // Small maps: 14, full maps: 16
        antialias: false, // Disable antialiasing for memory savings
        fadeDuration: 0, // Disable fade transitions
        // PROD-2671: the Map page (customSelection) retains the WebGL buffer as
        // a safety net so pin updates that land after the opening settle (e.g.
        // the viewport refetch) present reliably. Other surfaces keep the
        // memory-saving default (false). See `_startOpenSettle`.
        preserveDrawingBuffer: widget.customSelection,
      );

      // Create map
      _map = MapboxMap(options);

      // Add load event handler
      _map!.on(
        'load',
        (() {
          _onMapLoaded();
        }).toJS,
      );
    } catch (e) {
      debugPrint('[MapboxMapPlatform] Error creating map: $e');
    }
  }

  void _onMapLoaded() {
    if (!mounted) return;

    _mapBreadcrumb(
      'Map loaded',
      data: {
        'markers': widget.markers.length,
        'interactive': widget.interactive,
      },
    );

    setState(() {
      _mapLoaded = true;
    });

    // Setup WebGL context loss handling
    _setupWebGLContextHandlers();

    // Setup cursor zone management for desktop web
    _setupCursorOverride();

    // PROD-702: No fog on shared maps — only the hero map (ImmersiveMapWeb)
    // uses its own scoped CSS fog overlay.

    // PROD-2016: cluster source-layer path means Mapbox handles all
    // marker repositioning on the canvas — we only forward the move
    // event to the consumer's `onMapMoved` callback.
    //
    // PROD-2046: suppress during our programmatic pin-tap ease so the
    // tooltip we just showed isn't immediately dismissed by the same
    // pan that's bringing the pin into position.
    _moveEndCallback = (() {
      if (_suppressMoveCallback) return;
      widget.onMapMoved?.call();
    }).toJS;
    _map!.on('moveend', _moveEndCallback!);
    _map!.on('move', _moveEndCallback!);

    // PROD-2993: the **real** "the user did this" signal.
    //
    // Mapbox GL sets `originalEvent` (the underlying DOM event) on a camera
    // event only when a user gesture caused it — a drag, a wheel, a pinch, an
    // arrow key. Our own `easeTo` / `flyTo` / `fitBounds` fire the same
    // `movestart` with no `originalEvent` at all. So this distinguishes them
    // exactly, including the case that defeats every timing heuristic: the user
    // grabbing the map *in the middle of* one of our animations (Mapbox aborts
    // the animation and starts a fresh, user-originated move).
    if (widget.onUserGesture != null) {
      _userGestureCallback = ((JSAny? event) {
        if (event == null) return;
        final e = event as JSObject;
        if (e.getProperty('originalEvent'.toJS) == null) return;
        widget.onUserGesture!.call();
      }).toJS;
      // `movestart` covers pan, wheel, pinch and keyboard — every user-driven
      // camera change begins with one.
      _map!.on('movestart', _userGestureCallback!);
    }

    // PROD-2671: settle-to-search — a moveend-only listener that reads the
    // camera state and hands it to the consumer. Only wired when the Map
    // page passes `onCameraIdle`; suppressed during our programmatic ease.
    if (widget.onCameraIdle != null) {
      _cameraIdleCallback = (() {
        if (_suppressMoveCallback) return;
        _emitCameraIdle();
      }).toJS;
      _map!.on('moveend', _cameraIdleCallback!);
    }

    // PROD-2807 (#4): live mid-gesture re-selection — a `move` listener that
    // forwards the throttled camera state so the selection re-runs while the
    // user pans/zooms (the pool still refetches only on the `moveend` above).
    // Suppressed during our programmatic pin-tap ease, same as the others.
    if (widget.onCameraMove != null) {
      _cameraMoveCallback = (() {
        if (_suppressMoveCallback) return;
        _emitCameraMove();
      }).toJS;
      _map!.on('move', _cameraMoveCallback!);
    }

    // Parked pins-on-open fix (Map page): run the opening zoom-in settle on the
    // first `idle` after load (see `_startOpenSettle`).
    if (widget.customSelection) {
      _awaitingOpenEase = true;
      _compositeIdleCb = (() => _startOpenSettle()).toJS;
      _map!.on('idle', _compositeIdleCb!);
      // Track camera movement so the pin-reveal only arms while settled (new
      // pins that appear mid-pan slide in with the map; the next settle animates
      // the refetch's new pins). Not gated by `_suppressMoveCallback` — this
      // must reflect the real camera state, incl. our own opening ease.
      _moveStartAnimCb = (() => _cameraMoving = true).toJS;
      _moveEndAnimCb = (() => _cameraMoving = false).toJS;
      _map!.on('movestart', _moveStartAnimCb!);
      _map!.on('moveend', _moveEndAnimCb!);
    }

    // Safari fix: Force resize after map is loaded to ensure proper dimensions
    // Safari sometimes doesn't compute container dimensions correctly on initial render
    _map!.resize();

    // PROD-2671 (Map page): apply the chrome-aware camera padding before the
    // opening settle so the map frames within the visible area from the start.
    // Suppressed internally so its synchronous move/moveend isn't read as a pan.
    _applyViewportPadding();

    // Install the cluster source + style layers, then push the initial
    // feature collection. PROD-2671: in category-icon mode, register the
    // PNG pins first so the symbol layer has its images on first paint.
    if (widget.categoryIcons && widget.categoryIconAssets.isNotEmpty) {
      _registerCategoryIcons().whenComplete(() {
        if (!mounted || _map == null) return;
        _installClusterSourceAndLayers();
        _renderMarkers();
      });
    } else {
      _installClusterSourceAndLayers();
      _renderMarkers();
    }

    // PROD-1978 Phase 4: apply the initial interactive state. With the
    // always-on top-level `interactive: true`, the individual
    // pan/zoom/touch handlers were enabled by createMapOptions iff
    // widget.interactive was true. Calling this here also normalises
    // the cursor override on first paint.
    _applyInteractiveState(widget.interactive);

    // Fit to explicit bbox first (e.g. /lists hub fitting a selected
    // city's bbox); otherwise fall through to marker-derived bounds.
    if (widget.boundsConfig?.hasBbox == true) {
      _fitToBbox();
    } else if (widget.fitMarkers && widget.markers.isNotEmpty) {
      _fitToMarkers();
    }

    // Safari fix: Schedule additional resizes to handle delayed layout calculations
    // This handles cases where Safari computes layout after the 'load' event.
    // PROD-1978 (PR #432 fold-in): tighten guards — re-check `_container`
    // and `_mapLoaded` so the callback is a clean no-op if dispose() ran
    // during the 100/500 ms window.
    // PROD-2160: also re-apply the camera fit after the delayed resize.
    // If Mapbox initialised against a zero-size container, resize() recovers
    // the viewport but leaves the camera at whatever the bad initial layout
    // produced (world view), so the fit must run again once dimensions are real.
    Future.delayed(const Duration(milliseconds: 100), _resizeAndRefitIfNeeded);
    Future.delayed(const Duration(milliseconds: 500), _resizeAndRefitIfNeeded);

    widget.onMapReady?.call();
  }

  /// Setup WebGL context loss/restore handlers to recover from GPU issues
  void _setupWebGLContextHandlers() {
    if (_map == null) return;

    try {
      final canvasContainer = _map!.getCanvasContainer();
      final canvas = canvasContainer.querySelector('canvas');
      if (canvas != null) {
        canvas.addEventListener(
          'webglcontextlost',
          ((web.Event e) {
            e.preventDefault();
            debugPrint('[MapboxMapPlatform] WebGL context lost');
          }).toJS,
        );

        canvas.addEventListener(
          'webglcontextrestored',
          ((web.Event e) {
            debugPrint('[MapboxMapPlatform] WebGL context restored');
            // Resize map to refresh rendering
            _scheduleResize();
          }).toJS,
        );
      }
    } catch (e) {
      debugPrint('[MapboxMapPlatform] Error setting up WebGL handlers: $e');
    }
  }

  /// Setup mousemove-based cursor management. Two responsibilities:
  ///
  /// 1. **Overlay zones**: when the mouse is within a configured
  ///    [MapCursorZone] (e.g. a floating button's bbox), force the
  ///    canvas-container cursor to the zone's cursor (typically
  ///    'pointer'). This is the workaround for Flutter web's
  ///    HtmlElementView absorbing pointer/cursor events — Flutter's
  ///    `MouseRegion` (including the one inside `Clickable`) doesn't
  ///    fire over a platform view, so we set the cursor directly on
  ///    the Mapbox canvas's CSS.
  /// 2. **Top/bottom dead bands**: optional — when the mouse is in
  ///    the top `topPx` or bottom `bottomPx` px of the map, force
  ///    `cursor: default`. Useful for legacy "drawer hides the map"
  ///    layouts.
  ///
  /// When the mouse leaves both zones AND dead bands, the cursor
  /// falls back to the "base" cursor — which depends on
  /// `widget.interactive`: grab for interactive (Mapbox's default
  /// via `.mapboxgl-interactive` class), `default` for static (set
  /// by `_applyInteractiveState`).
  /// Setup mousemove-based cursor management for legacy "drawer dead
  /// bands" (`topPx` / `bottomPx`). Sets `cursor: default` when the
  /// pointer is in a configured band. Active only when the consumer
  /// passes a `MapCursorOverride` with non-zero bands; otherwise the
  /// listener isn't registered.
  ///
  /// **Out of scope here**: hover-cursor for floating overlay buttons
  /// (fit-all, my-location, activation chip). Those need a separate
  /// solution — see PROD-2002. The pin/cluster pointer cursor is
  /// handled by Mapbox's layer-scoped `mouseenter`/`mouseleave`
  /// subscriptions in `_installClusterSourceAndLayers`.
  void _setupCursorOverride() {
    final override = widget.cursorOverride;
    if (override == null || _container == null) return;

    final topPx = override.topPx;
    final bottomPx = override.bottomPx;
    if (topPx <= 0 && bottomPx <= 0) return;

    _cursorMoveCallback = ((web.MouseEvent e) {
      // Don't interfere during drag — let Mapbox handle grabbing cursor
      if (e.buttons != 0) return;

      final rect = _container!.getBoundingClientRect();
      final y = e.clientY - rect.top;
      final h = rect.height;

      final canvasContainer = _container!.querySelector(
        '.mapboxgl-canvas-container',
      );
      if (canvasContainer == null) return;
      final el = canvasContainer as web.HTMLElement;

      if (y < topPx || y > h - bottomPx) {
        el.style.setProperty('cursor', 'default', 'important');
      } else {
        el.style.removeProperty('cursor');
      }
    }).toJS;

    _container!.addEventListener('mousemove', _cursorMoveCallback!);
  }

  /// PROD-2016: markers are rendered via the cluster source-layer
  /// path — venue/event pins on `heyl-pins` (clustered), the user-
  /// location dot on `heyl-user` (unclustered). The legacy DOM-
  /// overlay implementation lived here; deleted now that every
  /// consumer uses the cluster path.
  void _renderMarkers() {
    if (!_mapLoaded) return;
    _updateClusterSource();
    _applySymbolZOrder();
    _updateUserLocationSource();
    // DEBUG-only: keep the search-area overlay in sync (no-op when off).
    _syncDebugSearchArea();
    // PROD-3109: draw the picker boundary overlay if one is set (no-op else).
    _syncBoundaryOverlay();
    _syncHoverOverlay(); // parity: re-populate the hover overlay after a re-render too
  }

  /// PROD-3004: the flat-pool tie-break gate — the ONLY thing that varies with
  /// the pool. Both sort keys are defined statically on their layers (see the
  /// `addLayer` calls); this flips `symbol-z-order` between `auto` (scores vary →
  /// the keys drive caption priority + icon z-order) and `viewport-y` (flat pool →
  /// Mapbox ignores the keys; icons get true viewport-Y depth, captions fall back
  /// to source order). See [mapSymbolZOrder] for why `viewport-y` masks the key.
  ///
  /// Native runs the identical toggle, which is the whole point: this used to be
  /// web-only "set the key / unset the key" gating that native couldn't reproduce
  /// (its SDK can't unset a layout prop), so flat pools diverged.
  ///
  /// Runs on every marker update, so it tracks whatever the latest fetch returned.
  /// The layer definitions carry the correct INITIAL value too — the source is
  /// installed with real features, so waiting for the first `_renderMarkers` would
  /// leave a frame painted in the wrong order.
  void _applySymbolZOrder() {
    final map = _map;
    if (map == null || !_clusterLayersInstalled || !widget.categoryIcons) {
      return;
    }
    final zOrder = mapSymbolZOrder(widget.markers);
    for (final layerId in <String>[
      _unclusteredIconLayerId,
      // PROD-3828: only when the caption layer was actually added.
      if (widget.showPinCaptions) _unclusteredCaptionLayerId,
    ]) {
      try {
        // GL JS no-ops an unchanged setLayoutProperty, so no guard needed here
        // (native does need one — it has no such check).
        map.setLayoutProperty(layerId, 'symbol-z-order', zOrder.toJS);
      } catch (_) {
        // Layer not ready / interop hiccup. The layer definition's initial
        // value stands; the next marker update re-applies.
      }
    }
  }

  /// PROD-2993: re-apply the caption `text-offset` so it tracks the pin's size
  /// when the results-highlight enlargement (`widget.captionSizeMul`) turns on or
  /// off. The layers are BORN with the right value (creation reads
  /// `widget.captionSizeMul`); this handles the later half-drawer open/close.
  /// A layout-property write only — it moves no camera, so unlike the camera
  /// tokens it can't re-enter Dart mid-layout. Mirror of native's twin.
  void _applyCaptionOffset() {
    final map = _map;
    if (map == null || !_clusterLayersInstalled || !widget.categoryIcons) {
      return;
    }
    final offset = MapPinIconTokens.captionOffsetExpression(
      sizeMul: widget.captionSizeMul,
      stops: _pinStops,
    ).jsify();
    // The lone-pin caption always; the stack's count-label caption only when the
    // custom-selection stack layout re-pointed it (else it isn't a right-side
    // caption). Both no-op on an unchanged value.
    final layerIds = <String>[
      // PROD-3828: only when the caption layer was actually added.
      if (widget.showPinCaptions) _unclusteredCaptionLayerId,
      if (widget.customSelection) _clusterCountLayerId,
    ];
    for (final layerId in layerIds) {
      try {
        map.setLayoutProperty(layerId, 'text-offset', offset);
      } catch (_) {
        // Layer not ready / interop hiccup. The layer definition's initial
        // value stands; the next captionSizeMul change re-applies.
      }
    }
  }

  /// PROD-2160: resize + re-apply the initial camera fit. Used by the
  /// 100/500 ms post-load retries — if Mapbox initialised against a
  /// zero-size container, resize() alone recovers viewport dimensions
  /// but leaves the camera at the bad initial layout (world view), so
  /// pins render but land off-screen.
  void _resizeAndRefitIfNeeded() {
    if (!mounted || _container == null || _map == null || !_mapLoaded) {
      return;
    }
    _map!.resize();
    if (widget.boundsConfig?.hasBbox == true) {
      _fitToBbox();
    } else if (widget.fitMarkers && widget.markers.isNotEmpty) {
      _fitToMarkers();
    }
    _map!.triggerRepaint();
  }

  /// Fit the camera to an explicit lat/lng bbox passed via
  /// [MapBoundsConfig.north]/[south]/[east]/[west]. Used by the /lists
  /// hub to fit the selected city regardless of where markers land.
  void _fitToBbox() {
    final config = widget.boundsConfig;
    if (config == null) return;
    _fitToBboxConfig(config);
  }

  /// req3: fit an explicit [MapBoundsConfig] (used by the imperative recenter
  /// step, which passes [MapboxMapPlatform.fitBoundsOverride] instead of
  /// [boundsConfig]).
  void _fitToBboxConfig(MapBoundsConfig config) {
    if (_map == null || !config.hasBbox) return;

    // createBoundsFromCoordinates expects SW + NE corners as [lng, lat].
    final bounds = createBoundsFromCoordinates([
      [config.west!, config.south!],
      [config.east!, config.north!],
    ]);

    final options = createFitBoundsOptions(
      padding: config.padding,
      paddingTop: config.paddingTop,
      paddingBottom: config.paddingBottom,
      paddingLeft: config.paddingLeft,
      paddingRight: config.paddingRight,
      maxZoom: config.maxZoom,
      duration: config.duration,
    );

    _map!.fitBounds(bounds, options);
  }

  void _fitToMarkers() {
    if (_map == null || widget.markers.isEmpty) return;

    // PROD-1978: user-location dots don't count toward the fit area —
    // the user could be anywhere, and including their dot would skew
    // the camera away from the actual list pins. Filter to the
    // "placed" markers (venues, events, etc.) for the bbox math.
    final placed = widget.markers
        .where((m) => m.type != MapMarkerType.userLocation)
        .toList();
    if (placed.isEmpty) return;

    // PROD-1978 fold-in (PR #432 punch list): short-circuit to easeTo
    // for ≤1 unique point or zero-area bounds. Mapbox's `fitBounds`
    // throws "Map cannot fit within canvas..." on a degenerate bbox and
    // skips the camera move — under heavy parent rebuilds this fires
    // hundreds of times per second. easeTo with an explicit zoom is
    // always well-defined.
    final config = widget.boundsConfig ?? const MapBoundsConfig();
    final uniqueCoords = <String>{};
    for (final m in placed) {
      // Round to 6 decimal places (~11 cm) to dedupe near-identical
      // points without colliding distinct ones.
      uniqueCoords.add(
        '${m.lng.toStringAsFixed(6)},${m.lat.toStringAsFixed(6)}',
      );
    }
    if (uniqueCoords.length <= 1) {
      final m = placed.first;
      _map!.easeTo(
        createEaseToOptions(
          lng: m.lng,
          lat: m.lat,
          zoom: config.maxZoom ?? 14,
          duration: config.duration,
        ),
      );
      return;
    }

    final coordinates = placed.map((m) => [m.lng, m.lat]).toList();

    final bounds = createBoundsFromCoordinates(coordinates);

    final options = createFitBoundsOptions(
      padding: config.padding,
      paddingTop: config.paddingTop,
      paddingBottom: config.paddingBottom,
      paddingLeft: config.paddingLeft,
      paddingRight: config.paddingRight,
      maxZoom: config.maxZoom,
      duration: config.duration,
    );

    _map!.fitBounds(bounds, options);
  }

  // Known behavior (Chrome desktop, Feb 2025): map visually updates when
  // the browser tab regains focus or the user clicks on the page, not on
  // every GPS poll tick. This is because Flutter's HtmlElementView only
  // composites a new frame on user interaction or visibility-change events.
  // triggerRepaint() mitigates this but cannot force a compositor
  // pass on its own. Native (iOS/Android) behavior is untested for GPS
  // spoofing but is expected to update on each widget rebuild.
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

    if (!_mapLoaded || _map == null) return;

    // req3: imperative recenter "fit both" — a token bump means fit these bounds
    // now and STOP: the recenter press only changes camera props, and the later
    // center-ease branch would otherwise immediately override the bbox fit
    // (fit-both clears the shell's _focusOverride, flipping the effective centre).
    if (widget.fitBoundsToken != oldWidget.fitBoundsToken &&
        widget.fitBoundsOverride?.hasBbox == true) {
      _fitToBboxConfig(widget.fitBoundsOverride!);
      return;
    }

    final markersChanged =
        widget.markers.length != oldWidget.markers.length ||
        !_areMarkersEqual(widget.markers, oldWidget.markers);

    // PROD-2016: when the shell flips the selected marker, the
    // GeoJSON feature properties need to update so the `case`
    // expression on `circle-radius` picks the new selection.
    // PROD-2205: same for the multi-pin set (zine item-page paging
    // changes which subset is highlighted yellow).
    final selectionChanged =
        widget.selectedMarkerId != oldWidget.selectedMarkerId ||
        !setEquals(widget.selectedMarkerIds, oldWidget.selectedMarkerIds);

    final centerChanged =
        widget.centerLat != oldWidget.centerLat ||
        widget.centerLng != oldWidget.centerLng;

    // PROD-1978: a fit-all button tap doesn't change the markers — it
    // only flips the parent's `_shouldFitMarkers` state, which in turn
    // flips `widget.fitMarkers` from false → true. The previous
    // implementation gated fit-to-markers on `markersChanged` and so
    // never re-fit on those button taps; the easeTo branch below ran
    // instead and flew the camera to `items.first.lat/lng` at zoom 12
    // (looked like fit-to-Lisbon for any list whose first item is in
    // Lisbon — symptom you saw on testeeee-gigante-do-ja). Treat the
    // false→true transition of `fitMarkers` as another trigger.
    final fitMarkersTurnedOn = widget.fitMarkers && !oldWidget.fitMarkers;

    // PROD-1978 follow-up: when the user has manually dragged or
    // zoomed the canvas, `widget.fitMarkers` stays `true` and the
    // edge above never re-fires on a subsequent fit-all click —
    // `_shouldFitMarkers` was already `true`, so the rebuild doesn't
    // change the prop. A monotonic token bumped on every fit-all
    // press gives an unambiguous "re-fit now" signal regardless of
    // declarative state.
    final tokenBumped = widget.fitToMarkersToken != oldWidget.fitToMarkersToken;

    if (markersChanged || selectionChanged) {
      _renderMarkers();
    }

    // Viewport-gated user dot (req2): re-sync the dedicated user-location source
    // whenever the picker toggles the dot point, independent of the markers list.
    if (widget.userDotLatLng != oldWidget.userDotLatLng) {
      _updateUserLocationSource();
    }

    // The picker's center-of-search pin moves as the user taps / pans; re-sync
    // its dedicated source whenever the point changes. `_installPickerPinLayer`
    // self-guards (lazy install on the first non-null point); the update then
    // pushes or clears it.
    if (widget.pickerPinLatLng != oldWidget.pickerPinLatLng) {
      _installPickerPinLayer();
      _updatePickerPinSource();
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

    // DEBUG-only: the search-area overlay changes independently of markers
    // (toggle on/off, or a new committed radius/viewport on settle). Reconcile
    // it whenever the value changes even if the marker set didn't.
    if (widget.debugSearchArea != oldWidget.debugSearchArea) {
      _syncDebugSearchArea();
    }

    // PROD-3109: redraw the picker boundary when the polygon or fallback point
    // changes (a new selection, or a clear).
    if (!identical(
          widget.highlightBoundaryGeoJson,
          oldWidget.highlightBoundaryGeoJson,
        ) ||
        widget.highlightPoint != oldWidget.highlightPoint ||
        widget.highlightRadiusMeters != oldWidget.highlightRadiusMeters) {
      _syncBoundaryOverlay();
    }

    // PROD-3109: redraw the hover boundary when it changes.
    if (!identical(
      widget.hoverBoundaryGeoJson,
      oldWidget.hoverBoundaryGeoJson,
    )) {
      _syncHoverOverlay();
    }

    // Picker drill-down: redraw the child polygons when the active city's
    // children arrive or clear.
    if (!identical(
      widget.childBoundariesGeoJson,
      oldWidget.childBoundariesGeoJson,
    )) {
      _syncChildrenOverlay();
    }

    // PROD-2671 (Map page): re-apply camera padding when the chrome insets
    // change — the bottom drawer peek publishes just after load, and grows when
    // a filter panel opens. Suppressed internally so it doesn't trigger a
    // refetch (a padding shift is not a user pan). Deferred until the opening
    // zoom-in settle has finished (`_openSettled`) so a mid-ease `setPadding`
    // jump can't disrupt that animation — the post-settle re-apply in
    // `_startOpenSettle` catches any inset that arrived during the ease.
    if ((widget.viewportPaddingTop != oldWidget.viewportPaddingTop ||
            widget.viewportPaddingBottom != oldWidget.viewportPaddingBottom) &&
        (!widget.customSelection || _openSettled)) {
      _applyViewportPadding();
    }

    // React to bbox changes (e.g. the /lists hub user picks a new city).
    final oldBbox = oldWidget.boundsConfig;
    final newBbox = widget.boundsConfig;
    final bboxChanged =
        newBbox?.hasBbox == true &&
        (oldBbox?.north != newBbox?.north ||
            oldBbox?.south != newBbox?.south ||
            oldBbox?.east != newBbox?.east ||
            oldBbox?.west != newBbox?.west);

    // PROD-2042 Wave 2: my-location button bumps `centerToToken` so
    // we ease to the new center even when the prop value hasn't
    // changed (after the initial fit-to-markers, the prop may
    // already equal the override target). Handled FIRST so token-
    // bumped easeTo's win over the declarative fit branch below
    // when the shell flipped `fitMarkers` off in the same frame.
    final centerTokenBumped = widget.centerToToken != oldWidget.centerToToken;

    // fitBounds and easeTo are mutually exclusive — avoid animation race
    if (centerTokenBumped &&
        widget.centerLat != null &&
        widget.centerLng != null) {
      _map!.easeTo(
        createEaseToOptions(
          lng: widget.centerLng!,
          lat: widget.centerLat!,
          zoom: widget.zoom,
          // PROD-3003: shared recenter duration (explicit — native mirrors it).
          duration: kMapRecenterEaseMs,
        ),
      );
    } else if (newBbox?.hasBbox == true &&
        (bboxChanged || markersChanged || tokenBumped)) {
      _fitToBbox();
    } else if (widget.markers.isNotEmpty &&
        ((widget.fitMarkers && (markersChanged || fitMarkersTurnedOn)) ||
            tokenBumped)) {
      // PROD-2042 Wave 2: `fitToMarkersToken` is an imperative re-fit
      // request — honour it even when the declarative `fitMarkers`
      // prop is false (e.g. modal pinned a single card; tapping
      // fit-all should still re-frame to ALL pins, not stay zoomed
      // on the selected one).
      _fitToMarkers();
    } else if (centerChanged &&
        widget.centerLat != null &&
        widget.centerLng != null) {
      _map!.easeTo(
        createEaseToOptions(
          lng: widget.centerLng!,
          lat: widget.centerLat!,
          zoom: widget.zoom,
          // PROD-3003: shared recenter duration (explicit — native mirrors it).
          duration: kMapRecenterEaseMs,
        ),
      );
    }

    // PROD-1978 Phase 4 fix: Mapbox bakes the `interactive` option at
    // `new mapboxgl.Map(...)` time, so widget-prop changes don't reach
    // its gesture handlers. When `widget.interactive` flips (e.g. the
    // static-toggle chip activates), we have to call enable()/disable()
    // on each handler sub-object directly.
    if (widget.interactive != oldWidget.interactive) {
      _applyInteractiveState(widget.interactive);
    }

    // Force Mapbox to render a new frame so DOM marker changes
    // and easeTo animations become visible through HtmlElementView
    if (markersChanged || centerChanged) {
      _map!.triggerRepaint();
    }
  }

  /// Apply the [interactive] flag to Mapbox's gesture handlers in-place.
  /// `interactive: true` enables pan + scroll-zoom + touch-zoom-rotate
  /// (and restores the default grab cursor on the canvas); `false`
  /// disables them and forces a default cursor so swipes/wheels on the
  /// canvas don't `preventDefault()` and the host scroll view can
  /// claim the gesture. Click handlers stay attached either way (we
  /// keep Mapbox's top-level `interactive: true` always — see
  /// `_initializeMap`).
  void _applyInteractiveState(bool interactive) {
    final map = _map;
    if (map == null) return;
    try {
      if (interactive) {
        map.scrollZoom.enable();
        map.dragPan.enable();
        map.touchZoomRotate.enable();
      } else {
        map.scrollZoom.disable();
        map.dragPan.disable();
        map.touchZoomRotate.disable();
        // doubleClickZoom / boxZoom / dragRotate are off at init and
        // stay off — no need to touch them here.
      }
    } catch (e) {
      debugPrint('[MapboxMapPlatform] _applyInteractiveState failed: $e');
    }
    // PROD-1978 Phase 4: also flip the canvas cursor. With our always-on
    // `interactive: true` at the map level, Mapbox keeps the
    // `mapboxgl-interactive` class on the canvas container (cursor:
    // grab). In static mode we want the cursor to read as "not
    // draggable" — force `cursor: default` via an inline style with
    // `!important` so it wins over Mapbox's stylesheet.
    try {
      final canvasContainer =
          _container?.querySelector('.mapboxgl-canvas-container')
              as web.HTMLElement?;
      if (canvasContainer != null) {
        if (interactive) {
          canvasContainer.style.removeProperty('cursor');
        } else {
          canvasContainer.style.setProperty('cursor', 'default', 'important');
        }
      }
    } catch (_) {
      // Cursor override is best-effort; failure here doesn't affect
      // functionality, just visual feedback.
    }
  }

  bool _areMarkersEqual(List<MapMarker> a, List<MapMarker> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ============================================================
  // PROD-1978: clustered source-layer path
  // ============================================================
  //
  // Active when `widget.cluster == true`. Replaces the per-pin DOM
  // overlay with a single Mapbox GeoJsonSource (cluster:true) + three
  // style layers (cluster bubble, cluster count, unclustered pin) + a
  // top-most SymbolLayer for letter labels. All pin rendering happens
  // on the WebGL canvas — gestures don't bleed through to Flutter
  // overlays, and pin counts scale because we're not creating one
  // DOM element per pin.

  // JSFunction refs kept so dispose() can detach the listeners cleanly.
  JSFunction? _clusterClickCb;
  JSFunction? _unclusteredClickCb;
  // PROD-2016: map-wide click (NOT layer-scoped) — fires for every
  // click on the canvas including non-pin areas. We query rendered
  // features at the click point to distinguish "tap outside" from
  // "tap on a pin/cluster (handled separately above)".
  JSFunction? _mapWideClickCb;
  JSFunction? _hoverEnterCb;
  JSFunction? _hoverLeaveCb;
  // PROD-2016: unclustered-pin hover handlers (open the tooltip).
  // Separate from the cluster-bubble handlers (cursor only).
  JSFunction? _unclusteredHoverEnterCb;
  JSFunction? _unclusteredHoverLeaveCb;
  // PROD-3109: map-wide hover — fires onMapHoverLatLng while the camera is still.
  JSFunction? _moveStartCb;
  JSFunction? _moveEndCb;
  JSFunction? _hoverMoveCb;
  JSFunction? _hoverOutCb;

  /// True once the GeoJSON source + layers have been added to the map.
  /// Guards against double-add when `_onMapLoaded` fires alongside a
  /// `style.load` (theme switch).
  bool _clusterLayersInstalled = false;

  // ── Opening zoom-in settle (parked pins-on-open bug) ──────────────────
  //
  // A STATIC map open caused two Map-page bugs:
  //   1. The browser never composites the freshly-rendered WebGL pins until
  //      real rAF render activity happens (a user pan / a camera animation).
  //      Every one-shot nudge failed (Flutter frame, slot inset, triggerRepaint,
  //      resize() — which also CLEARS the buffer).
  //   2. The seeded open fetched a broad radius, then the first camera settle
  //      upgraded the request v1→v2 with the real viewport — a visible SWAP from
  //      the wide result set to the zoomed-in one.
  //
  // Fix (Map page only): the map is BORN zoomed out (birth = target −
  // [kMapOpenSettleZoomDelta], see `_initializeMap`). On the first `idle` we:
  //   a. capture the EXACT target-zoom viewport with a synchronous
  //      setZoom(target)→getBounds→setZoom(birth) bounce (no paint between, so
  //      no flicker) and emit it as ONE settle — so the FIRST /map/pins fetch is
  //      already the zoomed-in (v2) query. No v1→v2 swap.
  //   b. `easeTo` the target zoom over [kMapOpenSettleMs]. The real animation's
  //      continuous frames composite the map (and warm the platform view).
  //   c. keep the pins HIDDEN (`_openSettled == false`) through the whole zoom
  //      so no intermediate set flashes, then reveal the single final set after
  //      the ease settles (the warm view composites it). The user-location dot
  //      (separate source) stays visible throughout.
  // Move callbacks are suppressed during the ease so it isn't read as a user pan.

  // PROD-2999: the settle constants (`kMapOpenSettleZoomDelta`,
  // `kMapOpenSettleMs`) are SHARED with the native renderer — they live in
  // `map_marker_model.dart` so the two platforms can't drift.

  // PROD-2671: the search-rect inward margin is shared with the native impl —
  // see `kMapSearchAreaMarginFraction` in `map_marker_model.dart`.

  /// Set once the opening settle has run (fires exactly once per map).
  bool _didOpenSettle = false;

  /// Armed once the map has loaded; the first `idle` starts the opening settle.
  bool _awaitingOpenEase = false;

  /// False until the opening settle finishes — pins stay hidden until then so a
  /// single final set is revealed (no mid-zoom swap). Non-Map surfaces leave it
  /// effectively true (the hide is gated on `customSelection`).
  bool _openSettled = false;

  /// Mapbox `idle` listener ref (Map page only) so dispose() can detach it.
  JSFunction? _compositeIdleCb;

  // ── Opening pin-reveal animation (Map page) ───────────────────────────
  //
  // When the pins are revealed (after the zoom-in settle), each pin fades +
  // scales up + does a small lift ("jump"), each starting at a RANDOM moment
  // within the stagger window so pins pop up in no particular order. Driven by a
  // per-frame `setData` loop that writes `anim_o` / `anim_s` / `anim_off` onto
  // each feature; the icon layer's expressions read them (see `revealIcon*` in
  // `_installClusterSourceAndLayers`). Tuned live in `pin-reveal-mockup.html`.
  // PROD-3000: the tuning constants + curves are shared cross-renderer tokens
  // in `map_marker_model.dart` (`kMapReveal*`, `mapReveal{Opacity,Scale,LiftPx}`)
  // — hoisted from this file's former private statics so native can't drift.
  Timer? _revealTimer;

  /// Pin ids currently rendered (individual pins only). The baseline the
  /// diff-animate compares each new render against — new ids animate in, ids
  /// that persist stay put.
  Set<String> _shownPinIds = <String>{};

  /// Animating pins → the clock ms at which each one's animation starts. Present
  /// only while a pin is mid-reveal; pruned as they finish / leave.
  final Map<String, int> _pinAppearAt = <String, int>{};

  /// Monotonic clock shared by all pin reveals (so overlapping batches align).
  final Stopwatch _animClock = Stopwatch()..start();
  final math.Random _rng = math.Random();

  /// Light haptic as each pin touches down. Web has no haptics, so this is a
  /// no-op here — it's wired anyway (and the native loop's hook sits at the
  /// exact same line) so the two renderers can't drift. See
  /// [MapPinLandingHaptics].
  final MapPinLandingHaptics _landingHaptics = MapPinLandingHaptics();

  /// True while the camera is mid-move (user pan/zoom or a programmatic ease).
  /// New pins that appear while moving are baselined but NOT animated — they
  /// slide in with the map; the next settle animates the refetch's new pins.
  bool _cameraMoving = false;
  JSFunction? _moveStartAnimCb;
  JSFunction? _moveEndAnimCb;

  /// On the first `idle` after load: prefetch the target-zoom viewport, then
  /// ease from the zoomed-out birth camera to the target zoom, revealing the
  /// pins once it settles.
  void _startOpenSettle() {
    if (!_awaitingOpenEase || _didOpenSettle || !mounted || _map == null) {
      return;
    }
    _didOpenSettle = true;
    _awaitingOpenEase = false;
    final targetZoom = widget.zoom;

    // Suppress the map's own move/moveend callbacks for the whole sequence (the
    // setZoom bounce below AND the ease) so neither is read as a user pan (which
    // would cancel the in-flight fetch and set `_userPanned`). Our own direct
    // `widget.onCameraIdle` call below is NOT gated by this flag, so the up-front
    // query still fires.
    _suppressMoveCallback = true;

    // (a) Capture the EXACT target-zoom viewport without a visible flicker:
    // setZoom is synchronous, so bounce to the target zoom, read its bounds,
    // and bounce back — all in one call stack, before any frame paints. Emit it
    // as a settle so the first fetch is already the zoomed-in (v2) query.
    MapCameraState? targetView;
    try {
      final birthZoom = _map!.getZoom().toDouble();
      _map!.setZoom(targetZoom);
      // Read the VISIBLE-rect (inset-aware) camera at the target zoom so the
      // up-front query is already the zoomed-in, chrome-trimmed viewport.
      targetView = _readCameraState();
      _map!.setZoom(birthZoom);
    } catch (_) {
      targetView = null;
    }
    if (targetView != null) widget.onCameraIdle?.call(targetView);

    // PROD-4104: reveal on the ease's REAL completion. Registered before the
    // ease is issued so the `moveend` it emits cannot be missed. `easeTo` starts
    // the animation synchronously on web, so — unlike native — there is no
    // dispatch race to guard against here.
    _openSettleMoveEndCb = (() => _completeOpenSettle()).toJS;
    _map!.on('moveend', _openSettleMoveEndCb!);

    // (b) Ease to the target zoom (move callbacks stay suppressed from above).
    _map!.easeTo(
      createEaseToOptions(
        lng: widget.centerLng ?? _defaultLng,
        lat: widget.centerLat ?? _defaultLat,
        zoom: targetZoom,
        duration: kMapOpenSettleMs,
      ),
    );

    // (c) Fallback only. If the `moveend` above never arrives — a failed ease,
    // a map torn down mid-animation, a browser that swallows the event — the
    // pins must still be revealed rather than left hidden forever. Kept at the
    // old fixed value so the worst case of PROD-4104 is exactly the previous
    // behaviour. [_completeOpenSettle] is idempotent, so whichever fires first
    // wins and the other is a no-op.
    Future.delayed(
      const Duration(milliseconds: kMapOpenSettleMs + 150),
      _completeOpenSettle,
    );
  }

  /// PROD-4104 — the opening animation has settled: stop suppressing, apply the
  /// deferred chrome inset, and reveal the pins.
  ///
  /// Idempotent, and that is the whole contract: it is raced by the real
  /// `moveend` and by the fallback timer, and exactly one of them may do the
  /// work. The order of the four steps below is unchanged from the timer-only
  /// version — `_applyViewportPadding` saves/restores `_suppressMoveCallback`
  /// itself, so releasing suppression before it is still correct.
  void _completeOpenSettle() {
    if (!mounted || _openSettled) return;
    _openSettled = true;
    if (_openSettleMoveEndCb != null) {
      _map?.off('moveend', _openSettleMoveEndCb!);
      _openSettleMoveEndCb = null;
    }
    _suppressMoveCallback = false;
    // Apply any chrome inset that arrived DURING the ease (deferred by the
    // didUpdateWidget guard) now that the opening animation is done.
    _applyViewportPadding();
    // First real render: every pin is "new" vs the empty baseline, so the
    // diff-animate path animates them all (the opening reveal).
    _renderMarkers();
    // PROD-3124: dots were held empty through the opening reveal (same gate
    // as the pins) — release them now; their fade delay keeps them after
    // the pins.
    _syncDotHints();
  }

  /// Render the Map-page pins, animating any pin whose id is NEW since the last
  /// render (a fade + scale + lift) while pins that persist across requests stay
  /// put. Animation only arms while the camera is SETTLED — during a pan, pins
  /// just slide in with the map (no popping); the next settle animates whatever
  /// the refetch introduced. Degrades to a plain render on any error.
  void _renderPinsDiffAnimate(MapboxGeoJsonSource source) {
    try {
      // Current on-screen pin ids (individual pins only — bubbles never animate).
      final currentIds = <String>{};
      for (final m in widget.markers) {
        if (m.type == MapMarkerType.userLocation) continue;
        if (m.overflowCount != null) continue;
        currentIds.add(m.id);
      }
      // Arm a random start (within the stagger window) for each genuinely-new
      // pin — but only while settled; mid-pan additions are just baselined so
      // they don't pop when the pan ends.
      if (!_cameraMoving) {
        final now = _animClock.elapsedMilliseconds;
        for (final id in currentIds) {
          if (!_shownPinIds.contains(id)) {
            _pinAppearAt[id] =
                now + (_rng.nextDouble() * kMapRevealStaggerMs).round();
          }
        }
      }
      _shownPinIds = currentIds;
      _pinAppearAt.removeWhere((id, _) => !currentIds.contains(id));

      // A loop is already running → it picks up the updated appear-map + live
      // markers on its next frame; don't start a second one.
      if (_revealTimer?.isActive ?? false) return;
      if (_pinAppearAt.isEmpty) {
        // Nothing to animate → plain render (still reflects moves / updates).
        source.setData(
          _markersAsFeatureCollectionMap(widget.markers).jsify() as JSObject,
        );
        return;
      }
      _startAnimLoop();
    } catch (_) {
      _revealTimer?.cancel();
      _pinAppearAt.clear();
      source.setData(
        _markersAsFeatureCollectionMap(widget.markers).jsify() as JSObject,
      );
    }
  }

  /// The per-frame `setData` loop: writes `anim_*` onto pins currently in
  /// [_pinAppearAt], leaves everything else settled, and stops once every
  /// animation has finished. Reads live [widget.markers] each frame so pins
  /// added/removed mid-animation are handled.
  void _startAnimLoop() {
    _revealTimer?.cancel();
    void frame() {
      final map = _map;
      final source = map?.getSource(_clusterSourceId);
      if (!mounted || map == null || source == null) {
        _revealTimer?.cancel();
        return;
      }
      final clock = _animClock.elapsedMilliseconds;
      // Pins whose animation ended on this frame: prune them (a settled pin
      // falls back to the layer's coalesce defaults) — that moment is the
      // touchdown the haptic marks.
      final landed = <String>[
        for (final e in _pinAppearAt.entries)
          if (clock >= e.value + kMapRevealFadeMs) e.key,
      ];
      for (final id in landed) {
        _pinAppearAt.remove(id);
        _landingHaptics.pinLanded(clock);
      }
      // icon-offset is multiplied by icon-size, so convert the px we want into
      // icon-size units at the current zoom.
      final baseIconSize = _iconBaseSizeAtZoom(map.getZoom().toDouble());
      final fc = _markersAsFeatureCollectionMap(widget.markers);
      final feats = (fc['features'] as List).cast<Map<String, dynamic>>();
      for (final feat in feats) {
        final props = feat['properties'] as Map<String, dynamic>;
        final id = props['id'] as String?;
        final start = id == null ? null : _pinAppearAt[id];
        if (start == null) continue; // settled (coalesce defaults handle it)
        final local = ((clock - start) / kMapRevealFadeMs).clamp(0.0, 1.0);
        final s = mapRevealScale(local);
        props['anim_o'] = mapRevealOpacity(local);
        props['anim_s'] = s;
        props['anim_off'] = <double>[
          0,
          mapRevealLiftPx(local) / (baseIconSize * (s < 0.05 ? 0.05 : s)),
        ];
      }
      source.setData(fc.jsify() as JSObject);
      if (_pinAppearAt.isEmpty) {
        _revealTimer?.cancel(); // that frame was settled
      }
    }

    frame();
    _revealTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => frame(),
    );
  }

  /// Icon-size at [z] (matches the layer's zoom interpolation over the
  /// [MapPinIconTokens] stops; clamped outside the range).
  double _iconBaseSizeAtZoom(double z) =>
      MapPinIconTokens.iconSizeForZoom(z, stops: _pinStops);

  /// A resolved tap on a custom-selection `+k` overflow bubble — shared by
  /// the (transparent) bubble-circle click handler and the bubble-caption
  /// path in the map-wide click handler.
  ///
  /// PROD-2671 cluster-focus: a TERMINAL bubble (co-located / unsplittable)
  /// does NOT zoom — it routes to the app so the shell can enter
  /// cluster-focus (fade the rest, scope the drawer to its members).
  /// PROD-2807: a splittable bubble zooms +2 toward its centre; move
  /// callbacks deliberately NOT suppressed — the ease's trailing `moveend`
  /// must fire settle-to-search so the pool refetches and the grid
  /// re-selects at the finer level, declustering the bubble.
  void _handleCustomSelectionBubbleTap(
    Map<Object?, Object?> props,
    double centerLng,
    double centerLat,
  ) {
    // Read `overflow_terminal` defensively (it crosses the interop channel
    // as a JSON-ish value); default false when absent.
    if (props['overflow_terminal'] == true) {
      final bubbleIdAny = props['id'];
      if (bubbleIdAny is String) {
        for (final m in widget.markers) {
          if (m.id == bubbleIdAny) {
            widget.onMarkerTap?.call(m, Offset.zero);
            return;
          }
        }
      }
      return;
    }
    final z = _map!.getZoom().toDouble();
    final targetZoom = z + 2.0 > 18.0 ? 18.0 : z + 2.0;
    _map!.easeTo(
      createEaseToOptions(
        lng: centerLng,
        lat: centerLat,
        zoom: targetZoom,
        duration: 400,
      ),
    );
  }

  /// PROD-3124: a resolved tap on a dot hint — report it to the consumer
  /// (which promotes the item to a pin) and fly to the dot at street zoom.
  /// Move callbacks deliberately NOT suppressed (same rule as the splittable
  /// bubble zoom): the ease's trailing settle refetches the pool, and the
  /// promoted item then renders as a captioned pin.
  void _handleDotHintTap(String id, String entity, double lat, double lng) {
    widget.onDotHintTap?.call(id, entity, lat, lng);
    _map!.easeTo(
      createEaseToOptions(
        lng: lng,
        lat: lat,
        zoom: kDotHintFocusZoom,
        duration: 500,
      ),
    );
  }

  /// Resolve the TOPMOST feature of a `queryRenderedFeatures` result back to
  /// a live [MapMarker] via its stamped `id` property. Null when the query
  /// hit nothing (or the id doesn't match a current marker).
  MapMarker? _markerFromQuery(JSArray featuresJs) {
    if (featuresJs.length == 0) return null;
    final feature = featuresJs.toDart.first as MapboxFeature;
    final propsAny = feature.properties.dartify();
    if (propsAny is! Map) return null;
    final markerId = propsAny.cast<Object?, Object?>()['id'];
    if (markerId is! String) return null;
    for (final m in widget.markers) {
      if (m.id == markerId) return m;
    }
    return null;
  }

  /// A resolved tap on an unclustered pin — shared by the pin (icon) and
  /// caption hit paths (a caption tap must behave exactly like a tap on its
  /// pin).
  void _handleUnclusteredMarkerTap(MapMarker match) {
    // PROD-2671: Map page (no tooltip) → fire onMarkerTap IMMEDIATELY and
    // do NOT ease the camera. The ease + deferred fire below are only for
    // tooltip placement; on the Map page they'd just move the map. The
    // pixel is unused when there's no tooltip.
    if (!widget.centerOnMarkerTap) {
      widget.onMarkerTap?.call(match, Offset.zero);
      return;
    }
    // PROD-2046 Option A: ease the map so the tapped pin lands at
    // a CONSISTENT screen position — (viewport.width / 2,
    // viewport.height * `_pinTargetYFraction`). The tooltip then
    // renders at that fixed location for every pin, every time.
    // Mapbox's `easeTo({center, offset})` places the supplied
    // lat/lng at `(mapCenter + offset)` in screen pixels.
    final container = _map!.getContainer();
    final viewportW = container.clientWidth.toDouble();
    final viewportH = container.clientHeight.toDouble();
    final pinTargetY = viewportH * _pinTargetYFraction;
    final easeOffsetY = pinTargetY - (viewportH / 2);

    // Cancel any prior pending tooltip-show — quick taps on
    // different pins should show only the latest one's tooltip.
    _pendingTooltipShow?.cancel();
    // PROD-2046: close the currently-open tooltip (if any) BEFORE
    // the ease starts so the user doesn't see the old card
    // floating in place while the map pans to the new pin. The
    // shell reopens the tooltip after the ease completes with the
    // new marker's content. No-op on first tap (no tooltip open).
    widget.onMapTapOutside?.call();
    _suppressMoveCallback = true;
    _map!.easeTo(
      <String, dynamic>{
            'center': <num>[match.lng, match.lat],
            'offset': <num>[0, easeOffsetY],
            'duration': _pinEaseDurationMs,
            'animate': true,
          }.jsify()
          as JSObject,
    );

    // PROD-2046 part 2: wait for the ease to finish before
    // surfacing the tooltip, so it never renders at a stale or
    // mid-animation position.
    final pixel = Offset(viewportW / 2, pinTargetY);
    _pendingTooltipShow = Timer(
      const Duration(milliseconds: _pinEaseDurationMs),
      () {
        _pendingTooltipShow = null;
        if (!mounted) return;
        // Show the tooltip first, then clear the suppress flag a
        // bit later — guards against Mapbox's trailing `moveend`
        // event closing the tooltip we just opened.
        widget.onMarkerTap?.call(match, pixel);
        Future.delayed(const Duration(milliseconds: _moveSuppressTailMs), () {
          if (mounted) _suppressMoveCallback = false;
        });
      },
    );
  }

  /// Register the GeoJSON source (with clustering) and the three
  /// style layers + the label layer. Idempotent — does nothing if
  /// already installed.
  void _installClusterSourceAndLayers() {
    if (_map == null || _clusterLayersInstalled) return;

    // PROD-3124: dot hints go in FIRST — Mapbox paints in layer-insertion
    // order, so installing before every pin layer below structurally
    // guarantees dots can never cover a pin, caption, or bubble.
    _installDotHintsLayer();

    // Map page: keep pins hidden until the opening zoom-in settle finishes —
    // gate the INITIAL source data too (not just later setData in
    // `_updateClusterSource`), else installing the source while pins already
    // exist paints them before the reveal. See `_startOpenSettle`.
    final hidePins = widget.customSelection && !_openSettled;
    final featureCollection = hidePins
        ? const <String, dynamic>{
            'type': 'FeatureCollection',
            'features': <dynamic>[],
          }
        : _markersAsFeatureCollectionMap(widget.markers);
    web.console.log(
      '[MapboxMapPlatform] Installing cluster source — features=${(featureCollection['features'] as List).length} hidden=$hidePins'
          .toJS,
    );

    // Build the entire source spec as pure Dart and jsify once at the
    // root. The previous shape (Dart Map containing an already-jsified
    // FeatureCollection) led to `data` being passed through as an
    // opaque JSObject reference inside the parent jsify pass — Mapbox
    // saw a non-GeoJSON value at `data` and silently skipped both the
    // cluster step and the unclustered-pin layer rendering.
    // PROD-2807: in custom-selection mode we compute the "clusters"
    // ourselves (the `+k` overflow bubbles are markers carrying
    // `overflowCount`), so Mapbox's built-in clustering is OFF and the
    // bubble layers key off our own `overflow_count` property. Otherwise
    // (every other consumer) Mapbox clusters natively via `point_count`.
    final bool nativeCluster = !widget.customSelection;
    final sourceSpec = <String, dynamic>{
      'type': 'geojson',
      'data': featureCollection,
      'cluster': nativeCluster,
      if (nativeCluster) ...<String, dynamic>{
        'clusterRadius': MapClusterTokens.sourceClusterRadius,
        'clusterMaxZoom': MapClusterTokens.sourceClusterMaxZoom,
        // PROD-1993: aggregate per-type counts inside each cluster so the
        // bubble color can reflect homogeneous vs mixed contents. `'+'`
        // sums the inner expression evaluated against every feature in
        // the cluster (1 if the feature matches the type, 0 otherwise).
        'clusterProperties': <String, dynamic>{
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
        },
      },
    };
    _map!.addSource(_clusterSourceId, sourceSpec.jsify() as JSObject);

    // The property that flags a "bubble" feature + carries its count. Native
    // clustering → Mapbox's `point_count`; custom selection → our stamped
    // `overflow_count`. Drives the bubble layers' filter, radius, and label.
    final String bubbleCountKey = widget.customSelection
        ? 'overflow_count'
        : 'point_count';

    // Cluster bubble color (PROD-1993): mirror the unclustered pin
    // colors when the cluster is homogeneous — pure-place → Soko Blue,
    // pure-event → Soko Green — and fall back to the neutral Soko Pink
    // for mixed clusters (or markers without a category).
    final clusterColorExpression = <dynamic>[
      'case',
      // Mixed cluster
      <dynamic>[
        'all',
        <dynamic>[
          '>',
          <dynamic>['get', 'event_count'],
          0,
        ],
        <dynamic>[
          '>',
          <dynamic>['get', 'place_count'],
          0,
        ],
      ],
      _hexFromColor(AppColors.mapClusterFill),
      // Pure events
      <dynamic>[
        '>',
        <dynamic>['get', 'event_count'],
        0,
      ],
      _hexFromColor(AppColors.mapPinEvent),
      // Pure places
      <dynamic>[
        '>',
        <dynamic>['get', 'place_count'],
        0,
      ],
      _hexFromColor(AppColors.mapPinVenue),
      // Untyped fallback (markers without category)
      _hexFromColor(AppColors.mapClusterFill),
    ];
    final clusterPaint = <String, dynamic>{
      'circle-color': clusterColorExpression,
      'circle-radius': [
        'step',
        ['get', bubbleCountKey],
        MapClusterTokens.bubbleRadiusSmall,
        MapClusterTokens.mediumAt,
        MapClusterTokens.bubbleRadiusMedium,
        MapClusterTokens.largeAt,
        MapClusterTokens.bubbleRadiusLarge,
      ],
      'circle-stroke-color': '#FFFFFF',
      'circle-stroke-width': 2,
    };
    _map!.addLayer(
      <String, dynamic>{
            'id': _clusterLayerId,
            'type': 'circle',
            'source': _clusterSourceId,
            'filter': ['has', bubbleCountKey],
            'paint': clusterPaint,
          }.jsify()
          as JSObject,
    );

    // Bubble count label: custom selection stamps a ready-made `+k`
    // string (`overflow_label`); native clustering uses Mapbox's built-in
    // `point_count_abbreviated` ("10k" etc.).
    final bubbleLabelExpr = widget.customSelection
        ? <dynamic>['get', 'overflow_label']
        : <dynamic>['get', 'point_count_abbreviated'];
    _map!.addLayer(
      <String, dynamic>{
            'id': _clusterCountLayerId,
            'type': 'symbol',
            'source': _clusterSourceId,
            'filter': ['has', bubbleCountKey],
            'layout': {
              'text-field': bubbleLabelExpr,
              'text-size': 12,
              'text-font': ['Open Sans Semibold', 'Arial Unicode MS Bold'],
            },
            'paint': {'text-color': _hexFromColor(AppColors.mapClusterText)},
          }.jsify()
          as JSObject,
    );

    // Unclustered pin — small filled circle, no label on top. Color
    // via match expression on `item_type` (event = green, place = blue,
    // PROD-1993). Border is Soko/Ink (not white) per the latest design call.
    _map!.addLayer(
      <String, dynamic>{
            'id': _unclusteredLayerId,
            'type': 'circle',
            'source': _clusterSourceId,
            'filter': [
              '!',
              ['has', bubbleCountKey],
            ],
            'paint': {
              // Semantic colour by item type. PROD-2205-followup
              // dropped the prior `case selected → mapPinSelected
              // (yellow)` wrapper — selection is now differentiated
              // by radius + stroke instead, so the event-green /
              // venue-blue signal stays visible on the focused pin.
              'circle-color': <Object>[
                'match',
                <Object>['get', 'item_type'],
                'event',
                _hexFromColor(AppColors.mapPinEvent),
                'place',
                _hexFromColor(AppColors.mapPinVenue),
                // Fall through to the per-feature `color` property if set
                // (consumers passing `MapMarker.color`), otherwise the
                // semantic default.
                <Object>[
                  'coalesce',
                  <Object>['get', 'color'],
                  _hexFromColor(AppColors.mapPinDefault),
                ],
              ],
              // PROD-2016 + PROD-2205-followup: enlarge the selected
              // pin via a `case` expression keyed on the per-feature
              // `selected` property. Values come from MapPinTokens so
              // they stay in sync with the native side.
              'circle-radius': <Object>[
                'case',
                <Object>[
                  'boolean',
                  <Object>['get', 'selected'],
                  false,
                ],
                MapPinTokens.selectedRadius,
                MapPinTokens.unselectedRadius,
              ],
              // PROD-2042 Wave 2: animate the radius change so the
              // selection visual feels intentional rather than a snap.
              'circle-radius-transition': <String, Object>{
                'duration': 150,
                'delay': 0,
              },
              // PROD-2205-followup r2: selected stroke is a per-
              // category mix of `0.7 · pin fill + 0.3 · sokoPink`
              // (pre-computed in AppColors). Softer than the prior
              // flat white, still high-contrast against the basemap,
              // and visually related to each pin's semantic fill.
              // The unselected default stays Soko/Ink for subtle
              // separation from the basemap.
              'circle-stroke-color': <Object>[
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
                  _hexFromColor(AppColors.mapPinEventSelectedStroke),
                  'place',
                  _hexFromColor(AppColors.mapPinVenueSelectedStroke),
                  // Legacy / per-feature colour fallback.
                  _hexFromColor(AppColors.mapPinDefaultSelectedStroke),
                ],
                _hexFromColor(AppColors.sokoInk),
              ],
              'circle-stroke-color-transition': <String, Object>{
                'duration': 150,
                'delay': 0,
              },
              // PROD-2205-followup: the stroke thickens on selection
              // from 0.5 → 3 px. Paired with the radius bump above
              // this is the primary "you are here" cue now that the
              // yellow fill is gone.
              'circle-stroke-width': <Object>[
                'case',
                <Object>[
                  'boolean',
                  <Object>['get', 'selected'],
                  false,
                ],
                MapPinTokens.selectedStrokeWidth,
                MapPinTokens.unselectedStrokeWidth,
              ],
              'circle-stroke-width-transition': <String, Object>{
                'duration': 150,
                'delay': 0,
              },
            },
            // PROD-2042 Wave 2: selected pin always renders on top of
            // overlapping unselected pins.
            'layout': <String, Object>{
              'circle-sort-key': <Object>[
                'case',
                <Object>[
                  'boolean',
                  <Object>['get', 'selected'],
                  false,
                ],
                1,
                0,
              ],
            },
          }.jsify()
          as JSObject,
    );

    // Note: the previous unclustered-label SymbolLayer ("A", "B", …) is
    // removed per the latest design — single pins are intentionally
    // unlabelled. Letters now live only on the bottom-drawer cards
    // (when those return), and on the future tap-to-detail sheet.

    // Click on a cluster → smoothly zoom to its expansion zoom.
    //
    // Mirrors the pattern in Mapbox's official cluster example:
    // re-query the features at the click point rather than trusting
    // `evt.features`. With the layer-scoped on() registration the
    // event SHOULD carry features for that layer, but a fresh
    // queryRenderedFeatures is robust against quirks in the dart:js
    // interop conversion path (which is where the earlier attempt
    // silently no-op'd).
    _clusterClickCb = ((JSAny evtAny) {
      // PROD-2016: cluster click works in static mode too — zoom-in
      // is a programmatic camera move, not a gesture, so it doesn't
      // imply "unlock". The gesture handlers stay disabled around it.
      // (PROD-1978 originally gated this on `widget.interactive`;
      // PROD-2016 retired that gate.)
      final evt = evtAny as MapboxMapMouseEvent;
      web.console.log('[cluster] cluster-layer click received'.toJS);
      final pointJs = evt.point as JSObject;
      // PROD-1978: pass `layers` as a pure-Dart list inside the
      // options Map and jsify once. Pre-jsifying the inner list and
      // nesting it triggers the same opaque-reference issue that
      // silently dropped the source data earlier in this phase.
      final queryOptions =
          <String, dynamic>{
                'layers': <String>[_clusterLayerId],
              }.jsify()
              as JSObject;
      final featuresJs = _map!.queryRenderedFeatures(pointJs, queryOptions);
      if (featuresJs.length == 0) {
        web.console.log('[cluster] no features at click point'.toJS);
        return;
      }
      final feature = featuresJs.toDart.first as MapboxFeature;
      final propsAny = feature.properties.dartify();
      if (propsAny is! Map) {
        web.console.log('[cluster] properties not a Map: $propsAny'.toJS);
        return;
      }
      final props = propsAny.cast<Object?, Object?>();

      // Pull the bubble/cluster centre from the feature geometry — needed by
      // both the custom-selection and native-cluster paths below.
      final geomAny = feature.geometry.dartify();
      if (geomAny is! Map) return;
      final geom = geomAny.cast<Object?, Object?>();
      final coords = geom['coordinates'];
      if (coords is! List || coords.length < 2) return;
      final centerLng = (coords[0] as num).toDouble();
      final centerLat = (coords[1] as num).toDouble();

      // Custom selection: terminal bubbles route to the app, splittable ones
      // zoom — shared with the bubble-CAPTION tap path in the map-wide click
      // handler (a caption tap must behave exactly like a bubble tap).
      if (widget.customSelection) {
        _handleCustomSelectionBubbleTap(props, centerLng, centerLat);
        return;
      }

      final clusterId = props['cluster_id'];
      if (clusterId is! num) {
        web.console.log('[cluster] missing cluster_id: $props'.toJS);
        return;
      }
      final source = _map?.getSource(_clusterSourceId);
      if (source == null) return;
      source.getClusterExpansionZoom(
        clusterId,
        ((JSAny? err, JSAny? zoomAny) {
          if (!mounted || _map == null) return;
          if (zoomAny == null) {
            web.console.log(
              '[cluster] getClusterExpansionZoom returned null'.toJS,
            );
            return;
          }
          final dart = zoomAny.dartify();
          if (dart is! num) {
            web.console.log('[cluster] expansion zoom not numeric: $dart'.toJS);
            return;
          }
          web.console.log(
            '[cluster] zooming to ${dart.toDouble()} at $centerLng,$centerLat'
                .toJS,
          );
          _map!.easeTo(
            createEaseToOptions(
              lng: centerLng,
              lat: centerLat,
              zoom: dart.toDouble(),
              duration: 400,
            ),
          );
        }).toJS,
      );
    }).toJS;
    _map!.onLayer('click', _clusterLayerId, _clusterClickCb!);

    // Click on an unclustered pin → resolve back to the underlying
    // MapMarker by id and fire `onMarkerTap`. Same queryRenderedFeatures
    // pattern as the cluster handler above for the same reason.
    //
    // NOT registered in categoryIcons mode (the Map page): there the circle
    // layer is a legacy invisible halo ~2× the rendered pin (r24, constant
    // screen px), so pin clicks resolve in the map-wide handler below
    // against the rendered ICON (+ margin) and the caption instead.
    if (!widget.categoryIcons) {
      _unclusteredClickCb = ((JSAny evtAny) {
        // PROD-2016: leaf taps work in static mode — they open the
        // tooltip without unlocking the map (handoff §
        // "Locked-map pin tap").
        final evt = evtAny as MapboxMapMouseEvent;
        final pointJs = evt.point as JSObject;
        final queryOptions =
            <String, dynamic>{
                  'layers': <String>[_unclusteredLayerId],
                }.jsify()
                as JSObject;
        final match = _markerFromQuery(
          _map!.queryRenderedFeatures(pointJs, queryOptions),
        );
        if (match != null) {
          _handleUnclusteredMarkerTap(match);
        }
      }).toJS;
      _map!.onLayer('click', _unclusteredLayerId, _unclusteredClickCb!);
    }

    // PROD-2016: map-wide click — fires for EVERY click on the
    // canvas.
    _mapWideClickCb = ((JSAny evtAny) {
      final evt = evtAny as MapboxMapMouseEvent;
      // PROD-3109: every canvas tap carries its geographic coordinate.
      final ll = evt.lngLat;
      widget.onMapTapLatLng?.call(ll.lat.toDouble(), ll.lng.toDouble());
      final pointJs = evt.point as JSObject;
      if (widget.categoryIcons) {
        // Map page: pin + caption clicks resolve HERE — one place decides
        // priority (bubble > pin icon > pin caption > bubble caption >
        // tap-outside), so a single
        // click can never double-fire.
        final clusterOptions =
            <String, dynamic>{
                  'layers': <String>[_clusterLayerId],
                }.jsify()
                as JSObject;
        if (_map!.queryRenderedFeatures(pointJs, clusterOptions).length > 0) {
          // The cluster layer-scoped handler consumes this click.
          return;
        }
        // The pin's tap target is its RENDERED icon dilated by
        // [MapPinIconTokens.pinHitMarginPx]: query a margin-sized box around
        // the click point against the icon layer, so the target tracks the
        // pin's on-screen size at every zoom (finger-forgiving, but no more
        // giant halo). Mirror of native's rendered-rectangle test
        // ([MapPinIconTokens.pinHitDistance]).
        const double margin = MapPinIconTokens.pinHitMarginPx;
        final x = evt.point.x.toDouble();
        final y = evt.point.y.toDouble();
        final boxJs =
            <List<double>>[
                  <double>[x - margin, y - margin],
                  <double>[x + margin, y + margin],
                ].jsify()
                as JSObject;
        final iconOptions =
            <String, dynamic>{
                  'layers': <String>[_unclusteredIconLayerId],
                }.jsify()
                as JSObject;
        final iconMatch = _markerFromQuery(
          _map!.queryRenderedFeatures(boxJs, iconOptions),
        );
        if (iconMatch != null) {
          _handleUnclusteredMarkerTap(iconMatch);
          return;
        }
        // Caption tap = pin tap (user feedback): the caption's rendered
        // text box is a target too — exact hit, no margin (the text block
        // is already large).
        //
        // PROD-3828: skipped when captions are off — the layer doesn't exist
        // then, and GL JS logs a "layer does not exist and cannot be queried"
        // error for every click on such a surface.
        if (widget.showPinCaptions) {
          final captionOptions =
              <String, dynamic>{
                    'layers': <String>[_unclusteredCaptionLayerId],
                  }.jsify()
                  as JSObject;
          final captionMatch = _markerFromQuery(
            _map!.queryRenderedFeatures(pointJs, captionOptions),
          );
          if (captionMatch != null) {
            _handleUnclusteredMarkerTap(captionMatch);
            return;
          }
        }
        // Bubble-caption tap = bubble tap: the "X venues / Y events" title
        // beside a `+k` stack (the re-pointed count layer) routes exactly
        // like tapping the bubble — terminal → cluster-focus, splittable →
        // zoom to split.
        final bubbleTitleOptions =
            <String, dynamic>{
                  'layers': <String>[_clusterCountLayerId],
                }.jsify()
                as JSObject;
        final bubbleFeatures = _map!.queryRenderedFeatures(
          pointJs,
          bubbleTitleOptions,
        );
        if (bubbleFeatures.length > 0) {
          final feature = bubbleFeatures.toDart.first as MapboxFeature;
          final propsAny = feature.properties.dartify();
          final geomAny = feature.geometry.dartify();
          if (propsAny is Map && geomAny is Map) {
            final coords = geomAny.cast<Object?, Object?>()['coordinates'];
            if (coords is List && coords.length >= 2) {
              _handleCustomSelectionBubbleTap(
                propsAny.cast<Object?, Object?>(),
                (coords[0] as num).toDouble(),
                (coords[1] as num).toDouble(),
              );
              return;
            }
          }
        }
        // PROD-3124: dot-hint tap — LOWEST priority (any pin/bubble/caption
        // hit above already returned). Same margin box as the pin icons so
        // the 10 px dot is finger-forgiving.
        final dotOptions =
            <String, dynamic>{
                  'layers': <String>[_dotHintsLayerId],
                }.jsify()
                as JSObject;
        final dotFeatures = _map!.queryRenderedFeatures(boxJs, dotOptions);
        if (dotFeatures.length > 0) {
          final feature = dotFeatures.toDart.first as MapboxFeature;
          final propsAny = feature.properties.dartify();
          final geomAny = feature.geometry.dartify();
          if (propsAny is Map && geomAny is Map) {
            final props = propsAny.cast<Object?, Object?>();
            final coords = geomAny.cast<Object?, Object?>()['coordinates'];
            final id = props['id'];
            final entity = props['entity'];
            if (id is String &&
                entity is String &&
                coords is List &&
                coords.length >= 2) {
              _handleDotHintTap(
                id,
                entity,
                (coords[1] as num).toDouble(),
                (coords[0] as num).toDouble(),
              );
              return;
            }
          }
        }
        widget.onMapTapOutside?.call();
        return;
      }
      // Layer-scoped handlers above also fire for pin/cluster hits; we
      // don't want to double-handle. Re-query features at the click point
      // and bail if any pin/cluster was hit. If nothing was hit → fire
      // `onMapTapOutside` so the shell can close any open tooltip.
      final queryOptions =
          <String, dynamic>{
                'layers': <String>[_clusterLayerId, _unclusteredLayerId],
              }.jsify()
              as JSObject;
      final featuresJs = _map!.queryRenderedFeatures(pointJs, queryOptions);
      if (featuresJs.length == 0) {
        widget.onMapTapOutside?.call();
      }
    }).toJS;
    _map!.on('click', _mapWideClickCb!);

    // PROD-3109 hover: suppress hover resolves while the camera is moving
    // (pan inertia, wheel/trackpad zoom, programmatic ease/fit).
    _moveStartCb = ((JSAny _) {
      _cameraMoving = true;
    }).toJS;
    _moveEndCb = ((JSAny _) {
      _cameraMoving = false;
    }).toJS;
    _map!.on('movestart', _moveStartCb!);
    _map!.on('moveend', _moveEndCb!);

    if (widget.onMapHoverLatLng != null) {
      _hoverMoveCb = ((JSAny evtAny) {
        if (_cameraMoving) return;
        final evt = evtAny as MapboxMapMouseEvent;
        final ll = evt.lngLat;
        widget.onMapHoverLatLng?.call(ll.lat.toDouble(), ll.lng.toDouble());
      }).toJS;
      _map!.on('mousemove', _hoverMoveCb!);
      _hoverOutCb = ((JSAny _) {
        widget.onMapHoverExit?.call();
      }).toJS;
      _map!.on('mouseout', _hoverOutCb!);
    }

    // PROD-1978 / PROD-2016: pointer cursor on hover over a cluster or
    // leaf pin (desktop only — touch devices don't fire mouseenter).
    // Fires in BOTH interactive and locked mode because:
    //   - In interactive mode, the cursor signals "draggable target".
    //   - In locked mode (PROD-2016), pins are still tappable + the
    //     hover opens the tooltip — so the pointer cursor is honest.
    // `'important'` wins over both the cursorOverride zones AND the
    // locked-mode cursor override on the canvas container.
    web.HTMLElement? canvasContainer() =>
        _container?.querySelector('.mapboxgl-canvas-container')
            as web.HTMLElement?;

    _hoverEnterCb = ((JSAny _) {
      canvasContainer()?.style.setProperty('cursor', 'pointer', 'important');
    }).toJS;
    _hoverLeaveCb = ((JSAny _) {
      // Strip our pointer override; the underlying cursor (grab when
      // interactive, default when locked) takes over again.
      canvasContainer()?.style.removeProperty('cursor');
    }).toJS;

    // PROD-2016 (web hover-to-show): mouseenter on an unclustered pin
    // also opens the tooltip in "hover" mode. Re-query features at
    // the event point to get the marker id + pixel (the layer-scoped
    // mouseenter doesn't carry features in `evt` reliably under
    // dart:js_interop).
    _unclusteredHoverEnterCb = ((JSAny evtAny) {
      canvasContainer()?.style.setProperty('cursor', 'pointer', 'important');
      if (widget.onPinHoverEnter == null) return;
      final evt = evtAny as MapboxMapMouseEvent;
      final pointJs = evt.point as JSObject;
      // PROD-3828: re-query the layer the pointer is actually over. Under
      // `categoryIcons` that's the rendered ICON layer — querying the circle
      // layer there would hit-test an r24 halo lifted 20 px above the tip,
      // which can resolve a different (or no) marker than the one hovered.
      final queryOptions =
          <String, dynamic>{
                'layers': <String>[
                  widget.categoryIcons
                      ? _unclusteredIconLayerId
                      : _unclusteredLayerId,
                ],
              }.jsify()
              as JSObject;
      final featuresJs = _map!.queryRenderedFeatures(pointJs, queryOptions);
      if (featuresJs.length == 0) return;
      final feature = featuresJs.toDart.first as MapboxFeature;
      final propsAny = feature.properties.dartify();
      if (propsAny is! Map) return;
      final markerId = propsAny.cast<Object?, Object?>()['id'];
      if (markerId is! String) return;
      MapMarker? match;
      for (final m in widget.markers) {
        if (m.id == markerId) {
          match = m;
          break;
        }
      }
      if (match != null) {
        final pixel = Offset(evt.point.x.toDouble(), evt.point.y.toDouble());
        widget.onPinHoverEnter!(match, pixel);
      }
    }).toJS;
    _unclusteredHoverLeaveCb = ((JSAny _) {
      canvasContainer()?.style.removeProperty('cursor');
      widget.onPinHoverExit?.call();
    }).toJS;

    _map!.onLayer('mouseenter', _clusterLayerId, _hoverEnterCb!);
    _map!.onLayer('mouseleave', _clusterLayerId, _hoverLeaveCb!);
    if (widget.categoryIcons) {
      // The tap targets are the rendered ICON + caption (the circle layer is
      // an inert legacy halo) → pointer cursor over those instead.
      //
      // PROD-3828: the ICON layer gets the full `_unclusteredHoverEnterCb`
      // (cursor + `onPinHoverEnter`), not the cursor-only `_hoverEnterCb` it
      // used to get. Previously the hover-enter callback was registered ONLY
      // in the `else` branch below, so a `categoryIcons` surface could never
      // fire it — that was fine while the Map page was the only such surface
      // (it wants no hover tooltip) but would have silently dropped hover on
      // every surface PROD-3830 converts.
      //
      // ⚠️ Today this is a no-op in PRACTICE, on every surface: the callback
      // reaches `MapboxMapWidget._handlePinHoverEnter`, which is an
      // intentional no-op because nothing ever sets `_selectionFromHover`.
      // Hover-to-show-tooltip is currently dead app-wide, NOT something the
      // `categoryIcons` branch loses. Registering it here restores the
      // structural parity between the two branches so that reviving the
      // feature is a one-place change, and costs nothing meanwhile (the
      // callback also sets the cursor, which is all the old one did).
      _map!.onLayer(
        'mouseenter',
        _unclusteredIconLayerId,
        _unclusteredHoverEnterCb!,
      );
      _map!.onLayer(
        'mouseleave',
        _unclusteredIconLayerId,
        _unclusteredHoverLeaveCb!,
      );
      // Cursor-only on the caption + bubble-count layers.
      if (widget.showPinCaptions) {
        _map!.onLayer('mouseenter', _unclusteredCaptionLayerId, _hoverEnterCb!);
        _map!.onLayer('mouseleave', _unclusteredCaptionLayerId, _hoverLeaveCb!);
      }
      _map!.onLayer('mouseenter', _clusterCountLayerId, _hoverEnterCb!);
      _map!.onLayer('mouseleave', _clusterCountLayerId, _hoverLeaveCb!);
    } else {
      _map!.onLayer(
        'mouseenter',
        _unclusteredLayerId,
        _unclusteredHoverEnterCb!,
      );
      _map!.onLayer(
        'mouseleave',
        _unclusteredLayerId,
        _unclusteredHoverLeaveCb!,
      );
    }

    // PROD-2671: category-icon mode — render per-category PNG teardrops on
    // top via a symbol layer, and make the unclustered circle transparent
    // and inert (pin clicks/hover route through the ICON + caption layers —
    // see the map-wide click handler). The `cluster:true` bubbles + count
    // layers are untouched. Off by default → every other consumer keeps the
    // colored-circle pins.
    if (widget.categoryIcons) {
      // PROD-2671: scale pins with zoom so they don't dominate the basemap
      // when zoomed out (a country-sized pin at world view) yet stay a legible
      // tap target up close. Shared by the single-pin icon layer AND the
      // stack-of-5 cluster layers so the two never drift.
      // PROD-2993: the stack teardrops honour the per-feature `icon_scale` too,
      // so the results-highlight enlargement covers stacks as well as pins
      // (D14). Bubbles historically omitted the property entirely, so the
      // `coalesce` default of 1.0 keeps every pre-existing caller byte-identical
      // — this only bites once something actually stamps it on a bubble.
      //
      // Folded INTO each interpolate stop, not around the whole expression: a
      // `["zoom"]` expression must stay top-level, so Mapbox rejects
      // `["*", <zoom interpolate>, …]`. Same constraint as `revealIconSize`.
      final List<dynamic> stackScale = <dynamic>[
        'coalesce',
        <dynamic>['get', 'icon_scale'],
        1,
      ];
      final List<dynamic> iconSizeExpr = <dynamic>[
        'interpolate',
        <dynamic>['linear'],
        <dynamic>['zoom'],
        for (final (zoom, size) in _pinStops) ...[
          zoom,
          <dynamic>['*', size, stackScale],
        ],
      ];

      // PROD-2671 cluster-focus: dim non-focused features when focus is
      // active. Reads the per-feature `dim` prop (default false when absent)
      // → 0.25 for dimmed, 1.0 otherwise. OPACITY ONLY — dimmed features stay
      // tappable (their transparent hit-target circle is untouched). Shared by
      // the single-pin icon+label, the stack layers, and the count label.
      // 0.25 is a first pass — candidate for on-device tuning.
      final List<dynamic> dimOpacityExpr = <dynamic>[
        'case',
        <dynamic>[
          'boolean',
          <dynamic>['get', 'dim'],
          false,
        ],
        0.25,
        1.0,
      ];

      // PROD-2671 opening-reveal animation: per-feature `anim_*` props (absent →
      // no change via `coalesce`) let `_playRevealAnimation` fade/scale/lift each
      // pin as it appears. `anim_off` is in icon-size units (Mapbox multiplies
      // icon-offset by icon-size), so the driver size-compensates for the px it
      // wants. Folded ONLY into the single-pin icon layer (bubbles appear plain).
      //
      // The scale multiplier goes INTO each icon-size interpolate stop, not
      // around the whole expression — a `["zoom"]` expression must stay
      // top-level, so Mapbox rejects `["*", <zoom interpolate>, …]`.
      final List<dynamic> animScale = <dynamic>[
        'coalesce',
        <dynamic>['get', 'anim_s'],
        1,
      ];
      // PROD-2947 (FE-1): per-feature score→size multiplier (0.85–1.15; absent →
      // 1.0). Folded into each interpolate stop alongside `animScale` — a
      // `["zoom"]` interpolate must stay top-level, so Mapbox rejects wrapping
      // the whole expression in `["*", <zoom interpolate>, …]`.
      final List<dynamic> scoreScale = <dynamic>[
        'coalesce',
        <dynamic>['get', 'icon_scale'],
        1,
      ];
      // PROD-3828: selection enlargement — a fourth factor on the SINGLE-pin
      // layer only. Deliberately not applied to the `+k` stack layers above:
      // "selected" is meaningless for a bubble standing in for several
      // markers, and stacks are `customSelection`-only (Map page) anyway.
      // No-op on the Map page, which passes neither `selectedMarkerId` nor
      // `selectedMarkerIds`, so `selected` is never stamped and the `case`
      // always takes its `1` default.
      final List<dynamic> selectedScale = _selectedScaleExpr;
      final List<dynamic> revealIconSize = <dynamic>[
        'interpolate',
        <dynamic>['linear'],
        <dynamic>['zoom'],
        for (final (zoom, size) in _pinStops) ...[
          zoom,
          <dynamic>['*', size, animScale, scoreScale, selectedScale],
        ],
      ];
      // PROD-2989 "seen" hint: an item whose detail sheet has been opened this
      // visit fades by `MapPinIconTokens.viewedIconOpacity` (per-feature
      // `viewed` prop; absent → 1.0). A third multiplicative factor so it
      // composes with the focus-dim AND the reveal fade below — and applies ONLY
      // to the individual-pin layers (bubbles use the bare `dimOpacityExpr`, so
      // `+k` stacks are unaffected).
      final List<dynamic> viewedOpacityExpr = <dynamic>[
        'case',
        <dynamic>[
          'boolean',
          <dynamic>['get', 'viewed'],
          false,
        ],
        MapPinIconTokens.viewedIconOpacity,
        1.0,
      ];
      final List<dynamic> revealIconOpacity = <dynamic>[
        '*',
        dimOpacityExpr,
        <dynamic>[
          'coalesce',
          <dynamic>['get', 'anim_o'],
          1,
        ],
        viewedOpacityExpr,
      ];
      final List<dynamic> revealIconOffset = <dynamic>[
        'coalesce',
        <dynamic>['get', 'anim_off'],
        <dynamic>[
          'literal',
          <double>[0, 0],
        ],
      ];

      // The unclustered circle layer is INERT in this mode — fully
      // transparent and no longer a hit target. (It used to be an invisible
      // r24 halo lifted 20px, which at the working zooms was ~2× the rendered
      // pin — taps clearly beside/below a pin still opened it. Pin taps now
      // hit-test the rendered ICON + [MapPinIconTokens.pinHitMarginPx] in the
      // map-wide click handler; native mirrors via
      // [MapPinIconTokens.pinHitDistance].)
      _map!.setPaintProperty(_unclusteredLayerId, 'circle-opacity', 0.0.toJS);
      _map!.setPaintProperty(
        _unclusteredLayerId,
        'circle-stroke-opacity',
        0.0.toJS,
      );
      // The pin ICON layer — teardrop art only. Captions live in a SEPARATE
      // layer added directly above (see below), so a nearer pin's icon can no
      // longer paint over a farther pin's caption.
      _map!.addLayer(
        <String, dynamic>{
              'id': _unclusteredIconLayerId,
              'type': 'symbol',
              'source': _clusterSourceId,
              'filter': <dynamic>[
                '!',
                <dynamic>['has', bubbleCountKey],
              ],
              'layout': <String, dynamic>{
                'icon-image': <dynamic>['get', 'icon'],
                'icon-size': revealIconSize,
                'icon-offset': revealIconOffset,
                // PROD-2940: score-driven draw order. `icon-allow-overlap: true`
                // means Mapbox draws the HIGHER sort-key on top, so the key is
                // `1 − sort_key = score` — the INVERSE of the caption layer, whose
                // overlap rule is lower-key-wins. Same expression on native.
                //
                // PROD-3004: set STATICALLY and always. Whether it's honoured is
                // `symbol-z-order`'s job (`_applySymbolZOrder`): a flat pool sets
                // `viewport-y`, which masks the key and restores viewport-Y depth.
                // The initial value must be right here — the source is installed
                // WITH features, so deferring to the first `_renderMarkers` would
                // paint a frame in the wrong order.
                'symbol-sort-key': <dynamic>[
                  '-',
                  1,
                  <dynamic>[
                    'coalesce',
                    <dynamic>['get', 'sort_key'],
                    1,
                  ],
                ],
                'symbol-z-order': mapSymbolZOrder(widget.markers),
                'icon-allow-overlap': true,
                'icon-ignore-placement': true,
                // PROD-2671: BOTTOM anchor so the teardrop's tip sits ON the
                // coordinate (the standard map-pin convention) — the tip marks
                // the location, and the pin no longer appears to drift/float as
                // the zoom scales its size (a centred pin shifted with zoom).
                'icon-anchor': 'bottom',
              },
              'paint': <String, dynamic>{
                // PROD-2671 cluster-focus: fade non-focused pins.
                // Reveal anim folds in via the `anim_o` multiplier.
                'icon-opacity': revealIconOpacity,
              },
            }.jsify()
            as JSObject,
      );

      // PROD-3828: the caption layer is now GATED. It used to be added
      // unconditionally whenever `categoryIcons` was on, which meant a
      // consumer with no `pinTitle`/`pinSubtitle` still paid for an empty
      // `format` label and its placement work. Per-consumer flag rather than
      // inferring from a null title — see [MapboxMapPlatform.showPinCaptions].
      if (widget.showPinCaptions) {
        // The pin CAPTION layer — name + secondary facet, stacked ABOVE the icon
        // layer so captions always render on top of every pin (never occluded by a
        // neighbouring teardrop). Same source + filter as the icons; captions still
        // avoid each OTHER (`text-allow-overlap` default false + `text-optional`),
        // so the LOWER `symbol-sort-key` wins a caption collision — the opposite
        // rule to the icon layer, hence the un-inverted key below.
        //
        // PROD-3004: because `text-allow-overlap` is false, this layer's
        // `canOverlap` is FALSE, so it NEVER sorts by viewport-Y — with the key
        // masked (flat pool) it falls back to SOURCE order. That's true on native
        // too; it's what makes the two platforms agree. Mirror of the native layer.
        _map!.addLayer(
          <String, dynamic>{
                'id': _unclusteredCaptionLayerId,
                'type': 'symbol',
                'source': _clusterSourceId,
                'filter': <dynamic>[
                  '!',
                  <dynamic>['has', bubbleCountKey],
                ],
                'layout': <String, dynamic>{
                  // PROD-2940 caption placement priority; PROD-3004 static + gated
                  // by `symbol-z-order` (see the icon layer above).
                  'symbol-sort-key': <dynamic>[
                    'coalesce',
                    <dynamic>['get', 'sort_key'],
                    1,
                  ],
                  'symbol-z-order': mapSymbolZOrder(widget.markers),
                  // PROD-2671: inline label — item name (medium) over the
                  // secondary facet (regular), to the right of the teardrop.
                  // Uses Open Sans (Mapbox stock glyphs); the design's Zalando
                  // Sans isn't in the style glyph set — a known font divergence
                  // to resolve with a custom style. `text-optional` lets a
                  // colliding label drop while the icon always renders.
                  'text-field': <dynamic>[
                    'format',
                    <dynamic>[
                      'coalesce',
                      <dynamic>['get', 'pin_title'],
                      '',
                    ],
                    <String, dynamic>{
                      'text-font': <dynamic>[
                        'literal',
                        <String>['Open Sans Semibold', 'Arial Unicode MS Bold'],
                      ],
                    },
                    // PROD-3830: the separator is CONDITIONAL. This used to
                    // be a bare '\n', so a pin with a title and no subtitle
                    // rendered as "Title\n" — a phantom empty second line,
                    // which inflates the caption's collision box and makes
                    // neighbouring captions drop that didn't need to. Only the
                    // Map page had captions when this was written, and its
                    // pins almost always carry a facet subtitle, so the case
                    // was rare enough to go unnoticed. PROD-3830's list maps
                    // have NO subtitle at all (list items carry no facet), so
                    // every one of their captions would hit it.
                    //
                    // `pin_subtitle` is stamped only when non-null, so `has`
                    // is the right test. Map-page pins WITH a subtitle are
                    // byte-identical to before.
                    <dynamic>[
                      'case',
                      <dynamic>['has', 'pin_subtitle'],
                      '\n',
                      '',
                    ],
                    <dynamic>[
                      'coalesce',
                      <dynamic>['get', 'pin_subtitle'],
                      '',
                    ],
                    <String, dynamic>{
                      'font-scale': 0.9,
                      'text-font': <dynamic>[
                        'literal',
                        <String>[
                          'Open Sans Regular',
                          'Arial Unicode MS Regular',
                        ],
                      ],
                    },
                  ],
                  'text-size': 13,
                  // PROD-2671 (Figma 6949-21685): caption sits to the RIGHT of
                  // the teardrop, **top-aligned** with the pin's top (title on
                  // top, secondary facet stacked below), ~6px clear of the pin.
                  // `top-left` anchors the block's top-left corner. The offset is
                  // a ZOOM-INTERPOLATED expression (not a constant) so it tracks
                  // the pin's scaled size at every zoom — a constant ems offset
                  // drifts off the pin as it shrinks when zoomed out. It is
                  // measured from the geometry point (like the icon offset), so
                  // splitting icon/text into two layers keeps the exact position.
                  // See [MapPinIconTokens.captionOffsetExpression].
                  'text-anchor': 'top-left',
                  'text-offset': MapPinIconTokens.captionOffsetExpression(
                    sizeMul: widget.captionSizeMul,
                    stops: _pinStops,
                  ),
                  'text-justify': 'left',
                  'text-optional': true,
                  'text-max-width': 12,
                },
                'paint': <String, dynamic>{
                  'text-color': _hexFromColor(AppColors.sokoInk),
                  'text-halo-color': '#FFFFFF',
                  'text-halo-width': 1.0,
                  // PROD-2671 cluster-focus: fade non-focused captions in step
                  // with their icon (same `anim_o`/`dim` source props).
                  'text-opacity': revealIconOpacity,
                },
              }.jsify()
              as JSObject,
        );
      }

      // PROD-2671: stack-of-5 cluster visual (custom selection only). The
      // circle bubble stays as a transparent tap/hover hit target (its click
      // handler zooms to decluster); on top we draw up to 5 member teardrops
      // shifted 3 px up-and-left per layer (`icon-translate` = constant screen
      // px), most-relevant on top, and re-point the count label to a
      // right-side "X venues / Y events" title.
      if (widget.customSelection) {
        _map!.setPaintProperty(_clusterLayerId, 'circle-opacity', 0.0.toJS);
        _map!.setPaintProperty(
          _clusterLayerId,
          'circle-stroke-opacity',
          0.0.toJS,
        );
        // PROD-2671: the stack teardrops are BOTTOM-anchored too (tips near the
        // centroid, bodies reaching up), so lift the transparent bubble hit
        // target ~20px to sit over the visible stack rather than the empty
        // space below it. Mirror of the single-pin hit-circle shift above.
        _map!.setPaintProperty(
          _clusterLayerId,
          'circle-translate',
          <double>[0, -20].jsify(),
        );
        _map!.setPaintProperty(
          _clusterLayerId,
          'circle-translate-anchor',
          'viewport'.toJS,
        );
        // Add back-to-front so stack_icon_0 (most relevant) ends up topmost:
        // layer 4 first … layer 0 last.
        for (var i = 4; i >= 0; i--) {
          final d = -3.0 * i;
          _map!.addLayer(
            <String, dynamic>{
                  'id': 'heyl-stack-$i',
                  'type': 'symbol',
                  'source': _clusterSourceId,
                  'filter': <dynamic>['has', 'stack_icon_$i'],
                  'layout': <String, dynamic>{
                    'icon-image': <dynamic>['get', 'stack_icon_$i'],
                    'icon-size': iconSizeExpr,
                    'icon-allow-overlap': true,
                    'icon-ignore-placement': true,
                    // PROD-2671: BOTTOM anchor so each stacked teardrop plants
                    // its tip at the centroid (the 3px-per-layer fan reaches
                    // up-left), matching the single-pin convention.
                    'icon-anchor': 'bottom',
                  },
                  'paint': <String, dynamic>{
                    'icon-translate': <double>[d, d],
                    // PROD-2671 cluster-focus: fade non-focused overflow
                    // bubbles' stacked member teardrops.
                    'icon-opacity': dimOpacityExpr,
                  },
                }.jsify()
                as JSObject,
          );
        }
        // Re-point the count label at the localized "X venues / Y events"
        // title (falls back to "+k" until the Map page wires it), to the
        // right of the stack, in Soko Ink.
        _map!.setLayoutProperty(
          _clusterCountLayerId,
          'text-field',
          <dynamic>[
            'coalesce',
            <dynamic>['get', 'bubble_title'],
            <dynamic>['get', 'overflow_label'],
          ].jsify(),
        );
        // PROD-2671: position the cluster's "X venues / Y events" title EXACTLY
        // like a single pin's caption — `top-left` anchor + the same
        // zoom-tracked offset expression + the same text-size (13) — so the
        // stack's front teardrop (i=0, translate 0, bottom-anchored on the
        // centroid) carries a caption identical to a lone pin's. (Was
        // `left`-anchored with a small constant offset → sat too low and too
        // close to the stack.)
        _map!.setLayoutProperty(
          _clusterCountLayerId,
          'text-anchor',
          'top-left'.toJS,
        );
        _map!.setLayoutProperty(
          _clusterCountLayerId,
          'text-size',
          MapPinIconTokens.captionTextSizePx.toJS,
        );
        _map!.setLayoutProperty(
          _clusterCountLayerId,
          'text-offset',
          MapPinIconTokens.captionOffsetExpression(
            sizeMul: widget.captionSizeMul,
            stops: _pinStops,
          ).jsify(),
        );
        _map!.setLayoutProperty(
          _clusterCountLayerId,
          'text-justify',
          'left'.toJS,
        );
        _map!.setLayoutProperty(
          _clusterCountLayerId,
          'text-allow-overlap',
          true.toJS,
        );
        _map!.setPaintProperty(
          _clusterCountLayerId,
          'text-color',
          _hexFromColor(AppColors.sokoInk).toJS,
        );
        // PROD-2671 cluster-focus: fade non-focused overflow bubbles' count
        // labels along with their stacked teardrops.
        _map!.setPaintProperty(
          _clusterCountLayerId,
          'text-opacity',
          dimOpacityExpr.jsify(),
        );
      }
    }

    _clusterLayersInstalled = true;
    _mapBreadcrumb(
      'Cluster source + layers installed',
      data: {'markers': widget.markers.length},
    );

    // PROD-1978: user-location dot lives in a SEPARATE GeoJsonSource
    // (`cluster: false`) so it never aggregates with venue/event pins.
    // Rendered last → on top of all other layers. Style matches the
    // chat compact map: blue (#3B82F6) fill, white 2 px border. No
    // accuracy circle yet — fold in if/when product asks for it.
    _installUserLocationLayer();
    // Picker center-of-search pin — its own symbol layer above the user dot,
    // driven by [pickerPinLatLng] (no-op when null). Registers its PNG image
    // asynchronously, then adds the icon layer + pushes the point.
    _installPickerPinLayer();
    // PROD-2971: admin debug overlay, installed last (renders above pins). Draws
    // immediately if debugOverlay is already set (e.g. hot reload with debug on).
    _installMapDebugLayer();
    // PROD-3109: boundary overlays (hover beneath committed) — installed after
    // debug so they don't interfere with the debug z-order. Both sources start
    // empty; _syncBoundaryOverlay/_syncHoverOverlay push live data.
    _installBoundaryOverlays();
  }

  /// PROD-2971: install the admin debug-overlay source + a fill + line layer,
  /// both coloured per-feature via `['get', ...]` paint expressions so one pair
  /// of layers renders every shape. Idempotent. Empty until
  /// [_updateMapDebugOverlay] fills it.
  void _installMapDebugLayer() {
    final map = _map;
    if (map == null) return;
    if (map.getSource(_mapDebugSourceId) != null) return;
    map.addSource(
      _mapDebugSourceId,
      <String, dynamic>{
            'type': 'geojson',
            'data': <String, dynamic>{
              'type': 'FeatureCollection',
              'features': <Map<String, dynamic>>[],
            },
          }.jsify()
          as JSObject,
    );
    map.addLayer(
      <String, dynamic>{
            'id': _mapDebugFillLayerId,
            'type': 'fill',
            'source': _mapDebugSourceId,
            'paint': <String, dynamic>{
              'fill-color': <dynamic>['get', 'fill_color'],
            },
          }.jsify()
          as JSObject,
    );
    map.addLayer(
      <String, dynamic>{
            'id': _mapDebugLineLayerId,
            'type': 'line',
            'source': _mapDebugSourceId,
            'paint': <String, dynamic>{
              'line-color': <dynamic>['get', 'line_color'],
              'line-width': <dynamic>['get', 'line_width'],
            },
          }.jsify()
          as JSObject,
    );
    _updateMapDebugOverlay();
  }

  /// PROD-2971: rebuild the debug overlay from `widget.debugOverlay` (or clear
  /// it when null). Shared [buildMapDebugOverlayGeoJson] builds the geometry so
  /// native + web can't drift.
  void _updateMapDebugOverlay() {
    final map = _map;
    if (map == null) return;
    final source = map.getSource(_mapDebugSourceId);
    if (source == null) return;
    source.setData(
      buildMapDebugOverlayGeoJson(
            widget.debugOverlay,
            shapes: widget.debugOverlayShapes,
          ).jsify()
          as JSObject,
    );
  }

  /// PROD-3124: install the dot-hints source + circle layer. Runs FIRST inside
  /// [_installClusterSourceAndLayers], so the layer sits beneath every pin
  /// layer. One layer paints all colours via `['get', 'dot_color']`; radius
  /// tracks the dots' zoom curve ([dotRadiusStopsFlat]); opacity starts at 0 —
  /// [_syncDotHints] fades it in per data sync (the progressive reveal).
  /// Idempotent.
  void _installDotHintsLayer() {
    final map = _map;
    if (map == null) return;
    if (map.getSource(_dotHintsSourceId) != null) return;
    map.addSource(
      _dotHintsSourceId,
      <String, dynamic>{
            'type': 'geojson',
            'data': <String, dynamic>{
              'type': 'FeatureCollection',
              'features': <Map<String, dynamic>>[],
            },
          }.jsify()
          as JSObject,
    );
    map.addLayer(
      <String, dynamic>{
            'id': _dotHintsLayerId,
            'type': 'circle',
            'source': _dotHintsSourceId,
            'paint': <String, dynamic>{
              'circle-color': <dynamic>['get', 'dot_color'],
              'circle-radius': <dynamic>[
                'interpolate',
                <dynamic>['linear'],
                <dynamic>['zoom'],
                ...dotRadiusStopsFlat(),
              ],
              'circle-opacity': 0.0,
              'circle-stroke-color': kDotHintStrokeColor,
              'circle-stroke-width': kDotHintStrokePx,
              'circle-stroke-opacity': 0.0,
            },
          }.jsify()
          as JSObject,
    );
    _syncDotHints();
  }

  /// PROD-3124: push the current dot hints into the source and run the
  /// progressive reveal — snap the layer invisible (zero-duration transition),
  /// swap the data, then fade fill + stroke to [kDotHintOpacity] after
  /// [kDotFadeDelayMs] over [kDotFadeDurationMs]. Paint-property transitions:
  /// the GL engine tweens, no Dart frames. Pins paint instantly on the same
  /// settle, so they always land first. Gated on the Map page's opening reveal
  /// like the pins ([_openSettled] — [_startOpenSettle] re-syncs on reveal).
  void _syncDotHints() {
    final map = _map;
    if (map == null) return;
    final source = map.getSource(_dotHintsSourceId);
    if (source == null) return;
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
        _setDotHintOpacity(opacity: 0, durationMs: 0, delayMs: 0);
      }
      source.setData(
        (data ??
                    const <String, dynamic>{
                      'type': 'FeatureCollection',
                      'features': <dynamic>[],
                    })
                .jsify()
            as JSObject,
      );
      if (!removalOnly && features.isNotEmpty) {
        _setDotHintOpacity(
          opacity: kDotHintOpacity,
          durationMs: kDotFadeDurationMs,
          delayMs: kDotFadeDelayMs,
        );
      }
      _dotHintsRevealed = features.isNotEmpty;
    } catch (e) {
      // The layer's actual state is now unknown — force a full reveal next time.
      _dotHintsRevealed = false;
      web.console.warn('[MapboxMapPlatform] dot hints sync failed: $e'.toJS);
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
  /// [durationMs]/[delayMs] (0/0 = snap). The transition property must be set
  /// BEFORE the value so the change animates with the intended timing.
  void _setDotHintOpacity({
    required double opacity,
    required int durationMs,
    required int delayMs,
  }) {
    final map = _map;
    if (map == null) return;
    final transition = <String, dynamic>{
      'duration': durationMs,
      'delay': delayMs,
    };
    map.setPaintProperty(
      _dotHintsLayerId,
      'circle-opacity-transition',
      transition.jsify(),
    );
    map.setPaintProperty(
      _dotHintsLayerId,
      'circle-stroke-opacity-transition',
      transition.jsify(),
    );
    map.setPaintProperty(_dotHintsLayerId, 'circle-opacity', opacity.toJS);
    map.setPaintProperty(
      _dotHintsLayerId,
      'circle-stroke-opacity',
      opacity.toJS,
    );
  }

  void _installUserLocationLayer() {
    final map = _map;
    if (map == null) return;
    if (map.getSource(_userLocationSourceId) != null) return;
    // PROD-2671: accuracy ring FIRST so it renders behind the dot. A fill +
    // thin outline, semi-transparent blue (matches the original approximate-
    // location ring). Empty until `_updateUserLocationSource` populates it.
    map.addSource(
      _userAccuracySourceId,
      <String, dynamic>{
            'type': 'geojson',
            'data': <String, dynamic>{
              'type': 'FeatureCollection',
              'features': <Map<String, dynamic>>[],
            },
          }.jsify()
          as JSObject,
    );
    map.addLayer(
      <String, dynamic>{
            'id': _userAccuracyFillLayerId,
            'type': 'fill',
            'source': _userAccuracySourceId,
            'paint': {'fill-color': 'rgba(59, 130, 246, 0.12)'},
          }.jsify()
          as JSObject,
    );
    map.addLayer(
      <String, dynamic>{
            'id': _userAccuracyLineLayerId,
            'type': 'line',
            'source': _userAccuracySourceId,
            'paint': {
              'line-color': 'rgba(59, 130, 246, 0.3)',
              'line-width': kAccuracyRingLineWidth,
            },
          }.jsify()
          as JSObject,
    );
    map.addSource(
      _userLocationSourceId,
      <String, dynamic>{
            'type': 'geojson',
            'data': <String, dynamic>{
              'type': 'FeatureCollection',
              'features': <Map<String, dynamic>>[],
            },
          }.jsify()
          as JSObject,
    );
    map.addLayer(
      <String, dynamic>{
            'id': _userLocationLayerId,
            'type': 'circle',
            'source': _userLocationSourceId,
            'paint': {
              'circle-color': '#3B82F6',
              'circle-radius': 7,
              'circle-stroke-color': '#FFFFFF',
              'circle-stroke-width': 2,
            },
          }.jsify()
          as JSObject,
    );
    _updateUserLocationSource();
  }

  void _updateUserLocationSource() {
    final map = _map;
    if (map == null) return;
    final source = map.getSource(_userLocationSourceId);
    if (source == null) return;
    final features = <Map<String, dynamic>>[];
    MapMarker? userMarker;
    final dot = widget.userDotLatLng;
    if (dot != null) {
      // Picker path: an explicit dot point (viewport-gated by the caller) wins
      // over the markers scan, so dot visibility is independent of the markers
      // list. No accuracy ring in this path.
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[dot.lng, dot.lat],
        },
        'properties': <String, dynamic>{},
      });
    } else {
      for (final m in widget.markers) {
        if (m.type != MapMarkerType.userLocation) continue;
        userMarker = m;
        features.add(<String, dynamic>{
          'type': 'Feature',
          'geometry': <String, dynamic>{
            'type': 'Point',
            'coordinates': <double>[m.lng, m.lat],
          },
          'properties': <String, dynamic>{},
        });
        break; // at most one user-location dot
      }
    }
    source.setData(
      <String, dynamic>{
            'type': 'FeatureCollection',
            'features': features,
          }.jsify()
          as JSObject,
    );
    _updateUserAccuracySource(userMarker);
  }

  /// PROD-2671: set (or clear) the accuracy-ring polygon from the user-location
  /// marker's `accuracyM`. Drawn only for an imprecise fix (≥ threshold); a
  /// precise fix leaves the ring empty.
  void _updateUserAccuracySource(MapMarker? userMarker) {
    final map = _map;
    if (map == null) return;
    final source = map.getSource(_userAccuracySourceId);
    if (source == null) return;
    final features = <Map<String, dynamic>>[];
    final acc = userMarker?.accuracyM;
    if (userMarker != null && acc != null && acc >= kAccuracyRingMinMeters) {
      final ring = accuracyCircleRing(userMarker.lat, userMarker.lng, acc);
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <dynamic>[ring],
        },
        'properties': <String, dynamic>{},
      });
    }
    source.setData(
      <String, dynamic>{
            'type': 'FeatureCollection',
            'features': features,
          }.jsify()
          as JSObject,
    );
  }

  /// Install the picker center-of-search pin's source + symbol layer. The
  /// source is added synchronously (empty); the PNG image is registered
  /// asynchronously and the icon layer added once it's ready, then the point
  /// is pushed. Idempotent. No-op past teardown.
  void _installPickerPinLayer() {
    final map = _map;
    if (map == null) return;
    // Picker-only: skip the source/layer + PNG load on every other map surface,
    // which never sets a picker pin. Installs lazily on a null→non-null flip.
    if (widget.pickerPinLatLng == null) return;
    if (map.getSource(_pickerPinSourceId) != null) return;
    map.addSource(
      _pickerPinSourceId,
      <String, dynamic>{
            'type': 'geojson',
            'data': <String, dynamic>{
              'type': 'FeatureCollection',
              'features': <Map<String, dynamic>>[],
            },
          }.jsify()
          as JSObject,
    );
    _registerPickerPinImage().whenComplete(() {
      final m = _map;
      if (!mounted || m == null) return;
      if (m.getLayer(_pickerPinLayerId) == null) {
        m.addLayer(
          <String, dynamic>{
                'id': _pickerPinLayerId,
                'type': 'symbol',
                'source': _pickerPinSourceId,
                'layout': <String, dynamic>{
                  'icon-image': _pickerPinImageKey,
                  'icon-size': _pickerPinIconSize,
                  // Tip of the teardrop sits on the coordinate.
                  'icon-anchor': 'bottom',
                  // Always draw it — never let symbol collision drop the one
                  // pin the picker is all about.
                  'icon-allow-overlap': true,
                  'icon-ignore-placement': true,
                },
              }.jsify()
              as JSObject,
        );
      }
      _updatePickerPinSource();
    });
  }

  /// Load `pin-search.png`, decode to RGBA, and register it with Mapbox under
  /// [_pickerPinImageKey] via `addImage`. Bytes-based (immune to Flutter-web
  /// asset-URL quirks), mirroring [_registerCategoryIcons]. Best-effort.
  Future<void> _registerPickerPinImage() async {
    final map = _map;
    if (map == null) return;
    if (map.hasImage(_pickerPinImageKey)) return;
    try {
      final data = await rootBundle.load(_pickerPinAssetPath);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return;
      if (!mounted || _map == null) return;
      if (_map!.hasImage(_pickerPinImageKey)) return;
      _map!.addImage(
        _pickerPinImageKey,
        MapboxStyleImage(
          width: image.width,
          height: image.height,
          data: rgba.buffer.asUint8List().toJS,
        ),
      );
    } catch (_) {
      // Skip — the picker still functions without the pin art.
    }
  }

  /// Push (or clear) the picker pin's point onto its dedicated source. Mirror
  /// of [_updateUserLocationSource]; null [pickerPinLatLng] empties the source.
  void _updatePickerPinSource() {
    final map = _map;
    if (map == null) return;
    final source = map.getSource(_pickerPinSourceId);
    if (source == null) return;
    final features = <Map<String, dynamic>>[];
    final pin = widget.pickerPinLatLng;
    if (pin != null) {
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[pin.lng, pin.lat],
        },
        'properties': <String, dynamic>{},
      });
    }
    source.setData(
      <String, dynamic>{
            'type': 'FeatureCollection',
            'features': features,
          }.jsify()
          as JSObject,
    );
  }

  // DEBUG-only search-area overlay — soko-red `#F68686`. Fill at 30 % + a solid
  // outline so the boundary reads even where the fill overlaps the map/pins.
  static const String _debugAreaFillColor = 'rgba(246, 134, 134, 0.3)';
  static const String _debugAreaLineColor = 'rgba(246, 134, 134, 0.95)';

  /// DEBUG-only: reconcile the search-area overlay with [widget.debugSearchArea].
  /// Null → tear the layers down (zero footprint when off). Non-null → install
  /// the layers on first use (on TOP of everything) and push the circle + rect
  /// polygons. Best-effort — any interop hiccup degrades to "no overlay".
  void _syncDebugSearchArea() {
    final map = _map;
    if (map == null || !_mapLoaded) return;
    final area = widget.debugSearchArea;

    try {
      if (area == null) {
        // Toggled off (or never on): remove layers + source if present.
        if (map.getLayer(_debugAreaLineLayerId) != null) {
          map.removeLayer(_debugAreaLineLayerId);
        }
        if (map.getLayer(_debugAreaFillLayerId) != null) {
          map.removeLayer(_debugAreaFillLayerId);
        }
        if (map.getSource(_debugAreaSourceId) != null) {
          map.removeSource(_debugAreaSourceId);
        }
        return;
      }

      // Install the source + fill/line layers the first time it's toggled on.
      if (map.getSource(_debugAreaSourceId) == null) {
        map.addSource(
          _debugAreaSourceId,
          <String, dynamic>{
                'type': 'geojson',
                'data': <String, dynamic>{
                  'type': 'FeatureCollection',
                  'features': <Map<String, dynamic>>[],
                },
              }.jsify()
              as JSObject,
        );
        map.addLayer(
          <String, dynamic>{
                'id': _debugAreaFillLayerId,
                'type': 'fill',
                'source': _debugAreaSourceId,
                'paint': {'fill-color': _debugAreaFillColor},
              }.jsify()
              as JSObject,
        );
        map.addLayer(
          <String, dynamic>{
                'id': _debugAreaLineLayerId,
                'type': 'line',
                'source': _debugAreaSourceId,
                'paint': {'line-color': _debugAreaLineColor, 'line-width': 2.0},
              }.jsify()
              as JSObject,
        );
      }

      final features = <Map<String, dynamic>>[];
      // The v2 viewport RECTANGLE (SW → NE), drawn only when actually sent.
      if (area.hasRect) {
        final ring = <List<double>>[
          [area.swLng!, area.swLat!],
          [area.neLng!, area.swLat!],
          [area.neLng!, area.neLat!],
          [area.swLng!, area.neLat!],
          [area.swLng!, area.swLat!],
        ];
        features.add(<String, dynamic>{
          'type': 'Feature',
          'geometry': <String, dynamic>{
            'type': 'Polygon',
            'coordinates': <dynamic>[ring],
          },
          'properties': <String, dynamic>{'kind': 'rect'},
        });
      }
      // The radius CIRCLE (center + radius_meters), as a geodesic polygon.
      if (area.hasCircle) {
        final ring = accuracyCircleRing(
          area.centerLat,
          area.centerLng,
          area.radiusMeters!,
          segments: 96,
        );
        features.add(<String, dynamic>{
          'type': 'Feature',
          'geometry': <String, dynamic>{
            'type': 'Polygon',
            'coordinates': <dynamic>[ring],
          },
          'properties': <String, dynamic>{'kind': 'circle'},
        });
      }

      final source = map.getSource(_debugAreaSourceId);
      source?.setData(
        <String, dynamic>{
              'type': 'FeatureCollection',
              'features': features,
            }.jsify()
            as JSObject,
      );
    } catch (_) {
      // A bad expression / interop hiccup just leaves the overlay unchanged.
    }
  }

  static const String _pickerBoundaryFillColor = 'rgba(199, 98, 116, 0.15)';
  static const String _pickerBoundaryLineColor = 'rgba(199, 98, 116, 0.95)';
  // Hover overlay: same soko-red hue at lower opacity + thinner line.
  static const String _pickerHoverFillColor = 'rgba(199, 98, 116, 0.08)';
  static const String _pickerHoverLineColor = 'rgba(199, 98, 116, 0.50)';
  // Drill-down children: transparent fill (an additive fill just washes the
  // city fill out uniformly), dark sokoInk dividers that clearly carve the
  // tappable freguesias. Tappability is hit-tested in Dart, not via the fill.
  static const String _pickerChildrenFillColor = 'rgba(68, 19, 29, 0.0)';
  static const String _pickerChildrenLineColor = 'rgba(68, 19, 29, 0.6)';

  /// PROD-3109: install the hover (lighter) boundary pair FIRST, then the
  /// committed (solid) boundary pair, so committed always renders on top.
  /// Each source starts with an empty FeatureCollection; [_syncBoundaryOverlay]
  /// and [_syncHoverOverlay] push live data via `source.setData(...)`. Mirrors
  /// the [_installMapDebugLayer] pattern. Idempotent.
  void _installBoundaryOverlays() {
    final map = _map;
    if (map == null) return;

    // ── children pair (installed first → beneath hover + committed) ───────
    if (map.getSource(_pickerChildrenSourceId) == null) {
      map.addSource(
        _pickerChildrenSourceId,
        <String, dynamic>{
              'type': 'geojson',
              'data': <String, dynamic>{
                'type': 'FeatureCollection',
                'features': <Map<String, dynamic>>[],
              },
            }.jsify()
            as JSObject,
      );
      map.addLayer(
        <String, dynamic>{
              'id': _pickerChildrenFillLayerId,
              'type': 'fill',
              'source': _pickerChildrenSourceId,
              'paint': {'fill-color': _pickerChildrenFillColor},
            }.jsify()
            as JSObject,
      );
      map.addLayer(
        <String, dynamic>{
              'id': _pickerChildrenLineLayerId,
              'type': 'line',
              'source': _pickerChildrenSourceId,
              'paint': {
                'line-color': _pickerChildrenLineColor,
                'line-width': 1.2,
              },
            }.jsify()
            as JSObject,
      );
    }

    // ── hover pair (installed after children → above them) ────────────────
    if (map.getSource(_pickerHoverSourceId) == null) {
      map.addSource(
        _pickerHoverSourceId,
        <String, dynamic>{
              'type': 'geojson',
              'data': <String, dynamic>{
                'type': 'FeatureCollection',
                'features': <Map<String, dynamic>>[],
              },
            }.jsify()
            as JSObject,
      );
      map.addLayer(
        <String, dynamic>{
              'id': _pickerHoverFillLayerId,
              'type': 'fill',
              'source': _pickerHoverSourceId,
              'paint': {'fill-color': _pickerHoverFillColor},
            }.jsify()
            as JSObject,
      );
      map.addLayer(
        <String, dynamic>{
              'id': _pickerHoverLineLayerId,
              'type': 'line',
              'source': _pickerHoverSourceId,
              'paint': {'line-color': _pickerHoverLineColor, 'line-width': 1.5},
            }.jsify()
            as JSObject,
      );
    }

    // ── committed pair (installed second → on top of hover) ───────────────
    if (map.getSource(_pickerBoundarySourceId) == null) {
      map.addSource(
        _pickerBoundarySourceId,
        <String, dynamic>{
              'type': 'geojson',
              'data': <String, dynamic>{
                'type': 'FeatureCollection',
                'features': <Map<String, dynamic>>[],
              },
            }.jsify()
            as JSObject,
      );
      map.addLayer(
        <String, dynamic>{
              'id': _pickerBoundaryFillLayerId,
              'type': 'fill',
              'source': _pickerBoundarySourceId,
              'paint': {'fill-color': _pickerBoundaryFillColor},
            }.jsify()
            as JSObject,
      );
      map.addLayer(
        <String, dynamic>{
              'id': _pickerBoundaryLineLayerId,
              'type': 'line',
              'source': _pickerBoundarySourceId,
              'paint': {
                'line-color': _pickerBoundaryLineColor,
                'line-width': 2.0,
              },
            }.jsify()
            as JSObject,
      );
    }

    // Populate all sources from current widget state.
    _syncChildrenOverlay();
    _syncBoundaryOverlay();
    _syncHoverOverlay();
  }

  /// Picker drill-down: push the city's child neighbourhoods (a ready-made
  /// FeatureCollection) into the pre-installed children source via `setData`.
  /// No-op until [_installBoundaryOverlays] has run.
  void _syncChildrenOverlay() {
    final map = _map;
    if (map == null || !_mapLoaded) return;
    try {
      final source = map.getSource(_pickerChildrenSourceId);
      if (source == null) return;
      final fc =
          widget.childBoundariesGeoJson ??
          const <String, dynamic>{
            'type': 'FeatureCollection',
            'features': <Map<String, dynamic>>[],
          };
      source.setData(fc.jsify() as JSObject);
    } catch (_) {
      // A bad geometry / interop hiccup just leaves the overlay unchanged.
    }
  }

  /// PROD-3109: push the committed boundary into the pre-installed source via
  /// `setData` (no add/remove). Mirrors [_updateMapDebugOverlay]. No-op until
  /// [_installBoundaryOverlays] has run.
  void _syncBoundaryOverlay() {
    final map = _map;
    if (map == null || !_mapLoaded) return;
    final geometry = widget.highlightBoundaryGeoJson;
    final point = widget.highlightPoint;

    try {
      final source = map.getSource(_pickerBoundarySourceId);
      if (source == null) return; // not yet installed

      final Map<String, dynamic> featureGeometry;
      if (geometry != null) {
        featureGeometry = geometry;
      } else if (point != null) {
        final ring = accuracyCircleRing(
          point.lat,
          point.lng,
          widget.highlightRadiusMeters ?? _pickerPointFallbackRadiusMeters,
          segments: 64,
        );
        featureGeometry = <String, dynamic>{
          'type': 'Polygon',
          'coordinates': <dynamic>[ring],
        };
      } else {
        // No geometry — push an empty FeatureCollection to clear the layer.
        source.setData(
          <String, dynamic>{
                'type': 'FeatureCollection',
                'features': <Map<String, dynamic>>[],
              }.jsify()
              as JSObject,
        );
        return;
      }

      source.setData(
        <String, dynamic>{
              'type': 'FeatureCollection',
              'features': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'Feature',
                  'geometry': featureGeometry,
                  'properties': <String, dynamic>{},
                },
              ],
            }.jsify()
            as JSObject,
      );
    } catch (_) {
      // A bad geometry / interop hiccup just leaves the overlay unchanged.
    }
  }

  /// PROD-3109: push the hover boundary into the pre-installed hover source via
  /// `setData`. Lighter fill + line than the committed overlay; rendered beneath
  /// it (install order in [_installBoundaryOverlays] guarantees z-order). No-op
  /// until [_installBoundaryOverlays] has run.
  void _syncHoverOverlay() {
    final map = _map;
    if (map == null || !_mapLoaded) return;

    try {
      final source = map.getSource(_pickerHoverSourceId);
      if (source == null) return; // not yet installed

      final geometry = widget.hoverBoundaryGeoJson;
      if (geometry == null) {
        source.setData(
          <String, dynamic>{
                'type': 'FeatureCollection',
                'features': <Map<String, dynamic>>[],
              }.jsify()
              as JSObject,
        );
        return;
      }

      source.setData(
        <String, dynamic>{
              'type': 'FeatureCollection',
              'features': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'Feature',
                  'geometry': geometry,
                  'properties': <String, dynamic>{},
                },
              ],
            }.jsify()
            as JSObject,
      );
    } catch (_) {
      // A bad geometry / interop hiccup just leaves the overlay unchanged.
    }
  }

  /// Refresh the GeoJSON data on the existing source — cheap, no layer
  /// teardown. No-op if the source isn't installed yet (e.g. first
  /// `_renderMarkers` call before `_onMapLoaded` finishes).
  void _updateClusterSource() {
    if (_map == null) return;
    final source = _map!.getSource(_clusterSourceId);
    if (source == null) {
      // Map loaded but layers not yet installed — install them now.
      if (_mapLoaded && !_clusterLayersInstalled) {
        _installClusterSourceAndLayers();
      }
      return;
    }
    // Map page: keep the pins HIDDEN until the opening zoom-in settle finishes,
    // so we reveal a single final set (no mid-zoom swap). The pins are still
    // fetched during the zoom; they're just not drawn yet. The user-location dot
    // lives on a separate source and stays visible. See `_startOpenSettle`.
    if (widget.customSelection && !_openSettled) {
      source.setData(
        const <String, dynamic>{
              'type': 'FeatureCollection',
              'features': <dynamic>[],
            }.jsify()
            as JSObject,
      );
      return;
    }
    // Map page (revealed): animate newly-introduced pins; keep persisting pins put.
    if (widget.customSelection) {
      _renderPinsDiffAnimate(source);
      return;
    }
    // Every other consumer: plain render.
    source.setData(
      _markersAsFeatureCollectionMap(widget.markers).jsify() as JSObject,
    );
  }

  /// Build a Mapbox-shaped GeoJSON FeatureCollection from MapMarkers as
  /// a pure-Dart Map tree. Caller jsifies at the call site (so the
  /// whole spec — including the FeatureCollection — is jsified in one
  /// pass; nesting an already-jsified JSObject inside a Dart Map and
  /// re-jsifying the outer Map produced a broken `data` payload that
  /// Mapbox silently dropped, defeating clustering).
  ///
  /// Each feature carries `properties.id` (MapMarker.id), `item_type`
  /// (`place` / `event` / null — PROD-1993 wire vocabulary), `label`
  /// (letter text), and `color` (hex fallback when no category set).
  Map<String, dynamic> _markersAsFeatureCollectionMap(List<MapMarker> markers) {
    final features = <Map<String, dynamic>>[];
    final selectedId = widget.selectedMarkerId;
    final selectedIds = widget.selectedMarkerIds;
    for (final m in markers) {
      // User-location is rendered via its own path (DOM accuracy circle
      // for now). Skip it from the cluster source so we don't accidentally
      // cluster the user dot with venues / events.
      if (m.type == MapMarkerType.userLocation) continue;
      // PROD-2016 / PROD-2205: enlarged-radius hint for the unclustered
      // layer's `case` expression — stamped on the tooltip-target
      // marker AND on every marker in the consumer-supplied set
      // (multi-venue event highlight). Defaults to absent (treated as
      // false by Mapbox).
      final isSelected =
          (selectedId != null && m.id == selectedId) ||
          (selectedIds != null && selectedIds.contains(m.id));
      // PROD-2807: an overflow bubble (`overflowCount` set) is rendered by the
      // bubble layers, not as a pin — stamp `overflow_count` (+ a ready `+k`
      // label) and the event/place breakdown the bubble-colour expression
      // reads (event-only → green, venue-only → blue, mixed → pink).
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
          'overflow_terminal': m.overflowTerminal,
          'dim': m.dimmed,
          // PROD-2993 (D14): stacks grow with the pins while the results
          // highlight is on. Read by the `heyl-stack-<i>` layers' `icon-size`
          // (which coalesces a missing value to 1.0, so a 1.0 here is a no-op).
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
        props = <String, dynamic>{
          'id': m.id,
          if (m.category != null) 'item_type': m.category!.wire,
          if (m.label != null) 'label': m.label,
          if (m.color != null) 'color': _hexFromColor(m.color!),
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
          'dim': m.dimmed,
          // PROD-2989: faded once the item's detail sheet has been opened
          // this visit. Read with a `false` default by `viewedOpacityExpr`.
          'viewed': m.viewed,
          // PROD-2947 (FE-1): pool-relevance size multiplier (1.0 = baseline).
          // Bubbles omit it → `icon-size` coalesces to 1.0 (unchanged).
          'icon_scale': m.scoreSizeMul,
          // PROD-2947 (FE-1): caption placement priority (`symbol-sort-key`,
          // lower = wins). Higher-scored pins keep their caption on collision.
          'sort_key': m.captionSortKey,
        };
      }
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': <String, dynamic>{
          'type': 'Point',
          'coordinates': <double>[m.lng, m.lat],
        },
        'properties': props,
      });
    }
    return <String, dynamic>{'type': 'FeatureCollection', 'features': features};
  }

  /// Convert a Flutter [Color] to a `#RRGGBB` Mapbox-friendly hex.
  /// Strips the alpha channel (Mapbox circle-color takes the alpha
  /// via a separate `circle-opacity` paint property).
  static String _hexFromColor(Color c) {
    final argb = c.toARGB32();
    final rgb = argb & 0x00FFFFFF;
    final hex = rgb.toRadixString(16).padLeft(6, '0');
    return '#$hex';
  }

  /// PROD-2671: read the current camera + visible bounds and forward them
  /// to `widget.onCameraIdle` (settle-to-search). Best-effort — any
  /// interop hiccup is swallowed so a transient read can't crash the map.
  void _emitCameraIdle() {
    final cb = widget.onCameraIdle;
    if (cb == null) return;
    final cam = _readCameraState();
    if (cam != null) cb(cam);
  }

  /// PROD-2807 (#4): forward the live camera to `widget.onCameraMove` during a
  /// gesture, throttled to [_cameraMoveThrottleMs] (leading edge). The exact
  /// settled position is still delivered by `_emitCameraIdle` on `moveend`.
  void _emitCameraMove() {
    final cb = widget.onCameraMove;
    if (cb == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCameraMoveEmitMs < _cameraMoveThrottleMs) return;
    _lastCameraMoveEmitMs = now;
    final cam = _readCameraState();
    if (cam != null) cb(cam);
  }

  /// Read the current camera into a [MapCameraState]. Best-effort — any interop
  /// hiccup is swallowed (returns null) so a transient read can't crash the map.
  ///
  /// When viewport insets are set (Map page), the reported centre + corners
  /// describe the **visible rectangle** — the canvas minus the top-chrome and
  /// bottom-drawer strips — so the `/map/pins` query + pin selection cover only
  /// what the user actually sees. Every other surface (insets 0) keeps the
  /// original full-canvas `getBounds()` path.
  MapCameraState? _readCameraState() {
    final map = _map;
    if (map == null) return null;
    try {
      final top = widget.viewportPaddingTop;
      final bottom = widget.viewportPaddingBottom;
      if (top <= 0 && bottom <= 0) {
        // Full-canvas path — unchanged for every non-Map surface.
        final center = map.getCenter();
        final bounds = map.getBounds();
        final ne = bounds.getNorthEast();
        final sw = bounds.getSouthWest();
        return MapCameraState(
          centerLat: center.lat.toDouble(),
          centerLng: center.lng.toDouble(),
          zoom: map.getZoom().toDouble(),
          neLat: ne.lat.toDouble(),
          neLng: ne.lng.toDouble(),
          swLat: sw.lat.toDouble(),
          swLng: sw.lng.toDouble(),
        );
      }
      return _visibleRectCameraState(map, top, bottom);
    } catch (_) {
      return null;
    }
  }

  /// PROD-2671: the camera state for the **search rectangle** — the canvas with
  /// [top]/[bottom] logical-px chrome insets removed (the top bar + drawer that
  /// overlap the full-bleed map), then pulled further IN on all four sides by
  /// [kMapSearchAreaMarginFraction] so we don't fetch/select items hugging the
  /// screen border. Corners come from `unproject`-ing that pixel rect, so centre
  /// + NE/SW (and thus the derived radius) describe only the inner area. Assumes
  /// a north-up map (no bearing/pitch — the Map page never rotates), matching the
  /// existing NE/SW-only `getBounds()` contract.
  MapCameraState? _visibleRectCameraState(
    MapboxMap map,
    double top,
    double bottom,
  ) {
    final container = map.getContainer();
    final w = container.clientWidth.toDouble();
    final h = container.clientHeight.toDouble();
    if (w <= 0 || h <= 0) return null;
    // Clamp so a drawer/chrome taller than the canvas can't invert the rect.
    final usableTop = top.clamp(0.0, h - 1);
    final usableBottom = bottom.clamp(0.0, h - usableTop - 1);
    final visTop = usableTop;
    final visBottom = h - usableBottom;
    final visHeight = visBottom - visTop;
    // Pull IN from the visible edges by the margin (fraction of each dimension),
    // centred on the visible-area centre so only the extent shrinks.
    final marginX = w * kMapSearchAreaMarginFraction;
    final marginY = visHeight * kMapSearchAreaMarginFraction;
    final xLeft = marginX;
    final xRight = w - marginX;
    final yTop = visTop + marginY;
    final yBottom = visBottom - marginY;
    // Top-left pixel → NW corner (max lat, min lng); bottom-right → SE corner
    // (min lat, max lng). NE/SW compose from those.
    final topLeft = map.unproject(<double>[xLeft, yTop].jsify()! as JSArray);
    final bottomRight = map.unproject(
      <double>[xRight, yBottom].jsify()! as JSArray,
    );
    final centerPt = map.unproject(
      <double>[(xLeft + xRight) / 2, (yTop + yBottom) / 2].jsify()! as JSArray,
    );
    return MapCameraState(
      centerLat: centerPt.lat.toDouble(),
      centerLng: centerPt.lng.toDouble(),
      zoom: map.getZoom().toDouble(),
      neLat: topLeft.lat.toDouble(),
      neLng: bottomRight.lng.toDouble(),
      swLat: bottomRight.lat.toDouble(),
      swLng: topLeft.lng.toDouble(),
    );
  }

  /// PROD-2671: apply the persistent Mapbox camera padding from the viewport
  /// insets so the map centres + frames within the visible area (above the
  /// results drawer, below the top bar). `setPadding` fires `move`/`moveend`
  /// synchronously (it's a `jumpTo` under the hood), so we suppress our own
  /// move/idle callbacks around it — a padding change is not a user pan and must
  /// not cancel the in-flight fetch or emit a settle. No-op when no insets are
  /// set (every non-Map surface). Best-effort.
  void _applyViewportPadding() {
    final map = _map;
    if (map == null || !_mapLoaded) return;
    final top = widget.viewportPaddingTop;
    final bottom = widget.viewportPaddingBottom;
    if (top <= 0 && bottom <= 0) return;
    final prevSuppress = _suppressMoveCallback;
    _suppressMoveCallback = true;
    try {
      map.setPadding(
        <String, double>{
              'top': top,
              'bottom': bottom,
              'left': 0,
              'right': 0,
            }.jsify()
            as JSObject,
      );
    } catch (_) {
      // Padding is a nicety; a failure just leaves the camera unpadded.
    } finally {
      _suppressMoveCallback = prevSuppress;
    }
  }

  /// PROD-2671: load each category PNG from assets, decode to RGBA, and
  /// register it with Mapbox under its key via `addImage`. Bytes-based
  /// (not URL) so it's immune to Flutter-web asset-URL / base-href quirks
  /// and works headless. Best-effort per image — a failed pin is skipped.
  Future<void> _registerCategoryIcons() async {
    final map = _map;
    if (map == null) return;
    for (final entry in widget.categoryIconAssets.entries) {
      final key = entry.key;
      if (map.hasImage(key)) continue;
      try {
        final data = await rootBundle.load(entry.value);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        final image = frame.image;
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (rgba == null) continue;
        if (!mounted || _map == null) return;
        // Re-check after the awaits — a rebuild may have registered it.
        if (_map!.hasImage(key)) continue;
        _map!.addImage(
          key,
          MapboxStyleImage(
            width: image.width,
            height: image.height,
            data: rgba.buffer.asUint8List().toJS,
          ),
        );
      } catch (_) {
        // Skip a pin that fails to load/decode; the rest still register.
      }
    }
    // Repaint so the symbol layer picks up the freshly-registered images.
    _map?.triggerRepaint();
  }

  @override
  void dispose() {
    // PROD-3833: stamp the teardown so the NEXT map on this page waits out the
    // WebGL cleanup window — and only that map. See [_pendingContextCleanupWait].
    _lastDisposedAt = DateTime.now();
    WidgetsBinding.instance.removeObserver(this);
    _resizeDebounce?.cancel();
    _pendingTooltipShow?.cancel();
    _revealTimer?.cancel();
    _dotRemovalTimer?.cancel();

    if (_visibilityCallback != null) {
      web.document.removeEventListener(
        'visibilitychange',
        _visibilityCallback!,
      );
      _visibilityCallback = null;
    }

    if (_cameraMoveCallback != null) {
      _map?.off('move', _cameraMoveCallback!);
      _cameraMoveCallback = null;
    }

    if (_cameraIdleCallback != null) {
      _map?.off('moveend', _cameraIdleCallback!);
      _cameraIdleCallback = null;
    }

    // PROD-4104: normally cleared by [_completeOpenSettle]; this covers a map
    // torn down while the opening ease is still running.
    if (_openSettleMoveEndCb != null) {
      _map?.off('moveend', _openSettleMoveEndCb!);
      _openSettleMoveEndCb = null;
    }

    if (_moveEndCallback != null) {
      _map?.off('moveend', _moveEndCallback!);
      _map?.off('move', _moveEndCallback!);
      _moveEndCallback = null;
    }

    if (_compositeIdleCb != null) {
      _map?.off('idle', _compositeIdleCb!);
      _compositeIdleCb = null;
    }

    if (_moveStartAnimCb != null) {
      _map?.off('movestart', _moveStartAnimCb!);
      _moveStartAnimCb = null;
    }
    if (_moveEndAnimCb != null) {
      _map?.off('moveend', _moveEndAnimCb!);
      _moveEndAnimCb = null;
    }

    if (_cursorMoveCallback != null) {
      _container?.removeEventListener('mousemove', _cursorMoveCallback!);
      _cursorMoveCallback = null;
    }

    // PROD-1978: detach cluster layer click + hover listeners. Done
    // BEFORE map.remove() so the layer ids are still valid.
    if (_map != null && _clusterLayersInstalled) {
      if (_clusterClickCb != null) {
        _map!.offLayer('click', _clusterLayerId, _clusterClickCb!);
        _clusterClickCb = null;
      }
      if (_unclusteredClickCb != null) {
        _map!.offLayer('click', _unclusteredLayerId, _unclusteredClickCb!);
        _unclusteredClickCb = null;
      }
      if (_mapWideClickCb != null) {
        _map!.off('click', _mapWideClickCb!);
        _mapWideClickCb = null;
      }
      if (_moveStartCb != null) {
        _map?.off('movestart', _moveStartCb!);
        _moveStartCb = null;
      }
      if (_moveEndCb != null) {
        _map?.off('moveend', _moveEndCb!);
        _moveEndCb = null;
      }
      if (_hoverMoveCb != null) {
        _map?.off('mousemove', _hoverMoveCb!);
        _hoverMoveCb = null;
      }
      if (_hoverOutCb != null) {
        _map?.off('mouseout', _hoverOutCb!);
        _hoverOutCb = null;
      }
      // PROD-3828: this teardown MIRRORS the registration above — the icon
      // layer now carries `_unclusteredHoverEnterCb` (not `_hoverEnterCb`)
      // under `categoryIcons`, and the caption layer is only bound when
      // captions are on. `offLayer` with a listener that was never added is a
      // silent no-op in GL JS, but keeping the two in lock-step is what stops
      // a listener surviving a style reload.
      if (_hoverEnterCb != null) {
        _map!.offLayer('mouseenter', _clusterLayerId, _hoverEnterCb!);
        if (widget.categoryIcons) {
          if (widget.showPinCaptions) {
            _map!.offLayer(
              'mouseenter',
              _unclusteredCaptionLayerId,
              _hoverEnterCb!,
            );
          }
          _map!.offLayer('mouseenter', _clusterCountLayerId, _hoverEnterCb!);
        }
        _hoverEnterCb = null;
      }
      if (_hoverLeaveCb != null) {
        _map!.offLayer('mouseleave', _clusterLayerId, _hoverLeaveCb!);
        if (widget.categoryIcons) {
          if (widget.showPinCaptions) {
            _map!.offLayer(
              'mouseleave',
              _unclusteredCaptionLayerId,
              _hoverLeaveCb!,
            );
          }
          _map!.offLayer('mouseleave', _clusterCountLayerId, _hoverLeaveCb!);
        }
        _hoverLeaveCb = null;
      }
      if (_unclusteredHoverEnterCb != null) {
        _map!.offLayer(
          'mouseenter',
          widget.categoryIcons ? _unclusteredIconLayerId : _unclusteredLayerId,
          _unclusteredHoverEnterCb!,
        );
        _unclusteredHoverEnterCb = null;
      }
      if (_unclusteredHoverLeaveCb != null) {
        _map!.offLayer(
          'mouseleave',
          widget.categoryIcons ? _unclusteredIconLayerId : _unclusteredLayerId,
          _unclusteredHoverLeaveCb!,
        );
        _unclusteredHoverLeaveCb = null;
      }
    }
    _clusterLayersInstalled = false;

    // PROD-595: Full WebGL cleanup to release GPU memory
    // This is critical for preventing memory crashes when switching between maps
    if (_map != null) {
      // Explicitly release WebGL context BEFORE map.remove()
      // Without this, GPU memory may not be released until garbage collection
      forceReleaseWebGLContext(_map!);
      _map!.remove();
      _map = null;
      // Clear Mapbox global caches (tiles, glyphs, sprites)
      clearMapboxGlobalCaches();
      debugPrint('[MapboxMapPlatform] WebGL context destroyed in dispose()');
      _mapBreadcrumb('Map disposed (WebGL released)');
    }

    // DOM cleanup — remove container + canvas to release GPU resources.
    // PROD-2016: the legacy `_markersContainer` + per-marker DOM
    // elements were removed; the cluster source-layer path renders
    // on the WebGL canvas which `map.remove()` already tears down.
    if (_container != null) {
      while (_container!.firstChild != null) {
        _container!.removeChild(_container!.firstChild!);
      }
      _container!.parentElement?.removeChild(_container!);
      _container = null;
      debugPrint('[MapboxMapPlatform] Container removed from DOM in dispose()');
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Show loading placeholder while Mapbox JS loads
    if (!_mapboxReady) {
      return _buildLoadingPlaceholder();
    }

    // Show error state if Mapbox failed to load
    if (_mapboxLoadFailed) {
      return _buildErrorPlaceholder();
    }

    // PROD-1978 Phase 4: when the map is interactive, we have to
    // isolate it from the host scroll view on two separate event
    // pipelines that Flutter handles independently:
    //
    //   1. Pointer events (drag): `RawGestureDetector` with an
    //      `EagerGestureRecognizer` claims the gesture arena, so the
    //      ancestor scrollable doesn't compete with the map's drag
    //      and pan the page underneath.
    //
    //   2. Pointer signal events (mouse wheel, trackpad scroll):
    //      these don't go through the gesture arena. They fire as
    //      `PointerSignalEvent`s and bubble up the widget tree to
    //      whoever calls `pointerSignalResolver.register(...)`. The
    //      inner `Listener` registers an empty consumer so the
    //      ancestor scroll view doesn't also receive the wheel
    //      and scroll the page while the user is zooming the map.
    //      Mapbox's own DOM `wheel` listener handles the zoom
    //      independently (it runs at the browser level, not Flutter).
    //
    // Static-mode (`!widget.interactive`) doesn't wrap — pointers
    // and wheel events fall through to the page as the user expects.
    final view = HtmlElementView(viewType: _viewId);
    if (!widget.interactive) {
      return view;
    }
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              () => EagerGestureRecognizer(),
              (recognizer) {},
            ),
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            // Claim the wheel/trackpad scroll so an ancestor
            // ScrollView doesn't also handle it. The callback is a
            // no-op — Mapbox handles the actual zoom via its DOM
            // `wheel` listener on the canvas.
            GestureBinding.instance.pointerSignalResolver.register(
              event,
              (_) {},
            );
          }
        },
        child: view,
      ),
    );
  }

  /// Loading placeholder shown while Mapbox JS downloads
  Widget _buildLoadingPlaceholder() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? AppColors.backgroundDark : AppColors.background,
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(
              isDark ? Colors.white38 : AppColors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }

  /// Error placeholder shown if Mapbox fails to load
  Widget _buildErrorPlaceholder() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark ? AppColors.backgroundDark : AppColors.background,
    );
  }
}
