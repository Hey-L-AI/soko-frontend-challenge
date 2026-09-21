import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/location_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/pointer_capabilities.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/mapbox_map_widget.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../../map/providers/boundary_children_provider.dart';
import '../../map/providers/boundary_resolve_provider.dart';
import '../../map/utils/location_picker_scope.dart';
import '../../map/utils/point_in_polygon.dart';
import '../../map/utils/map_boundary_scope.dart' as boundary_scope;
import '../../map/widgets/area_search_controller.dart';
import '../../map/widgets/area_search_dropdown.dart';
import '../models/search_scope.dart';

/// Height of the sheet as a fraction of the viewport — large enough for a
/// comfortable map interaction, but still a sheet (not a full-screen map).
const double kLocationScopeSheetHeightFraction = 0.9;

/// Diameter (logical px) of the small centre dot that marks the point the map
/// is reading — a light reference, not a pin (the selected area's outline is the
/// real feedback).
const double _kCenterDotSize = 14.0;

/// Zoom the camera eases to when the user taps the current-location button.
const double _kCurrentLocationZoom = 14.0;

/// Rounds a coordinate to ~110 m so nearby camera settles reuse one
/// `boundaryResolveProvider` family entry instead of minting a fresh (retained)
/// one on every pan.
double _round3(double v) => (v * 1000).roundToDouble() / 1000;

/// True when a camera settle landed on the SAME (~110 m rounded) centre AND zoom
/// as the last settle actually resolved at — a no-op the picker must skip.
///
/// The trigger this exists for: tapping a search suggestion calls
/// `FocusNode.unfocus()`, the keyboard dismisses, the sheet grows, the Mapbox
/// view resizes and fires an idle with an unchanged centre/zoom. Re-resolving on
/// that idle bumps the shared `_idleSeq` guard and silently supersedes the
/// in-flight search pick — so the picked city never lands (PROD map-picker bug).
/// [lastCenter] is expected pre-rounded; the fresh coords are rounded here.
/// Zoom is compared with a small epsilon: a resize never changes zoom, and the
/// opening seed uses the requested zoom (not the map's reported one), so exact
/// equality could spuriously miss the match on float noise — while a real
/// zoom-level change (which re-tiers the pick) is far larger than the epsilon.
@visibleForTesting
bool isNoOpSettle({
  required ({double lat, double lng})? lastCenter,
  required double? lastZoom,
  required double newLat,
  required double newLng,
  required double newZoom,
}) {
  if (lastCenter == null || lastZoom == null) return false;
  return _round3(newLat) == lastCenter.lat &&
      _round3(newLng) == lastCenter.lng &&
      (newZoom - lastZoom).abs() < 0.001;
}

/// The map-based location-scope picker, hosted in a fixed-height modal bottom
/// sheet by `showLocationScopePicker`.
///
/// **Area-first, zoom-levelled:** the map centre is the aim; on each camera
/// settle the containing administrative area is resolved and selected as a
/// whole — its polygon is outlined and its name shown. **Zoom picks the level:**
/// zoomed in selects the tight neighbourhood (freguesia); zoomed out grows the
/// selection to its whole city (the municipality polygon the same resolve
/// returns inline). Confirming commits that area's centroid + recommended radius
/// + stable id + geometry. Where the backend has no covering polygon (a POI, or
/// outside its coverage — Portugal today) the pick falls back to the centre
/// point + the viewport-scaled radius. See `docs/features/user-location.md`.
class LocationScopeSheet extends ConsumerStatefulWidget {
  const LocationScopeSheet({super.key, this.initialScope});

  /// Previous scope to centre on / restore. Null → cached location → GPS →
  /// Lisbon.
  final SearchScope? initialScope;

  @override
  ConsumerState<LocationScopeSheet> createState() => _LocationScopeSheetState();
}

class _LocationScopeSheetState extends ConsumerState<LocationScopeSheet> {
  // Camera seed props. Mutated only for a deliberate recenter (search result /
  // current location); normal panning never feeds back here.
  late ({double lat, double lng}) _center;
  double _seedZoom = kPickerDefaultZoom;
  int _centerToToken = 0;
  bool _locating = false; // current-location button spinner

  // Current selection — exactly one of these describes it:
  //  • _boundary  → a covered area (centre-resolved or a search hit); outlined.
  //  • _point     → an uncovered point (POI / outside coverage) + a radius.
  //  • _restored  → an untouched restore (committed verbatim until the user acts).
  GeoBoundary? _boundary;
  ({double lat, double lng})? _point;
  double _pointRadiusMeters = 3000;
  String _pointName = '';
  SearchScopeArea? _restored;

  Map<String, dynamic>? _outlineGeoJson; // the covered area's polygon

  // Drill-down: when the selection is a whole city, its child neighbourhoods
  // (freguesias) are shown as a light tappable layer. Tapping one selects it.
  // `_children` backs the in-Dart tap hit-test; `_childrenGeoJson` is the map
  // FeatureCollection; `_childrenForCityId` guards against stale async loads.
  List<GeoBoundary> _children = const [];
  Map<String, dynamic>? _childrenGeoJson;
  String? _childrenForCityId;

  bool _resolving = false;

  /// True from the moment the user grabs the map until the settle that follows
  /// has resolved. The current selection is STALE for that whole window — the
  /// centre has moved but nothing has re-resolved yet — so confirm must be
  /// disabled. [_resolving] alone is not enough: it only covers the async
  /// resolve, which does not begin until the camera has already come to rest.
  bool _cameraMoving = false;

