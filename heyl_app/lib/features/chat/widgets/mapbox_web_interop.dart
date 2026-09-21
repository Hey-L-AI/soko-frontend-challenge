@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Load Mapbox GL JS dynamically (returns a Promise)
@JS('loadMapbox')
external JSPromise _loadMapboxJs();

/// Check if Mapbox is already loaded
@JS('isMapboxLoaded')
external bool isMapboxLoaded();

/// Dart-friendly wrapper to load Mapbox on demand
/// Returns a Future that completes when Mapbox is ready to use
Future<void> loadMapbox() {
  return _loadMapboxJs().toDart;
}

/// Set Mapbox access token
@JS('mapboxgl.accessToken')
external set mapboxAccessToken(String token);

/// PROD-595: Memory optimization settings
/// Reduce concurrent tile requests (default is 16)
@JS('mapboxgl.maxParallelImageRequests')
external set maxParallelImageRequests(int value);

/// Reduce web worker count (default is 4)
@JS('mapboxgl.workerCount')
external set workerCount(int value);

/// Apply memory optimization settings - call once before creating any maps
void applyMemoryOptimizations() {
  maxParallelImageRequests = 4; // Reduce from 16 to 4
  workerCount = 2; // Reduce from 4 to 2
  web.console.log(
    '[Mapbox] Memory optimizations applied: maxParallelImageRequests=4, workerCount=2'
        .toJS,
  );
}

/// Mapbox GL Map class
@JS('mapboxgl.Map')
extension type MapboxMap._(JSObject _) implements JSObject {
  external factory MapboxMap(JSObject options);

  external void on(String event, JSFunction callback);
  // Layer-scoped event subscription: `on(event, layerId, callback)` filters
  // events to those that hit the named layer (PROD-1978 cluster click).
  @JS('on')
  external void onLayer(String event, String layerId, JSFunction callback);
  external void once(String event, JSFunction callback);
  external void off(String event, JSFunction callback);
  // Layer-scoped off (mirrors `onLayer`) — required to detach the listener
  // in dispose() without leaking JSFunction refs.
  @JS('off')
  external void offLayer(String event, String layerId, JSFunction callback);
  external void setFog(JSObject fog);
  external void setStyle(String style);
  external void setBearing(num bearing);
  external num getBearing();
  external void flyTo(JSObject options);
  external void easeTo(JSObject options);
  external void fitBounds(JSArray bounds, JSObject? options);
  external void setCenter(JSArray center);
  external void setZoom(num zoom);
  external num getZoom();
  // PROD-2671: Mapbox returns a `LngLat` object (with `.lng`/`.lat`), not
  // an array — re-typed from the prior (unused) JSArray declaration.
  external MapboxLngLat getCenter();
  // PROD-2671: visible viewport bounds — used to derive a settle-to-search
  // radius on the Map page.
  external MapboxLngLatBounds getBounds();
  external MapboxPoint project(JSArray lngLat);
  // Mapbox returns a `LngLat` (`.lng`/`.lat`), not an array — re-typed from the
  // prior (unused) JSArray declaration so callers can read the coordinates.
  // PROD-2671: the Map page unprojects the VISIBLE-rect pixel corners (canvas
  // minus the top-chrome + bottom-drawer chrome) to derive the search area.
  external MapboxLngLat unproject(JSArray point);
  // PROD-2671: persistent camera padding (px) so the Map page centres + frames
  // within the visible area (above the results drawer, below the top bar).
  external void setPadding(JSObject padding);
  external web.HTMLElement getContainer();
  external web.HTMLElement getCanvasContainer();
  external void resize();
  external void remove();
  external bool loaded();
  external void triggerRepaint();

  // Source + layer management (PROD-1978 clustering).
  //
  // `getSource(id)` is typed as `MapboxGeoJsonSource?` because every
  // source we ever add in this widget is a GeoJSON source — the return
  // value of `map.getSource('heyl-pins')` in Mapbox GL JS IS the
  // `GeoJSONSource` instance with `setData` / `getClusterExpansionZoom`
  // directly callable on it. (Earlier draft declared a separate
  // `getGeoJsonSource` method that doesn't exist on the JS side and
  // threw `getGeoJsonSource is not a function` at runtime.)
  external void addSource(String id, JSObject source);
  external void removeSource(String id);
  external MapboxGeoJsonSource? getSource(String id);
  external void addLayer(JSObject layer);
  external void removeLayer(String id);
  external JSObject? getLayer(String id);
  external JSArray queryRenderedFeatures(
    JSObject pointOrBbox,
    JSObject? options,
  );
  external void setLayoutProperty(String layerId, String name, JSAny? value);
  external void setPaintProperty(String layerId, String name, JSAny? value);
  external bool hasImage(String id);
  external void loadImage(String url, JSFunction callback);
  external void addImage(String id, JSObject image);

