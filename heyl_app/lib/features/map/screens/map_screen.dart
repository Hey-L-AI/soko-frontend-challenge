import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, setEquals;
import 'package:flutter/material.dart';

import '../../../core/utils/defer_provider_write.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/config/environment.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/utils/web_history.dart';
import '../../../data/models/map_debug.dart';
import '../../../data/models/map_pin.dart';
import '../../../data/models/user_list.dart';
import '../../../data/models/user_profile.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/providers/shell_stray_tap_provider.dart';
import '../../../shared/utils/map_debug_overlay.dart' show MapDebugShape;
import '../../../shared/utils/map_mercator.dart';
import '../../../shared/utils/map_zoom_level.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/detail_seed_provider.dart';
import '../../../providers/city_scope_provider.dart';
import '../../../providers/location_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../lists/models/search_scope.dart';
import '../../../shared/widgets/mapbox_map_widget.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../event_detail/widgets/event_detail_sheet.dart';
import '../../item_detail/widgets/item_detail_sheet.dart';
import '../../venue_detail/widgets/venue_detail_sheet.dart';
import '../models/map_active_search.dart';
import '../models/map_query.dart';
import '../utils/map_camera.dart';
import '../utils/map_deep_link_params.dart';
import '../utils/map_area_display_mode.dart';
import '../utils/map_leave_prompt.dart';
import '../providers/discovery_facets_provider.dart';
import '../providers/map_execution_command_provider.dart';
import '../providers/map_focus_session_provider.dart';
import '../providers/map_dot_hints_provider.dart';
import '../providers/map_grid_provider.dart';
import '../providers/map_highlight_provider.dart';
import '../providers/map_leave_prompt_provider.dart';
import '../providers/map_markers_provider.dart';
import '../providers/map_query_provider.dart';
import '../providers/map_render_provider.dart';
import '../providers/map_search_executor.dart'
    show clearMapActiveSearch, kMapLocationPointZoom;
import '../providers/map_search_provider.dart';
import '../providers/map_selection_provider.dart';
import '../providers/map_seed_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../utils/map_grid_selection.dart';
import '../utils/map_highlight_geometry.dart';
import '../../../shared/utils/map_pin_assets.dart';
import '../utils/map_pin_labels.dart';
import '../widgets/map_debug_tab.dart';
import '../widgets/boundary_hover_cache.dart';
import '../widgets/boundary_hover_controller.dart';
import '../widgets/map_canvas_shield.dart';
import '../widgets/map_open_transition.dart';
import '../widgets/map_drawer_metrics.dart';
import '../widgets/map_filter_bar.dart';
import '../widgets/map_results_sheet.dart';
import '../widgets/map_search_bar.dart';
import '../widgets/map_search_focused_overlay.dart';
import '../widgets/map_suggest_dropdown.dart';

