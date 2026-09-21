import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../core/services/location_service.dart';
import '../../core/services/unified_analytics_service.dart';
import '../../core/theme/app_colors.dart';
import '../../features/chat/widgets/approximate_location_badge.dart';
import '../../features/chat/widgets/enable_location_badge.dart';
import '../../features/chat/widgets/location_sharing_banner.dart';
import '../../features/map/utils/picker_map_math.dart';
import '../../l10n/generated/l10n.dart';
import '../../data/models/map_debug.dart';
import '../../providers/location_provider.dart';
import '../utils/map_debug_overlay.dart' show MapDebugShape;
import '../utils/map_zoom_level.dart';
import 'browser_instructions_sheet.dart';
import 'bt_sq_ico.dart';
import 'clickable.dart';
import 'map_marker_model.dart';
import 'soko_tag.dart';

// Conditional import for platform-specific implementations
import 'mapbox_map_stub.dart'
    if (dart.library.js_interop) 'mapbox_map_web.dart'
    if (dart.library.io) 'mapbox_map_native.dart';

export 'map_marker_model.dart';

/// PROD-2042 Wave 2: style for the location-status banner that the
/// widget can render internally (when `showLocationStatusBanners` is
/// on). `compact` = pill (~28 px) for inline previews; `fullWidth` =
/// banner (~64 px) for full-screen surfaces like the places modal.
enum LocationBannerStyle { compact, fullWidth }

/// Which edge of the map the location-status banner is anchored to.
///
/// `bottom` is the historic behaviour (and what every full-bleed map wants —
/// the banner sits above whatever chrome the host has down there). `top` exists
/// for the location-scope sheet, whose map card already spends its bottom row
/// on the centred selected-place chip: at that card's width the two overlap by
/// ~50 px on a phone, so the banner has to move to the free corner.
enum LocationBannerAnchor { bottom, top }

/// Resolves a location-status banner's vertical `Positioned` edges.
///
/// Exactly one of the two is non-null, always: a `Positioned` given both a top
/// and a bottom is *stretched* between them, so a host that passes a full
/// `EdgeInsets` (which every `EdgeInsets.fromLTRB` is) would otherwise get a
/// banner as tall as the map instead of one pinned to an edge.
({double? top, double? bottom}) locationBannerEdges({
  required EdgeInsets inset,
  required LocationBannerAnchor anchor,
}) => switch (anchor) {
  LocationBannerAnchor.top => (top: inset.top, bottom: null),
  LocationBannerAnchor.bottom => (top: null, bottom: inset.bottom),
};

/// Cross-platform Mapbox map widget. Wraps `MapboxMapPlatform` (web or
/// native) with shared overlay chrome — activation chip (static-by-
/// default mode), and an anchored pin tooltip (PROD-2016).
///
/// **Tooltip flow** (when enabled): tapping a pin sets the
/// shell-internal `_selected` + `_selectedPixel` state, the tooltip
/// renders next to the pin, the user clicks "View details" → the host
/// page's `onViewDetails(marker)` callback navigates. Hover-to-show on
/// web is layered on top in PROD-2016 commit 4.
///
/// **Legacy `onMarkerTap`**: still fires whenever a pin is tapped, for
/// consumers that need a side-effect (e.g. `places_map_modal` syncing
/// a card carousel). The tooltip and the legacy callback are
/// independent — both fire when both are configured.
class MapboxMapWidget extends ConsumerStatefulWidget {
  /// List of markers to display on the map
  final List<MapMarker> markers;

  /// When set, renders the user-location blue dot at this point, on a dedicated
  /// layer independent of [markers]. The picker uses this so toggling the dot's
  /// visibility never re-triggers marker/bounds fitting. Null → no dot.
  final ({double lat, double lng})? userDotLatLng;

  /// When set, renders the map-location-picker's center-of-search pin (the
  /// Soko teardrop, `assets/pins/pin-search.png`) at this point on a dedicated
  /// symbol layer, independent of [markers]. Mirrors [userDotLatLng]: a single
  /// static overlay that never touches the cluster/category-pin machinery.
  /// Null → no picker pin. Picker only.
  final ({double lat, double lng})? pickerPinLatLng;

  /// req3: when set (picker mode), the my-location button toggles fit-both ↔
  /// zoom-user, framing this anchor (the search pin) together with the user
  /// location on the first press and zooming to the user on the next. Null →
  /// the default PROD-3124 center-then-zoom behaviour.
  final ({double lat, double lng})? recenterAnchor;

  /// req3: a monotonic key that changes only on a *semantic* selection change
  /// (a new tap/search/clear), NOT on camera drift. Bumping it restarts the
  /// recenter toggle at fit-both so the next press frames the new selection —
  /// keyed on this rather than [recenterAnchor] because the unselected anchor
  /// tracks the camera and would otherwise reset on the recenter's own pan.
  final int recenterResetKey;

  /// Center latitude (optional, overridden if fitMarkers is true)
  final double? centerLat;

  /// Center longitude (optional, overridden if fitMarkers is true)
  final double? centerLng;

  /// Initial zoom level
  final double zoom;

  /// Whether to fit the map bounds to all markers
  final bool fitMarkers;

  /// Legacy callback when a marker is tapped — fires on every pin tap
  /// alongside the tooltip flow. Use this only for non-tooltip side
  /// effects (card carousel sync, custom camera focus). Most
  /// consumers should leave this null and use [onViewDetails].
  final OnMarkerTap? onMarkerTap;

  /// Whether the map allows user interaction (pan, zoom)
  final bool interactive;

  /// Configuration for bounds fitting
  final MapBoundsConfig? boundsConfig;

  /// Callback when the map is ready
  final VoidCallback? onMapReady;

  /// Callback when the map is moved (pan or zoom)
  final VoidCallback? onMapMoved;

  /// PROD-2671: fires when the user taps the map canvas away from any pin —
  /// forwarded from the platform's tap-outside (alongside the internal tooltip
  /// dismissal). The Map page uses it to close an open filter drawer on a map
  /// tap, matching the pan/zoom dismissal.
  final VoidCallback? onMapTapOutside;

  /// PROD-3109: fires on every canvas tap with the tapped geographic
  /// coordinate `(lat, lng)`. Used by the map location picker to resolve the
  /// tapped neighborhood; null everywhere else. Forwarded straight to the
  /// platform (distinct from [onMapTapOutside], which carries no coordinate).
  final void Function(double lat, double lng)? onMapTapLatLng;

  /// PROD-3109: GeoJSON geometry (MultiPolygon) of the selected neighborhood to
  /// outline on the map. Null clears it. Takes precedence over [highlightPoint].
  ///
  /// Redraw is identity-based (`identical`): pass a **new** map instance per
  /// selection — mutating the same map in place will not trigger a redraw.
  final Map<String, dynamic>? highlightBoundaryGeoJson;

  /// Picker drill-down: a GeoJSON FeatureCollection of a selected city's child
  /// neighbourhoods, drawn as a light tappable layer beneath
  /// [highlightBoundaryGeoJson]. Null/empty clears it. Tap hit-testing happens
  /// in Dart (via [onMapTapLatLng]); this layer is display only. Redraw is
  /// identity-based — pass a **new** map instance when the children change.
  final Map<String, dynamic>? childBoundariesGeoJson;

  /// PROD-3109: fires on every canvas hover with the hovered geographic
  /// coordinate `(lat, lng)`. Web-only (desktop pointer); null on native/stub.
  final void Function(double lat, double lng)? onMapHoverLatLng;

  /// PROD-3109: fires when the pointer leaves the map canvas. Web-only
  /// (desktop pointer); null on native/stub.
  final VoidCallback? onMapHoverExit;

  /// PROD-3109: GeoJSON geometry (MultiPolygon) of the neighborhood under the
  /// hover cursor to outline as a preview. Null clears it. Web-only.
  final Map<String, dynamic>? hoverBoundaryGeoJson;

  /// PROD-3109: fallback highlight (small circle) when no boundary polygon is
  /// available. Ignored when [highlightBoundaryGeoJson] is set.
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

  /// Whether to use dark mode styling
  final bool isDark;

  /// PROD-595: Enable memory optimizations for small/thumbnail maps
  /// When true: uses lower maxZoom (14), skips fog effect, reduces memory footprint
  final bool optimizeForSmallSize;

  /// Optional max zoom-in override. Null → the web default cap (14 small /
  /// 16 full, PROD-595); native is uncapped when null. PROD-3001: honoured on
  /// BOTH renderers now (web map-init option; native
  /// `setBounds(CameraBoundsOptions(maxZoom:))`). The Map page passes **20**
  /// — capped identically on web + native (decision 2026-07-10: no user
  /// benefit past ~20).
  final double? maxZoom;

  /// Web-only: override cursor in overlay zones to prevent Mapbox grab cursor
  /// from bleeding through to Flutter widgets (buttons, drawers, banners).
  final MapCursorOverride? cursorOverride;

  /// PROD-1978 opt-in: render markers via a Mapbox GeoJSON source layer
  /// with clustering, instead of per-pin DOM elements.
  final bool cluster;

  /// PROD-1978 Phase 4: ship the map in non-interactive mode by
  /// default and expose a tap-to-activate chip. When the user taps
  /// the activation button, the map becomes fully interactive;
  /// tapping the "lock" chip returns it to non-interactive.
  final bool staticByDefault;

  /// Fires when the static-toggle activates/deactivates. Used by
  /// hosts to conditionally show their own overlay controls only
  /// while the map is unlocked. Ignored when [staticByDefault] is false.
  final ValueChanged<bool>? onInteractiveChanged;

  /// Increment to imperatively re-fit the camera. Any change to this
  /// value triggers a fit — independent of [fitMarkers]'s edge.
  final int fitToMarkersToken;