  // PROD-1978 Phase 4: gesture handler sub-objects. Each has
  // `.enable()` / `.disable()` so we can flip interactivity at
  // runtime without re-creating the map. Mapbox bakes the `interactive`
  // option at map-init time, so prop-change-driven toggling has to
  // route through these sub-objects.
  external MapboxHandler get scrollZoom;
  external MapboxHandler get dragPan;
  external MapboxHandler get touchZoomRotate;
  external MapboxHandler get doubleClickZoom;
  external MapboxHandler get boxZoom;
  external MapboxHandler get dragRotate;
  external MapboxHandler get keyboard;
}

/// Generic Mapbox gesture handler — exposes the `.enable()` / `.disable()`
/// pair common to scrollZoom, dragPan, touchZoomRotate, etc. PROD-1978.
extension type MapboxHandler._(JSObject _) implements JSObject {
  external void enable();
  external void disable();
  external bool isEnabled();
}

/// Mapbox GL GeoJsonSource wrapper. Returned by `getGeoJsonSource(id)` so
/// we can mutate features in-place via `setData` and query cluster
/// expansion zoom on cluster taps (PROD-1978).
extension type MapboxGeoJsonSource._(JSObject _) implements JSObject {
  external void setData(JSObject geojson);

  /// `getClusterExpansionZoom(clusterId, callback)` — invokes the callback
  /// with `(error, zoom)` where zoom is the smallest zoom at which the
  /// cluster expands. We pass a Dart closure as JSFunction.
  external void getClusterExpansionZoom(num clusterId, JSFunction callback);

  /// `getClusterChildren(clusterId, callback)` — returns the immediate
  /// child features of a cluster (mix of sub-clusters and leaf features).
  /// Reserved for future use; not called in Phase 1.
  external void getClusterChildren(num clusterId, JSFunction callback);

  /// `getClusterLeaves(clusterId, limit, offset, callback)` — returns
  /// the leaf features inside a cluster, paginated.
  external void getClusterLeaves(
    num clusterId,
    num limit,
    num offset,
    JSFunction callback,
  );
}

/// Mapbox click/touch event payload — minimal interop, just the bits we
/// need for Phase 1 cluster handling.
extension type MapboxMapMouseEvent._(JSObject _) implements JSObject {
  external MapboxPoint get point;
  // Mapbox GL fires a `LngLat` object (`.lng`/`.lat`), not an array (PROD-3109).
  external MapboxLngLat get lngLat;
  external JSArray? get features;
}

/// Single feature from `queryRenderedFeatures` / `evt.features`.
extension type MapboxFeature._(JSObject _) implements JSObject {
  external JSObject get geometry;
  external JSObject get properties;
  external String? get layer; // when present
}

/// Mapbox GL Point class (returned by project)
extension type MapboxPoint._(JSObject _) implements JSObject {
  external num get x;
  external num get y;
}

/// Mapbox GL LngLatBounds class
@JS('mapboxgl.LngLatBounds')
extension type MapboxLngLatBounds._(JSObject _) implements JSObject {
  external factory MapboxLngLatBounds(JSArray? sw, JSArray? ne);

  external MapboxLngLatBounds extend(JSArray lngLat);
  // PROD-2671: re-typed from JSArray — these return `LngLat` objects.
  external MapboxLngLat getSouthWest();
  external MapboxLngLat getNorthEast();
  external JSArray toArray();
}

/// Mapbox GL `LngLat` — returned by `map.getCenter()` and
/// `LngLatBounds.get{North,South}{East,West}`. Has `.lng`/`.lat` num
/// getters (PROD-2671).
extension type MapboxLngLat._(JSObject _) implements JSObject {
  external num get lng;
  external num get lat;
}