/// PROD-2671/2736 — the dedicated **Map page** (v0, admin-only, web-first).
///
/// Composes a full-screen Mapbox map (generic pins from the slim `/map/pins`
/// payload, keyed by entity) with the [MapResultsSheet] (PROD-3043: the
/// gesture-driven, 3-snap bottom drawer — results grid + question buttons + the
/// open filter's option row) and the top
/// [MapSearchBar] (PROD-3496, flag-gated) + [MapShortcutChips] — all writing
/// [MapQuery]. The map seeds
/// its camera from a [MapCameraTarget] (an explicit centre + search radius);
/// settle-to-search flows through `onCameraIdle` →
/// [MapQueryNotifier.onCameraSettled] → [mapPinsProvider].
///
/// [initialCamera] is the seam for the direction we're heading — opening the map
/// at a specific point + radius passed in (a saved search, a deep link, a
/// "search this area" hand-off). When null (today's only caller), the page opens
/// on the **user's location** at [kDefaultMapRadiusMeters].
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({
    super.key,
    this.initialCamera,
    this.seeded = false,
    this.deepLink = MapDeepLinkParams.none,
  });

  /// Explicit opening camera. `null` → derive from the user's location.
  final MapCameraTarget? initialCamera;

  /// PROD-4124 — filters preselected by the `/map` URL, already parsed and
  /// validated by the route. [MapDeepLinkParams.none] for a plain `/map`, which
  /// keeps every existing path byte-identical.
  ///
  /// Applied in `initState` on the opening path and in `didUpdateWidget` on a
  /// re-arrival — the route's page key is constant, so a second `/map?…` does
  /// not remount this screen and an initState-only read would silently do
  /// nothing.
  final MapDeepLinkParams deepLink;

  /// Seeded (read-only-results) mode — the chat map. The selection / grid /
  /// pins providers are overridden with a FIXED list (see `map_seed.dart`) in
  /// the route's `ProviderScope`, so this screen must NOT drive the live
  /// pipeline: every query-seeding path (`_seedQueryCamera`, `_seedFrom`,
  /// `_applyCityScope`) and the pan→refetch commit short-circuit, and the
  /// live-search chrome (search bar, shortcut chips + "search this area",
  /// the What/From/When filter footer) is hidden. Default `false` keeps the
  /// standalone `/map` byte-identical. Pair with a non-null [initialCamera]
  /// (framed from the seeded items) so the location/city opening path is
  /// skipped entirely.
  final bool seeded;

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  // The opening camera: a centre + a search radius the zoom is derived from
  // (see [MapCameraTarget] + [zoomForRadius] in `utils/map_camera.dart`).
  double? _initialLat;
  double? _initialLng;
  double _initialRadiusMeters = kDefaultMapRadiusMeters;

  /// The default opening zoom (PROD-3124, was exact-fix-only PROD-2671): every
  /// location-seeded open — exact, approximate, or IP fallback — starts at
  /// the walking-level zoom, matching the my-location button's base zoom
  /// (`MapboxMapWidget.userLocationZoom`), so opening the map and tapping
  /// "my location" land on the same framing. Explicit camera targets
  /// (deep link / saved search) and a user-picked city keep their own
  /// radius/bbox-derived framing (they're deliberate, not "default" opens).
  static const double _kOpenZoom = kMapZoomWalkingStart;

  /// When set, overrides the radius-derived opening zoom (see [_seedFrom]):
  /// location-seeded opens set [_kOpenZoom]; the explicit-target and
  /// city-pick paths leave this null and fall back to [zoomForRadius] over
  /// [_initialRadiusMeters] (bbox/radius framing).
  double? _initialZoomOverride;

  // Once the user pans we stop auto-recentring (the live camera then drives
  // MapQuery via onCameraIdle, not the other way round). A precise-fix upgrade
  // is still honoured once (see [_seedFrom]).
  bool _userPanned = false;
  bool _centeredOnPreciseFix = false;

  /// Set once we've opened on a **user-selected city** ([cityScopeProvider], an
  /// explicit non-auto pick) — then the location-based seeding ([_seedFrom]) is
  /// suppressed, so the map stays framed on the chosen city, not the user's GPS.
  bool _pinnedToCity = false;

  // PROD-3193: camera-centre boundary resolution reuses the picker's
  // cache/debounce controller. The cache is also the hysteresis: small pans
  // inside a known polygon never refetch or flicker the display mode.
  final _areaBoundaryCache = BoundaryHoverCache();
  late final BoundaryHoverController _areaBoundary;
  final int _areaBoundarySequence = 0;
  MapCameraState? _areaDisplayCamera;
  MapAreaDisplayMode? _areaDisplayOverride;

  // PROD-3193 area display is hidden for now: no on-map boundary/radius overlay
  // and no boundary/radius toggle. Flip to `true` to restore both. Kept as a
  // non-const field on purpose so the resolution logic below stays live (and
  // warning-free) while the surface is dark.
  final bool _showAreaDisplay = false;

  // PROD-3194: leaving is intercepted so system back, browser back and the
  // visible back affordance all funnel through one path. `_allowRoutePop`
  // flips only after the leave has been committed.
  bool _allowRoutePop = false;
  Object? _leaveNavigationOwner;

  /// Held from `initState` so [dispose] never has to touch `ref`.
  ///
  /// `ref.read` inside `ConsumerState.dispose()` **always throws**
  /// (`Bad state: Cannot use "ref" after the widget was disposed`):
  /// `StatefulElement.unmount()` calls `super.unmount()` — which nulls
  /// `_widget`, so `context.mounted` is already false — *before* it calls
  /// `state.dispose()`, and riverpod's `_assertNotDisposed` gates on exactly
  /// that. The throw is swallowed by `BuildOwner.finalizeTree()`, so it never
  /// crashes; it just silently skips the rest of `dispose()`.
  ///
  /// That is not academic here: it left this screen's leave-handler registered
  /// on the app-scoped guard after the map was gone, and since
  /// [DiscoveryBottomNav] routes **every** nav tap through that guard, one
  /// visit to `/map` killed the whole bottom nav until app restart. The guard
  /// object outlives this widget (plain non-autoDispose `Provider`), so
  /// holding it is safe. See
  /// `docs/learnings/ref-read-in-consumerstate-dispose-always-throws.md`.
  MapLeaveNavigationGuard? _leaveNavigationGuard;

  /// PROD-3627 — captured in `initState` so `dispose` can clear it without
  /// touching `ref` (which throws there — see [_leaveNavigationGuard]).
  StateController<ShellStrayTapDismisser?>? _strayTapDismiss;

  /// The exact callback this state registered. `dispose` clears the provider
  /// only if it still holds THIS one — the same ownership rule
  /// [MapLeaveNavigationGuard] uses, so a slow dispose during a fast route
  /// replacement cannot wipe a newer MapScreen's registration.
  ShellStrayTapDismisser? _strayTapCallback;

  /// PROD-3223: a one-shot trigger for the NEXT camera settle, used when a
  /// programmatic camera move IS the search (today only the "Search this area"
  /// re-centre). Without it, our own re-centre settles as `onCameraIdle` with
  /// the default `'pan'` and clobbers the `'area'` trigger before results
  /// resolve, so `map_area_searched` was mislabeled `pan`. Consumed by the next
  /// `onCameraIdle`; cleared by any real user gesture ([_onUserMapGesture]) so a
  /// stale intent can never leak onto a later user pan.
  String? _pendingSettleTrigger;

  /// PROD-3524 — the focused-mode ⇄ URL mirror's memory (previous URL, a write
  /// in flight, and whether the marker in the URL is ours to pop).
  ///
  /// Held as one object because [stepMapFocusUrl] advances all three together
  /// in a fixed order, and getting that order wrong is the entire bug surface:
  /// ownership must be recomputed from the current observation BEFORE the
  /// action is chosen. Per-visit by nature — the State is recreated on every
  /// `/map` mount, which is correct, since a fresh visit owns no entry yet.
  MapFocusUrlState _focusUrlState = const MapFocusUrlState();

  @override
  void initState() {
    super.initState();
    _areaBoundary = BoundaryHoverController(
      cache: _areaBoundaryCache,
      selectionSeq: () => _areaBoundarySequence,
      resolve: (lat, lng, cancel) => ref
          .read(geoApiProvider)
          .resolveBoundaryAt(
            lat: lat,
            lng: lng,
            locale: Localizations.localeOf(context).languageCode,
            cancelToken: cancel,
          ),
    );
    _areaBoundary.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
    final leaveNavigationGuard = ref.read(mapLeaveNavigationGuardProvider);
    _leaveNavigationGuard = leaveNavigationGuard;
    _leaveNavigationOwner = leaveNavigationGuard.register((navigate) {
      // PROD-3627 (Decision #51): a shell-level navigation (bottom-nav tap)
      // while the focused search mode is up **is consumed** — it closes the
      // mode and nothing else. A second tap navigates normally.
      //
      // The bottom nav lives outside the map's widget subtree (it is the
      // Scaffold's `bottomNavigationBar`, a sibling of the body the focused
      // overlay fills), so the scrim cannot absorb it the way it absorbs a
      // tap on the map, the drawer or the filter row. This guard is the only
      // seam that sees those taps, which is why the rule is enforced here.
      //
      // PROD-3496 used to exit the mode and then navigate anyway. The reversal
      // is deliberate: with the keyboard up, a stray tap must never fire an
      // unintended action, least of all leaving the page.
      //
      // ⚠️ Returning here is load-bearing. `_requestLeave` owns the page-LEAVE
      // flow (divergence prompt + the `_allowRoutePop` latch), and exiting
      // focused mode is not leaving the page — `resolveMapBackAction` draws
      // exactly that line for the back paths. Falling through would let a
      // dismiss tap arm the leave latch.
      if (ref.read(mapSearchProvider).focused) {
        ref.read(mapSearchProvider.notifier).exitFocus();
        return Future<void>.value();
      }
      return _requestLeave(onComplete: navigate);
    });
    // PROD-3627 — the LAST surface an outside tap has to cover: the shell's
    // side tabs (Feedback, admin Loc) float in a Stack ABOVE the whole
    // Scaffold, so the focused overlay's scrim — which lives inside the map's
    // own subtree — can never reach them. Registered once for the page's
    // lifetime; the callback re-checks `focused` itself, so a stale
    // registration is a no-op rather than a permanently dead tab (see the
    // provider's doc, and the leaked-nav-guard outage it cites).
    _strayTapDismiss = ref.read(shellStrayTapDismissProvider.notifier);
    _strayTapCallback = () {
      // `mounted` FIRST, and it is the whole reason a stale registration is
      // safe: `State.mounted` is legal to read after dispose (it returns
      // false), whereas `ref` is NOT — reading a provider from a disposed
      // ConsumerState throws. Without this the "degrades to a no-op" property
      // would actually be "throws inside the tab's onTap", which is worse than
      // the dead tab it was meant to prevent.
      if (!mounted) return false;
      if (!ref.read(mapSearchProvider).focused) return false;
      ref.read(mapSearchProvider.notifier).exitFocus();
      return true;
    };
    // Deferred to post-frame, and that is load-bearing since PROD-3524.
    //
    // `shellStrayTapDismissProvider` is WATCHED by `DiscoveryShell` (it gates
    // the side tabs). The map is now reached by a declarative `context.go`,
    // which rebuilds the shell's page list in the very frame this `initState`
    // runs — so a synchronous write here lands while a listener is mid-build
    // and throws "Tried to modify a provider while the widget tree was
    // building", taking the whole map page down with it. Under the old
    // imperative `context.push` the shell was already settled, which is the
    // only reason this ever worked.
    //
    // Losing the first frame costs nothing: a stray tap needs the focused
    // search mode to be open, which cannot happen before the page has painted.
    // Registration stays identity-based, so `dispose` still can't wipe a newer
    // MapScreen's callback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _strayTapDismiss?.state = _strayTapCallback;
    });
    // PROD-3219: opening the dedicated Map page. Reuses `open_map` with a
    // map-page context (distinct from the chat places-modal, which is the only
    // other `open_map` caller). Fires once per mount.
    ref
        .read(unifiedAnalyticsProvider)
        .trackOpenMap(context: MapContext.mapPage);
    // PROD-4124 — preselected filters, applied BEFORE any camera seeding.
    //
    // The order is what makes this free: `MapPinsNotifier._fetch` bails on
    // `!hasCenter`, and no centre exists yet on the opening path — so this
    // write issues no request, and the camera seed below fires the single
    // fetch with every filter already applied.
    //
    // ⚠️ Post-frame, NOT synchronous, for the same reason as the stray-tap
    // registration above — and this one was shipped wrong and caught in the
    // browser. `initState` runs inside the build phase, `mapPinsProvider`
    // listens to `mapQueryProvider` with `fireImmediately: true`, and its
    // `_fetch` writes its own loading state. A synchronous write here therefore
    // lands while a listener is mid-build and Riverpod throws
    // "Tried to modify a provider while the widget tree was building",
    // surfacing as a `StateNotifierListenerError` against `MapQueryNotifier`
    // that takes the whole page down.
    //
    // Registered BEFORE the camera callbacks below, and post-frame callbacks
    // run in registration order — so the ordering the paragraph above depends
    // on survives the deferral.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyDeepLink(widget.deepLink);
    });
    final target = widget.initialCamera;
    if (target != null) {
      // Explicit target (future: saved search / deep link) wins outright — no
      // location seeding, no upgrades.
      _initialLat = target.lat;
      _initialLng = target.lng;
      _initialRadiusMeters = target.radiusMeters;
      _centeredOnPreciseFix = true;
      _userPanned = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // (Seeded map opens the results drawer to `half` from inside the sheet,
        // once its metrics resolve — see MapResultsSheet's seeded one-shot.)
        _seedQueryCamera(
          lat: target.lat,
          lng: target.lng,
          radiusMeters: target.radiusMeters,
        );
      });
      return;
    }
    // No explicit target → open on the user's **selected city** if they've
    // picked one that isn't the auto-detected default; otherwise the user's
    // location. Both resolve async, so try the city first, then fall back to
    // location seeding (which no-ops once we've pinned to a city).
    WidgetsBinding.instance.addPostFrameCallback((_) => _seedOpeningCamera());
  }

  /// PROD-4124 — a **second** `/map?…` arriving while this screen is already
  /// mounted.
  ///
  /// The route's page carries a constant `ValueKey('mapa')`, so go_router
  /// updates this widget rather than remounting it: `initState` does not run
  /// again, and without this the new link's filters would be silently dropped.
  /// A push notification landing on an open map is the case that hits it.
  ///
  /// Guarded on inequality so an unrelated rebuild (any parent rebuild produces
  /// a fresh `MapScreen` instance) does not re-apply the same filters and cost
  /// a refetch.
  @override
  void didUpdateWidget(covariant MapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.deepLink == oldWidget.deepLink) return;
    final cam = widget.initialCamera;
    final cameraMoved = cam != null && cam != oldWidget.initialCamera;
    // Post-frame for the same reason as `initState` — `didUpdateWidget` is
    // named in Riverpod's own "not allowed" list, so a synchronous write here
    // throws exactly as it did on the opening path.
    //
    // Both halves go in ONE callback so their order is fixed: the query write
    // first, then the camera. Unlike the opening path the query already has a
    // centre, so that write does fetch; the camera move supersedes it rather
    // than adding to it (`_fetch` cancels the in-flight token first), leaving
    // one completed request. The camera is MOVED, not seeded — `seedViewport`
    // no-ops once a centre exists, by design.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyDeepLink(widget.deepLink);
      if (cameraMoved) {
        _easeCameraTo(
          cam.lat,
          cam.lng,
          zoomForRadius(
            cam.radiusMeters,
            cam.lat,
            MediaQuery.sizeOf(context).width,
          ),
        );
      }
    });
  }

  /// Write a deep link's filters into [mapQueryProvider], plus the filter bar's
  /// "touched" highlights.
  ///
  /// Two providers, deliberately, because they answer different questions. The
  /// query is *what the map is filtering by*; `mapTouchedFiltersProvider` is
  /// *which questions the user (or their link) actually answered* — and card B3
  /// makes a link's answer count even when it equals the default. That
  /// distinction is unrecoverable from the query alone, which is why
  /// [MapDeepLinkParams.touchedTabs] carries it.
  ///
  /// The touched set is **merged, not replaced**: on a re-arrival the user may
  /// have picked filters by hand since, and a link that preselects `entity`
  /// should not un-pink their `Quando`.
  void _applyDeepLink(MapDeepLinkParams link) {
    // Seeded (chat) map: fixed, provider-overridden pins — never drive the live
    // query. Mirrors every other seeding path on this screen.
    if (widget.seeded || !link.hasFilters) return;
    ref.read(mapQueryProvider.notifier).applyDeepLink(link);
    if (link.touchedTabs.isNotEmpty) {
      ref
          .read(mapTouchedFiltersProvider.notifier)
          .update((prev) => {...prev, ...link.touchedTabs});
    }
  }

  /// PROD-3833 — seed [mapQueryProvider] with the WHOLE opening camera, so the
  /// first `/map/pins` is already the `pins_version=2` request the map wants
  /// instead of a v1 placeholder the opening settle throws away.
  ///
  /// Takes the camera as arguments rather than reading `_initialLat` /
  /// `_initialLng` / `_initialZoomOverride`, and that is load-bearing: **every
  /// caller assigns those fields AFTER seeding** (`_seedFrom` seeds at the top
  /// and `setState`s the fields below it; `_applyCityScope` the same), so
  /// reading them here would seed the previous frame's camera — null on the
  /// first open. Caught in codex review before it shipped.
  ///
  /// Falls back to [MapQueryNotifier.seedCenter] when the map's box has not
  /// been laid out yet and no rectangle can be computed. That is strictly
  /// today's behaviour, so the worst case of this whole change is the status
  /// quo.
  void _seedQueryCamera({
    required double lat,
    required double lng,
    required double radiusMeters,
    double? zoomOverride,
  }) {
    // Seeded (chat) map: never arm the live `/map/pins` fetch — the pins are a
    // fixed, provider-overridden set. Callers assign the camera-framing fields
    // before calling this, so opening framing is preserved.
    if (widget.seeded) return;
    final notifier = ref.read(mapQueryProvider.notifier);
    final box = _mapBox;
    if (box.width > 0 && box.height > 0) {
      // Mirror `build`'s opening-zoom expression exactly — a seeded rect
      // computed at a different zoom than the map is born at would describe a
      // view the user never sees.
      final zoom =
          zoomOverride ??
          zoomForRadius(radiusMeters, lat, MediaQuery.sizeOf(context).width);
      final cam = openingCameraState(
        centerLat: lat,
        centerLng: lng,
        zoom: zoom,
        widthPx: box.width,
        heightPx: box.height,
        // The same insets the renderer is handed (`searchAreaTopInset` /
        // `searchAreaBottomInset` in `build`), so the seeded rectangle is the
        // same visible rect the map will report back.
        paddingTop: mapTopChromeInset(context),
        paddingBottom: ref.read(mapDrawerBasePeekHeightProvider),
      );
      if (cam != null) {
        notifier.seedViewport(cam);
        return;
      }
    }
    notifier.seedCenter(lat, lng);
  }

  Future<void> _seedOpeningCamera() async {
    // PROD-3188: map and picker share the same session-TTL rule. Awaiting the
    // scope restore means an expired C is discarded before it can re-frame the
    // map, while a fresh C still wins over the durable user location (U).
    final scope = await ref.read(cityScopeProvider.notifier).openSearchCenter();
    if (!mounted) return;
    _applyCityScope(scope);
    _seedFrom(ref.read(locationProvider));
  }

  /// Seed / recentre the opening camera from the user's location — on the first
  /// frame and again whenever [locationProvider] emits, until the user takes
  /// over. Recentres when (a) nothing's been centred yet, or (b) a **precise**
  /// GPS fix arrives after we'd only seeded a fast IP-fallback centroid — that
  /// upgrade is honoured **once even past a pan**, so a slow GPS fix corrects the
  /// "opened on the city, not my location" case. After centring on a precise fix
  /// and the user has panned, it stops.
  void _seedFrom(LocationState loc) {
    // Seeded (chat) map: fixed camera + fixed pins; the location stream must
    // never re-frame or re-query.
    if (widget.seeded) return;
    // The user picked a city → the map stays on it; ignore location seeding.
    if (_pinnedToCity) return;
    final snap = loc.lastLocation;
    if (snap == null) return;
    // A GPS fix (even a coarse one) upgrades a fast IP-fallback centroid — that
    // upgrade is honoured once even past a pan (distinct from [loc.isPrecise],
    // which is stricter: GPS with good accuracy).
    final isGpsFix = !loc.isIpFallback;
    final firstSeed = _initialLat == null;
    final preciseUpgrade = isGpsFix && !_centeredOnPreciseFix;
    if (!firstSeed && _userPanned && !preciseUpgrade) return;

    // PROD-3124 pins every location-seeded open at [_kOpenZoom], so pass it
    // explicitly — `_initialZoomOverride` is only assigned in the `setState`
    // below, i.e. after this call (see [_seedQueryCamera]).
    _seedQueryCamera(
      lat: snap.lat,
      lng: snap.lon,
      radiusMeters: kDefaultMapRadiusMeters,
      zoomOverride: _kOpenZoom,
    );
    if (isGpsFix) _centeredOnPreciseFix = true;

    // Opening framing (default-open only; an explicit [initialCamera] target
    // keeps its own radius and never reaches here). PROD-3124: every
    // location-seeded open — exact, approximate, or IP fallback — starts at
    // [_kOpenZoom] (the walking-level my-location zoom). Previously only
    // exact fixes had a fixed zoom (16); the others framed their accuracy
    // circle / the default area.
    setState(() {
      _initialLat = snap.lat;
      _initialLng = snap.lon;
      _initialZoomOverride = _kOpenZoom;
      _initialRadiusMeters = kDefaultMapRadiusMeters;
    });
  }

  /// Open (and re-frame) on the user's **selected city** ([cityScopeProvider])
  /// when it's an explicit, non-auto pick. City picks frame their bounding box
  /// (or a city-scale fallback); map-picked areas frame their own center and
  /// radius. Pins the map to C so location seeding stops. No-op for U,
  /// country-only scopes, or once the user has panned.
  void _applyCityScope(SearchScope? scope) {
    // Seeded (chat) map: fixed camera; a city-scope change must not re-frame.
    if (widget.seeded) return;
    if (_userPanned) return;
    final target = cameraTargetForSearchScope(scope);
    if (target == null) return;

    _pinnedToCity = true;
    _centeredOnPreciseFix = true; // a city pick pre-empts GPS upgrades
    // Bootstrap the fetch camera before the camera settles; the camera itself
    // re-frames via the widget's centre/zoom below (like the precise upgrade).
    // A city scope frames its bbox, so the zoom is radius-derived — no
    // override, matching `build`'s `_initialZoomOverride ?? zoomForRadius(...)`.
    _seedQueryCamera(
      lat: target.lat,
      lng: target.lng,
      radiusMeters: target.radiusMeters,
    );
    setState(() {
      _initialLat = target.lat;
      _initialLng = target.lng;
      _initialZoomOverride = null; // radius-derived → frames the bbox
      _initialRadiusMeters = target.radiusMeters;
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PROD-2993 — results-highlight session state
  //
  // The full state machine lives in
  // `docs/investigations/context/prod-2993-map-highlight-results-on-scroll.md`.
  // In short: at the drawer's `half` snap the map highlights the pins for the
  // cards in view, and moves the camera ONLY when one of them is hidden behind
  // the drawer. The user's own gestures always win.
  // ═══════════════════════════════════════════════════════════════════════════

  /// Imperative "ease to [_camLat]/[_camLng]/[_camZoom] now" counter.
  ///
  /// Every camera move this feature makes goes through here rather than through
  /// `boundsConfig`. That is not a style preference — both renderers refit a
  /// bbox whenever `boundsConfig.hasBbox && markersChanged`, and this page
  /// rebuilds its markers on **every camera move** (live re-selection,
  /// PROD-2807 #4). A standing `boundsConfig` would therefore drive the camera
  /// from its own output, without end. A token has no such coupling.
  int _centerToToken = 0;

  /// The camera target the token above eases to. Null → the map keeps whatever
  /// the user/seed left it at.
  double? _camLat;
  double? _camLng;
  double? _camZoom;

  /// The live camera, as last reported. The session's snapshot is taken from it.
  MapCameraSnapshot? _liveCamera;

  /// The map's own box, needed to reason in pixels about what the drawer covers.
  Size _mapBox = Size.zero;

  /// Coalesces carousel settles: a fast multi-card fling fires several settles
  /// in quick succession, and we want ONE camera move at the end, not one per
  /// card flown past (PROD-2993 D25). Short — the carousel has already snapped by
  /// the time this fires, so this only de-dupes; it is not the "wait for the user
  /// to stop" delay the vertical-scroll model needed.
  Timer? _scrollSettle;
  static const Duration _kFocusSettle = Duration(milliseconds: 150);

  /// Run a camera-event handler, but **never during a build/layout**.
  ///
  /// Mapbox-gl normally fires camera events while the app is idle, so the handler
  /// (which writes providers) runs immediately. But a programmatic `easeTo`
  /// invoked from the map's `didUpdateWidget` — a build/layout lifecycle — can
  /// interrupt an in-flight ease and fire `moveend` **synchronously**, re-entering
  /// the handler mid-frame. Writing a provider then throws ("Tried to modify a
  /// provider while the widget tree was building"). When that happens, defer the
  /// handler to after the frame. Normal user pans are unaffected (they fire when
  /// idle → the immediate path); only the re-entrant programmatic case defers.
  void _onCameraEvent(VoidCallback handler) {
    final phase = SchedulerBinding.instance.schedulerPhase;
    final safe =
        phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks;
    if (safe) {
      handler();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) handler();
      });
    }
  }

  /// PROD-2807 (#4): push the live camera viewport into the selection so it
  /// re-runs mid-gesture (from move) and stays exact on settle (from idle).
  void _updateLiveViewport(MapCameraState cam) {
    ref.read(mapLiveViewportProvider.notifier).state = MapViewport(
      swLat: cam.swLat,
      swLng: cam.swLng,
      neLat: cam.neLat,
      neLng: cam.neLng,
      zoom: cam.zoom,
    );
    _liveCamera = MapCameraSnapshot(
      lat: cam.centerLat,
      lng: cam.centerLng,
      zoom: cam.zoom,
    );
  }

  /// Drive the camera. Nothing has to be suppressed or timed around it: the map
  /// tells us separately when a move was the USER's ([_onUserMapGesture]), so
  /// our own moves simply never look like theirs.
  void _easeCameraTo(double lat, double lng, double zoom) {
    setState(() {
      _camLat = lat;
      _camLng = lng;
      _camZoom = zoom;
      _centerToToken++;
    });
  }

  /// **The user grabbed the map.** (A drag, a wheel, a pinch — never one of our
  /// own camera moves; both renderers give us a genuine gesture signal, so this
  /// does not have to be inferred from timing.)
  ///
  /// Following stops immediately. The pool is frozen, so what they are now
  /// looking at is an area we have not searched — say so, with "Search this
  /// area", rather than quietly showing them the wrong pins (D9). The next
  /// carousel swipe re-arms us and pulls the camera back to the focused card
  /// (D10 — `_recenterOnFocused` always recenters and clears the dirty flag).
  void _onUserMapGesture() {
    // PROD-3223: a genuine grab overrides any pending programmatic search intent
    // (e.g. a "Search this area" re-centre that never settled) — so a stale
    // `'area'` can't leak onto the user's own pan. Cleared before the
    // session-scoped early-return below so it always runs.
    _pendingSettleTrigger = null;
    final session = ref.read(mapFocusSessionProvider);
    if (session == null) {
      // PROD-3568 — abandon the old area's in-flight requests, which is what
      // `cancelInFlight` was always documented to mean ("the moment the user
      // starts panning"). It sat on `onMapMoved` until now, which fires for our
      // own camera moves and for layout-driven ones too — so a search cancelled
      // its own request. `onUserGesture` is the signal that actually answers
      // "did the user drive this?" (`movestart.originalEvent` on web,
      // `onScroll`/`onZoom` on native).
      //
      // Session-scoped exactly as before: during a results session the camera
      // moves while the user reads the cards, and cancelling the grid's hydrate
      // would abort the very cards they scrolled to.
      ref.read(mapPinsProvider.notifier).cancelInFlight();
      ref.read(mapGridProvider.notifier).cancelInFlight();
      return;
    }
    // PROD-2992: during pin-focus the map is non-interactive — the open detail
    // sheet's modal barrier (and, on web, the canvas shield) absorbs pan/pinch
    // and a tap dismisses it. So this rarely fires while focused; if a gesture
    // ever leaks through, it's a no-op here (pin-focus has no "Search this area"
    // dirty state — that belongs to the results-highlight sessions — and always
    // restores the snapshot on exit).
    if (session.kind == MapFocusSessionKind.pinFocus) return;
    ref.read(mapFocusSessionProvider.notifier).markCameraDirty();
    // Kill any pending recenter — it was scheduled for a camera the user has now
    // overruled, and running it would be the app yanking the map back.
    _scrollSettle?.cancel();
  }

  // ------------------------------------------------------------ session enter

  /// PROD-2993 — is this a WIDE viewport? Wide `half` shows the full grid and
  /// highlights on card HOVER (a distinct session kind); narrow `half` shows the
  /// carousel. Either way the camera machinery is the same. The drawer spans the
  /// map's width, so the screen width is the right proxy for the layout decision.
  bool _isWideViewport() =>
      MediaQuery.sizeOf(context).width >= kMapWideDrawerMinWidth;

  /// PROD-2993 — are we in narrow `half` with the CAROUSEL highlight session
  /// running? The one state where a faded-pin tap selects the card instead of
  /// opening its detail: wide `half` highlights on hover, and full/peek don't
  /// highlight at all.
  bool _isNarrowHalfHighlightActive() =>
      !_isWideViewport() &&
      ref.read(mapDrawerSnapProvider) == MapDrawerSnap.half &&
      ref.read(mapFocusSessionProvider)?.kind ==
          MapFocusSessionKind.resultsHighlight;

  /// The drawer's snap changed. This is the feature's only entry and exit door.
  void _onDrawerSnapChanged(MapDrawerSnap? prev, MapDrawerSnap next) {
    // PROD-3219: every results-drawer snap change — half/full opens (did users
    // actually open the results grid?) and the collapse back to peek.
    ref
        .read(unifiedAnalyticsProvider)
        .trackMapDrawerSnapChange(snap: next.name, previousSnap: prev?.name);
    switch (next) {
      case MapDrawerSnap.half:
        // Entering (or returning to) the highlight state. Narrow drives it off
        // the carousel's centred card; wide drives it off card HOVER — a
        // different session KIND so `mapHighlightProvider` can tell them apart,
        // but BOTH feed the same camera machinery (recenter on the focused pin,
        // freeze the pool + "Search this area" on a pan, restore on close).
        // `enter` is a no-op if a session of this kind is already open — which is
        // exactly what makes `full` a pass-through and stops half→full→half from
        // re-snapshotting a camera our own highlighting had already moved.
        ref
            .read(mapFocusSessionProvider.notifier)
            .enter(
              _isWideViewport()
                  ? MapFocusSessionKind.resultsHoverHighlight
                  : MapFocusSessionKind.resultsHighlight,
              snapshot: _liveCamera,
            );
        if (prev != MapDrawerSnap.full) {
          ref.read(unifiedAnalyticsProvider).trackMapHighlightEnter();
        }
      // The entry recenter (onto the first card) is NOT kicked off here. It
      // can't be: the carousel publishes its focused index, and the drawer its
      // occluded height, only once things have laid out and settled. Firing now
      // would recenter against the wrong (peek) geometry. Instead we react to
      // the focused index and the occluded height once they arrive, below.
      case MapDrawerSnap.full:
        // Pass-through: the session (and its snapshot) survives. The highlight
        // itself switches off — see `mapHighlightProvider`.
        break;
      case MapDrawerSnap.peek:
        _endSession();
    }
  }

  // ------------------------------------------------------------- session exit

  /// Close the session. **Which camera the user ends up with depends entirely on
  /// how they got here** (PROD-2993 D11) — this is the part that is easy to get
  /// subtly, invisibly wrong.
  ///
  /// * They never touched the map → **restore** the snapshot. Closing the drawer
  ///   means "put me back where I was".
  /// * They panned → **keep their camera** and search there. Closing without
  ///   scrolling again is an implicit "Search this area"; restoring would throw
  ///   away a deliberate gesture, which reads as the app undoing your work.
  ///
  /// Either way the freeze lifts, so the next settle re-searches normally.
  void _endSession() {
    final session = ref.read(mapFocusSessionProvider.notifier).exit();
    _scrollSettle?.cancel();
    ref.read(mapVisibleCardIndicesProvider.notifier).state = const [];
    ref.read(mapHoveredCardIndexProvider.notifier).state = null;
    if (session == null) return;

    if (session.cameraDirty) {
      // Their camera stands. But the pool is still the OLD area's — and the
      // freeze meant `onCameraSettled` never saw the pan, so nothing will
      // refetch on its own. Commit the camera we're actually looking at.
      _commitLiveCameraToQuery();
      return;
    }

    final snap = session.snapshot;
    if (snap != null) _easeCameraTo(snap.lat, snap.lng, snap.zoom);
  }

  /// Push the live camera into [mapQueryProvider] by hand.
  ///
  /// Needed because the freeze works by *skipping* `onCameraSettled` — so when a
  /// session ends on a camera the user moved, the query still describes the area
  /// they left, and no further camera event is coming to correct it. Without
  /// this, the map would sit on stale pins indefinitely.
  void _commitLiveCameraToQuery() {
    // Seeded (chat) map: fixed pins — never commit the camera to the query.
    if (widget.seeded) return;
    final vp = ref.read(mapLiveViewportProvider);
    final cam = _liveCamera;
    if (vp == null || cam == null) return;
    ref
        .read(mapQueryProvider.notifier)
        .onCameraSettled(
          lat: cam.lat,
          lng: cam.lng,
          radiusMeters: _radiusForViewport(vp),
          zoom: cam.zoom,
          neLat: vp.neLat,
          neLng: vp.neLng,
          swLat: vp.swLat,
          swLng: vp.swLng,
          // PROD-3219: an explicit "Search this area" (or a session-end with a
          // dirty camera) — tags the resulting `map_area_searched` as 'area'.
          trigger: 'area',
        );
  }

  // ------------------------------------------------ map_area_searched (PROD-3219)

  /// Dedup key of the last `map_area_searched` we logged: coarse centre (3dp) +
  /// zoom bucket + filter signature. Consecutive searches over the same
  /// area/zoom/filters collapse to one — this is what kills the old per-settle
  /// pan spam. `trigger` is deliberately EXCLUDED (see [_onPinsResolved]).
  String? _lastSearchLogKey;

  /// A `/map/pins` search RESOLVED → log the deduped outcome event. Only a
  /// FRESH successful response counts: a cancelled/superseded fetch keeps the
  /// same last-good `data` object ([MapPinsState] never replaces it on cancel),
  /// so the identity guard drops searches the user panned away from before they
  /// resolved. `counts.total` is the area's true post-gate total (0 included —
  /// that's the coverage-gap signal we're after).
  void _onPinsResolved(MapPinsState? prev, MapPinsState next) {
    if (next.isLoading) return;
    final data = next.data;
    if (data == null || identical(data, prev?.data)) return;

    final q = ref.read(mapQueryProvider);
    if (!q.hasCenter) return;
    final trigger = ref.read(mapQueryProvider.notifier).lastTrigger;

    // Key EXCLUDES `trigger` on purpose: an initial seed fetch ('initial') and
    // the first camera-idle commit ('pan') land on the same centre/zoom/filters
    // on every map open — keying on trigger too would double-log that open.
    // Collapsing on area+zoom+filters keeps it to one event per real search
    // (the trigger of whichever resolved first is what we ship). Filter/shortcut
    // changes shift `_filterSig`, so they still log as distinct searches.
    final key =
        '${_bucketCoord(q.centerLat!)},${_bucketCoord(q.centerLng!)}'
        '|${q.zoom.round()}|${q.filterSignature}';
    if (key == _lastSearchLogKey) return;
    _lastSearchLogKey = key;

    ref
        .read(unifiedAnalyticsProvider)
        .trackMapAreaSearched(
          trigger: trigger,
          centerLat: q.centerLat!,
          centerLng: q.centerLng!,
          resultCount: data.counts.total,
          radiusM: q.radiusMeters,
          zoom: q.zoom,
        );
  }

  /// Round a coordinate to 3dp (~110m) for the dedup bucket — the same
  /// precision the event itself ships at.
  double _bucketCoord(double v) => (v * 1000).roundToDouble() / 1000;

  // ------------------------------------------------ list-on-map (PROD-3566)

  /// A `/map/pins` response landed while a list was entered → do the two
  /// things entering a list still owes: frame it, or back out if it's gone.
  ///
  /// Both live here rather than in the executor because both need what only
  /// the screen has — the laid-out map box for a fit, and a `WidgetRef` for
  /// the toast.
  void _onListPinsResolved(MapPinsState? prev, MapPinsState next) {
    if (next.listUnavailable && !(prev?.listUnavailable ?? false)) {
      _onActiveListUnavailable();
      return;
    }
    if (next.isLoading) return;
    final data = next.data;
    if (data == null || identical(data, prev?.data)) return;

    final pending = ref.read(mapPendingListFitProvider);
    if (pending == null) return;
    final consume = shouldConsumeListFit(
      pendingListId: pending,
      query: ref.read(mapQueryProvider),
      lastTrigger: ref.read(mapQueryProvider.notifier).lastTrigger,
    );
    // Drop the claim either way: a fresh response is its one chance, so a
    // claim that can't be honoured now is stale, not waiting.
    ref.read(mapPendingListFitProvider.notifier).state = null;
    if (!consume) return;

    // Fit the WHOLE list, not the display selection: `venues`/`events` carry
    // the full fetched pool (unbounded under `ignore_radius` for a bounded
    // scope), while `selection` is only what v2 chose to draw for the current
    // viewport — which is empty when the list lives somewhere else entirely,
    // and that is exactly the case a fit-to-pins exists to rescue.
    final box = boundsOfPins([...data.venues, ...data.events]);
    // A list whose items have no coordinates frames nothing and keeps the
    // camera, rather than flying to a meaningless point (Done-when: "degrades
    // gracefully rather than framing to nothing").
    if (box == null) return;
    _fitCameraToBox(box, minZoom: kMapListFitMinZoom);
  }

  /// The active list answered **404** — gone, unshared, deleted or moderated
  /// (every authorization failure is a 404 by design, so we can't tell which,
  /// and don't need to). Tell the user in the app's standard toast, then
  /// restore a coherent query. Zé's decision, 2026-07-31.
  void _onActiveListUnavailable() {
    ref.read(mapPendingListFitProvider.notifier).state = null;
    // One query write (`clearList` drops the scope AND the list-scoped
    // keyword), then the bar's own state — where `setKeyword` no-ops, so
    // routing through the shared clear costs nothing. Entering a list already
    // emptied the bar, but the user can have typed *inside* the list since,
    // and that search must not survive the corpus it was scoped to.
    ref.read(mapQueryProvider.notifier).clearList();
    clearMapActiveSearch(ref, trigger: 'filter');
    if (!mounted) return;
    showSoko(ref, message: Lt.of(context).mapListUnavailable);
  }

  /// Half the viewport's diagonal, in metres — the same "search radius" the
  /// camera's own `onCameraIdle` reports, reconstructed from the viewport rect
  /// for the hand-committed path above.
  double _radiusForViewport(MapViewport vp) {
    final latM = (vp.neLat - vp.swLat).abs() * 111320.0 / 2;
    final lngM =
        (vp.neLng - vp.swLng).abs() *
        111320.0 *
        math.cos(((vp.neLat + vp.swLat) / 2) * math.pi / 180.0).abs() /
        2;
    return math.sqrt(latM * latM + lngM * lngM);
  }

  // ------------------------------------------------------- "Search this area"

  /// PROD-2993 D11(c). The user is looking at an area we haven't searched; they
  /// asked us to search it.
  ///
  /// Note the camera work. At `half` the strip of map they were reading is a
  /// **narrow band above the drawer**; at `peek` the visible area is far taller
  /// and its centre sits much lower on screen. Handing the same camera centre to
  /// both would let the thing they were studying drift up and away the moment the
  /// drawer closes. So we re-centre for the geometry they're about to have.
  void _onSearchThisArea() {
    // Seeded (chat) map: no live search (the chip is hidden too) — guard anyway.
    if (widget.seeded) return;
    final vp = ref.read(mapLiveViewportProvider);
    final cam = _liveCamera;
    ref.read(unifiedAnalyticsProvider).trackMapSearchThisArea();

    // PROD-3223: the re-centre below is programmatic, so its `onCameraIdle`
    // would otherwise settle as `'pan'`. Tag the next settle as `'area'` so the
    // resulting `map_area_searched` reflects the explicit search. The
    // `_commitLiveCameraToQuery` path (no-ease fallback) already passes `'area'`.
    _pendingSettleTrigger = 'area';

    if (vp != null && cam != null && _mapBox.height > 0) {
      final lat = recenteredLatForChrome(
        viewport: vp,
        mapHeightPx: _mapBox.height,
        topInsetPx: mapTopChromeInset(context),
        bottomInsetPx: ref.read(mapDrawerOccludedHeightProvider),
        nextBottomInsetPx: ref.read(mapDrawerBasePeekHeightProvider),
      );
      if (lat != null) _easeCameraTo(lat, cam.lng, cam.zoom);
    }

    // Collapsing to `peek` runs `_endSession`. The camera is dirty, so it
    // commits the (just re-centred) camera to the query — which is the search.
    ref.read(mapDrawerSnapProvider.notifier).state = MapDrawerSnap.peek;
  }

  // ------------------------------------------------------------- the camera

  /// **Recenter the map on the focused carousel card** (PROD-2993 D24).
  ///
  /// The carousel is a deliberate one-card-at-a-time browse, so — unlike the
  /// earlier grid model — the camera ALWAYS recenters on the focused card, the
  /// Apple-Maps feel José chose. There is no "only move when a pin is hidden"
  /// gate any more; the recenter target simply centres the focused pin in the
  /// un-occluded strip of map above the drawer (`fitCameraFor` with one point
  /// keeps the zoom and just pans).
  ///
  /// Seeded (chat) map: one-shot fit that frames ALL pins. `initialCamera`
  /// (from `seededCamera()`) is only a first-paint approximation over the full
  /// screen width; this corrects to a true fit that accounts for the top chrome
  /// and the opened drawer's occlusion (via [_fitCameraToBox] + `mapFitMargins`),
  /// so no pin hides under the drawer. Runs once, after the map box is laid out
  /// and the drawer has settled (fired from the occluded-height listener).
  bool _seededDidFitAll = false;
  void _maybeSeededFitAll() {
    if (!widget.seeded || _seededDidFitAll || _mapBox.height <= 0) return;
    final seed = ref.read(mapSeedProvider);
    if (seed == null || seed.pins.isEmpty) return;
    final box = boundsOfPins(seed.pins);
    if (box == null) return;
    _seededDidFitAll = true;
    // Same min-zoom as the live list fit — a chat's places can span cities.
    _fitCameraToBox(box, minZoom: kMapListFitMinZoom);
  }

  /// An `easeCameraTo` that lands where we already are is skipped, so a card
  /// whose pin is already centred doesn't trigger a pointless animation.
  void _recenterOnFocused() {
    if (!mounted) return;
    if (ref.read(mapFocusSessionProvider) == null) return;
    if (ref.read(mapDrawerSnapProvider) != MapDrawerSnap.half) return;

    // A finger is on the drawer (a VERTICAL resize drag — horizontal carousel
    // swipes don't set this). Don't move the map under it, and don't read the
    // occluded height mid-resize when it still describes the previous snap.
    if (ref.read(mapDrawerDraggingProvider)) return;

    final points = ref.read(mapHighlightProvider).points;
    if (points.isEmpty) return;

    final cam = _liveCamera;
    if (cam == null || _mapBox.height <= 0) return;

    final topInset = mapTopChromeInset(context);
    final bottomInset = ref.read(mapDrawerOccludedHeightProvider);

    final target = fitCameraFor(
      points: points,
      mapWidthPx: _mapBox.width,
      mapHeightPx: _mapBox.height,
      padTopPx: topInset + kMapHighlightFitMarginPx,
      padBottomPx: bottomInset + kMapHighlightFitMarginPx,
      padHorizontalPx: kMapHighlightFitMarginPx,
      currentZoom: cam.zoom,
    );
    if (target == null) return;

    // No-op guard: skip an ease that wouldn't visibly move the camera (the
    // focused pin is already centred). ~1e-5° ≈ 1 m — well below perceptible.
    if ((target.lat - cam.lat).abs() < 1e-5 &&
        (target.lng - cam.lng).abs() < 1e-5 &&
        (target.zoom - cam.zoom).abs() < 1e-3) {
      // Still clear the dirty flag: the user is back to browsing, so the
      // "Search this area" affordance should retire even when no ease is needed.
      ref.read(mapFocusSessionProvider.notifier).clearCameraDirty();
      return;
    }

    _easeCameraTo(target.lat, target.lng, target.zoom);
    // Browsing re-arms following and pulls the camera back over the pool's area,
    // so the pins describe what's under them again (D10).
    ref.read(mapFocusSessionProvider.notifier).clearCameraDirty();
  }

  /// The focused card changed (a carousel settle) — recenter on it. A short
  /// debounce coalesces a fast multi-card fling into one camera move at the end,
  /// rather than chasing each card the fling flies past.
  void _onHighlightChanged() {
    if (ref.read(mapFocusSessionProvider) == null) return;
    _scrollSettle?.cancel();
    _scrollSettle = Timer(_kFocusSettle, () {
      if (mounted) _recenterOnFocused();
    });
  }

  // -------------------------------------------------------------- pin focus

  // ---------------------------------------------------- v2 search execution

  /// PROD-3498 — the canonical event id for [pin], when it is the pin the
  /// active search promoted. Null otherwise (including for any ordinary pool
  /// pin, whose id genuinely IS an occurrence id).
  String? _activeSearchEventIdFor(MapPin pin) {
    final active = ref.read(mapSearchProvider).active;
    if (active == null || active.type != MapSearchTargetType.event) return null;
    final promoted = ref.read(mapPromotedPinProvider);
    if (promoted == null || promoted.id != pin.id) return null;
    return active.eventId;
  }

  /// PROD-3498 — perform one [MapExecutionCommand] from the search executor.
  ///
  /// Everything here needs something only the screen has: the imperative
  /// camera + its token, the map box size, or a `BuildContext` for a sheet.
  /// The executor owns the *decision*; this owns the *doing*.
  ///
  /// By the time a command lands the executor has already left focused mode,
  /// so `mapCameraFrozenProvider` is false and the settle that follows the
  /// move commits normally — which is what re-queries `/map/pins` for a
  /// location selection.
  void _runExecutionCommand(MapExecutionCommand command) {
    switch (command) {
      case MapEaseToCommand(:final lat, :final lng, :final zoom):
        _easeCameraTo(lat, lng, zoom);
      case MapFitBoxCommand(:final box):
        _fitCameraToBox(box);
      case MapOpenVenueSheetCommand(:final venueId):
        unawaited(
          showVenueDetailSheet(
            context,
            ref,
            venueId: venueId,
            listAddSource: ListSource.map,
          ),
        );
      case MapOpenEventSheetCommand(:final eventId):
        unawaited(
          showEventDetailSheet(
            context,
            ref,
            eventId: eventId,
            listAddSource: ListSource.map,
          ),
        );
    }
  }

  /// Frame a resolved area's bbox in the strip of map the user can actually
  /// see (the drawer covers the bottom). Hand-rolled rather than handed to the
  /// renderers' `boundsConfig` for the reason documented on [_centerToToken];
  /// a box too small or a map box not laid out yet falls back to centring.
  ///
  /// [minZoom] lets a caller widen the lower clamp — PROD-3566's list fit
  /// frames a whole corpus that may span cities, where the location default
  /// would crop it (see [kMapListFitMinZoom]).
  ///
  /// PROD-3626 — the margins come from [mapFitMarginsFor], not from a bare
  /// [kMapHighlightFitMarginPx]. That constant was smaller than the renderers'
  /// own selection inset, so a pin framed at the edge of this fit fell OUTSIDE
  /// the rect `mapSelectionProvider` selects against and was never plotted.
  /// This affects **every** box fit, not just the list one — a location pick
  /// framed its area with the same too-small margin.
  void _fitCameraToBox(
    LatLngBounds box, {
    double minZoom = kMapLocationFitMinZoom,
  }) {
    if (_mapBox.height <= 0) return;
    final margins = mapFitMarginsFor(
      mapWidthPx: _mapBox.width,
      mapHeightPx: _mapBox.height,
      topChromeInsetPx: mapTopChromeInset(context),
      // The inset the RENDERER was handed (`searchAreaBottomInset`), which is
      // what sizes the selection rect — not the drawer's current height.
      selectionBottomInsetPx: ref.read(mapDrawerBasePeekHeightProvider),
    );
    final target = fitCameraForBox(
      box: box,
      mapWidthPx: _mapBox.width,
      mapHeightPx: _mapBox.height,
      padTopPx: mapTopChromeInset(context) + margins.top,
      padBottomPx: ref.read(mapDrawerOccludedHeightProvider) + margins.bottom,
      padHorizontalPx: margins.horizontal,
      minZoom: minZoom,
    );
    if (target == null) {
      _easeCameraTo(
        (box.north + box.south) / 2,
        (box.east + box.west) / 2,
        kMapLocationPointZoom,
      );
      return;
    }
    _easeCameraTo(target.lat, target.lng, target.zoom);
  }

  /// PROD-2992 — **enter pin-focus** for a tapped pin: snapshot the camera, open
  /// a [MapFocusSessionKind.pinFocus] session (which freezes the settle refetch
  /// via [mapCameraFrozenProvider]), **pin the selection viewport** so the pool
  /// stops re-selecting live ([mapFrozenViewportProvider]), then recenter+zoom on
  /// the pin. The dim of the rest is the existing `mapFocusedPinProvider` fade
  /// (set by the caller); the focused pin's +25% enlarge + z-raise come from
  /// `map_render_provider` reacting to this session. Paired with [_exitPinFocus].
  void _enterPinFocus(MapMarker marker) {
    ref
        .read(mapFocusSessionProvider.notifier)
        .enter(MapFocusSessionKind.pinFocus, snapshot: _liveCamera);
    // Freeze reselection: pin the viewport the selection slices against to the
    // one at focus entry (fall back to the settled query box before the first
    // camera event). The fetch freeze rides on the session itself.
    ref.read(mapFrozenViewportProvider.notifier).state =
        ref.read(mapLiveViewportProvider) ??
        viewportForMapQuery(ref.read(mapQueryProvider));
    _recenterOnPinFocus(marker);
  }

  /// PROD-2992 — **exit pin-focus**: unfreeze reselection, close the session, and
  /// restore the exact pre-tap camera (AC: "restores the exact pre-tap camera").
  /// Always restores — pin-focus has no "keep the panned camera" fork. A no-op if
  /// no session is open (e.g. the tap opened no sheet). Called from the pin-tap
  /// `finally` only when THIS tap entered focus, so it never disturbs a
  /// results-highlight session the tap fell through from.
  void _exitPinFocus() {
    ref.read(mapFrozenViewportProvider.notifier).state = null;
    final session = ref.read(mapFocusSessionProvider.notifier).exit();
    final snap = session?.snapshot;
    if (snap != null) _easeCameraTo(snap.lat, snap.lng, snap.zoom);
  }

  /// PROD-2992 — recenter+zoom onto [marker] for focus: zoom in by +2 (capped at
  /// 16, never out) and **lift** the pin into the strip above the detail sheet
  /// (`kMapPinFocusPinScreenFraction`), so the enlarged pin isn't tucked behind
  /// the sheet. Uses the token-bumped [_easeCameraTo] so the move always lands.
  void _recenterOnPinFocus(MapMarker marker) {
    final cam = _liveCamera;
    if (cam == null || _mapBox.height <= 0) return;
    final targetZoom = pinFocusTargetZoom(cam.zoom);
    final centerLat = pinFocusCenterLat(
      pinLat: marker.lat,
      mapHeightPx: _mapBox.height,
      zoom: targetZoom,
    );
    _easeCameraTo(centerLat, marker.lng, targetZoom);
  }

  /// Pan-only camera follow when the user swipes the detail sheet to another
  /// result (see [_onPinTap]'s `onIndexChanged`). Recenters on [lat]/[lng] at
  /// the CURRENT zoom — the pin-focus zoom set on the tap — so repeated swipes
  /// don't keep zooming in, and lifts the pin above the sheet. The pin-focus
  /// session + fetch-freeze from the tap still hold, so this only moves the
  /// camera; it never re-snapshots or triggers a reselect.
  void _followCameraToCoord(double lat, double lng) {
    final cam = _liveCamera;
    if (cam == null || _mapBox.height <= 0) return;
    final centerLat = pinFocusCenterLat(
      pinLat: lat,
      mapHeightPx: _mapBox.height,
      zoom: cam.zoom,
    );
    _easeCameraTo(centerLat, lng, cam.zoom);
  }

  /// Close an open question-filter panel when the user interacts with the map
  /// (pan/zoom → `onMapMoved`, tap → `onMapTapOutside`). Same dismissal as
  /// tapping outside the bottom drawer — but the map stays fully interactive
  /// (no blocking shield), so the gesture both drives the map AND closes the
  /// options.
  void _closeOpenFilterOnMapInteraction() {
    if (ref.read(mapOpenFilterProvider) != null) {
      ref.read(mapOpenFilterProvider.notifier).state = null;
    }
    // A map interaction (pan / zoom / tap-away) also exits cluster-focus:
    // un-fade the map + collapse the drawer back to all results.
    //
    // PROD-3043: the collapse stays scoped to the cluster-focus exit. A drawer
    // the USER dragged open is left exactly where they put it — panning the map
    // while browsing results must not yank it shut (decision #10).
    if (ref.read(mapFocusedClusterProvider) != null) {
      ref.read(mapFocusedClusterProvider.notifier).state = null;
      ref.read(mapDrawerSnapProvider.notifier).state = MapDrawerSnap.peek;
    }
  }

  /// PROD-2981 — guards [_onPinTap] against re-entry. A pin tap opens a detail
  /// sheet, and that `await` only completes when the sheet is **dismissed** — so
  /// without this the map stayed live and tappable underneath, and a second tap
  /// opened a SECOND stacked sheet whose `finally` raced the first's (whichever
  /// closed first un-dimmed the map behind the one still open, and marked the
  /// wrong pin viewed).
  ///
  /// Extra taps are DROPPED, not queued: a queued tap just opens a sheet the
  /// user has stopped asking for. This also blocks a stack tap from interleaving
  /// with an opening/open pin sheet.
  bool _pinTapInFlight = false;

  /// Pin tap → the item's **full detail in a draggable sheet** (reuses the
  /// detail body; the `/venues|events/{id}` routes stay for deep links).
  ///
  /// Venues carry the venue id directly. Events carry the matched OCCURRENCE id,
  /// and the detail contract wants the event id (`GET /events/{id}`) — so that
  /// has to be resolved. PROD-2981: it is no longer resolved *here*, ahead of
  /// the sheet. It comes from the grid's hydrate when that's already loaded, and
  /// otherwise the sheet resolves it behind its own loading state. Either way
  /// **the sheet goes up immediately** — the old code awaited a `/map/hydrate`
  /// round-trip first, so tapping an event pin bought a dimmed map and nothing
  /// else until the network came back, which is what made people tap again.
  Future<void> _onPinTap(MapMarker marker) async {
    // Already handling a tap (a sheet is opening, or open) — drop this one.
    if (_pinTapInFlight) return;

    final data = marker.data;

    // A terminal (co-located) cluster → enter cluster-focus: scope the drawer
    // to its members, snap it open, and fade the rest of the map. The renderer
    // only routes a bubble tap here when it's terminal; other clusters zoom in
    // instead. PROD-3043: opens to `half` — the cluster's results are readable
    // while the map (and the cluster you just tapped) stay in view.
    //
    // Wholly synchronous, so it needs no in-flight window of its own: it is
    // already on screen by the time a second tap could land. (Re-tapping the
    // same stack just rewrites identical state — a no-op rebuild.)
    if (data is OverflowBubble) {
      fireMapTapHaptic();
      // PROD-3219: tapped a co-located "+N" pin cluster.
      ref
          .read(unifiedAnalyticsProvider)
          .trackMapClusterTap(memberCount: data.members.length);
      ref.read(mapFocusedClusterProvider.notifier).state = FocusedCluster(
        id: marker.id,
        members: data.members,
      );
      ref.read(mapDrawerSnapProvider.notifier).state = MapDrawerSnap.half;
      return;
    }
    if (data is! MapPin) return; // nothing to act on — no haptic, no guard

    // Acknowledge the tap NOW, ahead of every line below: the haptic lands
    // before a single pixel moves, so the tap is felt even when the sheet it
    // opens is still a frame (or a network call) away.
    fireMapTapHaptic();

    // PROD-2971: while the admin debug panel is open in debug mode, a pin tap
    // INSPECTS the pin — set it as the focused pin so the (non-modal) panel
    // shows its scoring breakdown — instead of opening the detail sheet. The
    // focused pin stays set (highlighted) until another is tapped or the panel
    // closes (which clears it).
    if (ref.read(mapDebugPanelOpenProvider) &&
        ref.read(mapDebugEnabledProvider)) {
      if (ref.read(mapFocusedClusterProvider) != null) {
        ref.read(mapFocusedClusterProvider.notifier).state = null;
      }
      ref.read(mapFocusedPinProvider.notifier).state = marker.id;
      return;
    }

    // PROD-2993: narrow `half` with the carousel highlight session running — a
    // tap on a FADED (non-centred) pin SELECTS it in the carousel (scroll to its
    // card; the highlight + camera recentre follow off that scroll) instead of
    // opening its detail. A tap on the already-lit/centred pin falls through and
    // opens its detail, mirroring the carousel card (`_onCardTap`). A pin not in
    // the (lazily hydrated) grid also falls through — index -1.
    if (_isNarrowHalfHighlightActive()) {
      final markerIds = ref.read(mapGridProvider).markerIds;
      final idx = markerIds.indexOf(marker.id);
      final focused = ref.read(mapVisibleCardIndicesProvider);
      final centredIdx = focused.isNotEmpty ? focused.first : -1;
      if (idx >= 0 && idx != centredIdx) {
        ref.read(mapCarouselFocusRequestProvider.notifier).state = idx;
        return;
      }
    }

    // An individual pin → leave any cluster-focus, then open its full detail.
    if (ref.read(mapFocusedClusterProvider) != null) {
      ref.read(mapFocusedClusterProvider.notifier).state = null;
    }

    // PROD-2671: fade the rest of the map while this pin's detail sheet is open
    // — the same dim as cluster-focus, scoped to this one pin (it stays lit).
    // Cleared in the `finally` once the sheet is dismissed. The results drawer
    // is deliberately untouched: the detail sheet is the surface here.
    ref.read(mapFocusedPinProvider.notifier).state = marker.id;

    // PROD-2992: enter pin-focus alongside the detail sheet (snapshot + freeze +
    // recenter/zoom + enlarge). Only when the tap will actually open a sheet (a
    // venue with an empty id shows nothing) AND no camera-reaction session is
    // already running — a narrow/wide `half` highlight tap that fell through to
    // here keeps ITS session; pin-focus is the plain-map tap flow. Exited
    // symmetrically in the `finally`, and only if THIS tap entered it.
    final enterFocus =
        (data.isEvent || data.id.isNotEmpty) &&
        ref.read(mapFocusSessionProvider) == null;
    if (enterFocus) _enterPinFocus(marker);

    // PROD-2981: shield the (web) Mapbox canvas while the detail sheet is up.
    // The sheet's own PointerInterceptor (inside DSDraggableSheet) covers only
    // the SHEET's rect — the map above it stayed a live HTML platform view, so
    // on web a tap outside the sheet never reached Flutter's modal barrier: it
    // panned the map / hit other pins instead of closing the sheet. With the
    // shield up, outside taps land on Flutter, the route's barrier dismisses
    // the sheet, and the map doesn't move. Cleared in the `finally` below,
    // which is what hands the map back once the sheet is gone. (Native was
    // already correct — platform views there sit under Flutter's barrier.)
    // PROD-3219: opened an item detail from a Map-page pin tap. Fires here —
    // past the debug-inspect and carousel-select early returns — so it counts
    // real detail opens, not every pin touch. Mirrors the embeds' "view
    // details" event, tagged surface:'pin', map_context:'map_page'.
    ref
        .read(unifiedAnalyticsProvider)
        .trackMapPinViewDetailsClick(
          itemId: data.id,
          itemType: data.isEvent ? 'event' : 'venue',
          mapContext: MapContext.mapPage,
          surface: 'pin',
        );
    ref.read(mapModalOpenProvider.notifier).state = true;
    // PROD-2989: whether a detail sheet was actually shown for this pin — only
    // then do we mark it "viewed" (a no-op tap must not fade a pin).
    var opened = false;
    _pinTapInFlight = true;
    try {
      // Swipe through the current results when this pin is in the (lazily
      // hydrated) grid and its grid item carries a concrete id — the sheet then
      // reads its siblings straight from the results, sidestepping the
      // occurrence→event resolution below. `markerIds` stays index-aligned with
      // the siblings, so each swiped-to result is marked "viewed".
      final grid = ref.read(mapGridProvider);
      final gridItems = grid.items;
      final markerIds = grid.markerIds;
      final gridIdx = markerIds.indexOf(marker.id);
      final tapped = gridIdx >= 0 ? gridItems[gridIdx] : null;
      final tappedId = tapped == null
          ? null
          : (tapped.type == 'event' ? tapped.eventId : tapped.venueId) ??
                tapped.id;
      if (tapped != null && tappedId != null && tappedId.isNotEmpty) {
        opened = true;
        // PROD-4160-followup — seed the detail shell so the sheet paints a
        // skeleton (hero + title + chips) from the pin's card data and then
        // hydrates, instead of a spinner.
        ref.cacheDetailSeed(DetailSeed.fromItemSuggestion(tapped));
        await showItemDetailSheet(
          context,
          ref,
          siblings: detailSiblingsFromSuggestions(gridItems, gridIdx),
          listAddSource: ListSource.map,
          onIndexChanged: (i) {
            if (i < 0 || i >= gridItems.length) return;
            // Lit pin + "viewed" follow the swiped-to result.
            if (i < markerIds.length && markerIds[i].isNotEmpty) {
              final mid = markerIds[i];
              ref.read(mapFocusedPinProvider.notifier).state = mid;
              ref
                  .read(mapViewedItemIdsProvider.notifier)
                  .update((s) => <String>{...s, mid});
            }
            // Camera pans to the swiped-to result's pin (keeps the focus zoom).
            final swiped = gridItems[i];
            final lat = swiped.latitude;
            final lng = swiped.longitude;
            if (lat != null && lng != null) _followCameraToCoord(lat, lng);
          },
        );
        return;
      }

      // Pin not in the hydrated grid (e.g. results drawer closed) → single-item
      // sheet, no swipe. This path also handles occurrence-only event pins.
      if (!data.isEvent) {
        if (data.id.isNotEmpty) {
          opened = true;
          await showVenueDetailSheet(
            context,
            ref,
            venueId: data.id,
            listAddSource: ListSource.map,
          );
        }
        return;
      }

      // Free when the grid already hydrated this pin; otherwise the sheet takes
      // the occurrence id and does the round-trip itself, with the surface
      // already up. Never a wait *before* the sheet.
      //
      // PROD-3498: a pin promoted by the v2 search may be keyed by the
      // CANONICAL event id rather than an occurrence id — a past-search
      // re-execution has no occurrence id to give (PROD-3495 stores the event
      // id by contract). Passing that as `occurrenceId` would 404, so take the
      // event id from the active search when this is that pin.
      final gridEventId =
          grid.eventIdForMarker(marker.id) ?? _activeSearchEventIdFor(data);
      opened = true;
      await showEventDetailSheet(
        context,
        ref,
        eventId: gridEventId,
        occurrenceId: gridEventId == null ? data.id : null,
        listAddSource: ListSource.map,
      );
    } finally {
      _pinTapInFlight = false;
      // Un-fade + drop the canvas shield once the sheet is dismissed (or the
      // tap no-op'd) — the map is interactive again from here — and, PROD-2989,
      // record this pin as viewed in the SAME rebuild so it drops straight
      // from lit (focused, 1.0) to faded with no flicker and never fights
      // the focus highlight while the sheet is up.
      if (mounted) {
        ref.read(mapModalOpenProvider.notifier).state = false;
        ref.read(mapFocusedPinProvider.notifier).state = null;
        // PROD-2992: end pin-focus and restore the pre-tap camera — but only if
        // THIS tap opened it, so a fell-through highlight session is untouched.
        if (enterFocus) _exitPinFocus();
        if (opened) {
          ref
              .read(mapViewedItemIdsProvider.notifier)
              .update((s) => <String>{...s, marker.id});
        }
      }
    }
  }

  /// DEBUG-only: the search area currently sent to `/map/pins`, as a
  /// [MapSearchAreaOverlay] the map draws in translucent soko red. Returns null
  /// (no overlay) unless we're in `kDebugMode`, the debug toggle is on, and we
  /// have a committed centre. Mirrors `map_markers_provider._fetch`: the radius
  /// circle is always part of the request; the viewport rectangle is only sent
  /// when server-side selection (`pins_version=2`) is active.
  MapSearchAreaOverlay? _buildDebugSearchArea() {
    if (!kDebugMode) return null;
    if (!ref.watch(mapDebugSearchAreaProvider)) return null;
    final q = ref.watch(mapQueryProvider);
    if (!q.hasCenter) return null;
    final wantV2 = ref.watch(
      experimentServiceProvider.select((s) => s.enableMapPinsV2),
    );
    final rectSent = wantV2 && q.hasBounds;
    return MapSearchAreaOverlay(
      centerLat: q.centerLat!,
      centerLng: q.centerLng!,
      radiusMeters: q.radiusMeters,
      swLat: rectSent ? q.swLat : null,
      swLng: rectSent ? q.swLng : null,
      neLat: rectSent ? q.neLat : null,
      neLng: rectSent ? q.neLng : null,
    );
  }

  @override
  void dispose() {
    _scrollSettle?.cancel();
    // NEVER reach for `ref` here — see [_leaveNavigationGuard]. Unregistering
    // is what hands navigation back to the bottom nav; if it is skipped, every
    // nav tap in the app is swallowed by this dead state's `_requestLeave`
    // (which short-circuits on the already-latched `_allowRoutePop`).
    final leaveNavigationOwner = _leaveNavigationOwner;
    if (leaveNavigationOwner != null) {
      _leaveNavigationGuard?.unregister(leaveNavigationOwner);
    }
    // PROD-3627 — release the stray-tap registration, but ONLY if it is still
    // ours. Clearing unconditionally would let a stale dispose wipe a newer
    // MapScreen's registration during a fast route replacement — the race
    // `MapLeaveNavigationGuard` carries a token for.
    //
    // Deferred out of the build phase — see [deferProviderWrite].
    //
    // The identity check moves INSIDE the callback deliberately. Checking now
    // and writing a frame later would widen the very race the token exists
    // for: a newer MapScreen could register in between, and we would wipe it.
    // Re-reading at write time makes the guard tighter, not looser.
    final strayTapDismiss = _strayTapDismiss;
    final ownCallback = _strayTapCallback;
    if (strayTapDismiss != null) {
      deferProviderWrite(() {
        if (identical(strayTapDismiss.state, ownCallback)) {
          strayTapDismiss.state = null;
        }
      });
    }
    _areaBoundary.dispose();
    super.dispose();
  }

  /// Resolve every settled camera centre through the picker controller. The
  /// display policy only uses the result in the polygon zoom band.
  void _syncAreaDisplay(MapCameraState camera) {
    _areaDisplayCamera = camera;
    if (!mapZoomWantsPolygon(camera.zoom)) {
      // The zoom policy owns the default. A person can temporarily opt for a
      // radius while a polygon is available, but zooming into/out of this band
      // returns to the policy-selected display when they come back.
      _areaDisplayOverride = null;
    }
    _areaBoundary.onHover(camera.centerLat, camera.centerLng);
    setState(() {});
  }

  /// Geometry for the shared Mapbox area overlay. Curated polygon geometry
  /// wins in the city/neighbourhood band; otherwise this remains an honest
  /// center + radius circle matching the existing map query.
  Map<String, dynamic>? get _areaDisplayGeometry {
    final camera = _areaDisplayCamera;
    if (camera == null) return null;
    return mapAreaDisplayGeometry(
      zoom: camera.zoom,
      centerLat: camera.centerLat,
      centerLng: camera.centerLng,
      radiusMeters: camera.radiusMeters,
      boundaryGeometry: _areaBoundary.hoverBoundary?.geometry,
      override: _areaDisplayOverride,
    );
  }

  bool get _canToggleAreaDisplay {
    final camera = _areaDisplayCamera;
    return camera != null &&
        canToggleMapAreaDisplay(
          zoom: camera.zoom,
          boundaryGeometry: _areaBoundary.hoverBoundary?.geometry,
        );
  }

  MapAreaDisplayMode get _effectiveAreaDisplayMode {
    final camera = _areaDisplayCamera!;
    return mapAreaDisplayModeFor(
      zoom: camera.zoom,
      boundaryGeometry: _areaBoundary.hoverBoundary?.geometry,
      override: _areaDisplayOverride,
    );
  }

  Future<void> _requestLeave({VoidCallback? onComplete}) async {
    // PROD-3674 — `navigateOnly` is the hardening. Once the leave decision is
    // made, the prompt must not run again, but a shell-level nav tap still has
    // to navigate: its `onComplete` IS the navigation. Returning here instead
    // (as this did) makes any failure of that closure permanent, because
    // `_allowRoutePop` is one-way and every later tap short-circuits on it —
    // the whole bottom nav goes dead rather than one tap being swallowed.
    switch (resolveMapLeaveRequest(
      leaveInFlight: false,
      leaveDecided: _allowRoutePop,
    )) {
      case MapLeaveRequest.ignore:
        return;
      case MapLeaveRequest.navigateOnly:
        // Called directly, not post-frame: nothing here mutates the tree, and
        // `_completeLeave` already committed `_allowRoutePop` in an earlier
        // frame. (Its own pending post-frame callback could in principle also
        // fire, but only for a second tap landing inside that single frame —
        // unreachable while the prompt is modal and the nav is hidden, and its
        // `if (!mounted) return;` covers the case that matters.)
        onComplete?.call();
        return;
      case MapLeaveRequest.run:
        break;
    }
    // The map-leave divergence prompt ("update your search area?") was
    // removed (2026-09): leaving the map — via the back arrow, system or
    // browser back, or any shell nav tap routed through
    // [mapLeaveNavigationGuardProvider] — no longer interrupts navigation.
    // Every exit leaves immediately, still routing through _completeLeave so
    // the `_allowRoutePop` latch + PopScope cooperate exactly as before.
    _completeLeave(onComplete: onComplete);
  }

  /// PROD-3496 — the single back funnel. The `PopScope` (Android system
  /// back, in-app pops) and the visible back arrow both land here so they
  /// can never disagree: while the focused search mode is up, back closes
  /// the MODE only — it must not start [_requestLeave] (whose divergence
  /// prompt + [_allowRoutePop] latch belong to page-leave exclusively).
  /// With the soft keyboard up, Android's back #1 is consumed by the IME
  /// before reaching the `PopScope`, so the keyboard closes and the mode
  /// stays — the required G2 ordering falls out for free.
  ///
  /// WEB does not come through here — and no longer needs to (PROD-3524).
  /// Browser back is a GoRouter route-information REBUILD, not a pop, so it
  /// can never reach a `PopScope`. Instead `/map` now owns a real URL (a child
  /// route of `/`, entered with `context.go`) and the focused mode owns
  /// `?search=1` on top of it, so browser back #1 pops that entry and
  /// [_reconcileFocusUrl] closes the mode — the same outcome this funnel
  /// produces on Android, reached by a different road.
  ///
  /// Back #2 (leaving `/map`) still bypasses the divergence prompt on web, as
  /// it always has. That is deliberate: we cannot ask the user to confirm a
  /// search-area change during a navigation we can't block, so the leave must
  /// commit nothing — and it doesn't, since the only search-centre write on
  /// this page is inside the prompt's own `MapLeavePromptAction.update` branch.
  void _handleBack() {
    final action = resolveMapBackAction(
      searchFocused: ref.read(mapSearchProvider).focused,
    );
    if (action == MapBackAction.exitFocusedSearch) {
      ref.read(mapSearchProvider.notifier).exitFocus();
      return;
    }
    unawaited(_requestLeave());
  }

  /// PROD-3524 — keep the focused search mode and the URL in agreement, in
  /// whichever direction moved first. Called from `build`, so a state flip and
  /// a browser navigation both arrive here the same way.
  ///
  /// Closing the mode because the URL lost the marker must do that and nothing
  /// else: back #1 must never start [_requestLeave], whose divergence prompt
  /// and `_allowRoutePop` latch belong to page-leave exclusively.
  ///
  /// Provider writes are deferred to a post-frame callback — mutating a
  /// provider mid-build throws and aborts the rest of `build()` (see
  /// `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`
  /// § Caveats).
  void _reconcileFocusUrl({
    required bool focused,
    required Uri uri,
    required bool enabled,
  }) {
    final step = stepMapFocusUrl(
      state: _focusUrlState,
      enabled: enabled,
      focused: focused,
      urlFocused: mapUriHasFocus(uri),
    );
    // Commit the new memory BEFORE acting: the side effects below are all
    // post-frame, so any build in between must already see that a write is in
    // flight and not re-decide off the not-yet-updated URL.
    _focusUrlState = step.next;
    // EVERY branch defers its side effect to a post-frame callback, and both
    // kinds need it for the same reason: this runs inside `build`, where
    // mutating a provider throws and `context.go` reaches `notifyListeners`
    // on the router — "setState() called during build", which silently killed
    // the URL write until a browser run caught it.
    switch (step.action) {
      case MapFocusSync.none:
        return;
      case MapFocusSync.pushEntry:
        // Literal path, not `AppRoutes.mapa`: importing app_router here would
        // cycle (it imports MapScreen). Pinned by the router test.
        final target = mapUriWithFocus(uri, focused: true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          context.go(target);
        });
      case MapFocusSync.replaceEntry:
        // Swap the marker out of the CURRENT entry — no push (which would
        // strand a dead back press) and no pop (which would leave the page,
        // because this marker is not ours).
        //
        // `Router.neglect` is what makes it a real `history.replaceState`.
        // `context.replace` is NOT enough: go_router replaces the top route
        // MATCH but still reports the change with
        // `RouteInformationReportingType.none`, which on an actually-changed
        // URL means `replace: false` — measured, it grew history by one.
        // `Router.neglect` forces the `neglect` reporting type for the
        // navigation performed inside it.
        final cleaned = mapUriWithFocus(uri, focused: false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Router.neglect(context, () => context.go(cleaned));
        });
      case MapFocusSync.popEntry:
        // Pop the entry we pushed rather than navigating to the clean URL —
        // go_router pushes a browser entry for every navigation, so `go` would
        // strand a dead back press per open/close cycle. We only reach here
        // with the marker actually on top, so we can only pop our own entry.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          browserHistoryBack();
        });
      case MapFocusSync.exitFocus:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(mapSearchProvider.notifier).exitFocus();
        });
      case MapFocusSync.enterFocus:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(mapSearchProvider.notifier).enterFocus();
        });
    }
  }

  void _completeLeave({VoidCallback? onComplete}) {
    if (!mounted || _allowRoutePop) return;
    setState(() => _allowRoutePop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (onComplete != null) {
        onComplete();
        return;
      }
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Seed the centre when location arrives after first frame.
    ref.listen<LocationState>(locationProvider, (_, next) => _seedFrom(next));

    // PROD-2993 — the drawer's snap is the feature's ONLY entry/exit door.
    ref.listen<MapDrawerSnap>(
      mapDrawerSnapProvider,
      (prev, next) => _onDrawerSnapChanged(prev, next),
    );

    // The user scrolled to a different row → the dim follows instantly; the
    // camera waits ~1s for them to stop (D8).
    ref.listen<MapHighlightState>(mapHighlightProvider, (prev, next) {
      if (!setEquals(prev?.markerIds, next.markerIds)) _onHighlightChanged();
    });

    // PROD-2993 D18 — **the entry fit**, and the only correct place for it.
    //
    // This provider changes when the drawer's coverage of the map does, written
    // on SETTLE. When the drawer lands at `half`, that's the moment the strip of
    // map above it is known — so recenter on the focused card into it. It's also
    // how the entry recenter happens (the drawer settling at `half` is what fires
    // this), and how a half→full→half bounce recenters against the new geometry.
    ref.listen<double>(mapDrawerOccludedHeightProvider, (_, _) {
      _recenterOnFocused();
      _maybeSeededFitAll();
    });

    // PROD-2993 — the finger came off the drawer (a vertical resize drag ended).
    //
    // Any recenter that wanted to run mid-drag was refused (correctly: the
    // geometry was stale and the map would have moved under their hand). This is
    // the moment it becomes safe, so re-evaluate — a drag that ends back on the
    // SAME snap publishes no new occluded height, so nothing else would.
    ref.listen<bool>(mapDrawerDraggingProvider, (prev, next) {
      if (prev == true && next == false) _recenterOnFocused();
    });

    // PROD-2993 D12 — a FILTER change during a session.
    //
    // The freeze is camera-scoped, so filter writes reach `mapQueryProvider`
    // untouched and the pool refetches as it always did. But the results have
    // genuinely changed underneath the user, so holding them at `half` against a
    // grid that is about to reset would be a lie. Drop to `peek` (which ends the
    // session) and let the new search play out normally.
    //
    // Any `mapQuery` change while a session is open IS a filter change — the
    // camera cannot write to it, because that is precisely what the freeze
    // blocks. That is why this needs no field-by-field comparison.
    ref.listen<MapQuery>(mapQueryProvider, (prev, next) {
      if (prev == null || !mounted) return;
      if (ref.read(mapFocusSessionProvider) == null) return;
      ref.read(mapDrawerSnapProvider.notifier).state = MapDrawerSnap.peek;
    });
    // A selected city (restored async / changed via the location pill) re-frames
    // the map on that city; suppresses location seeding while pinned.
    ref.listen<SearchScope?>(
      cityScopeProvider,
      (_, next) => _applyCityScope(next),
    );
    // PROD-3498 — the v2 search executor asks for camera moves and detail
    // sheets here. It stays widget-free (and unit-testable) by writing a
    // command; the screen is still the only thing that drives the camera.
    ref.listen<MapExecutionCommand?>(mapExecutionCommandProvider, (prev, next) {
      if (next == null || next.token == prev?.token) return;
      _runExecutionCommand(next);
    });
    // PROD-3219: fire `map_area_searched` when a search RESOLVES (deduped) —
    // the replacement for the old per-settle `map_search`. See `_onPinsResolved`.
    ref.listen<MapPinsState>(mapPinsProvider, _onPinsResolved);
    // PROD-3566: the same resolution also settles what entering a list still
    // owes — frame it, or toast + back out if it turned out to be gone.
    ref.listen<MapPinsState>(mapPinsProvider, _onListPinsResolved);
    // This subscription exists for its LIFETIME, not its callback: the claim
    // lives in an autoDispose provider the executor only writes, so without a
    // holder it would be disposed within a microtask and every list would
    // silently lose its camera fit. The screen is the right holder — a pending
    // fit with no map to perform it means nothing.
    ref.listen<String?>(mapPendingListFitProvider, (_, _) {});
    final pinsState = ref.watch(mapPinsProvider);
    // PROD-2671: the provider is context-free (pin keys, stack, counts); attach
    // the localized inline labels here (placeholder name + secondary facet on
    // pins; "X venues / Y events" on cluster bubbles) using the facet catalog.
    final markers = withMapPinLabels(
      l10n: Lt.of(context),
      catalog: ref.watch(discoveryFacetsProvider).asData?.value,
      markers: ref.watch(mapMarkersProvider),
    );
    final mapModalOpen = ref.watch(mapModalOpenProvider);

    // DEBUG-only: build the "search area" overlay the map draws in soko red —
    // the exact circle (radius_meters) + v2 viewport rectangle the FE sends to
    // `/map/pins`, so we can eyeball it against the visible screen. Mirrors the
    // request-building logic in `map_markers_provider._fetch`: the radius is
    // always sent (for `all` scope), the rectangle only when v2 is active (flag
    // on AND we have settled bounds). Only wired under `kDebugMode`; null
    // (overlay off) everywhere else.
    final MapSearchAreaOverlay? debugSearchArea = _buildDebugSearchArea();

    // Float the my-location button in the bottom-right, 12 px above the results
    // drawer's top edge. The drawer publishes its **peek chrome** height
    // ([mapDrawerChromeHeightProvider]) — NOT its live drag extent — so the
    // button rides up with the question buttons + open filter's option rows, yet
    // stays put (and is simply covered) while the user drags the drawer up over
    // it. The map widget adds the 12 px gap and animates the offset.
    final myLocationButtonBottomInset = ref.watch(
      mapDrawerChromeHeightProvider,
    );

    // PROD-2971: the map debug tab/panel/overlay are admin-only (usable in prod
    // for bug-hunting the pin algorithms) — off entirely for non-admins. Gate
    // the overlay on admin too (not just debug mode) so a role change mid-session
    // can't leave stale debug shapes drawn from the last-good response.
    final isAdmin = ref.watch(currentUserProvider)?.role == UserRole.admin;

    // PROD-3496 — the v2 search bar + focused search mode, gated by the
    // PostHog `map-search-v2` flag (internal rollout first). The dart-define
    // exists because local dev has PostHog disabled (flags stay default) and
    // the old debug-panel reveal toggle was removed with the v1 bar.
    // Seeded (chat) map: no live search — the search bar (and its focused
    // overlay + URL mirror, all gated on this) are hidden.
    final showSearchBar =
        !widget.seeded &&
        (EnvironmentConfig.mapSearchV2Enabled ||
            ref.watch(
              experimentServiceProvider.select((s) => s.enableMapSearchV2),
            ));

    // PROD-3524 — mirror the focused search mode into the URL so the browser's
    // back button has an entry to pop. Web-only by design: on native the
    // `PopScope` → [resolveMapBackAction] path already satisfies the required
    // keyboard → mode → page ordering, and leaving it untouched is the ticket's
    // "Android back behavior unchanged" requirement.
    //
    // ONE reconcile, driven from build, for both directions. `watch` (not
    // `listen`) so a state flip and a URL change re-enter through the same
    // door: a listener firing on the state edge would have to read the URL
    // that its own `go()` has not written yet, which is precisely how a fast
    // open-then-close strands `?search=1` with the mode shut.
    final focusUrlSyncEnabled = kIsWeb && showSearchBar;
    // PROD-3652 reads the same flag for a second, unrelated purpose: the
    // shortcut-chips row yields its slot to the domain tag row while focused
    // (see the chips layer below). One watch, two consumers.
    final searchFocused = ref.watch(mapSearchProvider.select((s) => s.focused));
    // Reading the router state here is also what subscribes this build to URL
    // changes in the first place.
    _reconcileFocusUrl(
      focused: searchFocused,
      uri: GoRouterState.of(context).uri,
      enabled: focusUrlSyncEnabled,
    );

    final debugOverlay = (isAdmin && ref.watch(mapDebugEnabledProvider))
        ? pinsState.data?.debug?.area
        : null;
    // Which overlay shapes are enabled (panel legend toggles). null overlay →
    // ignored; a change redraws the overlay (platform didUpdateWidget).
    final debugOverlayShapes = ref.watch(mapDebugShapesProvider);

    // PROD-3124: dot hints — settled-viewport FeatureCollection of category-
    // coloured dots for retrieved-but-not-pinned results, drawn beneath the
    // pins. Identity-stable between settles (the platform re-syncs + fades on
    // `!identical`), so it MUST come from the provider, never be built here.
    final dotHintsGeoJson = ref.watch(mapDotHintsGeoJsonProvider);

    // PROD-2993: the narrow half-drawer highlight enlarges EVERY pin by
    // `kMapHighlightSizeMul` (`MapHighlightState.enlargeAll`). Scale the captions'
    // `text-offset` by the same factor so each caption keeps tracking its (now
    // taller/wider) pin's top instead of drifting low, as it would otherwise —
    // the caption offset can't read the per-feature `icon_scale` the way the icon
    // does (see `MapPinIconTokens.captionOffsetExpression`). `1.0` (a no-op) in
    // every other state, incl. wide-viewport hover (only one pin grows there, so
    // a global caption bump would over-lift the rest).
    final captionSizeMul =
        ref.watch(mapHighlightProvider.select((h) => h.enlargeAll))
        ? kMapHighlightSizeMul
        : 1.0;

    // PROD-2671: the chrome insets so the `/map/pins` search area + pin
    // selection (and the camera framing) cover only the VISIBLE map — the top
    // bar and the bottom drawer sit over the full-bleed canvas.
    //   • Top = [mapTopChromeInset] — safe-area + the back/search row + the
    //     shortcut-chips row. Shared with the drawer, whose `full` snap parks
    //     just below it, so the two can never drift apart (PROD-3043).
    //   • Bottom = the drawer's **base peek** footprint
    //     ([mapDrawerBasePeekHeightProvider]) — the drag handle + count row +
    //     question buttons, EXCLUDING any open filter's option row. So the camera
    //     is rock-stable: it never re-frames when a filter opens, and never
    //     follows the drawer as the user drags it (PROD-3043 decision #7). A
    //     drawer dragged up simply covers more of the full-bleed canvas; the
    //     framing underneath stays put.
    //
    //     Measured (not hard-coded) so it re-adapts if the resting drawer UI ever
    //     changes — a redesigned count row, a row wrapping at a large text scale.
    //     See `docs/features/maps.md` §4 "Rock-stable camera when the drawer resizes".
    final double searchAreaTopInset = mapTopChromeInset(context);
    final double searchAreaBottomInset = ref.watch(
      mapDrawerBasePeekHeightProvider,
    );

    // Opening zoom: every location-seeded open starts at street level
    // ([_kOpenZoom] via [_initialZoomOverride] — PROD-3124, see [_seedFrom]).
    // The radius-derived fallback below serves the paths that frame an AREA
    // instead: an explicit [initialCamera] target (deep link / saved search),
    // a user-picked city's bbox, and the brief pre-fix moment (rough Lisbon
    // latitude — zoom is only weakly lat-dependent). Once the user pans, the
    // live camera owns the zoom.
    final initialZoom =
        _initialZoomOverride ??
        zoomForRadius(
          _initialRadiusMeters,
          _initialLat ?? 38.7223,
          MediaQuery.sizeOf(context).width,
        );

    return PopScope(
      canPop: _allowRoutePop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: ColoredBox(
        color: AppColors.sokoPaper,
        // Cap the map to the app-standard content width on desktop (paper
        // margins fill the rest via the ColoredBox above); full-bleed on
        // phones. [FullHeightPageContent] keeps the height tight so the
        // `Positioned.fill` map Stack below doesn't collapse. `_mapBox` reads
        // the LayoutBuilder's (already-capped) constraints, so the camera
        // occlusion maths stays correct at the narrower width.
        child: FullHeightPageContent(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // PROD-2993 — the map's own box. The occlusion maths is in pixels (how
              // much of the map is the drawer actually sitting on?), so it needs the
              // same box the drawer measures itself against. Both are `Positioned.fill`
              // in this Stack, so by construction they agree.
              _mapBox = Size(constraints.maxWidth, constraints.maxHeight);
              return _buildStack(
                markers: markers,
                initialZoom: initialZoom,
                pinsState: pinsState,
                mapModalOpen: mapModalOpen,
                isAdmin: isAdmin,
                showSearchBar: showSearchBar,
                searchFocused: searchFocused,
                debugOverlay: debugOverlay,
                debugOverlayShapes: debugOverlayShapes,
                debugSearchArea: debugSearchArea,
                dotHintsGeoJson: dotHintsGeoJson,
                captionSizeMul: captionSizeMul,
                myLocationButtonBottomInset: myLocationButtonBottomInset,
                searchAreaTopInset: searchAreaTopInset,
                searchAreaBottomInset: searchAreaBottomInset,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStack({
    required List<MapMarker> markers,
    required double initialZoom,
    required MapPinsState pinsState,
    required bool mapModalOpen,
    required bool isAdmin,
    required bool showSearchBar,
    required bool searchFocused,
    required MapDebugArea? debugOverlay,
    required Set<MapDebugShape>? debugOverlayShapes,
    required MapSearchAreaOverlay? debugSearchArea,
    required Map<String, dynamic>? dotHintsGeoJson,
    required double captionSizeMul,
    required double myLocationButtonBottomInset,
    required double searchAreaTopInset,
    required double searchAreaBottomInset,
  }) {
    return Stack(
      children: [
        // Full-bleed map.
        Positioned.fill(
          child: MapboxMapWidget(
            markers: markers,
            // PROD-2993: `_cam*` is the results-highlight camera (a fit, a
            // restore, a re-centre). Null except while it is driving, so the
            // seeded opening camera is untouched the rest of the time.
            centerLat: _camLat ?? _initialLat,
            centerLng: _camLng ?? _initialLng,
            zoom: _camZoom ?? initialZoom,
            // Imperative "go there NOW". Value-diffing the props would silently
            // drop a restore that happens to land where they already point —
            // see `docs/learnings/mapbox-imperative-tokens-fit-vs-center.md`.
            centerToToken: _centerToToken,
            cluster: true,
            customSelection: true,
            categoryIcons: true,
            // PROD-2993: keep pin captions aligned with the results-highlight
            // enlargement (narrow half-drawer grows every pin). 1.0 otherwise.
            captionSizeMul: captionSizeMul,
            // PROD-3001: zoom-in capped at 20 on BOTH platforms (decision
            // 2026-07-10, after hands-on testing of an uncapped build: past
            // ~20 the viewport is a couple of buildings and pins/captions
            // add nothing — no user benefit). Native honours this prop too
            // now (setBounds(CameraBoundsOptions(maxZoom:)) — was uncapped
            // ~22 before). Embedded map surfaces don't pass maxZoom and
            // keep their PROD-595 memory-opt caps (14/16).
            maxZoom: 20,
            categoryIconAssets: kMapPinAssets,
            // PROD-3193: a curated boundary outline at city/neighbourhood
            // zoom; otherwise an honest circle for the settled search area.
            // Hidden for now (see [_showAreaDisplay]) — the map draws no area
            // overlay until the feature is re-enabled.
            highlightBoundaryGeoJson: _showAreaDisplay
                ? _areaDisplayGeometry
                : null,
            showMyLocationButton: true,
            // Bottom-right placement that tracks the results drawer's height.
            myLocationButtonBottomInset: myLocationButtonBottomInset,
            // Location-status banner, bottom-LEFT. The compact pill, because
            // the bottom-right of this map is already the my-location button
            // and a full-width bar would have to sit 52 px higher, covering a
            // strip of map on every visit.
            //
            // Suppressed while the focused-search overlay or a map modal is up:
            // both put a scrim over this layer, so the banner would show
            // through it dimmed and un-tappable.
            showLocationStatusBanners: !searchFocused && !mapModalOpen,
            locationBannerStyle: LocationBannerStyle.compact,
            // Level with the my-location button: that one is positioned at
            // `myLocationButtonBottomInset + 12` internally, so the banner has
            // to carry the same + 12 itself. The two then ride up together when
            // a filter panel grows the drawer's peek chrome, and are painted
            // over by the drawer once it is dragged past them.
            bannerInset: EdgeInsets.fromLTRB(
              12,
              0,
              12,
              myLocationButtonBottomInset + 12,
            ),
            // Slim pins carry no name/image, so the sync tooltip is off;
            // tapping a pin resolves + opens its detail.
            enableTooltip: false,
            onMarkerTap: _onPinTap,
            // User started panning → abandon the old area's in-flight
            // requests; the next settle fetches the new area. Pins stay on
            // screen until then (last-good is retained).
            onMapMoved: () {
              // The user (or our own recentre) moved the camera → stop
              // auto-seeding the camera to the user's location.
              _userPanned = true;

              // PROD-2993 — during a session, a camera move is usually OURS
              // (a fit), so the default reactions are wrong here.
              //
              // Note this handler no longer tries to work out *who* moved the
              // camera. It can't, and it doesn't have to: `onUserGesture`
              // answers that question directly.
              if (ref.read(mapFocusSessionProvider) != null) {
                // Deliberately NOT cancelling the grid's in-flight hydrate:
                // during a session the camera moves while the user is reading
                // the results, and cancelling would abort the very cards they
                // scrolled to. The pool isn't refetching anyway (it's frozen),
                // so there is nothing else to abandon.
                //
                // Also NOT running `_closeOpenFilterOnMapInteraction`: it
                // collapses the drawer out of cluster-focus, which would tear
                // the session down on our own camera move (a cluster tap opens
                // the drawer to `half` — D19 — so the two are live together).
                if (ref.read(mapOpenFilterProvider) != null) {
                  ref.read(mapOpenFilterProvider.notifier).state = null;
                }
                return;
              }

              // Panning/zooming closes an open filter panel (the map stays
              // interactive — no blocking shield).
              _closeOpenFilterOnMapInteraction();
              // PROD-3568 — the in-flight cancel used to live HERE, and that
              // was the bug. `onMapMoved` fires for ANY camera movement, and on
              // native the soft keyboard dismissing at the end of a search
              // resizes the canvas enough to trigger it (measured on device:
              // viewport radius 781 m with the keyboard up vs 1038 m without).
              // So executing a search cancelled the very request it had just
              // issued, and nothing re-issued it: the settle that followed
              // reported the camera already committed, so `onCameraSettled`'s
              // sub-threshold `moved` guard dropped it. The map kept the
              // previous scope's pins until an unrelated pan came along.
              // The cancel now rides `onUserGesture` — see [_onUserMapGesture].
            },
            // PROD-2993: the genuine "the user drove the camera" signal
            // (`movestart.originalEvent` on web; `onScroll`/`onZoom` on
            // native). This — not `onMapMoved` — is what marks the camera
            // dirty, so a user grabbing the map mid-animation is read
            // correctly instead of being mistaken for our own move.
            onUserGesture: _onUserMapGesture,
            // A tap on the map (away from a pin) also closes an open filter
            // panel — same dismissal as tapping outside the drawer.
            onMapTapOutside: _closeOpenFilterOnMapInteraction,
            // PROD-2971: admin-only searched-area debug overlay (retrieval
            // circle / sargable bbox / grid cells / v2 selection rect). Null
            // unless an admin has debug mode on; [debugOverlayShapes] gates
            // which shapes draw (panel legend).
            debugOverlay: debugOverlay,
            debugOverlayShapes: debugOverlayShapes,
            // PROD-3124: dot hints render below the pins ("more to see —
            // zoom in"), fading in after each settle's pins land.
            dotHintsGeoJson: dotHintsGeoJson,
            // PROD-3124 dot tap: the platform flies to the dot at street
            // zoom; here we promote the item so it renders as a captioned
            // pin even if the relevance selection wouldn't pick it. Prefer
            // the full pool pin (name/facet drive caption + art); fall back
            // to a slim pin if the pool shifted mid-tap.
            onDotHintTap: (id, entity, lat, lng) {
              final resp = ref.read(mapPinsProvider).data;
              MapPin? promoted;
              if (resp != null) {
                for (final p in [...resp.venues, ...resp.events]) {
                  if (p.id == id && p.entity == entity) {
                    promoted = p;
                    break;
                  }
                }
              }
              promoted ??= MapPin(id: id, entity: entity, lat: lat, lng: lng);
              ref.read(mapPromotedPinProvider.notifier).state = promoted;
            },
            // PROD-2807 (#4): instant mid-gesture re-selection — update the
            // live viewport on every (throttled) move so the shown set +
            // grid + count follow the camera without waiting for settle. No
            // refetch here (that stays on settle, below).
            onCameraMove: (cam) =>
                _onCameraEvent(() => _updateLiveViewport(cam)),
            onCameraIdle: (cam) => _onCameraEvent(() {
              // Sync the live viewport to the exact settled position (and
              // seed it on the very first settle).
              _updateLiveViewport(cam);
              // Seeded (chat) map: the pins are a fixed overridden set. Keep the
              // live-viewport sync above (pin-focus / card-index math) but never
              // commit the camera to the query — no `/map/pins` refetch, no
              // "search this area" affordance.
              if (widget.seeded) return;
              _syncAreaDisplay(cam);

              // ══ PROD-2993 — THE FREEZE. This one `return` is all of it. ══
              //
              // While a camera-reaction session is open we do NOT commit the
              // camera to the query, so `/map/pins` never refetches, so the
              // settled selection never changes, so `mapGridProvider` is never
              // rebuilt — and so the results grid the user is *reading* does
              // not reset and rewind its scroll under their finger.
              //
              // Without it, "pan the camera to reveal a hidden pin" would
              // reset the grid, change which cards are in view, and pan again.
              // A closed loop, driven by its own output.
              //
              // It is deliberately CAMERA-scoped. Filter changes write to
              // `mapQueryProvider` directly and are untouched by this — they
              // must keep working, since the filter row is reachable at `half`
              // by design (PROD-3043 #3). See `map_focus_session_provider.dart`.
              //
              // PROD-3496: the focused search mode freezes through here too —
              // the keyboard's Scaffold resize fires settles that must not
              // commit (rationale on [mapCameraFrozenProvider]).
              if (ref.read(mapCameraFrozenProvider)) return;

              // PROD-3223: consume the one-shot programmatic-search trigger for
              // THIS settle ('pan' for an ordinary browse settle). One-shot, so
              // a later settle can't reuse it.
              final settleTrigger = _pendingSettleTrigger ?? 'pan';
              _pendingSettleTrigger = null;

              ref
                  .read(mapQueryProvider.notifier)
                  .onCameraSettled(
                    lat: cam.centerLat,
                    lng: cam.centerLng,
                    radiusMeters: cam.radiusMeters,
                    zoom: cam.zoom,
                    neLat: cam.neLat,
                    neLng: cam.neLng,
                    swLat: cam.swLat,
                    swLng: cam.swLng,
                    trigger: settleTrigger,
                  );
              // PROD-3219: the old per-settle `map_search` fired HERE — removed.
              // `map_area_searched` now fires on result RESOLUTION (deduped on a
              // coarse centre/zoom bucket), wired via the results listener, not
              // per camera settle. Panning still commits + refetches above; only
              // the noisy 1:1 analytics fire is gone. See Phase 2 (PROD-3219).
            }),
            // DEBUG-only: the red "search area" overlay (radius circle + v2
            // viewport rectangle) mirroring what we send to `/map/pins`.
            debugSearchArea: debugSearchArea,
            // PROD-2671: trim the search geometry + pin selection to the
            // visible map (excluding the top bar + bottom drawer) and pad the
            // camera so it frames within that area.
            viewportPaddingTop: searchAreaTopInset,
            viewportPaddingBottom: searchAreaBottomInset,
          ),
        ),

        // Top area, LOWER layer: the shortcut-chips row. The back/search row
        // itself renders in a separate layer near the top of this Stack
        // (above the PROD-3496 focused-search scrim); a fixed spacer holds
        // its slot here so the chips keep their exact position (Decision
        // #24: no reflow). The summed heights are the same `16 + 44 + 8`
        // that [mapTopChromeInset] / [mapDrawerFullTopInset] reserve — keep
        // all of them in lockstep.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            // PointerInterceptor (web) keeps taps/drags off the Mapbox
            // canvas underneath.
            child: PointerInterceptor(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Slot held by the back/search row layer (16 breathing room
                  // below the safe area + 44 row + 8 gap to the chips).
                  const SizedBox(height: 16 + 44 + 8),
                  // Figma 6917-18137 — the colourful quick-filter shortcut
                  // chips. PROD-2993 gives this same slot a third state:
                  // "Search this area", shown while the user has panned away
                  // from the area whose pins they're looking at.
                  //
                  // PROD-3652 — hidden while the search bar is focused: the
                  // domain tag row takes over this exact slot, and the chips
                  // would otherwise show through the gaps between the tags,
                  // dimmed by the scrim. They are already inert under it, so
                  // nothing is lost by not painting them.
                  // Seeded (chat) map: no quick-filter chips / "search this
                  // area" — the results are a fixed list.
                  if (!searchFocused && !widget.seeded)
                    MapShortcutChips(onSearchThisArea: _onSearchThisArea),
                ],
              ),
            ),
          ),
        ),

        // Loading shimmer line.
        if (pinsState.isLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
          ),

        // The results drawer (PROD-3043) — a gesture-driven, 3-snap
        // DraggableScrollableSheet: drag handle + results grid, over a pinned
        // footer of filter options + question buttons. It fills the Stack
        // (Positioned.fill) but only PAINTS the sheet at the bottom; the empty
        // region above it has no child, so map taps fall straight through.
        // Must stay BEFORE the debug tab/panel and the modal shield below, so
        // those still render (and hit-test) above it.
        const MapResultsSheet(),

        // Map diagnostics tab + its docked panel. Shown to **admins** (usable
        // in prod for bug-hunting the pin algorithms — PROD-2971's backend
        // debug overlay + per-pin scoring) OR in **debug builds** (PROD-2671's
        // kDebugMode search-area overlay). Off for a non-admin prod user. The
        // panel is non-modal (renders only when open) so pins stay tappable
        // underneath for live per-pin inspection.
        if (isAdmin || kDebugMode) const MapDebugTab(),
        if (isAdmin || kDebugMode)
          MapDebugPanel(
            settledBoundary: _areaBoundary.hoverBoundary,
            boundaryResolving: _areaBoundary.resolving,
          ),

        // PROD-3193: once a curated polygon is available, let a person switch
        // its visual context to the same center + radius circle the map query
        // already uses. The control intentionally disappears when geometry is
        // unavailable, capped, or outside this zoom band.
        // Hidden for now (see [_showAreaDisplay]).
        if (_showAreaDisplay && _canToggleAreaDisplay)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 112,
            right: 12,
            child: PointerInterceptor(
              child: _MapAreaDisplayToggle(
                mode: _effectiveAreaDisplayMode,
                onSelected: (mode) {
                  setState(() => _areaDisplayOverride = mode);
                },
              ),
            ),
          ),

        // PROD-3496 — the focused search mode's full-attention layer: input
        // shield over the Mapbox platform view + scrim + dropdown container.
        // Sits ABOVE the map, drawer, chips and debug chrome (all dimmed and
        // inert while focused) but BELOW the back/search row, which stays
        // lit and interactive. Mounted whenever the bar is (not only while
        // focused) so the shield's deactivation linger can run after exits.
        if (showSearchBar)
          const Positioned.fill(
            child: MapSearchFocusedOverlay(
              // PROD-3497 — the typed-suggestion dropdown fills the FE‑2
              // content slot; the overlay only shows the panel while focused.
              dropdownContent: MapSuggestDropdown(),
            ),
          ),

        // Top area, UPPER layer: the back arrow + v2 search bar row — split
        // from the chips layer above so the focused-search scrim can dim
        // everything beneath while this row stays interactive. Geometry
        // matches the slot the chips layer reserves (16 top pad + 44 row).
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: PointerInterceptor(
              child: Padding(
                // Search row is inset 15px; the chips row (lower layer) is
                // full-width with its own 15px start/end padding.
                padding: const EdgeInsets.only(top: 16, left: 15, right: 15),
                child: Row(
                  children: [
                    // PROD-2996: white fill (was sokoPaper). Always shown —
                    // it holds the row whether or not the search field does.
                    // PROD-3496: while the focused search mode is up this
                    // arrow exits the MODE, not the page (Decision #11) —
                    // routed through the same [_handleBack] as system back.
                    SokoBackButton(
                      variant: SokoBackButtonVariant.floating,
                      surfaceColor: Colors.white,
                      onTap: _handleBack,
                    ),
                    if (showSearchBar) ...const [
                      SizedBox(width: 8),
                      Expanded(child: MapSearchBar()),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),

        // While a map modal (Tema / a pin or card detail sheet) is open,
        // shield the Mapbox canvas so taps/drags don't bleed through to the
        // map on web (Flutter's modal barrier doesn't block HTML platform
        // views). The shield LINGERS briefly after the modal closes — see
        // [MapCanvasShield] for why (touch-browser compatibility clicks).
        Positioned.fill(child: MapCanvasShield(active: mapModalOpen)),

        // Container-transform landing anchor: the invisible full-screen
        // destination for the Discovery `Mapa` pill's Hero flight (see
        // [mapOpenFlightShuttleBuilder]). Ignores pointers and paints nothing,
        // so it never affects the live map — it only gives the flight a
        // full-bleed rect to grow into. Only on the live `/map`; the seeded
        // chat map is reached without the pill, so it has no source Hero.
        if (!widget.seeded)
          Positioned.fill(
            child: IgnorePointer(
              child: Hero(
                tag: kMapOpenHeroTag,
                flightShuttleBuilder: mapOpenFlightShuttleBuilder,
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }
}

/// Two compact, mutually-exclusive display choices for PROD-3193. This lives
/// above the Mapbox platform view so it remains a native Flutter control on
/// web and mobile, while [PointerInterceptor] prevents pointer bleed-through.
class _MapAreaDisplayToggle extends StatelessWidget {
  const _MapAreaDisplayToggle({required this.mode, required this.onSelected});

  final MapAreaDisplayMode mode;
  final ValueChanged<MapAreaDisplayMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Material(
      color: AppColors.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(20),
      child: SegmentedButton<MapAreaDisplayMode>(
        segments: [
          ButtonSegment(
            value: MapAreaDisplayMode.polygon,
            icon: const Icon(Icons.account_tree_outlined, size: 18),
            label: Text(l10n.mapAreaDisplayBoundary),
          ),
          ButtonSegment(
            value: MapAreaDisplayMode.radius,
            icon: const Icon(Icons.circle_outlined, size: 18),
            label: Text(l10n.mapAreaDisplayRadius),
          ),
        ],
        selected: {mode},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onSelected(selection.single),
      ),
    );
  }
}