  /// PROD-2993: fires ONLY when the **user** drives the camera (a drag, a wheel
  /// or pinch zoom) — never for our own programmatic camera moves.
  ///
  /// [onMapMoved] cannot tell the two apart, and neither can a timing heuristic:
  /// the one case it must get right is the user grabbing the map *during* one of
  /// our animations, which is precisely when a time window says "that was us".
  /// Both platforms expose a genuine gesture signal, so this forwards it.
  final VoidCallback? onUserGesture;

  /// Increment to imperatively ease the camera to the current
  /// [centerLat]/[centerLng]/[zoom] — **even when those values haven't
  /// changed**.
  ///
  /// This is the counterpart to [fitToMarkersToken], and it exists for the same
  /// reason (see `docs/learnings/mapbox-imperative-tokens-fit-vs-center.md`):
  /// the platform decides whether to move the camera by **value-diffing props**,
  /// so an intent that happens to target the position the props already name is
  /// silently dropped. Restoring a camera snapshot is exactly that case — the
  /// user may well be back where they started.
  ///
  /// Internally OR-ed with the my-location button's own counter; the two are
  /// independent intents that happen to share the same "ease to centre" branch.
  final int centerToToken;

  /// PROD-2016: enable the anchored pin tooltip. When `true` AND
  /// [tooltipContentResolver] is non-null, tapping a pin opens a
  /// tooltip next to it with the resolved content + a "View details"
  /// button (routed via [onViewDetails]). Cluster taps are unaffected
  /// — they still zoom in.
  final bool enableTooltip;

  /// Resolves the per-marker tooltip content (title + subtitle).
  /// Returning null hides the tooltip for that specific marker.
  /// Required for the tooltip to show; pair with [onViewDetails].
  final MapPinTooltipContentResolver? tooltipContentResolver;

  /// Fires when the user activates the "View details" button on a
  /// pin tooltip. Host page picks the destination route based on its
  /// surface context (in-list vs. standalone) — the map widget stays
  /// route-agnostic.
  final OnMapPinViewDetails? onViewDetails;

  /// PROD-2016: analytics surface label. Set by each consumer
  /// (e.g. 'list_cover', 'lists_hub', 'zine_item_aux'). Sent as
  /// `map_context` on `map_pin_tooltip_open` and
  /// `map_pin_view_details_click`. Optional — analytics still fires
  /// without it, just with `map_context: 'unknown'`.
  final String? analyticsContext;

  /// PROD-2017: render the top-right "fit all markers" button on the
  /// map. Visible only when the map is currently interactive (gestures
  /// unlocked) — matches the original list_map_view gating rule. On
  /// tap, bumps the internal fit-token to re-fit the camera to the
  /// full marker set and clears any my-location focus override.
  final bool showFitAllButton;

  /// PROD-2017: render the top-right "my location" button on the map.
  /// Auto-hides when no location is available. On tap, centers the
  /// camera on the user's last known location at [userLocationZoom].
  final bool showMyLocationButton;

  /// Render the top-right "+ / −" zoom buttons on the map.
  ///
  /// Off by default and deliberately **not** platform-detected here: a widget
  /// prop keeps every surface's choice visible at its call site. Hosts that
  /// want the pointer-capability rule pass
  /// `platformPrefersOnScreenZoomControls` (`core/utils/pointer_capabilities.dart`)
  /// — true only on a desktop browser, where there is no pinch gesture and
  /// scroll-wheel zoom is swallowed by any scrollable ancestor.
  ///
  /// Like the other floating controls, hidden while the map is locked
  /// (gestures off) so the user isn't offered a control that can't act.
  final bool showZoomButtons;

  /// Zoom levels added/removed per [showZoomButtons] tap. One level halves or
  /// doubles the visible span, matching Mapbox's own `zoomIn()`/`zoomOut()`.
  static const double zoomButtonStep = 1.0;

  /// Floor for the zoom buttons. Below this the map is a continent view, which
  /// no surface that wants these buttons has any use for.
  static const double zoomButtonMinZoom = 2.0;

  /// Ceiling for the zoom buttons when the surface sets no [maxZoom] — the same
  /// cap the Map page chose (decision 2026-07-10: no user benefit past ~20).
  static const double zoomButtonMaxZoom = 20.0;

  /// PROD-2017: zoom level applied when the user taps the my-location
  /// button. Slightly wider than a marker focus zoom so a few blocks
  /// of context surround the dot. Default mirrors list_map_view.
  final double userLocationZoom;

  /// PROD-3124 — the my-location button's SECOND zoom step: tapping while the
  /// camera is already centered on the user at [userLocationZoom] zooms in to
  /// the near-me level instead. Tapping again (now at close
  /// zoom, no longer "at base") returns to [userLocationZoom].
  static const double myLocationCloseZoom = kMapZoomNearMeStart;

  /// PROD-2671: top offset (logical px, from the map's top edge) for the
  /// top-right control column (fit-all / my-location). Defaults to `16`.
  /// The Map page overrides this to float the button **below** its top-bar
  /// chrome (search + shortcut chips) so it isn't hidden behind them; every
  /// other surface leaves it null and keeps the standard 16px inset.
  final double? topButtonsTopInset;

  /// When non-null, the my-location button is rendered **bottom-right** at this
  /// bottom offset (logical px from the map's bottom edge) instead of in the
  /// top-right control column — the Map page drives it off the results-drawer
  /// height so the button hugs the drawer's top edge and rides up with it, then
  /// is left behind (and covered by the drawer) once the drawer grows past it.
  /// The offset is animated here so callers can just feed the live target. Null
  /// everywhere else keeps the standard top-right placement.
  final double? myLocationButtonBottomInset;

  /// PROD-2042 Wave 2: consumer-driven pin selection visualization.
  /// The pin with this ID renders at the larger "selected" size on
  /// top of unselected pins, with a 150 ms paint transition.
  /// Independent of the widget's internal tooltip selection — when
  /// both are set, the consumer-supplied ID wins.
  final String? selectedMarkerId;

  /// PROD-2205: multi-pin variant of [selectedMarkerId]. Every marker
  /// whose id is in this set renders as selected (yellow + 1.5×) in
  /// addition to anything matched by [selectedMarkerId]. Used by the
  /// zine item-page map to highlight all venues of a multi-venue event
  /// at once. Null / empty means no multi-selection.
  final Set<String>? selectedMarkerIds;

  /// PROD-2042 Wave 2: render the location-status banner internally.
  /// The widget reads [locationProvider] and renders an IP-fallback
  /// CTA when `isIpFallback`, an approximate-location badge when
  /// `isGpsApproximate`, or nothing when location is precise / not
  /// granted. Owns the tap handler including the web
  /// `BrowserInstructionsSheet` flow.
  final bool showLocationStatusBanners;

  /// PROD-2042 Wave 2: visual style for the location-status banner.
  /// Defaults to `compact` (pill, ~28 px) for inline previews; the
  /// modal passes `fullWidth` (banner, ~64 px). Ignored if
  /// [showLocationStatusBanners] is false.
  final LocationBannerStyle locationBannerStyle;

  /// PROD-2042 Wave 2: positioning inset for the location-status
  /// banner. Defaults to `EdgeInsets.fromLTRB(12, 0, 12, 12)` (bottom-
  /// left + 12 px margin). The modal overrides the `bottom` value to
  /// clear its carousel drawer.
  ///
  /// Which of `top` / `bottom` is honoured follows [bannerAnchor]; `left` and
  /// `right` always are.
  final EdgeInsets? bannerInset;

  /// Which edge [bannerInset] is measured from. Defaults to `bottom` — the
  /// historic behaviour every full-bleed map surface wants.
  final LocationBannerAnchor bannerAnchor;

  /// Fired when a tap on the location-status banner ends with the user
  /// actually sharing their location (permission granted, fix acquired).
  ///
  /// The banner unmounts itself on its own — it is driven by [locationProvider]
  /// — so this exists only for hosts that owe the user a *further* reaction.
  /// The location-scope sheet uses it to fly its camera to the fresh fix:
  /// someone who taps a location control inside a location picker meant "take
  /// me there", not just "turn it on".
  final VoidCallback? onLocationEnabled;

  /// PROD-2671: render unclustered pins as per-category PNG teardrops
  /// (symbol layer) instead of colored circles. Opt-in.
  ///
  /// Implemented on **both** web and native — native has had it since
  /// PROD-2671 (the "No-op on native in v0, web-first, Decision #18" note
  /// this comment used to carry was stale by several releases; corrected in
  /// PROD-3828).
  ///
  /// Independent of [customSelection]: `categoryIcons: true` with
  /// `customSelection: false` is a supported combination (teardrop leaves +
  /// circle cluster bubbles) and is what every surface other than the Map
  /// page uses.
  final bool categoryIcons;

  /// PROD-2671: category-key → asset path for the PNG pins to register
  /// when [categoryIcons] is true. Each marker's `iconImage` must be one
  /// of these keys.
  final Map<String, String> categoryIconAssets;

  /// PROD-3828: show the inline pin captions (name over secondary facet) that
  /// [categoryIcons] renders beside each teardrop. Ignored unless
  /// [categoryIcons] is on.
  ///
  /// Defaults to `true` — i.e. this is an opt-**out**. That keeps the Map page
  /// (the only consumer when this landed) byte-identical without touching its
  /// call site, which PROD-3828 required. The trade-off is deliberate: a
  /// future `categoryIcons` consumer that forgets to pass `false` gets a
  /// caption, which is visible and trivially fixed — whereas a `false` default
  /// would silently strip the Map page's captions, a regression nobody would
  /// notice. Do NOT infer this from whether the markers carry `pinTitle`: an
  /// absent title renders an empty `format` label, which is harmless but still
  /// costs placement work, and inference makes the surface's intent
  /// unreadable.
  ///
  /// PROD-3830 passes `false` on the chat preview, the chat places modal and
  /// the event/venue detail blocks; `true` on the list cover / `/lists` hub
  /// and the zine item page.
  ///
  /// **Install-time only** — read when the style layers are installed, like
  /// [categoryIcons] / [categoryIconAssets] / [customSelection]. Pass a
  /// constant per surface; changing it on a live map is asserted against in
  /// debug (the layer is already built, but the caption tap paths read the
  /// live flag, so the two would disagree).
  final bool showPinCaptions;