/// PROD-2671: a raw RGBA style image for `map.addImage(id, {width, height,
/// data})`. Mapbox accepts a plain object with these three fields; the
/// named-param external factory creates that JS object literal directly
/// (avoids the nested-`jsify` pitfall that drops typed-array values).
extension type MapboxStyleImage._(JSObject _) implements JSObject {
  external factory MapboxStyleImage({
    required int width,
    required int height,
    required JSUint8Array data,
  });
}

/// Create map options object
/// PROD-595: Added memory optimization options (maxZoom, antialias, fadeDuration)
JSObject createMapOptions({
  required web.HTMLElement container,
  required String style,
  required double lng,
  required double lat,
  required double zoom,
  required double pitch,
  required double bearing,
  bool interactive = true,
  bool scrollZoom = true,
  bool dragPan = true,
  bool dragRotate = true,
  bool doubleClickZoom = false,
  bool touchZoomRotate = true,
  bool attributionControl = false,
  bool logoPosition = false,
  // PROD-595: Memory optimization options
  double? maxZoom, // Limit max zoom to reduce tile memory
  double? minZoom,
  bool antialias = false, // Disable antialiasing to save framebuffer memory
  int fadeDuration = 0, // Disable fade transitions to reduce overhead
  // PROD-2671: retain the WebGL drawing buffer. Default false (PROD-595 memory
  // win for thumbnail maps). The Map page sets true: with it false the buffer
  // is cleared after each composite, so a static open leaves the first pins
  // painted-but-unpresented until an interaction redraws the buffer — the
  // canonical Mapbox "blank canvas" bug. Retaining it lets the on-idle re-slot
  // reliably present the pins.
  bool preserveDrawingBuffer = false,
}) {
  final options = <String, dynamic>{
    'container': container,
    'style': style,
    'center': [lng, lat].jsify(),
    'zoom': zoom,
    'pitch': pitch,
    'bearing': bearing,
    'interactive': interactive,
    'scrollZoom': scrollZoom,
    'dragPan': dragPan,
    'dragRotate': dragRotate,
    'doubleClickZoom': doubleClickZoom,
    'touchZoomRotate': touchZoomRotate,
    'attributionControl': attributionControl,
    'antialias': antialias,
    'fadeDuration': fadeDuration,
    'trackResize': false, // Manual resize control for better performance
    'preserveDrawingBuffer': preserveDrawingBuffer,
  };

  if (maxZoom != null) {
    options['maxZoom'] = maxZoom;
  }
  if (minZoom != null) {
    options['minZoom'] = minZoom;
  }

  return options.jsify() as JSObject;
}

/// Create fog options for dark mode
JSObject createDarkFog() {
  return {
        'color': 'rgb(20, 20, 30)',
        'high-color': 'rgb(30, 30, 50)',
        'horizon-blend': 0.1,
      }.jsify()
      as JSObject;
}

/// Create fog options for light mode
JSObject createLightFog() {
  return {
        'color': 'rgb(240, 240, 245)',
        'high-color': 'rgb(200, 200, 220)',
        'horizon-blend': 0.1,
      }.jsify()
      as JSObject;
}

/// Create flyTo options
JSObject createFlyToOptions({
  required double lng,
  required double lat,
  required double zoom,
  double pitch = 45,
  double bearing = -17.6,
  int duration = 2000,
}) {
  return {
        'center': [lng, lat].jsify(),
        'zoom': zoom,
        'pitch': pitch,
        'bearing': bearing,
        'duration': duration,
        'essential':
            true, // Animation will happen even if user prefers reduced motion
      }.jsify()
      as JSObject;
}

/// Create easeTo options (simpler animation)
JSObject createEaseToOptions({
  required double lng,
  required double lat,
  double? zoom,
  double pitch = 0,
  double bearing = 0,
  int duration = 500,
}) {
  final options = <String, dynamic>{
    'center': [lng, lat].jsify(),
    'pitch': pitch,
    'bearing': bearing,
    'duration': duration,
    'essential': true,
  };
  if (zoom != null) {
    options['zoom'] = zoom;
  }
  return options.jsify() as JSObject;
}