  /// Gap between the search field and the results dropdown that overlays the
  /// body directly beneath it. Used twice on purpose: as the header's bottom
  /// padding (which is what physically separates them) and as the zoom hint's
  /// bottom padding, so the hint sits the same distance off the map.
  static const double _kDropdownGap = 6;
  bool _fromSearch =
      false; // last selection came from a search pick (analytics)

  // Latest-settle guard + programmatic-move suppression.
  int _idleSeq = 0;
  bool _ignoreNextIdle = false;
  // Last centre/zoom an idle actually resolved at (rounded to the same ~110 m
  // grid used for the resolve). A settle whose centre + zoom match these is a
  // no-op (e.g. the resize the keyboard dismissal triggers on search-select) and
  // must NOT re-resolve — doing so bumps [_idleSeq] and silently supersedes an
  // in-flight search pick. Mirrors the retired full-screen picker's
  // `if (!zoomChanged && !centerChanged) return;` guard.
  ({double lat, double lng})? _lastSettledCenter;
  double? _lastSettledZoom;
  MapBoundsConfig? _searchBounds; // one-shot fit for a searched boundary

  // Auto-fit tracking: frame the restored area on the first resolve, and frame
  // the whole city whenever the selection becomes a (new) city.
  bool _needsInitialFit = false;
  String? _lastFittedCityId;

  bool _applied = false; // set on Apply so dispose() doesn't log a dismiss

  // Captured in initState so dispose() can log the dismiss WITHOUT touching
  // `ref`: reading a provider from a ConsumerState dispose() throws and
  // silently aborts the rest of dispose(), including super.dispose(). See
  // docs/learnings/ref-read-in-consumerstate-dispose-always-throws.md.
  late final UnifiedAnalyticsService _analytics;
  bool _movedTracked = false; // 'moved' analytics fires once per open

  // Search field + dropdown (reused verbatim from the retired screen).
  final _searchTextController = TextEditingController();
  late final AreaSearchController _search;
  final _searchFocusNode = FocusNode();
  bool _searchFocused = false;
  bool _searchDropdownFocused = false;
  bool _submittedSearchOpen = false;
  bool _searchError = false;
  bool _suppressSearchQuery = false;
  CancelToken? _resolveCancel;
  late String _locale;
  bool _localeInitialized = false;