  /// PROD-3828: per-surface override for the pins' zoom→`icon-size` curve.
  /// Null keeps [MapPinIconTokens.iconSizeStops], the curve tuned for the
  /// full-screen Map page.
  ///
  /// Exists because that global curve is noticeably large on the small
  /// surfaces: on the 80×110 source art, 0.3× at z15 is ~24×33 px, against the
  /// r10 (20 px) circle it replaces — and it is bottom-anchored rather than
  /// centre-anchored. The chat compact preview (`optimizeForSmallSize`,
  /// `maxZoom: 14`) and the 1:1 detail blocks are the two that need a smaller
  /// one.
  ///
  /// Threaded into the icon-size expression, the caption offset AND the tap
  /// hit-test together — they all read this same list, so a surface's
  /// captions and tap targets track whatever art it renders.
  ///
  /// **Install-time only** — the layer expressions bake the curve when the
  /// style layers are installed, like [categoryIcons] /
  /// [categoryIconAssets] / [customSelection]. Pass a constant per surface;
  /// changing it on a live map is asserted against in debug (the baked art
  /// would keep the old curve while the tap hit-test used the new one).
  final List<(double zoom, double size)>? pinIconSizeStops;

  /// PROD-2807: use the app's custom world-grid selection (individual pins +
  /// `+k` overflow bubbles) instead of Mapbox's built-in clustering. Requires
  /// [cluster]. Opt-in — the Map page only. See [MapboxMapPlatform.customSelection].
  final bool customSelection;

  /// PROD-2671: fires when the map settles after a pan/zoom (`moveend`),
  /// carrying the camera centre/zoom/bounds — drives settle-to-search on
  /// the Map page.
  final MapCameraIdleCallback? onCameraIdle;

  /// PROD-2807 (#4): fires (throttled) on every camera move during a gesture,
  /// carrying the live camera state — drives instant mid-gesture re-selection
  /// on the Map page. Distinct from [onCameraIdle] (settle only).
  final MapCameraIdleCallback? onCameraMove;

  /// PROD-2971: admin-only searched-area debug overlay. When non-null, the
  /// platform draws the retrieval circle / sargable bbox / grid cells / v2
  /// selection rect over the map (distinct colours). Null → no overlay. The Map
  /// page feeds this from the `/map/pins` `debug.area` block while debug mode is
  /// on; every other surface leaves it null.
  final MapDebugArea? debugOverlay;

  /// PROD-2971: which overlay shapes to draw (null = all). The Map page feeds
  /// this from the panel's per-shape legend toggles.
  final Set<MapDebugShape>? debugOverlayShapes;

  /// DEBUG-only: the search area the FE currently sends to `/map/pins`, drawn
  /// on the map as a translucent soko-red overlay (radius circle + v2 viewport
  /// rectangle). Only set by the Map page under `kDebugMode`; web-only render.
  final MapSearchAreaOverlay? debugSearchArea;

  /// PROD-3124: dot hints — the GeoJSON FeatureCollection of small
  /// category-coloured circles rendered BENEATH the pins for retrieved-but-
  /// not-pinned results ("there's more here — zoom in"). Built by the Map
  /// page's `mapDotHintsGeoJsonProvider` (identity-stable between settles);
  /// null → the layer stays empty. Map page only.
  final Map<String, dynamic>? dotHintsGeoJson;

  /// PROD-3124 dot tap: fires when the user taps a dot hint (lowest tap
  /// priority — any pin/bubble/caption hit wins). The platform flies the
  /// camera to the dot at `kDotHintFocusZoom` itself; the consumer promotes
  /// the item to a pin (`mapPromotedPinProvider`).
  final void Function(String id, String entity, double lat, double lng)?
  onDotHintTap;

  /// PROD-2671: logical-px insets of the chrome overlapping the full-bleed map —
  /// the top bar (search + shortcut chips) and the bottom results drawer. The
  /// Map page passes these so the `/map/pins` query + pin selection cover only
  /// the **visible** rectangle (not the strips behind the chrome), and the
  /// camera centres/frames within it. Both default 0 → full-canvas behaviour.
  /// Web-only (native ignores them).
  final double viewportPaddingTop;
  final double viewportPaddingBottom;

  /// PROD-2993: a GLOBAL multiplier on the category pins' caption `text-offset`,
  /// so captions keep tracking the pin's top when the results-highlight
  /// enlargement grows every pin (the narrow half-drawer sets this to
  /// [kMapHighlightSizeMul]; `1.0` everywhere else). See
  /// [MapPinIconTokens.captionOffsetExpression] for why the enlargement can only
  /// be folded in globally rather than per-feature. Map page only (category
  /// pins); ignored unless [categoryIcons] is on.
  final double captionSizeMul;

  const MapboxMapWidget({
    super.key,
    this.markers = const [],
    this.userDotLatLng,
    this.pickerPinLatLng,
    this.recenterAnchor,
    this.recenterResetKey = 0,
    this.centerLat,
    this.centerLng,
    this.zoom = 13,
    this.fitMarkers = false,
    this.onMarkerTap,
    this.interactive = true,
    this.boundsConfig,
    this.onMapReady,
    this.onMapMoved,
    this.onMapTapOutside,
    this.onMapTapLatLng,
    this.highlightBoundaryGeoJson,
    this.childBoundariesGeoJson,
    this.onMapHoverLatLng,
    this.onMapHoverExit,
    this.hoverBoundaryGeoJson,
    this.highlightPoint,
    this.highlightRadiusMeters,
    this.isDark = false,
    this.optimizeForSmallSize = false,
    this.maxZoom,
    this.cursorOverride,
    this.cluster = false,
    this.staticByDefault = false,
    this.onInteractiveChanged,
    this.fitToMarkersToken = 0,
    this.centerToToken = 0,
    this.onUserGesture,
    this.enableTooltip = true,
    this.tooltipContentResolver,
    this.onViewDetails,
    this.analyticsContext,
    this.showFitAllButton = false,
    this.showMyLocationButton = false,
    this.showZoomButtons = false,
    this.userLocationZoom = kMapZoomWalkingStart,
    this.topButtonsTopInset,
    this.myLocationButtonBottomInset,
    this.selectedMarkerId,
    this.selectedMarkerIds,
    this.showLocationStatusBanners = false,
    this.locationBannerStyle = LocationBannerStyle.compact,
    this.bannerInset,
    this.bannerAnchor = LocationBannerAnchor.bottom,
    this.onLocationEnabled,
    this.categoryIcons = false,
    this.categoryIconAssets = const {},
    this.showPinCaptions = true,
    this.pinIconSizeStops,
    this.customSelection = false,
    this.onCameraIdle,
    this.onCameraMove,
    this.debugOverlay,
    this.debugOverlayShapes,
    this.debugSearchArea,
    this.dotHintsGeoJson,
    this.onDotHintTap,
    this.viewportPaddingTop = 0,
    this.viewportPaddingBottom = 0,
    this.captionSizeMul = 1.0,
  });

  @override
  ConsumerState<MapboxMapWidget> createState() => _MapboxMapWidgetState();
}

class _MapboxMapWidgetState extends ConsumerState<MapboxMapWidget> {
  // Static-toggle state — `false` when the chip says "Tap to interact",
  // `true` when the user has activated gestures. Only meaningful when
  // `widget.staticByDefault == true`.
  bool _activated = false;

  // Tooltip state — populated when a pin is selected. `_selectedPixel`
  // is in map-container coordinates (origin top-left). Set together
  // via `_openTooltipForMarker` and cleared via `_closeTooltip`.
  MapMarker? _selected;
  Offset? _selectedPixel;

  // PROD-2016: tracks whether the current selection came from a hover
  // (web only) vs a click. Hover-opened tooltips auto-close on
  // pin-leave + dwell; click-opened tooltips stay until explicit
  // dismissal. Future: feeds the analytics `source` field.
  // ignore: unused_field — feeds analytics in PROD-2016 commit 6.
  bool _selectionFromHover = false;

  // PROD-2016: 150 ms grace period between pin-leave and tooltip
  // close — lets the cursor traverse the gap from pin to tooltip.
  Timer? _hoverCloseTimer;
  static const Duration _hoverCloseGrace = Duration(milliseconds: 150);

  // PROD-2016: 300 ms stability filter for `map_pin_tooltip_open`.
  // Only fires the event after the tooltip has stayed open for the
  // full window on the same marker — prevents PostHog spam when the
  // user sweeps across many pins on web hover.
  Timer? _analyticsOpenTimer;
  static const Duration _analyticsOpenDebounce = Duration(milliseconds: 300);

  // PROD-2017: internal "re-fit now" counter bumped by the fit-all
  // button. OR-combined with [widget.fitToMarkersToken] before being
  // forwarded to the platform widget — so both consumer-driven and
  // button-driven re-fits flow through the same mechanism.
  int _internalFitToken = 0;

  // PROD-2017: imperative camera override — "ease to exactly this centre at
  // exactly this zoom". When set, takes precedence over
  // [widget.centerLat]/[centerLng]/[zoom] and disables fit-to-markers so the
  // platform widget animates there instead of re-fitting to the marker set on
  // next rebuild. Cleared by the fit-all button, and by a consumer-driven
  // centre change (see didUpdateWidget) so an external recenter always wins.
  //
  // Two features drive it: the my-location button (a new centre) and the
  // zoom buttons (the SAME centre, a new zoom). Sharing one mechanism is why
  // the zoom buttons need no new plumbing in the three platform renderers.
  ({double lat, double lng})? _focusOverride;

  // PROD-2042 Wave 2: bumped on every my-location button tap so the
  // platform widget runs `easeTo` (web) / `flyTo` (native) to the
  // override target even when the effective center prop already
  // matches the previous value (after an initial fit, the
  // `widget.centerLat` prop may already equal `_focusOverride.lat`).
  // Without this, value-diff platform predicates miss the change and
  // the camera stays put — see PROD-2042 Wave 2 follow-up.
  int _internalCenterToToken = 0;