/// Create fitBounds options
JSObject createFitBoundsOptions({
  int padding = 50,
  int? paddingTop,
  int? paddingBottom,
  int? paddingLeft,
  int? paddingRight,
  double? maxZoom,
  int duration = 500,
}) {
  final options = <String, dynamic>{'duration': duration, 'essential': true};

  // Use individual padding if specified, otherwise use uniform padding
  if (paddingTop != null ||
      paddingBottom != null ||
      paddingLeft != null ||
      paddingRight != null) {
    options['padding'] = {
      'top': paddingTop ?? padding,
      'bottom': paddingBottom ?? padding,
      'left': paddingLeft ?? padding,
      'right': paddingRight ?? padding,
    };
  } else {
    options['padding'] = padding;
  }

  if (maxZoom != null) {
    options['maxZoom'] = maxZoom;
  }

  return options.jsify() as JSObject;
}

/// Create bounds array from list of coordinates
/// Returns [[west, south], [east, north]]
JSArray createBoundsFromCoordinates(List<List<double>> coordinates) {
  if (coordinates.isEmpty) {
    throw ArgumentError('coordinates cannot be empty');
  }

  double west = coordinates[0][0];
  double east = coordinates[0][0];
  double south = coordinates[0][1];
  double north = coordinates[0][1];

  for (final coord in coordinates) {
    final lng = coord[0];
    final lat = coord[1];
    if (lng < west) west = lng;
    if (lng > east) east = lng;
    if (lat < south) south = lat;
    if (lat > north) north = lat;
  }

  return [
        [west, south].jsify(),
        [east, north].jsify(),
      ].jsify()
      as JSArray;
}

/// Convert a single coordinate to JSArray [lng, lat]
JSArray coordToJsArray(double lng, double lat) {
  return [lng, lat].jsify() as JSArray;
}

/// JS interop for WebGL context extension
@JS('WEBGL_lose_context')
extension type WebGLLoseContext._(JSObject _) implements JSObject {
  external void loseContext();
  external void restoreContext();
}

/// JS interop for WebGL rendering context
extension type WebGLContext._(JSObject _) implements JSObject {
  external WebGLLoseContext? getExtension(String name);
}

/// JS interop for clearStorage on mapboxgl
@JS('mapboxgl.clearStorage')
external void _mapboxClearStorage();

/// JS interop to check if clearStorage exists
@JS('mapboxgl.clearStorage')
external JSFunction? get _mapboxClearStorageFunc;

/// PROD-595: Force release WebGL context before map removal
/// This explicitly tells the browser to free GPU memory immediately
/// Without this, GPU memory may not be released until garbage collection
void forceReleaseWebGLContext(MapboxMap map) {
  try {
    final canvasContainer = map.getCanvasContainer();
    final canvas =
        canvasContainer.querySelector('canvas') as web.HTMLCanvasElement?;
    if (canvas != null) {
      // Try WebGL2 first, then WebGL1
      final gl2 = canvas.getContext('webgl2');
      final gl1 = canvas.getContext('webgl');
      final glContext = gl2 ?? gl1;

      if (glContext != null) {
        // Cast to our WebGLContext type and get the lose_context extension
        final gl = glContext as WebGLContext;
        final ext = gl.getExtension('WEBGL_lose_context');
        if (ext != null) {
          ext.loseContext();
          web.console.log(
            '[Mapbox] WebGL context explicitly released via WEBGL_lose_context'
                .toJS,
          );
        } else {
          web.console.log(
            '[Mapbox] WEBGL_lose_context extension not available'.toJS,
          );
        }
      }
    }
  } catch (e) {
    web.console.log('[Mapbox] Error releasing WebGL context: $e'.toJS);
  }
}

/// PROD-595: Clear Mapbox global caches to free memory
/// Mapbox maintains global caches for tiles, glyphs, sprites that persist after map.remove()
void clearMapboxGlobalCaches() {
  try {
    // Check if clearStorage function exists before calling
    if (_mapboxClearStorageFunc != null) {
      _mapboxClearStorage();
      web.console.log('[Mapbox] Global storage/tile cache cleared'.toJS);
    } else {
      web.console.log(
        '[Mapbox] clearStorage not available in this Mapbox version'.toJS,
      );
    }
  } catch (e) {
    web.console.log('[Mapbox] Error clearing global caches: $e'.toJS);
  }
}