  @override
  void initState() {
    super.initState();
    _analytics = ref.read(unifiedAnalyticsProvider);
    final lastKnown = ref.read(locationProvider).lastLocation;
    final previousCenter = scopeCenter(widget.initialScope);
    _center = resolvePickerCenter(
      previousScopeCenter: previousCenter,
      lastKnown: lastKnown,
    );

    final initial = widget.initialScope;
    if (initial is SearchScopeArea) {
      // Restore: reopen at the zoom tier the SAVED pick belongs to, so the
      // opening resolve re-selects the level the user confirmed. A city seeds
      // below `kCityLevelMaxZoom`, a neighbourhood above it.
      //
      // This used to be a flat `kPickerDefaultZoom` for every restore, on a
      // "you start specific and zoom OUT to broaden" rationale. That is right
      // for a neighbourhood pick and wrong for a city one: it re-tiered a saved
      // "Lisboa" down to the freguesia under its centroid, so the sheet offered
      // "Select Avenidas Novas" (976 m) while the home page still read "Lisboa"
      // (5 258 m). `restoredBoundaryFor` in `_resolveInitial` is the real
      // guard — this only frames it — but a seed that already sits at the saved
      // tier keeps the fallback path honest too.
      //
      // We still DON'T auto-fit a restored neighbourhood: fitting its bbox can
      // drop the camera below the city-zoom threshold, and a re-resolve there
      // would flip the pick up to the whole city. A restored CITY does fit (it
      // frames at ~z11.7, comfortably below the threshold) — see
      // `_resolveInitial`. The name shows from `_restored` until that returns.
      _restored = initial;
      _seedZoom = seedZoomForRestoredArea(initial);

      // A POINT scope (no polygon) carries its own radius, and that radius is
      // the whole selection — so reopen framing it instead of at the fixed
      // neighbourhood zoom. Previously the camera opened at
      // `kPickerDefaultZoom` regardless, and the first settle then rewrote
      // `_pointRadiusMeters` from that zoom: a 27 km pick reopened as a
      // neighbourhood, silently discarding what the user chose.
      //
      // `_ignoreNextIdle` keeps the fit's own settle from doing exactly that
      // rewrite, so the restored radius survives until the user actually moves
      // the map — at which point re-deriving it is correct.
      //
      // Boundary scopes keep the fixed seed zoom for the reason above.
      if (initial.boundaryId == null) {
        _point = (lat: initial.centerLat, lng: initial.centerLng);
        // Floored too: a scope persisted before PROD-4291 can be tighter than
        // the picker now allows, and reopening must not present a frame the
        // user can no longer choose.
        _pointRadiusMeters = clampPickerRadiusMeters(initial.radiusMeters);
        _pointName = initial.displayName;
        _searchBounds = boundsConfigForRadius(
          center: _point!,
          radiusMeters: initial.radiusMeters,
        );
        _ignoreNextIdle = true;
      }
    }

    final hasSeed = previousCenter != null || lastKnown != null;
    if (!hasSeed) _requestInitialGps();

    _search = AreaSearchController(
      search: (q, token, cancel) => ref
          .read(geoApiProvider)
          .searchAreas(
            q: q,
            sessionToken: token,
            locale: _locale,
            nearLat: _center.lat,
            nearLng: _center.lng,
            cancelToken: cancel,
          ),
      deepSearch: (q, cancel) => ref
          .read(geoApiProvider)
          .deepSearch(
            q: q,
            locale: _locale,
            nearLat: _center.lat,
            nearLng: _center.lng,
            cancelToken: cancel,
          ),
    );
    _searchTextController.addListener(() {
      if (_suppressSearchQuery) return;
      setState(() {
        if (_searchError) _searchError = false;
        _submittedSearchOpen = false;
      });
      _search.onQueryChanged(_searchTextController.text);
    });
    _searchFocusNode.addListener(
      () => setState(() => _searchFocused = _searchFocusNode.hasFocus),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(unifiedAnalyticsProvider)
          .trackLocationPickerInteraction(action: 'opened');
      // Draw the selected area's polygon on load rather than waiting for the
      // first map settle (which doesn't reliably fire when the camera opens
      // static on a restored pick).
      _resolveInitial();
    });
  }

  /// Resolve + outline the area at the opening centre immediately, so the
  /// selected polygon is visible as soon as the sheet loads. Superseded by any
  /// real camera settle (shared `_idleSeq`).
  Future<void> _resolveInitial() async {
    final seq = ++_idleSeq;
    final center = _center;
    // Captured BEFORE the await: the setState below clears `_restored`, and
    // this is the id that decides what we re-select. Null on a cold open.
    final savedBoundaryId = _restored?.boundaryId;
    final zoom = _seedZoom;
    // Seed the settled position at the opening centre/zoom. The sheet can open
    // static on a restored pick (no opening idle fires — the very reason this
    // method exists), so without this seed the FIRST resize-idle (from the
    // keyboard dismissal on a search-select) wouldn't be recognised as a no-op
    // and would supersede the search pick. This resolve covers the opening area,
    // so an opening idle at the same centre is a safe no-op to skip.
    _lastSettledCenter = (lat: _round3(center.lat), lng: _round3(center.lng));
    _lastSettledZoom = _seedZoom;
    // NOTE — a restored POINT scope is deliberately NOT skipped here.
    //
    // Skipping it is more correct for the SELECTION: a point pick (a `gl:`
    // area token, e.g. "Trafaria", which has no polygon in the boundary DB) is
    // already complete as centre + radius, and resolving finds the
    // administrative area that merely CONTAINS it — so confirming after a
    // reopen committed the containing freguesia instead of the point.
    //
    // But skipping it also leaves the map showing only the radius ring, with
    // no outline anywhere, until the user pans. Zé reverted this deliberately
    // (2026-08-26): the missing outline is the worse of the two. The scope
    // change is at least visible — the name and the confirm button both change
    // to the containing area — whereas an empty map reads as broken.
    //
    // The intended resolution is neither: draw the containing boundary as
    // CONTEXT while the restored point stays the committed pick. That needs a
    // second outline channel through the renderers. See
    // `docs/investigations/geo-issues/README.md` #7.
    setState(() => _resolving = true);
    GeoBoundary? boundary;
    try {
      boundary = await ref.read(
        boundaryResolveProvider((
          lat: _round3(center.lat),
          lng: _round3(center.lng),
        )).future,
      );
    } catch (_) {
      boundary = null;
    }
    if (!mounted || seq != _idleSeq) return;
    if (boundary == null) {
      // Uncovered point (outside PT/MX admin-boundary coverage): the server has
      // no polygon here, so there is nothing to draw — but we MUST still leave
      // the loading state. `_resolveInitial` set `_resolving = true` above, and
      // on a cold open where no opening camera-idle fires (notably iOS Safari,
      // which doesn't emit an idle for the seeded static camera) this is the
      // ONLY resolver that runs. Returning here without clearing `_resolving`
      // left the sheet stuck on "Finding area…" forever, with Apply disabled.
      // Mirror `_onCameraIdle`'s uncovered branch: fall back to a point pick at
      // the opening centre so Apply is usable — unless we reopened on a saved
      // pick, in which case its restored selection/label is kept.
      setState(() {
        _resolving = false;
        if (_restored == null) {
          _boundary = null;
          _point = (lat: center.lat, lng: center.lng);
          _pointName = '';
          _outlineGeoJson = null;
          _needsInitialFit = false;
          _lastFittedCityId = null;
        }
      });
      return;
    }
    // Re-select what was SAVED, not what this centre happens to resolve to.
    // `restoredBoundaryFor` matches the stored boundary id against the leaf and
    // its inline municipality; only an id it can't find falls back to tiering by
    // zoom. A cold open passes a null id and tiers as before — at
    // `kPickerDefaultZoom` that is the tight freguesia under the centre, which
    // is the right default (you start specific and zoom OUT to broaden).
    final active = restoredBoundaryFor(
      resolved: boundary,
      savedBoundaryId: savedBoundaryId,
      zoom: zoom,
    )!;
    final isCity = active.level == GeoBoundaryLevel.city;
    // Frame the restored area — at EITHER level. Reopening on a pick should
    // show you that pick, which is behaviour B1 applied to the restore path.
    //
    // This was previously city-only. Under the old fixed-zoom rule, fitting a
    // neighbourhood could drop the camera below the z13 cutoff and cascade the
    // selection up to the whole city — so the fit was suppressed to avoid it.
    // `boundaryForViewport` removes the hazard at its root: a viewport fitted
    // to a neighbourhood's bbox scores ~1.0–1.4 against that neighbourhood,
    // well under `kCityPromoteHoodFactor` (2.0), so the fit can no longer
    // promote the tier it is framing. See
    // `docs/features/location-scope-picker-selection-model.md` § "Why fitting
    // a restored area is safe now".
    final restoredBounds = boundsConfigForArea(active);
    setState(() {
      _resolving = false;
      _restored = null;
      _boundary = active;
      _point = null;
      _pointName = '';
      _outlineGeoJson = _geoJsonOf(active);
      if (restoredBounds != null) {
        _searchBounds = restoredBounds;
        _ignoreNextIdle = true; // the fit's own settle must not re-resolve
      }
      _needsInitialFit = false;
      _lastFittedCityId = isCity ? active.id : null;
    });
    _syncChildrenFor(active);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_localeInitialized) {
      // PROD-3986 follow-up — the API locale code, NOT
      // `Localizations.localeOf(context).languageCode`. That getter collapses
      // BOTH `Locale('pt')` and `Locale('pt','BR')` to `'pt'`, so a Brazilian
      // user was indistinguishable from a Portuguese one on the wire and the
      // backend served European Portuguese to both. `apiLocaleCodeProvider`
      // is the same normalized value `Accept-Language` already carries on
      // every request (PROD-2037) — this stops the query param from
      // contradicting the header.
      _locale = ref.read(apiLocaleCodeProvider) ?? 'en';
      _localeInitialized = true;
    }
  }

  @override
  void dispose() {
    if (!_applied) {
      _analytics.trackLocationPickerInteraction(action: 'dismissed');
    }
    _resolveCancel?.cancel('disposed');
    _searchTextController.dispose();
    _searchFocusNode.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _requestInitialGps() async {
    final result = await ref
        .read(locationServiceProvider)
        .getCurrentLocation(); // may prompt
    if (!mounted || !result.isSuccess) return;
    if (_movedTracked) return; // user already took over the map
    setState(() => _center = (lat: result.latitude!, lng: result.longitude!));
  }

  /// The map's genuine user-gesture signal (never our own camera moves).
  /// Starts the stale window, then forwards to the analytics one-shot.
  ///
  /// Deliberately NOT folded into [_onUserGesture]: `_selectChild` calls that
  /// for a child-polygon TAP, which selects immediately and is not a camera
  /// move — routing it through here would disable confirm on a completed pick.
  void _handleUserGesture() {
    if (!_cameraMoving) setState(() => _cameraMoving = true);
    _onUserGesture();
  }

  void _onUserGesture() {
    if (_movedTracked) return;
    _movedTracked = true;
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationPickerInteraction(action: 'moved');
  }

  Map<String, dynamic>? _geoJsonOf(GeoBoundary b) {
    final g = b.geometry;
    // Identity-based redraw: a fresh instance per selection is required.
    return g != null ? Map<String, dynamic>.from(g) : null;
  }

  /// Build the tappable child layer's FeatureCollection (a fresh instance so the
  /// map's identity check redraws). Null when no child carries geometry.
  Map<String, dynamic>? _childrenFeatureCollection(List<GeoBoundary> kids) {
    final features = <Map<String, dynamic>>[];
    for (final c in kids) {
      final g = c.geometry;
      if (g == null) continue;
      features.add(<String, dynamic>{
        'type': 'Feature',
        'geometry': Map<String, dynamic>.from(g),
        'properties': <String, dynamic>{'id': c.id, 'name': c.name},
      });
    }
    if (features.isEmpty) return null;
    return <String, dynamic>{'type': 'FeatureCollection', 'features': features};
  }

  /// Load (or clear) the drill-down children for the active selection. Fetches a
  /// city's freguesias so they can be shown + tapped; clears them for anything
  /// that isn't a city (a neighbourhood is a leaf, a point has no children).
  Future<void> _syncChildrenFor(GeoBoundary? active) async {
    if (active == null || active.level != GeoBoundaryLevel.city) {
      if (_children.isNotEmpty ||
          _childrenGeoJson != null ||
          _childrenForCityId != null) {
        setState(() {
          _children = const [];
          _childrenGeoJson = null;
          _childrenForCityId = null;
        });
      }
      return;
    }
    if (_childrenForCityId == active.id) return; // already loaded/loading
    _childrenForCityId = active.id;
    List<GeoBoundary> kids;
    try {
      kids = await ref.read(
        boundaryChildrenProvider((
          id: active.id,
          countryCode: active.countryCode,
          parentName: active.name,
          locale: _locale,
        )).future,
      );
    } catch (_) {
      kids = const [];
    }
    // Superseded (the active city changed while we were loading) or gone.
    if (!mounted || _childrenForCityId != active.id) return;
    // Collapse to a single tier — OSM tags real freguesias AND informal bairros
    // at admin_level 8, so the raw list nests (a bairro inside its freguesia);
    // we only want the outermost freguesias as tappable regions.
    final tier = outermostChildren(kids);
    setState(() {
      _children = tier;
      _childrenGeoJson = _childrenFeatureCollection(tier);
    });
  }

  double _bboxArea(GeoBounds b) =>
      (b.north - b.south).abs() * (b.east - b.west).abs();

  /// A tap on the map while a city's children are shown drills into the tapped
  /// neighbourhood. Hit-tests in Dart (no round-trip): the tightest containing
  /// child wins. Taps outside every child (or when no children are shown) are
  /// ignored — panning still recentres + resolves as before.
  void _handleMapTap(double lat, double lng) {
    if (_children.isEmpty) return;
    GeoBoundary? hit;
    double? bestArea;
    for (final c in _children) {
      final g = c.geometry;
      if (g == null || !pointInPolygon(lat, lng, g)) continue;
      final area = _bboxArea(c.bbox);
      if (bestArea == null || area < bestArea) {
        bestArea = area;
        hit = c;
      }
    }
    if (hit != null) _selectChild(hit);
  }

  /// Commit a drilled child as the active selection: outline it, frame its bbox,
  /// and drop the children layer (a neighbourhood has no further drill-down).
  void _selectChild(GeoBoundary child) {
    _onUserGesture();
    final bounds = boundsConfigForArea(child);
    setState(() {
      _idleSeq++; // supersede any in-flight centre resolve
      _resolving = false;
      // A tap IS a definitive pick, so the stale window ends here. Also covers
      // the one path that would otherwise strand it: tapping a child while a
      // pan's resolve is still in flight supersedes that resolve, and when the
      // child has no fittable bbox no further settle arrives to clear it.
      _cameraMoving = false;
      _restored = null;
      _fromSearch = false;
      _boundary = child;
      _point = null;
      _pointName = '';
      _outlineGeoJson = _geoJsonOf(child);
      _children = const [];
      _childrenGeoJson = null;
      _childrenForCityId = null;
      _lastFittedCityId = null;
      if (bounds != null) {
        _searchBounds = bounds; // fit the child; its settle is swallowed below
        _ignoreNextIdle = true;
      }
    });
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationPickerInteraction(action: 'drill_child');
  }

  /// On settle, select the administrative area under the centre (or fall back to
  /// a point when the backend has no covering polygon there).
  Future<void> _onCameraIdle(MapCameraState camera) async {
    if (_ignoreNextIdle) {
      // This settle came from our own camera move (initial / search fit) — keep
      // the selection it produced and drop the one-shot fit config. Record where
      // we landed so the follow-up no-op resize (keyboard dismiss) is ignored.
      _lastSettledCenter = (
        lat: _round3(camera.centerLat),
        lng: _round3(camera.centerLng),
      );
      _lastSettledZoom = camera.zoom;
      setState(() {
        _ignoreNextIdle = false;
        _searchBounds = null;
        _cameraMoving = false;
      });
      return;
    }

    // No-op settle guard: a resize (e.g. the keyboard dismissal that
    // `_handleSearchSelect` triggers via unfocus) fires an idle with the SAME
    // centre + zoom. Re-resolving here would bump [_idleSeq] and silently
    // supersede the in-flight search pick — the "selecting a city does nothing"
    // bug. Nothing moved → nothing to re-resolve.
    if (isNoOpSettle(
      lastCenter: _lastSettledCenter,
      lastZoom: _lastSettledZoom,
      newLat: camera.centerLat,
      newLng: camera.centerLng,
      newZoom: camera.zoom,
    )) {
      // Nothing moved, so nothing to re-resolve — but a gesture that ended
      // where it started still opened the stale window, and only this settle
      // can close it. Without this the confirm button stays disabled forever.
      if (_cameraMoving) setState(() => _cameraMoving = false);
      return;
    }
    _lastSettledCenter = (
      lat: _round3(camera.centerLat),
      lng: _round3(camera.centerLng),
    );
    _lastSettledZoom = camera.zoom;

    final seq = ++_idleSeq;
    setState(() => _resolving = true);

    GeoBoundary? boundary;
    try {
      boundary = await ref.read(
        boundaryResolveProvider((
          lat: _round3(camera.centerLat),
          lng: _round3(camera.centerLng),
        )).future,
      );
    } catch (_) {
      boundary = null;
    }
    if (!mounted || seq != _idleSeq) return;

    setState(() {
      _resolving = false;
      _cameraMoving = false;
      _restored = null; // a fresh resolve supersedes the restore
      _fromSearch = false;
      if (boundary != null) {
        // THE VIEWPORT picks the level (behaviours B1/B2 — see
        // `docs/features/location-scope-picker-selection-model.md`): the tight
        // neighbourhood while it fills the frame, its whole city (the inline
        // municipality polygon) once the frame shows several neighbourhoods or
        // the municipality entire. Both levels come from this one resolve, so
        // re-picking the level costs no extra call.
        //
        // Not `boundaryForZoom` any more: a fixed zoom cutoff assumes every
        // neighbourhood is the same size, and they range over 1.2x–8.9x of
        // their município. Passing the CURRENT selection's level supplies the
        // hysteresis that stops the tier flapping as you pan across the
        // threshold.
        final active = boundaryForViewport(
          neighbourhood: boundary,
          city: boundary.municipality,
          camera: camera,
          cityCurrentlySelected: _boundary?.level == GeoBoundaryLevel.city,
        )!;
        _boundary = active;
        _point = null;
        _pointName = '';
        _outlineGeoJson = _geoJsonOf(active);

        // Frame the whole region: on the first restore resolve, and whenever the
        // selection becomes a new city (so a manual zoom-out to the city fits it).
        // Fitting only on a city-id transition avoids re-fitting while panning at
        // city level; the fit's own settle is swallowed by `_ignoreNextIdle`.
        final isCity = active.level == GeoBoundaryLevel.city;
        final becameNewCity = isCity && active.id != _lastFittedCityId;
        if (_needsInitialFit || becameNewCity) {
          final bounds = boundsConfigForArea(active);
          if (bounds != null) {
            _searchBounds = bounds;
            _ignoreNextIdle = true;
          }
        }
        _needsInitialFit = false;
        _lastFittedCityId = isCity ? active.id : null;
      } else {
        _boundary = null;
        _point = (lat: camera.centerLat, lng: camera.centerLng);
        // INSCRIBED, not circumscribing: this radius is drawn, and the user
        // is choosing it by framing the map. `camera.radiusMeters` reaches the
        // viewport CORNERS, so its circle bulges past every edge and reads as
        // "bigger than the map" — which is exactly what it looked like.
        // Trade-off, deliberate: the viewport corners now fall outside the
        // scope, so it searches slightly less than the map shows. That is the
        // right way round for a control whose whole job is to show you the
        // area you are picking.
        // PROD-4291 — floored at [kMinPickerRadiusMeters]. Applied here rather
        // than at apply time so the highlight circle stops shrinking with the
        // frame: the control shows the scope it will actually store.
        _pointRadiusMeters = clampPickerRadiusMeters(
          camera.inscribedRadiusMeters,
        );
        _pointName = '';
        _outlineGeoJson = null;
        _needsInitialFit = false;
        _lastFittedCityId = null;
      }
    });
    // Load the tappable children when the settle landed on a city; clear them
    // for a neighbourhood / point selection.
    _syncChildrenFor(_boundary);
  }

  /// Recenter the map on the device's current location; the settle then resolves
  /// the area there. Failures stay silent.
  Future<void> _goToCurrentLocation() async {
    setState(() => _locating = true);
    final result = await ref.read(locationServiceProvider).getCurrentLocation();
    if (!mounted) return;
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationPickerInteraction(action: 'current_location');
    if (!result.isSuccess) {
      setState(() => _locating = false);
      return;
    }
    setState(() {
      _locating = false;
      _restored = null;
      _center = (lat: result.latitude!, lng: result.longitude!);
      _seedZoom = _kCurrentLocationZoom;
      _searchBounds = null;
      _centerToToken++; // ease even if the centre value happens to match
      // Leave _ignoreNextIdle false → the settle resolves the area at the user.
    });
  }

  void _setSearchFieldText(String s) {
    _suppressSearchQuery = true;
    _searchTextController.text = s;
    _suppressSearchQuery = false;
  }

  Future<void> _submitSearch(String raw) async {
    if (raw.trim().length < _search.minChars) return;
    setState(() => _submittedSearchOpen = true);
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationPickerInteraction(action: 'search');
    await _search.submitQuery(raw);
  }

  Future<void> _handleSearchSelect(AreaPrediction p) async {
    final seq = ++_idleSeq; // supersede any in-flight centre resolve
    _resolveCancel?.cancel('superseded');
    _resolveCancel = CancelToken();
    _searchDropdownFocused = false;
    _searchFocusNode.unfocus();
    setState(() {
      _resolving = true;
      _searchError = false;
      _submittedSearchOpen = false;
    });
    ref
        .read(unifiedAnalyticsProvider)
        .trackLocationPickerInteraction(action: 'search_result');

    ResolvedArea? area;
    try {
      area = await boundary_scope.resolveSearchPrediction(
        p,
        () => ref
            .read(geoApiProvider)
            .resolveArea(
              id: p.id,
              sessionToken: _search.sessionToken,
              locale: _locale,
              cancelToken: _resolveCancel,
            ),
      );
    } catch (_) {
      area = null;
    }
    if (!mounted || seq != _idleSeq) return;
    _search.afterResolve();

    if (area == null) {
      setState(() {
        _resolving = false;
        _searchError = true;
      });
      return;
    }

    _setSearchFieldText(boundary_scope.boundaryPlaceLabel(area.boundary));
    final b = area.boundary;
    if (area.kind == AreaKind.boundary) {
      final bounds = boundsConfigForArea(b);
      setState(() {
        _resolving = false;
        _searchError = false;
        _fromSearch = true;
        _restored = null;
        _boundary = b; // carries geometry → outlined immediately
        _point = null;
        _pointName = '';
        _outlineGeoJson = _geoJsonOf(b);
        _ignoreNextIdle = true;
        if (bounds != null) {
          _searchBounds = bounds; // fit the city/neighbourhood bbox
        } else {
          _center = (lat: b.centroidLat, lng: b.centroidLon);
          _searchBounds = null;
          _centerToToken++;
        }
      });
      _syncChildrenFor(b); // a searched city shows its tappable children
    } else {
      // A POI / point result: centre on it with its recommended radius, and
      // FRAME that radius.
      //
      // The resolve carries a real bbox alongside `recommended_radius_m` (a
      // Google city resolves through Place Details, so "Nova Iorque" arrives
      // as a ~27 km radius with a ~49 km bbox). Recentring without touching
      // the zoom left the camera wherever the user happened to be — pick New
      // York from neighbourhood zoom and you got a 27 km circle drawn over a
      // ~1 km viewport. The zoom was never hardcoded; it simply was not set,
      // and nothing tied it to the radius.
      //
      // Fitting the bbox is what ties them, and it is the same treatment the
      // boundary branch above already gives. `boundsConfigForArea` returns
      // null for a degenerate bbox (a true POI, or a pre-fix collapsed one),
      // where framing is meaningless — those keep the centre-only move.
      final bounds = boundsConfigForArea(b);
      setState(() {
        _resolving = false;
        _searchError = false;
        _fromSearch = true;
        _restored = null;
        _boundary = null;
        _point = (lat: b.centroidLat, lng: b.centroidLon);
        _pointName = boundary_scope.boundaryPlaceLabel(b);
        _pointRadiusMeters = b.recommendedRadiusM.toDouble();
        _outlineGeoJson = null;
        _center = _point!;
        if (bounds != null) {
          _searchBounds = bounds; // frames the radius
        } else {
          _searchBounds = null;
          _centerToToken++; // no usable bbox — centre only, keep the zoom
        }
        _ignoreNextIdle = true;
      });
      _syncChildrenFor(null); // a point result has no drill-down children
    }
  }

  void _clearSearch() {
    _resolveCancel?.cancel('cleared');
    _setSearchFieldText('');
    _search.reset();
    setState(() {
      _searchDropdownFocused = false;
      _submittedSearchOpen = false;
      _searchError = false;
    });
  }

  void _handleSearchDropdownFocusChanged(bool focused) {
    if (!mounted || _searchDropdownFocused == focused) return;
    setState(() => _searchDropdownFocused = focused);
  }

  void _cancel() {
    Navigator.of(context).pop(); // null → dispose() logs the dismiss
  }

  void _apply() {
    _applied = true;
    final SearchScopeArea scope;
    if (_boundary != null) {
      scope = areaScopeForBoundary(_boundary!);
    } else if (_point != null) {
      scope = pointScope(
        center: _point!,
        radiusMeters: _pointRadiusMeters,
        name: _pointName,
      );
    } else if (_restored != null) {
      scope = _restored!;
    } else {
      scope = pointScope(center: _center, radiusMeters: _pointRadiusMeters);
    }
    ref
        .read(unifiedAnalyticsProvider)
        .trackMapLocationPickerSelect(
          boundaryFound: _boundary != null,
          radiusMeters: scope.radiusMeters,
          method: _fromSearch ? 'search' : 'area',
        );
    Navigator.of(context).pop(scope);
  }

  bool get _showDropdown =>
      _searchTextController.text.trim().isNotEmpty &&
      (_searchFocused || _searchDropdownFocused || _submittedSearchOpen);

  String _placeName(Lt l10n) {
    if (_resolving || _cameraMoving) return l10n.mapLocationPickerResolving;
    if (_boundary != null) return _boundary!.name;
    if (_point != null) {
      return _pointName.isEmpty ? l10n.locationScopeUnnamedArea : _pointName;
    }
    if (_restored != null && _restored!.displayName.isNotEmpty) {
      return _restored!.displayName;
    }
    return l10n.locationScopeUnnamedArea;
  }

  /// Label for the confirm (Apply) button. Echoes the resolved area name —
  /// "Select {area}" — so the user commits the place they framed (and catches a
  /// wrong pick before confirming). Mirrors [_placeName]'s branching and the
  /// legacy picker's `_confirmLabel`. While a resolve is in flight the button is
  /// disabled and shows the "Finding area…" copy the chip also uses.
  String _applyLabel(Lt l10n) {
    if (_resolving || _cameraMoving) return l10n.mapLocationPickerResolving;
    if (_boundary != null) return l10n.locationScopeSelectArea(_boundary!.name);
    if (_point != null) {
      return _pointName.isEmpty
          ? l10n.locationScopeSelectThisArea
          : l10n.locationScopeSelectArea(_pointName);
    }
    if (_restored != null && _restored!.displayName.isNotEmpty) {
      return l10n.locationScopeSelectArea(
        _restored!.displayName.split(', ').first,
      );
    }
    return l10n.locationScopeSelectThisArea;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final media = MediaQuery.of(context);
    // Cap the sheet so it always fits between the keyboard (viewInsets.bottom,
    // which the Padding below lifts it above) and the top safe area.
    final maxHeight =
        media.size.height - media.viewInsets.bottom - media.padding.top;
    final height = (media.size.height * kLocationScopeSheetHeightFraction)
        .clamp(0.0, maxHeight);

    final locationState = ref.watch(locationProvider);
    final userLoc = locationState.lastLocation;
    final userPoint = (userLoc == null || locationState.isIpFallback)
        ? null
        : (lat: userLoc.lat, lng: userLoc.lon);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: DSSheetShell(
          maxHeightFraction: 1,
          header: _buildHeader(l10n),
          footer: _buildFooter(l10n),
          // The map is a framed card with top/bottom padding — so its visible
          // centre equals its geometric centre and the centre dot / selected
          // outline read as truly centred.
          // The dropdown floats over the map (see the Positioned below), so
          // the map card and the footer keep a FIXED position whether or not
          // results are showing. It used to be a `header` child, which made
          // the shell's header grow by up to 280 px and push both down.
          body: Stack(
            children: [
              Column(
                children: [
                  // Soko-tone nudge: zoom changes the granularity of the
                  // selection. It lives in the BODY, not the header, so the
                  // dropdown — which overlays the body from its very top — can
                  // cover it. Keeping it in the header forced the dropdown to
                  // start below it, which is what put a stripe of hint text
                  // between the field and the results.
                  //
                  // It is still laid out normally (never a fixed height), so a
                  // large-font or two-line translation just makes the map
                  // shorter instead of clipping or mispositioning anything.
                  if (!_searchError)
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 18,
                        right: 16,
                        bottom: _kDropdownGap,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          l10n.locationScopeZoomHint,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.body(
                            fontSize: 12,
                            fontWeight: FontWeight.w300,
                            color: AppColors.sokoShade4,
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: MapboxMapWidget(
                                centerLat: _center.lat,
                                centerLng: _center.lng,
                                zoom: _seedZoom,
                                centerToToken: _centerToToken,
                                markers: const [],
                                userDotLatLng: userPoint,
                                pickerPinLatLng: null,
                                // The selected area's polygon outline (null for points).
                                highlightBoundaryGeoJson: _outlineGeoJson,
                                // A point selection has no polygon, so draw the
                                // radius it will actually STORE. `_pointRadiusMeters`
                                // is already re-derived from the viewport on every
                                // settle (`_onCameraIdle`), so zooming grows/shrinks
                                // the ring in step with the scope it produces.
                                // Ignored by the platform layer whenever
                                // `highlightBoundaryGeoJson` is non-null.
                                highlightPoint: _point,
                                highlightRadiusMeters: _pointRadiusMeters,
                                // A selected city's tappable child neighbourhoods.
                                childBoundariesGeoJson: _childrenGeoJson,
                                boundsConfig: _searchBounds,
                                // Desktop browsers only: no pinch, and the
                                // sheet's own scrolling eats the wheel. Zoom
                                // is how this picker chooses its granularity
                                // (B1/B2 in the selection model), so a user
                                // who can't zoom can't pick a level at all.
                                showZoomButtons:
                                    platformPrefersOnScreenZoomControls,
                                onUserGesture: _handleUserGesture,
                                onCameraIdle: _onCameraIdle,
                                onMapTapLatLng: _handleMapTap,
                                // Location-status banner, TOP-left. This is the
                                // surface that needs it most: with location off
                                // the current-location button beside the search
                                // field fails silently and the blue dot is
                                // hidden, so nothing on screen explains either.
                                //
                                // Top, not bottom, because the card's bottom row
                                // is the centred selected-place chip — at this
                                // card's width (viewport − 32) a bottom-left
                                // pill overlaps it by ~50 px on a phone.
                                showLocationStatusBanners: true,
                                locationBannerStyle:
                                    LocationBannerStyle.compact,
                                bannerAnchor: LocationBannerAnchor.top,
                                bannerInset: const EdgeInsets.fromLTRB(
                                  12,
                                  12,
                                  12,
                                  0,
                                ),
                                // Someone who taps a location control inside a
                                // location picker means "take me there", so
                                // finish the job: the same recentre the button
                                // beside the search field performs.
                                onLocationEnabled: _goToCurrentLocation,
                              ),
                            ),

                            // Small centre reference dot (not a pin) — the outlined area
                            // is the real selection feedback.
                            IgnorePointer(
                              child: Center(
                                child: Container(
                                  width: _kCenterDotSize,
                                  height: _kCenterDotSize,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppColors.sokoInk,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.sokoInk.withValues(
                                          alpha: 0.3,
                                        ),
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                            // Selected-place chip — floats over the map, bottom-centred.
                            Positioned(
                              left: 16,
                              right: 16,
                              bottom: 16,
                              child: IgnorePointer(
                                child: Center(child: _buildPlaceChip(l10n)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // Search results — an overlay, aligned to the map card's own
              // horizontal insets so it reads as attached to the field above.
              if (_showDropdown)
                Positioned(
                  left: 16,
                  right: 16,
                  top: 0,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(12),
                    // The "Load more results" row carries a background colour,
                    // so without clipping it would square off the bottom
                    // corners of the rounded card.
                    clipBehavior: Clip.antiAlias,
                    child: AreaSearchDropdown(
                      controller: _search,
                      onSelect: _handleSearchSelect,
                      onFocusChanged: _handleSearchDropdownFocusChanged,
                      searchFocusNode: _searchFocusNode,
                      // Same path as the keyboard's Search key — the row exists
                      // only because users never discovered that key.
                      onLoadMore: () =>
                          _submitSearch(_searchTextController.text),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Lt l10n) {
    return Padding(
      // Bottom padding is the gap between the search field and the dropdown
      // that overlays the body directly beneath it (see `_kDropdownGap`).
      padding: const EdgeInsets.fromLTRB(16, 4, 16, _kDropdownGap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.mapLocationPickerTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.body(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 8),
          // Search field + the current-location button, side by side. Both are
          // pinned to a fixed 44 px height so they align (a cross-axis stretch
          // would demand a bounded height the min-size header Column can't
          // provide → infinite-height layout error).
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: SokoTextField(
                    controller: _searchTextController,
                    focusNode: _searchFocusNode,
                    hintText: l10n.locationScopeSearchHint,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _submitSearch,
                    prefix: const Icon(
                      LucideIcons.search,
                      size: 18,
                      color: AppColors.sokoInk,
                    ),
                    suffix: _searchTextController.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(LucideIcons.x, size: 18),
                            color: AppColors.sokoInk,
                            onPressed: _clearSearch,
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                _CurrentLocationButton(
                  locating: _locating,
                  onTap: _goToCurrentLocation,
                ),
              ],
            ),
          ),
          if (_searchError)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(8),
                color: AppColors.sokoRed,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    l10n.mapLocationSearchError,
                    style: AppTheme.body(
                      fontSize: 13,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The floating "selected place" chip shown bottom-centred over the map.
  Widget _buildPlaceChip(Lt l10n) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.sokoInk.withValues(alpha: 0.18),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.map_pin, size: 16, color: AppColors.sokoInk),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _placeName(l10n),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.body(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(Lt l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: BtSqIco(
              icon: null,
              label: l10n.locationSheetCancel,
              variant: BtSqIcoVariant.idle,
              expand: true,
              onTap: _cancel,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BtSqIco(
              icon: null,
              label: _applyLabel(l10n),
              variant: BtSqIcoVariant.selected,
              expand: true,
              // Spinner + disabled while an area resolve is in flight, so the
              // user can't commit the stale (previous) selection by tapping
              // before the pick lands — the Carnide→Amadora race.
              loading: _resolving || _cameraMoving,
              onTap: (_resolving || _cameraMoving) ? null : _apply,
            ),
          ),
        ],
      ),
    );
  }
}

/// Square icon button beside the search field that recenters the map on the
/// device's current location. Matches the `SokoTextField` look (sokoShade5 fill,
/// 6 px radius) and the 44 px search-row height.
class _CurrentLocationButton extends StatelessWidget {
  const _CurrentLocationButton({required this.locating, required this.onTap});

  final bool locating;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoShade5,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: locating ? null : onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: locating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.sokoInk,
                    ),
                  )
                : const Icon(
                    LucideIcons.locate_fixed,
                    size: 20,
                    color: AppColors.sokoInk,
                  ),
          ),
        ),
      ),
    );
  }
}