  // PROD-3124: last settled camera, teed from the platform's onCameraIdle
  // pass-through — lets the my-location button decide between its two zoom
  // steps. Null until the first settle. Not setState'd (render-irrelevant).
  MapCameraState? _lastCamera;

  // The zoom the current my-location override targets ([userLocationZoom] or
  // [MapboxMapWidget.myLocationCloseZoom]). Meaningful only while
  // `_focusOverride != null`.
  double? _focusZoom;

  // The zoom a +/- button tap asked for, while its ease is still in flight —
  // so a second tap steps from the target rather than from the pre-tap camera
  // and the two taps don't collapse into one level.
  //
  // Cleared the moment the camera settles OR the user starts a gesture, which
  // is what keeps it from going stale: after a pinch, `_lastCamera.zoom` is the
  // truth and this is null, so the next tap steps from where the user actually
  // is. (Reading `_focusZoom` instead would be wrong for exactly that case —
  // it survives a pinch and would step from a zoom the map left long ago.)
  double? _pendingZoomTarget;

  // req3: picker recenter toggle. When [recenterAnchor] is set the my-location
  // button strictly alternates fit-both ↔ zoom-user. Reset to fitBoth on a user
  // gesture, an anchor change, or a >25 m user-location move since the last press.
  RecenterStep _recenterStep = RecenterStep.fitBoth;
  ({double lat, double lng})? _lastRecenterUser;
  // The search-centre anchor frozen for the current toggle cycle. The live
  // anchor (the pin) drifts to the camera centre after a zoom-user step, so we
  // capture it once at cycle start and reuse it for every fit-both in the cycle.
  // Cleared on a reset (user gesture / big user-location move).
  ({double lat, double lng})? _frozenAnchor;
  // Imperative "fit these bounds now" for the fit-both step — kept separate from
  // [widget.boundsConfig] so it never collides with a surface's own fitting.
  MapBoundsConfig? _fitBoundsOverride;
  int _internalFitBoundsToken = 0;

  bool get _tooltipConfigured =>
      widget.enableTooltip && widget.tooltipContentResolver != null;

  /// Whether gestures are currently live on the platform widget.
  /// Equals `widget.interactive` unless `staticByDefault` is on and
  /// the user hasn't activated yet.
  bool get _liveInteractive => widget.staticByDefault
      ? (_activated && widget.interactive)
      : widget.interactive;

  void _handlePlatformMarkerTap(MapMarker marker, Offset pixel) {
    // Legacy side effects fire regardless — places_map_modal's
    // carousel sync, custom camera focus, etc.
    widget.onMarkerTap?.call(marker);

    if (!_tooltipConfigured) return;

    // Same-pin tap → either promote a hover-opened tooltip to sticky
    // (click-mode), or close if it's already sticky (true toggle).
    if (_selected != null && _selected!.id == marker.id) {
      if (_selectionFromHover) {
        // Hover-then-click: the user wants to keep this tooltip
        // around after moving the cursor away. Cancel the pending
        // hover-close timer and flip the mode flag — `_handlePinHover
        // Exit` already early-returns when `_selectionFromHover` is
        // false, so this prevents the next mouseleave from closing.
        _hoverCloseTimer?.cancel();
        _hoverCloseTimer = null;
        setState(() => _selectionFromHover = false);
        return;
      }
      // Already in click/sticky mode → close (toggle).
      _closeTooltip();
      return;
    }

    final content = widget.tooltipContentResolver!(marker);
    if (content == null) return; // resolver opted out for this marker

    _hoverCloseTimer?.cancel();
    setState(() {
      _selected = marker;
      _selectedPixel = pixel;
      _selectionFromHover = false;
    });
    _scheduleAnalyticsOpen(marker, source: 'click');
  }

  /// PROD-2016 / PROD-2046 (web): hover-to-open is disabled.
  ///
  /// Originally the desktop UX opened the tooltip on hover with a
  /// 150 ms dwell. PROD-2046 introduced a camera-pan on tooltip-open
  /// (the map eases so the tapped pin lands at a fixed screen target
  /// — see `mapbox_map_web.dart` / `mapbox_map_native.dart`). Panning
  /// the camera every time a cursor crosses a pin is jarring and
  /// unwanted, so hover only sets the cursor affordance (handled at
  /// the platform layer); it no longer opens the tooltip.
  void _handlePinHoverEnter(MapMarker marker, Offset pixel) {
    // Intentional no-op. The hover-exit + tooltip-hover handlers
    // below still exist as safety nets in case a `_selectionFromHover`
    // state somehow leaked in from a future code path; they're inert
    // today because nothing sets `_selectionFromHover = true`.
  }

  /// PROD-2016 (web): hover-exit from a pin starts the 150 ms grace
  /// timer. If the cursor reaches the tooltip in time, the tooltip's
  /// MouseRegion cancels the timer; otherwise the tooltip closes.
  void _handlePinHoverExit() {
    if (_selected == null || !_selectionFromHover) return;
    _hoverCloseTimer?.cancel();
    _hoverCloseTimer = Timer(_hoverCloseGrace, () {
      _hoverCloseTimer = null;
      if (mounted) _closeTooltip();
    });
  }

  /// PROD-2016 (web): cursor entered the tooltip itself — keep it
  /// open by cancelling the pending close.
  void _handleTooltipHoverEnter() {
    _hoverCloseTimer?.cancel();
    _hoverCloseTimer = null;
  }

  /// PROD-2016 (web): cursor left the tooltip — start the close
  /// timer (same grace as pin-leave).
  void _handleTooltipHoverExit() {
    if (!_selectionFromHover) return;
    _hoverCloseTimer?.cancel();
    _hoverCloseTimer = Timer(_hoverCloseGrace, () {
      _hoverCloseTimer = null;
      if (mounted) _closeTooltip();
    });
  }

  void _closeTooltip() {
    if (_selected == null) return;
    _hoverCloseTimer?.cancel();
    _hoverCloseTimer = null;
    // Cancel any pending tooltip-open analytics — the tooltip didn't
    // survive the 300 ms stability window.
    _analyticsOpenTimer?.cancel();
    _analyticsOpenTimer = null;
    setState(() {
      _selected = null;
      _selectedPixel = null;
      _selectionFromHover = false;
    });
  }

  /// PROD-2016 analytics debounce. Each new open schedules the event
  /// 300 ms in the future. A subsequent open before that fires
  /// cancels and re-schedules (covers the hover-sweep case — rapid
  /// pin-to-pin transitions don't each fire an open event). On close
  /// before the timer expires the pending dispatch is cancelled.
  void _scheduleAnalyticsOpen(MapMarker marker, {required String source}) {
    _analyticsOpenTimer?.cancel();
    _analyticsOpenTimer = Timer(_analyticsOpenDebounce, () {
      _analyticsOpenTimer = null;
      // Sanity: only fire if the SAME marker is still selected.
      if (!mounted || _selected?.id != marker.id) return;
      final itemType = marker.category?.wire ?? 'unknown';
      ref
          .read(unifiedAnalyticsProvider)
          .trackMapPinTooltipOpen(
            itemId: marker.id,
            itemType: itemType,
            source: source,
            mapContext: widget.analyticsContext ?? 'unknown',
          );
    });
  }

  /// PROD-2016: intercepts the platform's `onMapMoved` so the tooltip
  /// closes on every pan/zoom (its pixel anchor is stale otherwise)
  /// before forwarding to any consumer-supplied callback.
  void _handlePlatformMapMoved() {
    // A camera event can be dispatched SYNCHRONOUSLY from inside a layout pass:
    // this widget usually sits in a LayoutBuilder, so its didUpdateWidget runs
    // during layout, and an imperative `easeTo`/`centerTo` there stops the prior
    // ease and fires `moveend` right then. Both mutations below are illegal
    // mid-layout — `_closeTooltip` setState and `onMapMoved` (which cancels
    // in-flight provider fetches). Defer to post-frame only when mid-frame.
    _dispatchOutsideLayout(() {
      if (!mounted) return;
      if (_selected != null) _closeTooltip();
      widget.onMapMoved?.call();
    });
  }

  /// req3: intercept the platform's user-gesture signal so the recenter toggle
  /// resets to fit-both after the user moves the map, then forward to any
  /// consumer callback. Reset is render-irrelevant, so no setState.
  void _handleUserGesture() {
    // The user is now driving the camera; any button-requested zoom we were
    // still counting from is history.
    _pendingZoomTarget = null;
    _resetRecenterStep();
    widget.onUserGesture?.call();
  }

  /// Run [fn] now, unless we're mid-frame (build/layout/paint) — then defer it
  /// to the next post-frame. Mapbox dispatches camera events (`moveend`, idle)
  /// synchronously from an `easeTo` kicked off in [didUpdateWidget], which the
  /// enclosing LayoutBuilder runs DURING layout; the consumer callbacks mutate
  /// providers, which throws there. See [_handlePlatformMapMoved].
  void _dispatchOutsideLayout(VoidCallback fn) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fn();
      });
    } else {
      fn();
    }
  }

  /// PROD-2671: intercepts the platform's tap-outside so the internal tooltip
  /// still closes, then forwards to any consumer callback (the Map page closes
  /// its open filter drawer on a map tap).
  void _handlePlatformMapTapOutside() {
    _closeTooltip();
    widget.onMapTapOutside?.call();
  }

  @override
  void dispose() {
    _hoverCloseTimer?.cancel();
    _hoverCloseTimer = null;
    _analyticsOpenTimer?.cancel();
    _analyticsOpenTimer = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(MapboxMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the marker set changes such that the selected marker is gone,
    // close the tooltip — its anchor is stale.
    if (_selected != null) {
      final stillPresent = widget.markers.any((m) => m.id == _selected!.id);
      if (!stillPresent) _closeTooltip();
    }
    // PROD-2042 Wave 2 (Q9): externally-driven re-centers (e.g., the
    // places modal's card-tap recentering the camera on the selected
    // pin) should win over a stale my-location override. Without
    // this, a my-location tap followed by a card tap would land
    // under the sticky `_focusOverride` and the camera wouldn't move.
    if (_focusOverride != null &&
        (widget.centerLat != oldWidget.centerLat ||
            widget.centerLng != oldWidget.centerLng)) {
      _focusOverride = null;
    }
    // req3: restart the toggle when the SELECTION changes (a new tap/search/
    // clear bumps [recenterResetKey]) so the next press frames the new point.
    // Deliberately NOT keyed on [recenterAnchor] — the unselected anchor tracks
    // the camera, so it changes on the recenter's own animation and would break
    // the alternation. A real user gesture (below) also resets it.
    if (widget.recenterResetKey != oldWidget.recenterResetKey) {
      _resetRecenterStep();
    }
  }

  void _handleFitAllTap() {
    setState(() {
      _focusOverride = null;
      _internalFitToken++;
    });
  }

  /// "Already centered" tolerance for the my-location zoom toggle (metres).
  static const double _kCenteredOnUserMeters = 50;

  /// Zoom tolerance for "already at the base zoom" (my-location toggle).
  static const double _kAtBaseZoomEpsilon = 0.15;

  /// req3: fit-both padding (px) so both framed points sit comfortably in view.
  static const int _kRecenterFitPaddingPx = 120;

  /// req3: padding (px) for the zoom-user step's tiny box around the user —
  /// small so the close zoom (capped by maxZoom) actually engages.
  static const int _kRecenterZoomUserPaddingPx = 40;

  /// req3: reset the recenter toggle when the user moved the map, so the next
  /// press starts a fresh cycle (fit-both, re-capturing the search centre).
  void _resetRecenterStep() {
    _recenterStep = RecenterStep.fitBoth;
    _frozenAnchor = null;
  }

  void _handleMyLocationTap(LocationState locationState) {
    final loc = locationState.lastLocation;
    if (loc == null) return;
    final anchor = widget.recenterAnchor;
    if (anchor != null) {
      _handleRecenterToggle(anchor, loc.lat, loc.lon);
      return;
    }
    // PROD-3124: two-step zoom. Already centered on the user AT the base
    // zoom → zoom in to [MapboxMapWidget.myLocationCloseZoom]; anywhere
    // else (off-center, other zooms — including the close zoom itself) →
    // center at the base [userLocationZoom].
    final cam = _lastCamera;
    final atBase =
        cam != null &&
        (cam.zoom - widget.userLocationZoom).abs() <= _kAtBaseZoomEpsilon &&
        _isNearUser(cam, loc.lat, loc.lon);
    setState(() {
      _focusZoom = atBase
          ? MapboxMapWidget.myLocationCloseZoom
          : widget.userLocationZoom;
      _focusOverride = (lat: loc.lat, lng: loc.lon);
      // Bump the imperative center token so the platform widget eases
      // even when the effective center prop already equals the
      // override target (common after an initial fit-to-markers).
      _internalCenterToToken++;
    });
  }

  /// One step of the +/- zoom buttons.
  ///
  /// Re-uses the my-location ease path: hold the CURRENT camera centre and ask
  /// for `zoom ± step`. Holding the centre matters — these buttons zoom the
  /// view the user framed, and the picker reads the settled camera back out to
  /// re-derive its selection, so a centre that drifted would silently move the
  /// pick as well as its granularity.
  ///
  /// The base is the last settled camera (the live zoom) — or, while an earlier
  /// tap's ease is still in flight, that tap's target — falling back to the
  /// declarative props before the first settle. No-ops when there is no centre
  /// to hold, and when the step would land outside [MapboxMapWidget.zoomButtonMinZoom]
  /// … [maxZoom] — a tap that cannot move the camera must not bump the token,
  /// or the platform eases to a zoom it is already at and the picker resolves
  /// a redundant settle.
  void _handleZoomTap(double delta) {
    final cam = _lastCamera;
    final centre = cam != null
        ? (lat: cam.centerLat, lng: cam.centerLng)
        : (widget.centerLat != null && widget.centerLng != null
              ? (lat: widget.centerLat!, lng: widget.centerLng!)
              : null);
    if (centre == null) return;

    final target = steppedZoom(
      current: _pendingZoomTarget ?? cam?.zoom ?? widget.zoom,
      delta: delta,
      minZoom: MapboxMapWidget.zoomButtonMinZoom,
      maxZoom: widget.maxZoom ?? MapboxMapWidget.zoomButtonMaxZoom,
    );
    if (target == null) return;

    setState(() {
      _focusOverride = centre;
      _focusZoom = target;
      _pendingZoomTarget = target;
      // Same reason as the my-location button: the effective centre prop may
      // already equal the target, so only a token bump makes the platform ease.
      _internalCenterToToken++;
      // A button-driven zoom is a deliberate reframing, exactly like a pinch —
      // restart the recenter toggle so the next my-location press starts fresh.
      _resetRecenterStep();
    });
  }

  /// req3: the picker's strict fit-both ↔ zoom-user toggle.
  void _handleRecenterToggle(
    ({double lat, double lng}) anchor,
    double userLat,
    double userLng,
  ) {
    setState(() {
      // A >25 m user move since the last press means the target changed —
      // start a fresh cycle (jitter under the threshold does not reset).
      final last = _lastRecenterUser;
      if (last != null &&
          distanceMeters(last.lat, last.lng, userLat, userLng) > 25) {
        _recenterStep = RecenterStep.fitBoth;
        _frozenAnchor = null;
      }
      // Both steps drive the SAME imperative fit path (bumping the fit token);
      // a stale center override would fight it, so clear it first. Using one
      // mechanism for both steps avoids the shared PROD-3124 center-override
      // plumbing, which mis-centred step B.
      _focusOverride = null;
      _focusZoom = null;
      if (_recenterStep == RecenterStep.fitBoth) {
        // Step A: frame the search centre + the user. Freeze the anchor for the
        // cycle — the live [anchor] (the pin) drifts to the camera centre after
        // a zoom-user step, so re-reading it here would frame the wrong point.
        _frozenAnchor ??= anchor;
        _fitBoundsOverride = boundsForTwoPoints(
          aLat: _frozenAnchor!.lat,
          aLng: _frozenAnchor!.lng,
          bLat: userLat,
          bLng: userLng,
          padding: _kRecenterFitPaddingPx,
          maxZoom: MapboxMapWidget.myLocationCloseZoom,
        );
      } else {
        // Step B: zoom in centred ON the user — frame a tiny box around just
        // the user point (boundsForTwoPoints expands coincident points to a
        // ~100 m box), which fits centred on the user, capped at the close zoom.
        _fitBoundsOverride = boundsForTwoPoints(
          aLat: userLat,
          aLng: userLng,
          bLat: userLat,
          bLng: userLng,
          padding: _kRecenterZoomUserPaddingPx,
          maxZoom: MapboxMapWidget.myLocationCloseZoom,
        );
      }
      _internalFitBoundsToken++;
      _recenterStep = nextRecenterStep(_recenterStep);
      _lastRecenterUser = (lat: userLat, lng: userLng);
    });
  }

  /// Whether the settled camera centre is within [_kCenteredOnUserMeters] of
  /// the user fix — "already centered" for the my-location toggle.
  bool _isNearUser(MapCameraState cam, double lat, double lng) {
    final dLatM = (cam.centerLat - lat) * 111320.0;
    final dLngM =
        (cam.centerLng - lng) * 111320.0 * math.cos(lat * math.pi / 180.0);
    return math.sqrt(dLatM * dLatM + dLngM * dLngM) < _kCenteredOnUserMeters;
  }

  void _handleCameraIdle(MapCameraState cam) {
    _lastCamera = cam; // plain field write — safe even mid-layout
    // The camera has landed, so it — not our request — is the base for the
    // next +/- tap.
    _pendingZoomTarget = null;
    final cb = widget.onCameraIdle;
    if (cb == null) return;
    // Same hazard as onMapMoved: an `easeTo` kicked off in didUpdateWidget can
    // settle + fire idle synchronously during the enclosing LayoutBuilder's
    // layout, and onCameraSettled refetches (a provider write).
    _dispatchOutsideLayout(() => cb(cam));
  }

  /// PROD-2042 Wave 2: lifted from `places_map_modal._mapPermissionStatus`
  /// and `chat_map_widget._mapPermissionStatus` — both copies were
  /// byte-for-byte identical. Maps the location-service status enum to
  /// the analytics-event permission-status string.
  String _mapPermissionStatus(LocationPermissionStatus status) {
    switch (status) {
      case LocationPermissionStatus.granted:
        return PermissionStatus.granted;
      case LocationPermissionStatus.denied:
        return PermissionStatus.denied;
      case LocationPermissionStatus.deniedForever:
        return PermissionStatus.restricted;
      case LocationPermissionStatus.serviceDisabled:
      case LocationPermissionStatus.timeout:
      case LocationPermissionStatus.webUnsupported:
      case LocationPermissionStatus.unknownError:
        return PermissionStatus.denied;
    }
  }

  /// PROD-2042 Wave 2: lifted from `places_map_modal._handleBannerTap`
  /// and `chat_map_widget._handleEnableLocationTap` — both copies were
  /// functionally identical. Requests permission, opens settings, or
  /// shows the browser-instructions sheet on web depending on the
  /// current permission state. Sends the matching analytics events.
  Future<void> _handleLocationStatusTap(LocationState locationState) async {
    final notifier = ref.read(locationProvider.notifier);
    final analytics = ref.read(unifiedAnalyticsProvider);

    if (locationState.permissionStatus ==
        LocationPermissionStatus.deniedForever) {
      analytics.trackLocationPermission(
        action: LocationPermissionAction.settingsOpened,
        isFirstPrompt: false,
      );
      if (kIsWeb) {
        // PROD-4301 pulled this presenter out of `chat_screen` precisely so a
        // second surface wouldn't have to copy the sheet + re-request wiring —
        // "the two copies would drift on the part that matters (whether tapping
        // *check again* actually asks the browser again)". This is that second
        // surface, so use the shared one rather than re-introducing the copy.
        //
        // Its `onGranted` also closes a hole the local copy had: a successful
        // web recovery now reaches [onLocationEnabled], so the pickers recentre
        // on the new fix instead of silently dropping the result.
        await showBrowserLocationInstructions(
          context: context,
          ref: ref,
          onGranted: () async => widget.onLocationEnabled?.call(),
        );
      } else {
        notifier.openSettings();
      }
    } else {
      analytics.trackLocationPermission(
        action: LocationPermissionAction.promptShown,
        isFirstPrompt: false,
      );
      final status = await notifier.requestPermissionOnly();
      if (status == LocationPermissionStatus.granted) {
        analytics.trackLocationPermission(
          action: LocationPermissionAction.allowed,
          permissionStatus: PermissionStatus.granted,
          isFirstPrompt: false,
        );
        widget.onLocationEnabled?.call();
      } else {
        analytics.trackLocationPermission(
          action: LocationPermissionAction.denied,
          permissionStatus: _mapPermissionStatus(status),
          isFirstPrompt: false,
        );
      }
    }
  }

  /// Tap handler for the **approximate-location** badge — the "we have a real
  /// fix, but it's coarser than 500 m" state.
  ///
  /// What is actually actionable here differs per platform, and the badge is
  /// only made tappable where something is (see [_approximateTapHandler]):
  ///
  /// * **iOS** — the per-app "Precise Location" switch is the usual cause, and
  ///   iOS lets us ask for a full-accuracy upgrade *in place*
  ///   (`requestTemporaryFullAccuracy`). That is one tap and no app switch, so
  ///   it goes first. It grants accuracy for the session only, and the user can
  ///   decline it outright — so if we come back and precise is still off, fall
  ///   through to app settings, where the switch lives permanently.
  /// * **Android** — there is no in-app upgrade dialog, and
  ///   `Geolocator.getLocationAccuracy()` is iOS-only, so we cannot even tell
  ///   whether the grant was "Approximate". App settings is both the right
  ///   destination (Android 12+ has a per-app "Use precise location" toggle)
  ///   and the only one we can offer.
  /// * **Web** — browsers expose no accuracy setting whatsoever, and
  ///   `LocationService.openAppSettings()` is a documented no-op there. The
  ///   badge stays inert rather than offering a tap that goes nowhere.
  Future<void> _handleApproximateTap() async {
    final notifier = ref.read(locationProvider.notifier);
    final service = ref.read(locationServiceProvider);
    final analytics = ref.read(unifiedAnalyticsProvider);

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Reachable only while the per-app switch is OFF ([_approximateTapHandler]
      // gates on it), so the dialog really will appear — which is what makes
      // reporting it as a prompt honest. Same promptShown → allowed/denied
      // shape as the permission CTA above.
      analytics.trackLocationPermission(
        action: LocationPermissionAction.promptShown,
        permissionStatus: PermissionStatus.limited,
        isFirstPrompt: false,
      );
      await notifier.requestTemporaryPreciseLocation();
      // Granted → the fix turns precise, `isGpsApproximate` goes false and this
      // badge unmounts itself. Still off → the user declined (or iOS suppressed
      // the dialog), and only Settings can fix it for good.
      final preciseNow = await service.isPreciseLocationEnabled();
      if (mounted) setState(() => _preciseSettingEnabled = preciseNow);
      if (preciseNow) {
        analytics.trackLocationPermission(
          action: LocationPermissionAction.allowed,
          permissionStatus: PermissionStatus.granted,
          isFirstPrompt: false,
        );
        // The fix just got better, so the pickers owe the user the same camera
        // move they make after the permission CTA — otherwise the dot sharpens
        // while the map stays on the old area.
        widget.onLocationEnabled?.call();
        return;
      }
      analytics.trackLocationPermission(
        action: LocationPermissionAction.denied,
        permissionStatus: PermissionStatus.limited,
        isFirstPrompt: false,
      );
    }

    // Only here is a settings screen actually opening. Firing settingsOpened
    // any earlier would book every successful in-app iOS upgrade — the common
    // case — as a settings visit that never happened.
    analytics.trackLocationPermission(
      action: LocationPermissionAction.settingsOpened,
      isFirstPrompt: false,
    );
    await service.openAppSettings();
  }

  /// iOS's per-app "Precise Location" switch, resolved lazily the first time a
  /// coarse fix actually renders the badge. Null while unknown (and on every
  /// other platform, which never probes).
  ///
  /// Probed rather than assumed because it is what decides whether the badge is
  /// a CTA at all — see [_approximateTapHandler]. Resolved once per mount: a
  /// user who flips the switch OFF mid-session keeps an inert badge until the
  /// next build of this widget, which is the harmless direction to be stale in.
  bool? _preciseSettingEnabled;
  bool _preciseProbeInFlight = false;

  void _ensurePreciseSettingProbe() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    if (_preciseSettingEnabled != null || _preciseProbeInFlight) return;
    _preciseProbeInFlight = true;
    ref.read(locationServiceProvider).isPreciseLocationEnabled().then((value) {
      if (!mounted) return;
      setState(() {
        _preciseSettingEnabled = value;
        _preciseProbeInFlight = false;
      });
    });
  }

  /// The badge's tap handler, or null where a coarse fix isn't user-fixable.
  ///
  /// * **Web** — no browser exposes an accuracy setting; there is nowhere to go.
  /// * **iOS with "Precise Location" already ON** — this is PROD-4083's dead
  ///   end: the fix is warming up or genuinely stuck (indoors, desktop), the
  ///   full-accuracy dialog will not appear, and Settings would show a switch
  ///   that is already on. Null while the probe is still in flight too, so the
  ///   badge never advertises a chevron it can't honour.
  /// * **iOS with it OFF, and Android** — actionable; see
  ///   [_handleApproximateTap].
  VoidCallback? get _approximateTapHandler {
    if (kIsWeb) return null;
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        _preciseSettingEnabled != false) {
      return null;
    }
    return _handleApproximateTap;
  }

  /// PROD-2042 Wave 2: render the location-status banner Positioned
  /// inside the map's Stack. IP fallback → CTA (style determines pill
  /// vs banner). Approximate location → display-only badge (always
  /// the compact pill — there's no full-width approximate variant).
  /// Returns null when banners are off or no banner is applicable.
  /// Positions a location-status banner, animating the offset on the same
  /// 220 ms / easeOut curve as the bottom-right my-location button.
  ///
  /// The Map page feeds both from the same drawer-height provider, so they must
  /// move as one — a plain `Positioned` here would jump to the new offset in a
  /// single frame while the button glided to it.
  Widget _bannerSlot({
    required Widget child,
    required double left,
    double? right,
    double? top,
    double? bottom,
    bool interactive = true,
  }) => AnimatedPositioned(
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOut,
    left: left,
    right: right,
    top: top,
    bottom: bottom,
    child: interactive
        // PROD-3310, same shield the floating controls carry: on iOS Safari a
        // tap on a Flutter overlay is followed by a *synthetic* click that
        // lands on the Mapbox HtmlElementView underneath. Both pickers pass
        // `onMapTapLatLng`, so without this, enabling location from the banner
        // would also re-anchor the area the user is picking. No-op off web.
        ? PointerInterceptor(child: child)
        // Display-only: there is no tap to shield, and the pill must not eat
        // pans and taps over its own rectangle — the map underneath owns them.
        : IgnorePointer(child: child),
  );

  Widget? _buildLocationStatusBanner(LocationState locationState) {
    if (!widget.showLocationStatusBanners) return null;
    final inset =
        widget.bannerInset ?? const EdgeInsets.fromLTRB(12, 0, 12, 12);
    final edges = locationBannerEdges(
      inset: inset,
      anchor: widget.bannerAnchor,
    );
    final top = edges.top;
    final bottom = edges.bottom;

    if (locationState.isIpFallback) {
      final isDenied =
          locationState.permissionStatus ==
          LocationPermissionStatus.deniedForever;
      void onTap() => _handleLocationStatusTap(locationState);
      switch (widget.locationBannerStyle) {
        case LocationBannerStyle.fullWidth:
          return _bannerSlot(
            left: inset.left,
            right: inset.right,
            top: top,
            bottom: bottom,
            child: LocationSharingBanner(
              isDeniedForever: isDenied,
              onTap: onTap,
            ),
          );
        case LocationBannerStyle.compact:
          return _bannerSlot(
            left: inset.left,
            top: top,
            bottom: bottom,
            child: EnableLocationBadge(onTap: onTap),
          );
      }
    }

    if (locationState.isGpsApproximate) {
      // Resolve the iOS precise-location switch now that a coarse fix is
      // actually on screen — it decides whether this badge is a CTA at all.
      // Async, so the setState lands after this frame, not during it.
      _ensurePreciseSettingProbe();
      // Always the compact pill — the `fullWidth` style has no
      // approximate-location equivalent. Tappable only where a coarse fix is
      // something the user can actually act on ([_approximateTapHandler]).
      final approximateTap = _approximateTapHandler;
      return _bannerSlot(
        left: inset.left,
        top: top,
        bottom: bottom,
        interactive: approximateTap != null,
        child: ApproximateLocationBadge(onTap: approximateTap),
      );
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final showActivationChip = widget.staticByDefault;
    final tooltipVisible = _selected != null && _selectedPixel != null;

    // PROD-2017: read location once so we can gate the my-location
    // button visibility and wire its tap handler. Cheap watch — we
    // only re-read coords, not the full snapshot. Hidden when the
    // map is locked.
    final locationState = ref.watch(locationProvider);
    final showTopButtons =
        _liveInteractive &&
        (widget.showFitAllButton ||
            widget.showZoomButtons ||
            (widget.showMyLocationButton && locationState.hasLocation));

    // Effective camera config: my-location override beats the
    // consumer-supplied center/zoom and disables fit-to-markers. The
    // fit-all button bumps `_internalFitToken` which is OR-ed into
    // the platform widget's fit predicate.
    final effectiveCenterLat = _focusOverride?.lat ?? widget.centerLat;
    final effectiveCenterLng = _focusOverride?.lng ?? widget.centerLng;
    final effectiveZoom = _focusOverride != null
        ? (_focusZoom ?? widget.userLocationZoom)
        : widget.zoom;
    final effectiveFitMarkers = widget.fitMarkers && _focusOverride == null;
    final effectiveFitToken = widget.fitToMarkersToken + _internalFitToken;

    // PROD-2042 Wave 2: build the optional location-status banner
    // here so the Stack body stays a flat list of conditional
    // children. Returns null when banners are off or no banner is
    // applicable to the current location state.
    final locationBanner = _buildLocationStatusBanner(locationState);

    // PROD-2016: LayoutBuilder gives us the viewport size so the
    // tooltip can edge-clamp against the actual map bounds. Cheap —
    // only rebuilds the immediate subtree when the size changes.
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            MapboxMapPlatform(
              markers: widget.markers,
              userDotLatLng: widget.userDotLatLng,
              pickerPinLatLng: widget.pickerPinLatLng,
              centerLat: effectiveCenterLat,
              centerLng: effectiveCenterLng,
              zoom: effectiveZoom,
              fitMarkers: effectiveFitMarkers,
              onMarkerTap: _handlePlatformMarkerTap,
              onMapTapOutside: _handlePlatformMapTapOutside,
              onMapTapLatLng: widget.onMapTapLatLng,
              highlightBoundaryGeoJson: widget.highlightBoundaryGeoJson,
              childBoundariesGeoJson: widget.childBoundariesGeoJson,
              onMapHoverLatLng: widget.onMapHoverLatLng,
              onMapHoverExit: widget.onMapHoverExit,
              hoverBoundaryGeoJson: widget.hoverBoundaryGeoJson,
              highlightPoint: widget.highlightPoint,
              highlightRadiusMeters: widget.highlightRadiusMeters,
              // PROD-2671: only ease the camera to centre a tapped pin when a
              // tooltip will actually show. Surfaces without a tooltip (the Map
              // page) get an immediate onMarkerTap and no camera move.
              centerOnMarkerTap: _tooltipConfigured,
              // PROD-2042 Wave 2: consumer-supplied selection (e.g.,
              // the modal's carousel card index) takes precedence over
              // the tooltip-driven internal selection. Falls back to
              // the tooltip selection when not set, preserving the
              // existing tooltip-selected-pin visual.
              selectedMarkerId: widget.selectedMarkerId ?? _selected?.id,
              // PROD-2205: multi-selection for the zine item-page map
              // (event with several venues paints all N yellow).
              // Combined with `selectedMarkerId` at the stamping step.
              selectedMarkerIds: widget.selectedMarkerIds,
              onPinHoverEnter: _handlePinHoverEnter,
              onPinHoverExit: _handlePinHoverExit,
              interactive: _liveInteractive,
              boundsConfig: widget.boundsConfig,
              // req3: imperative "fit both points now" for the recenter step A,
              // kept distinct from boundsConfig so it never collides.
              fitBoundsOverride: _fitBoundsOverride,
              fitBoundsToken: _internalFitBoundsToken,
              onMapReady: widget.onMapReady,
              onMapMoved: _handlePlatformMapMoved,
              onUserGesture: _handleUserGesture,
              isDark: widget.isDark,
              optimizeForSmallSize: widget.optimizeForSmallSize,
              maxZoom: widget.maxZoom,
              cursorOverride: widget.cursorOverride,
              cluster: widget.cluster,
              fitToMarkersToken: effectiveFitToken,
              // Two independent intents ("restore the camera" from the consumer;
              // "go to my location" from the button) share one ease-to-centre
              // branch on the platform. Summing keeps either one's bump visible
              // as a change.
              centerToToken: widget.centerToToken + _internalCenterToToken,
              categoryIcons: widget.categoryIcons,
              categoryIconAssets: widget.categoryIconAssets,
              showPinCaptions: widget.showPinCaptions,
              pinIconSizeStops: widget.pinIconSizeStops,
              customSelection: widget.customSelection,
              onCameraIdle: _handleCameraIdle,
              onCameraMove: widget.onCameraMove,
              debugOverlay: widget.debugOverlay,
              debugOverlayShapes: widget.debugOverlayShapes,
              debugSearchArea: widget.debugSearchArea,
              dotHintsGeoJson: widget.dotHintsGeoJson,
              onDotHintTap: widget.onDotHintTap,
              viewportPaddingTop: widget.viewportPaddingTop,
              viewportPaddingBottom: widget.viewportPaddingBottom,
              captionSizeMul: widget.captionSizeMul,
            ),

            // PROD-2017: top-right floating buttons. Hidden when the
            // map is locked (gestures off) so the user isn't offered
            // controls they can't act on — same rule list_map_view
            // applied locally before this lifted to the shell.
            //
            // When [myLocationButtonBottomInset] is set, the my-location button
            // moves to the bottom-right (rendered below) and only fit-all stays
            // in this top-right column.
            if (showTopButtons)
              Positioned(
                top: widget.topButtonsTopInset ?? 16,
                right: 16,
                child: Column(
                  children: [
                    if (widget.showFitAllButton)
                      _CircleButton(
                        icon: Icons.fit_screen,
                        onTap: _handleFitAllTap,
                      ),
                    if (widget.showFitAllButton &&
                        widget.myLocationButtonBottomInset == null &&
                        widget.showMyLocationButton &&
                        locationState.hasLocation)
                      const SizedBox(height: 8),
                    if (widget.myLocationButtonBottomInset == null &&
                        widget.showMyLocationButton &&
                        locationState.hasLocation)
                      _CircleButton(
                        icon: Icons.my_location,
                        onTap: () => _handleMyLocationTap(locationState),
                      ),
                    // Zoom pair last in the column, so adding it never moves
                    // the controls a surface already had.
                    if (widget.showZoomButtons) ...[
                      if (widget.showFitAllButton ||
                          (widget.myLocationButtonBottomInset == null &&
                              widget.showMyLocationButton &&
                              locationState.hasLocation))
                        const SizedBox(height: 8),
                      _CircleButton(
                        icon: Icons.add,
                        semanticLabel: Lt.of(context).mapZoomInLabel,
                        onTap: () =>
                            _handleZoomTap(MapboxMapWidget.zoomButtonStep),
                      ),
                      const SizedBox(height: 8),
                      _CircleButton(
                        icon: Icons.remove,
                        semanticLabel: Lt.of(context).mapZoomOutLabel,
                        onTap: () =>
                            _handleZoomTap(-MapboxMapWidget.zoomButtonStep),
                      ),
                    ],
                  ],
                ),
              ),

            // Bottom-right my-location button (Map page): hugs the results
            // drawer's top edge via an animated bottom offset the caller feeds
            // from the drawer height. Rendered as part of the map layer so the
            // drawer (later in the page's Stack) paints over it once it grows
            // past the button. Same interactive gate as the top-right buttons.
            if (_liveInteractive &&
                widget.myLocationButtonBottomInset != null &&
                widget.showMyLocationButton &&
                locationState.hasLocation)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                right: 12,
                bottom: widget.myLocationButtonBottomInset! + 12,
                child: _CircleButton(
                  icon: Icons.my_location,
                  onTap: () => _handleMyLocationTap(locationState),
                ),
              ),

            // Activation chip — only on static-by-default surfaces.
            if (showActivationChip)
              Positioned(
                bottom: 12,
                right: 12,
                child: _ActivationChip(
                  label: _activated
                      ? Lt.of(context).mapActivateChipLock
                      : Lt.of(context).mapActivateChipPrompt,
                  icon: _activated
                      ? Icons.image_outlined
                      : Icons.touch_app_outlined,
                  onTap: () {
                    setState(() => _activated = !_activated);
                    widget.onInteractiveChanged?.call(_activated);
                  },
                ),
              ),

            // PROD-2042 Wave 2: location-status banner. Renders when
            // `showLocationStatusBanners` is true AND the current
            // location state warrants a banner (IP fallback → CTA;
            // approximate → display badge). Owned by the widget so
            // every consumer gets a consistent look + tap handler.
            if (locationBanner != null) locationBanner,

            // Pin tooltip — rendered when a marker is selected. The
            // overlay computes its own clamped position from the
            // anchor + the viewport size.
            if (tooltipVisible)
              _PinTooltipOverlay(
                anchor: _selectedPixel!,
                viewport: viewport,
                content: widget.tooltipContentResolver!(_selected!)!,
                marker: _selected!,
                // PROD-2016: wrap the consumer's `onViewDetails` so
                // we also fire `map_pin_view_details_click`. Analytics
                // happens BEFORE navigation so the event isn't lost
                // when the consumer pushes a route.
                onViewDetails: (m) {
                  final itemType = m.category?.wire ?? 'unknown';
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackMapPinViewDetailsClick(
                        itemId: m.id,
                        itemType: itemType,
                        mapContext: widget.analyticsContext ?? 'unknown',
                      );
                  widget.onViewDetails?.call(m);
                },
                onDismiss: _closeTooltip,
                onHoverEnter: _handleTooltipHoverEnter,
                onHoverExit: _handleTooltipHoverExit,
              ),
          ],
        );
      },
    );
  }
}

/// PROD-2016 / PROD-2046: anchored pin tooltip — renders above the
/// tapped pin with a notch pointing down to it.
///
/// Placement rules (PROD-2046 "Option A" — consistent placement):
/// - The platform layer programmatically pans the map so that any
///   tapped pin lands at a fixed screen target ({viewport.width/2,
///   viewport.height * `_pinTargetYFraction`}). `anchor` IS that fixed
///   target — independent of where the pin originally was on screen,
///   independent of which pin was tapped.
/// - Card is ALWAYS centred horizontally on the anchor. No edge-clamping.
/// - Card is ALWAYS above the pin. No above/below flip.
/// - Arrow apex always sits directly under the card's horizontal centre
///   (so it always lines up perfectly with the pin).
///
/// Single fixed-position layout — guarantees the tooltip looks the same
/// regardless of which pin was tapped or where it was on screen at tap
/// time. The camera pan absorbs the variability.
///
/// Trade-off: on very narrow viewports (<~256 px wide) the card
/// overflows horizontally because we don't clamp — the centred-on-the-
/// pin behaviour is the load-bearing guarantee. Mobile portrait
/// (≥360 px) is comfortably above this threshold; desktop and tablet
/// are too.
class _PinTooltipOverlay extends StatelessWidget {
  final Offset anchor;
  final Size viewport;
  final MapPinTooltipContent content;
  final MapMarker marker;
  final OnMapPinViewDetails? onViewDetails;
  final VoidCallback onDismiss;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;

  /// Distance from the pin CENTRE to the notch apex, in screen pixels.
  /// The platform layer now projects the marker's lat/lng to a screen
  /// pixel so `anchor` IS the pin centre — independent of where in the
  /// hit area the user tapped (`mapbox_map_web.dart` `_unclusteredClickCb`
  /// + `mapbox_map_native.dart` `_handleClusterTap` / `_onMapTap`,
  /// PROD-2046). With a 10 px gap and selected-pin radius 12, the
  /// notch's apex sits just inside the pin's outer edge → looks
  /// "kissing the pin" without floating off.
  static const double _apexGap = 10;

  /// Triangular notch height. The arrow's footprint is
  /// `_arrowWidth × _arrowSize`.
  static const double _arrowSize = 8;
  static const double _arrowWidth = 16;

  /// Card width — fixed so the Positioned overlay has a known
  /// horizontal extent. Vertical extent is intentionally NOT fixed:
  /// the Column inside grows to fit its content and the layout
  /// anchors from the BOTTOM edge so the actual card height doesn't
  /// affect where the arrow apex lands (PROD-2046 fix — previously
  /// anchoring from `top` plus a math-only `_height` constant left a
  /// phantom gap because the constant overestimated the actual
  /// rendered card height). The tooltip's actual
  /// rendered size matches because the content (18 px title up to 2
  /// lines, type tag, optional DS button) is bounded. Measuring
  /// intrinsic size dynamically is fragile and unnecessary here.
  static const double _width = 240;

  const _PinTooltipOverlay({
    required this.anchor,
    required this.viewport,
    required this.content,
    required this.marker,
    required this.onViewDetails,
    required this.onDismiss,
    required this.onHoverEnter,
    required this.onHoverExit,
  });

  /// Resolves placement in viewport coordinates.
  ///
  /// Always-centred-above layout (Option A): the platform layer has
  /// already panned the map so `anchor` is the fixed screen target —
  /// no per-pin variability remains to resolve here.
  ///
  /// Returns:
  /// - `cardLeft`: x of the card's left edge.
  /// - `boxBottom`: distance from the viewport's BOTTOM edge to the
  ///   bottom of the Column (card + arrow). Used as `Positioned.bottom`
  ///   so the Column grows UPWARD from the apex — the arrow's tip
  ///   always sits exactly `_apexGap` above the pin centre regardless
  ///   of the card's actual rendered height.
  /// - `arrowOffsetX`: x-offset of the arrow's left edge within the
  ///   card's local x — always centred since the anchor is the card's
  ///   horizontal midpoint by construction.
  ({double cardLeft, double boxBottom, double arrowOffsetX})
  _resolvePosition() {
    final double cardLeft = anchor.dx - _width / 2;
    final double boxBottom = viewport.height - anchor.dy + _apexGap;
    final double arrowOffsetX = (_width - _arrowWidth) / 2;
    return (
      cardLeft: cardLeft,
      boxBottom: boxBottom,
      arrowOffsetX: arrowOffsetX,
    );
  }

  /// Accent color for the type tag — matches the venue/event detail page
  /// tags so the tooltip's "Sítio" / "Evento" chip reads as the same
  /// primitive (`SokoTag`) the user sees on the page they navigate to.
  /// Falls back to a neutral fill when the marker has no category — only
  /// possible for legacy `MapMarker.pin/.place` call sites that don't
  /// pass one (single-pin detail pages don't show the tooltip today, so
  /// the fallback is effectively unreachable on the cover/hub maps).
  static Color _tagBackground(MapMarkerCategory? category) {
    switch (category) {
      case MapMarkerCategory.event:
        return AppColors.sokoEventAccent;
      case MapMarkerCategory.venue:
        return AppColors.sokoVenueAccent;
      case null:
        return AppColors.sokoShade5;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.surfaceDark : Colors.white;
    final fg = isDark ? AppColors.textPrimaryDark : AppColors.sokoInk;
    final shadow = isDark
        ? AppColors.shadowDark
        : Colors.black.withValues(alpha: 0.15);

    final pos = _resolvePosition();

    final lt = Lt.of(context);

    return Positioned(
      left: pos.cardLeft,
      bottom: pos.boxBottom,
      width: _width,
      // PROD-2016 (web): MouseRegion keeps the tooltip open while
      // the cursor is over it — the shell cancels its pending close
      // timer on enter and re-starts on exit. No-op on touch.
      child: MouseRegion(
        onEnter: (_) => onHoverEnter(),
        onExit: (_) => onHoverExit(),
        // PROD-2016 A11y: Esc closes the tooltip and returns focus to
        // the surrounding map area. `autofocus: true` puts the View
        // Details button at the top of the tab order so keyboard
        // users land on the actionable element.
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              onDismiss();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          // PROD-2016 A11y: announce the tooltip as a live region so
          // screen readers read the title + subtitle when the tooltip
          // appears; mark the whole surface as a `dialog`-ish container
          // for traversal.
          child: Semantics(
            container: true,
            liveRegion: true,
            label: '${content.title}, ${content.subtitle}',
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [BoxShadow(color: shadow, blurRadius: 10)],
                    ),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          content.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                            color: fg,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SokoTag(
                          background: _tagBackground(marker.category),
                          child: Text(
                            content.subtitle,
                            style: SokoTag.textStyle,
                          ),
                        ),
                        if (content.showViewDetails) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Semantics(
                              button: true,
                              label: lt.mapPinTooltipViewDetails,
                              child: BtSqIco(
                                icon: null,
                                label: lt.mapPinTooltipViewDetails,
                                variant: BtSqIcoVariant.selected,
                                onTap: () {
                                  // Close the overlay first, then defer
                                  // the navigation to the next frame.
                                  // Pushing a route synchronously after
                                  // `onDismiss()` mutates the navigator
                                  // while the setState that removes this
                                  // overlay is still pending — the
                                  // resulting build cycle is inconsistent
                                  // and surfaces on web as a cascade of
                                  // "Tried to build dirty widget in the
                                  // wrong build scope" / "Looking up a
                                  // deactivated widget's ancestor is
                                  // unsafe" / "Cannot get renderObject of
                                  // inactive element" assertion failures
                                  // both on push AND on pop-back.
                                  onDismiss();
                                  final cb = onViewDetails;
                                  if (cb != null) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback(
                                          (_) => cb(marker),
                                        );
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _TooltipArrow(offsetX: pos.arrowOffsetX, color: bg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// PROD-2046: triangular notch glued to the bottom of the tooltip card,
/// apex pointing down to the pin. Solid fill matches the card; no shadow
/// on the triangle itself — the card's [BoxShadow] provides enough
/// visual anchoring and a separate blurred shadow on a tiny triangle
/// reads as noise more than as polish.
class _TooltipArrow extends StatelessWidget {
  final double offsetX;
  final Color color;

  const _TooltipArrow({required this.offsetX, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: offsetX),
      child: CustomPaint(
        size: const Size(
          _PinTooltipOverlay._arrowWidth,
          _PinTooltipOverlay._arrowSize,
        ),
        painter: _TooltipArrowPainter(color: color),
      ),
    );
  }
}

class _TooltipArrowPainter extends CustomPainter {
  final Color color;

  const _TooltipArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TooltipArrowPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _ActivationChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ActivationChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.surfaceDark : Colors.white;
    final fg = isDark ? AppColors.textPrimaryDark : AppColors.sokoInk;
    final shadow = isDark
        ? AppColors.shadowDark
        : Colors.black.withValues(alpha: 0.15);

    // PROD-1978: explicit cursor wrap so the desktop hover affordance
    // matches the pin/cluster hover treatment even with Mapbox's
    // canvas-container `cursor: grab` bleeding through underneath.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bg.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: shadow, blurRadius: 8)],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// PROD-2017: top-right floating button used for the fit-all and my-
/// location overlays. Lifted from `list_map_view` so every consumer of
/// [MapboxMapWidget] that opts in via [MapboxMapWidget.showFitAllButton]
/// / [showMyLocationButton] gets the same look + tap target.
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  /// Screen-reader name. The icon-only buttons carry no text, so without this
  /// they announce as an unlabelled button.
  final String? semanticLabel;

  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? AppColors.surfaceDark : Colors.white;
    final shadowColor = isDark
        ? AppColors.shadowDark
        : Colors.black.withValues(alpha: 0.2);
    final iconColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;

    // PROD-3310: shield the floating control from Mapbox click-through. On iOS
    // Safari a tap on this Flutter overlay is followed by a *synthetic* click
    // that lands on the HtmlElementView (the Mapbox canvas) underneath, which
    // the map-wide handler (`onMapTapLatLng`) reads as a location selection —
    // moving the picker anchor and defeating the my-location / fit-all step.
    // [PointerInterceptor] drops an HTML shield over the button so that leaked
    // click never reaches the canvas. No-op on non-web (returns the child).
    return PointerInterceptor(
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: Clickable(
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: bgColor.withValues(alpha: 0.95),
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: shadowColor, blurRadius: 8)],
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
        ),
      ),
    );
  }
}
