import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/location_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/pointer_capabilities.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/utils/map_zoom_level.dart';
import '../../../shared/widgets/mapbox_map_widget.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../lists/models/search_scope.dart';
import '../providers/boundary_resolve_provider.dart';
import '../widgets/area_search_controller.dart';
import '../widgets/area_search_dropdown.dart';
import '../utils/point_in_polygon.dart';
import '../utils/map_boundary_scope.dart' as boundary_scope;
import '../widgets/boundary_hover_cache.dart';
import '../widgets/boundary_hover_controller.dart';

/// Full-screen "Pick on map" location picker (PROD-3109, Phase 1).
///
/// The user taps the map; the tapped point is resolved to its containing
/// Portuguese neighborhood via [boundaryResolveProvider], the real outline is
/// drawn, and confirming returns a [SearchScopeArea] (center + shape-aware
/// radius, radius mode). Taps outside covered areas fall back to a plain point
/// + a default radius so the picker works everywhere.
///
/// Pushed by `showLocationScopePicker` — the only location picker now;
/// returns the scope via `Navigator.pop`, or null on cancel.
class MapLocationPickerScreen extends ConsumerStatefulWidget {
  const MapLocationPickerScreen({super.key, this.initialScope});

  /// Previous scope to center on / restore. Null → cached location → GPS → Lisbon.
  final SearchScope? initialScope;

  @override
  ConsumerState<MapLocationPickerScreen> createState() =>
      MapLocationPickerScreenState();
}

/// Extracted from the Mapbox screen so the real text-input submission channel
/// can be widget-tested without booting the platform view.
@visibleForTesting
class MapLocationSearchField extends StatelessWidget {
  const MapLocationSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surface,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        textInputAction: TextInputAction.search,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          prefixIcon: const Icon(LucideIcons.search, size: 18),
          hintText: hintText,
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(LucideIcons.x, size: 18),
                  onPressed: onClear,
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
      ),
    );
  }
}

/// The picker opens at this zoom, which maps a point fallback to the 3 km
/// neighbourhood tier until the user changes the camera.
const double _kPickerInitialZoom = 15;

/// Baseline zoom for the point-fallback radius default. Kept at the
/// neighbourhood tier (3 km) and deliberately decoupled from
/// [_kPickerInitialZoom]: opening the camera closer (req5) must NOT shrink the
/// documented default search radius a confirmed point selection carries when no
/// explicit tap-time radius is set. Real taps still track the live camera zoom
/// via [pointFallbackRadiusMetersForZoom]`(_cameraZoom)` in `_handleTap`.
const double _kPickerPointFallbackZoom = 12;

/// Returns the proximity radius for a point picked at [zoom]. The radius is
/// captured with the tap so later map movement cannot alter a pending choice.
/// The named zoom-level policy lives in `shared/utils/map_zoom_level.dart`.
@visibleForTesting
double pointFallbackRadiusMetersForZoom(double zoom) =>
    mapZoomLevelFor(zoom).radiusMeters;

// Lisbon — global fallback center when no user location is available.
const double _kDefaultLat = 38.7223;
const double _kDefaultLng = -9.1393;

/// The most-specific place name for a resolved boundary (e.g. "Alvalade"),
/// shown in the picker field, selection card and hover chip. Delegates to the
/// shared [boundary_scope.boundaryPlaceLabel] so every location surface names
/// the same place identically.
@visibleForTesting
String boundaryPlaceLabel(GeoBoundary b) {
  return boundary_scope.boundaryPlaceLabel(b);
}

/// Build the [SearchScopeArea] a confirmed selection produces. Pure + exposed
/// for tests: a resolved [boundary] yields its centroid + shape-aware radius +
/// stable id + full hierarchy label; otherwise the [fallbackPoint] yields a
/// point + default radius. Exactly one of the two must be non-null.
@visibleForTesting
SearchScopeArea buildAreaScope({
  GeoBoundary? boundary,
  ({double lat, double lng})? fallbackPoint,
  double? fallbackRadiusMeters,
}) {
  if (boundary != null) {
    return boundary_scope.searchScopeAreaForBoundary(boundary);
  }
  final point = fallbackPoint!;
  return SearchScopeArea(
    centerLat: point.lat,
    centerLng: point.lng,
    radiusMeters:
        fallbackRadiusMeters ??
        pointFallbackRadiusMetersForZoom(_kPickerPointFallbackZoom),
    displayName: '',
  );
}

/// Stage a [SearchScopeArea] from a resolved search area. `kind: point` results
/// (future Google street/POI) get `boundaryId: null` so a provider place-id
/// never lands in the containment-reserved field; the label still shows.
@visibleForTesting
SearchScopeArea buildAreaScopeFromResolved(ResolvedArea area) {
  final b = area.boundary;
  final isBoundary = area.kind == AreaKind.boundary;
  return SearchScopeArea(
    centerLat: b.centroidLat,
    centerLng: b.centroidLon,
    radiusMeters: b.recommendedRadiusM.toDouble(),
    boundaryId: isBoundary ? b.id : null,
    boundaryVersion: isBoundary ? b.version : null,
    boundaryLevel: isBoundary ? b.level : GeoBoundaryLevel.unknown,
    boundaryGeometry: isBoundary ? b.geometry : null,
    displayName: boundaryPlaceLabel(b),
    city: b.city,
  );
}

/// Use map-ready coordinates embedded by deep search; only legacy/local area
/// predictions need the existing resolve endpoint. Moved to
/// `utils/map_boundary_scope.dart` (PROD-3498 — the v2 search executor resolves
/// locations the same way); re-exported so this screen's tests and call sites
/// keep their existing import.
const resolveSearchPrediction = boundary_scope.resolveSearchPrediction;

/// The geo-point of the current selection, for the center-of-search pin.
///
/// A map tap drops the pin exactly where the user clicked ([tappedPoint]) — even
/// when the tap resolves to a neighbourhood boundary, the pin stays on the click
/// point, NOT the boundary centroid. The committed search scope is still built
/// from the resolved boundary (centroid + id + radius), so the pin position is
/// purely a visual and changing it doesn't affect what gets searched.
///
/// Precedence: tapped point → search-area centroid (search has no click point) →
/// restored-scope centre. Null when there is no selection at all. [req1]
@visibleForTesting
({double lat, double lng})? pickerSelectionCenter({
  ({double lat, double lng})? tappedPoint,
  ResolvedArea? searchArea,
  ({double lat, double lng})? restoredMarker,
}) {
  if (tappedPoint != null) return tappedPoint;
  if (searchArea != null) {
    return (
      lat: searchArea.boundary.centroidLat,
      lng: searchArea.boundary.centroidLon,
    );
  }
  return restoredMarker;
}

/// The point the always-on center-of-search pin sits on: the resolved selection
/// point if there is a selection, otherwise the live camera centre (so a fresh,
/// unselected picker still shows a pin where the map is looking). [req1]
@visibleForTesting
({double lat, double lng}) pickerPinPoint({
  required ({double lat, double lng})? selectionPoint,
  required ({double lat, double lng}) cameraCenter,
}) => selectionPoint ?? cameraCenter;

/// True when a bbox is too small to safely fit-bounds (points / synthetic
/// boxes). Moved to `utils/map_boundary_scope.dart` (PROD-3498 — the v2 search
/// executor frames the same boxes by hand); re-exported so this screen's tests
/// and call sites keep their existing import.
const isDegenerateBbox = boundary_scope.isDegenerateBbox;

/// A `MapBoundsConfig` fitting the area's bbox, or null when the bbox is
/// degenerate (caller should center on the centroid instead).
@visibleForTesting
MapBoundsConfig? boundsConfigForArea(
  GeoBoundary b, {
  double minSpanDeg = boundary_scope.kMinBboxSpanDeg,
}) {
  if (isDegenerateBbox(b.bbox, minSpanDeg: minSpanDeg)) return null;
  return MapBoundsConfig(
    north: b.bbox.north,
    south: b.bbox.south,
    east: b.bbox.east,
    west: b.bbox.west,
    padding: 48,
    maxZoom: 15,
  );
}

/// Camera center a scope can seed, most-granular first. Null when the scope
/// carries no usable coordinate (country-only, or a Google city not yet resolved).
@visibleForTesting
({double lat, double lng})? scopeCenter(SearchScope? scope) => switch (scope) {
  SearchScopeArea(:final centerLat, :final centerLng) => (
    lat: centerLat,
    lng: centerLng,
  ),
  SearchScopeCountryCity(:final city)
      when city.latitude != null && city.longitude != null =>
    (lat: city.latitude!, lng: city.longitude!),
  _ => null,
};

/// Initial camera center: previous pick → cached location → fresh GPS → Lisbon.
@visibleForTesting
({double lat, double lng}) resolvePickerCenter({
  ({double lat, double lng})? previousScopeCenter,
  LocationSnapshot? lastKnown,
  ({double lat, double lng})? freshGps,
}) {
  if (previousScopeCenter != null) return previousScopeCenter;
  if (lastKnown != null) return (lat: lastKnown.lat, lng: lastKnown.lon);
  if (freshGps != null) return freshGps;
  return (lat: _kDefaultLat, lng: _kDefaultLng);
}

/// Scope to commit on confirm: a fresh tap (boundary or point) wins; otherwise
/// a search area result is used; otherwise an untouched restore returns its
/// scope verbatim so a re-resolve miss or an empty recomputed label can never
/// corrupt what gets committed.
@visibleForTesting
SearchScopeArea confirmScope({
  GeoBoundary? boundary,
  ({double lat, double lng})? fallbackPoint,
  double? fallbackRadiusMeters,
  ResolvedArea? searchArea,
  SearchScopeArea? restoredScope,
}) {
  if (boundary != null || fallbackPoint != null) {
    return buildAreaScope(
      boundary: boundary,
      fallbackPoint: fallbackPoint,
      fallbackRadiusMeters: fallbackRadiusMeters,
    );
  }
  if (searchArea != null) return buildAreaScopeFromResolved(searchArea);
  return restoredScope!; // caller guarantees a selection exists
}

/// True when confirming an untouched restored selection (no intervening tap).
@visibleForTesting
bool isRestoredConfirm({
  GeoBoundary? boundary,
  ({double lat, double lng})? fallbackPoint,
  SearchScopeArea? restoredScope,
}) => restoredScope != null && boundary == null && fallbackPoint == null;

/// A late GPS fix may only move the camera when the user hasn't touched the map
/// and no selection/restore exists — never disturb work in progress.
@visibleForTesting
bool shouldApplyGpsRecenter({
  required bool userTouched,
  required bool hasSelection,
}) => !userTouched && !hasSelection;

/// Text for the read-only field: resolving → fresh boundary label → search area
/// label → restored label → hint. An empty restored label falls through to the hint.
@visibleForTesting
String pickerFieldText({
  required bool resolving,
  GeoBoundary? boundary,
  ResolvedArea? searchArea,
  SearchScopeArea? restoredScope,
  required String resolvingText,
  required String hintText,
}) {
  if (resolving) return resolvingText;
  if (boundary != null) return boundaryPlaceLabel(boundary);
  if (searchArea != null) return boundaryPlaceLabel(searchArea.boundary);
  if (restoredScope != null && restoredScope.displayName.isNotEmpty) {
    return restoredScope.displayName;
  }
  return hintText;
}

/// Whether the search results dropdown should be mounted.
///
/// Focus alone is not enough: pressing Enter runs the heavier deep search, but
/// `TextInputAction.search` unfocuses the field (Flutter's
/// `EditableText._finalizeEditing`), which would collapse a purely
/// focus-gated dropdown right as the (possibly multi-second) deep search
/// starts — hiding both the spinner and the returned options. [submittedSearchOpen]
/// pins it open across a submitted search, independent of focus, until the user
/// edits, clears, taps the map, or picks a result.
@visibleForTesting
bool shouldShowSearchDropdown({
  required bool searchEnabled,
  required bool hasQueryText,
  required bool fieldFocused,
  required bool dropdownFocused,
  required bool submittedSearchOpen,
}) =>
    searchEnabled &&
    hasQueryText &&
    (fieldFocused || dropdownFocused || submittedSearchOpen);

/// The resolved place information shown below the picker search field. A plain
/// point has no hierarchy to show, but its coordinates remain useful feedback
/// that the map tap was recorded.
@visibleForTesting
typedef PickerSelectionDetails = ({
  String? hierarchyLabel,
  double latitude,
  double longitude,
});

/// The picker keeps the resolved place name visible below the field rather
/// than relying on the single-line, ellipsized search field. All resolved
/// boundary paths use the same leaf label and centroid; an uncovered map point
/// still reports its exact tapped coordinates.
@visibleForTesting
PickerSelectionDetails? pickerSelectionDetails({
  required bool resolving,
  GeoBoundary? boundary,
  ResolvedArea? searchArea,
  SearchScopeArea? restoredScope,
  ({double lat, double lng})? fallbackPoint,
}) {
  if (resolving) return null;
  if (boundary != null) {
    return (
      hierarchyLabel: boundaryPlaceLabel(boundary),
      latitude: boundary.centroidLat,
      longitude: boundary.centroidLon,
    );
  }
  if (searchArea != null) {
    final b = searchArea.boundary;
    return (
      hierarchyLabel: boundaryPlaceLabel(b),
      latitude: b.centroidLat,
      longitude: b.centroidLon,
    );
  }
  if (fallbackPoint != null) {
    return (
      hierarchyLabel: null,
      latitude: fallbackPoint.lat,
      longitude: fallbackPoint.lng,
    );
  }
  if (restoredScope != null) {
    return (
      hierarchyLabel: restoredScope.displayName.isEmpty
          ? null
          : restoredScope.displayName,
      latitude: restoredScope.centerLat,
      longitude: restoredScope.centerLng,
    );
  }
  return null;
}

/// Compact, map-safe selection summary. This remains outside the platform map
/// view so text and semantics behave consistently on web and native.
@visibleForTesting
class MapLocationSelectionDetails extends StatelessWidget {
  const MapLocationSelectionDetails({
    super.key,
    this.hierarchyLabel,
    required this.coordinatesLabel,
  });

  final String? hierarchyLabel;
  final String coordinatesLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: [
        if (hierarchyLabel != null) hierarchyLabel!,
        coordinatesLabel,
      ].join(', '),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hierarchyLabel != null)
                Text(
                  hierarchyLabel!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              Text(
                coordinatesLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Public (not `_`-prefixed) so widget tests can reach [handleTap] via
/// `tester.state`.
class MapLocationPickerScreenState
    extends ConsumerState<MapLocationPickerScreen> {
  GeoBoundary? _boundary;
  ({double lat, double lng})? _fallbackPoint;
  // Raw coordinate of the last map tap — where the center-of-search pin is
  // dropped. Kept even when the tap resolves to a boundary (the pin marks the
  // click, not the neighbourhood centroid); cleared by search-select and clear.
  ({double lat, double lng})? _tappedPoint;
  double? _fallbackRadiusMeters;
  bool _resolving = false;

  /// Monotonic selection counter shared by tap / restore / search-select / clear
  /// — a stale async result is dropped when a newer selection has fired.
  int _selectionSeq = 0;

  SearchScopeArea? _restoredScope; // untouched restore (label + confirm)
  late ({double lat, double lng})
  _center; // seed/GPS/search camera center — the `centerLat/Lng` map prop
  // Live camera centre from onCameraIdle, kept separate from [_center] (which
  // drives the camera prop) so tracking pan doesn't feed back into the camera.
  // Backs the unselected center-of-search pin so it follows where the map looks.
  late ({double lat, double lng}) _cameraCenter;
  double _cameraZoom = _kPickerInitialZoom;

  /// Imperative "go there NOW" counter for the camera. Only the banner recenter
  /// bumps it; every other camera move here is prop-driven as before.
  ///
  /// It exists because prop diffing is not enough for that one path: this screen
  /// can be seeded from `lastLocation`, so recentering on a fresh fix often
  /// assigns `_center` the value it already holds, `didUpdateWidget` sees no
  /// change, and the tap does nothing after the user has panned away. See
  /// `docs/learnings/mapbox-imperative-tokens-fit-vs-center.md`.
  int _centerToToken = 0;
  bool _userTouched = false; // any tap; guards late GPS recenter

  // Search-selection state (Phase 2).
  ResolvedArea? _searchArea; // staged search selection (kind + boundary)
  String? _searchResultType; // picked prediction.type (analytics)
  String? _searchResultSource; // picked prediction.source (analytics)
  MapBoundsConfig? _selectedBounds; // bbox to fit for the current selection
  bool _searchError = false; // transient resolve-error flag

  // Phase 2 — editable search field + dropdown (flag-gated).
  final _searchTextController = TextEditingController();
  late final AreaSearchController _search;
  bool _searchFocused = false;
  bool _searchDropdownFocused = false;
  // Keeps the results dropdown open across an Enter-submitted deep search even
  // after `TextInputAction.search` unfocuses the field. Cleared on edit, clear,
  // map tap, and result selection.
  bool _submittedSearchOpen = false;
  final _searchFocusNode = FocusNode();
  // Set once in didChangeDependencies — safe to use in closures.
  late String _locale;
  bool _localeInitialized = false;
  bool _suppressSearchQuery =
      false; // true while setting the field text programmatically
  CancelToken? _resolveCancel; // cancels an in-flight resolveArea

  // Web hover preview — only where a mouse exists.
  final _hoverCache = BoundaryHoverCache();
  late final BoundaryHoverController _hover;
  final bool _hoverEnabled = kIsWeb;

  bool get _hasSelection =>
      _boundary != null ||
      _fallbackPoint != null ||
      _searchArea != null ||
      _restoredScope != null;

  @override
  void initState() {
    super.initState();
    final lastKnown = ref.read(locationProvider).lastLocation;
    _center = resolvePickerCenter(
      previousScopeCenter: scopeCenter(widget.initialScope),
      lastKnown: lastKnown,
    );
    _cameraCenter = _center;
    final hasPrevOrCache =
        scopeCenter(widget.initialScope) != null ||
        ref.read(locationProvider).lastLocation != null;
    if (!hasPrevOrCache) _requestGpsRecenter();
    final initial = widget.initialScope;
    if (initial is SearchScopeArea) {
      _restoredScope = initial; // label + confirm come from the restored scope
    }
    _hover = BoundaryHoverController(
      cache: _hoverCache,
      selectionSeq: () => _selectionSeq,
      resolve: (lat, lng, cancel) => ref
          .read(geoApiProvider)
          .resolveBoundaryAt(
            lat: lat,
            lng: lng,
            locale: _locale,
            cancelToken: cancel,
          ),
    );
    _hover.addListener(() {
      if (mounted) setState(() {});
    });
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
      if (_suppressSearchQuery) return; // programmatic set — never search
      // Rebuild so `showDropdown` re-evaluates against the new text. Without
      // this the dropdown never mounts when the field goes empty → non-empty
      // (the controller's own notifyListeners only drives the AnimatedBuilder
      // *inside* the dropdown, which can't run until the dropdown is built).
      setState(() {
        if (_searchError) _searchError = false;
        // A fresh edit starts a new autocomplete session; the field is focused,
        // so drop the submitted-search pin and let focus drive visibility again.
        _submittedSearchOpen = false;
      });
      _search.onQueryChanged(_searchTextController.text);
    });
    _searchFocusNode.addListener(
      () => setState(() => _searchFocused = _searchFocusNode.hasFocus),
    );
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
    _resolveCancel?.cancel('disposed');
    _searchTextController.dispose();
    _searchFocusNode.dispose();
    _search.dispose();
    _hover.dispose();
    super.dispose();
  }

  /// Best-effort: re-resolve at the stored centroid and draw the outline ONLY if
  /// the returned boundary id matches (centroids can fall outside concave shapes).
  Future<void> _requestGpsRecenter() async {
    final result = await ref
        .read(locationServiceProvider)
        .getCurrentLocation(); // silent:false — may prompt
    if (!mounted || !result.isSuccess) {
      return; // denied/timeout/error → stay on Lisbon, silent
    }
    if (!shouldApplyGpsRecenter(
      userTouched: _userTouched,
      hasSelection: _hasSelection,
    )) {
      return;
    }
    setState(() => _center = (lat: result.latitude!, lng: result.longitude!));
  }

  /// Fly to the fix the user just enabled by tapping the location-status
  /// banner. Reads the snapshot the banner's own permission request already
  /// wrote, so there's no second GPS round trip.
  ///
  /// Deliberately **not** [_requestGpsRecenter]: that is the *opening*
  /// recentre, gated on `shouldApplyGpsRecenter` so it backs off once the user
  /// has touched the map or picked something — which is precisely the state a
  /// banner tap happens in. An explicit tap on a location control is an
  /// instruction, not a heuristic.
  void _recenterOnEnabledLocation() {
    final snapshot = ref.read(locationProvider).lastLocation;
    if (!mounted || snapshot == null) return;
    setState(() {
      _center = (lat: snapshot.lat, lng: snapshot.lon);
      // Ease even when the value is unchanged — see [_centerToToken].
      _centerToToken++;
    });
  }

  /// Exposed for widget tests (the real Mapbox view can't boot under
  /// `flutter test`, so tests drive taps through this instead of a gesture).
  @visibleForTesting
  Future<void> handleTap(double lat, double lng) => _handleTap(lat, lng);

  Future<void> _handleTap(double lat, double lng) async {
    // WYSIWYG: commit the hover preview only when the tap lands inside it —
    // what the user sees is what gets committed (no masking by a broader cached area).
    final preview = _hover.hoverBoundary;
    if (preview != null &&
        preview.geometry != null &&
        pointInPolygon(lat, lng, preview.geometry!)) {
      // Commit instantly from the previewed area — no re-resolve.
      ++_selectionSeq;
      _hover.onSelectionChanged();
      setState(() {
        _resolving = false;
        _boundary = preview;
        _fallbackPoint = null;
        _tappedPoint = (lat: lat, lng: lng);
        _fallbackRadiusMeters = null;
        _restoredScope = null;
        _searchArea = null;
        _searchResultType = null;
        _searchResultSource = null;
        _selectedBounds = null;
        _submittedSearchOpen =
            false; // a map tap supersedes the submitted search
        _userTouched = true;
      });
      _setSearchFieldText(boundaryPlaceLabel(preview));
      return;
    }

    final seq = ++_selectionSeq;
    _hover.onSelectionChanged();
    setState(() {
      _resolving = true;
      // Supersede a pinned submitted search immediately, before the async
      // boundary resolve, so its dropdown can't linger over the map mid-tap.
      _submittedSearchOpen = false;
      // Drop the pin on the raw tap immediately, before boundary resolution —
      // the pin must follow the click even during a slow/failing resolve.
      _tappedPoint = (lat: lat, lng: lng);
      _userTouched =
          true; // set immediately so a late GPS fix can't recenter mid-tap
    });

    GeoBoundary? boundary;
    try {
      boundary = await ref.read(
        boundaryResolveProvider((lat: lat, lng: lng)).future,
      );
    } catch (_) {
      boundary = null; // network/parse failure → point fallback
    }

    // Stale tap (a newer one fired) or screen gone — drop this result.
    if (!mounted || seq != _selectionSeq) return;

    // Update field to reflect the tapped area — suppress listener to avoid
    // firing a /geo/areas query (programmatic set, not user input).
    _setSearchFieldText(boundary != null ? boundaryPlaceLabel(boundary) : '');
    setState(() {
      _resolving = false;
      _boundary = boundary;
      _fallbackPoint = boundary == null ? (lat: lat, lng: lng) : null;
      // The pin marks the click point regardless of boundary resolution.
      _tappedPoint = (lat: lat, lng: lng);
      _fallbackRadiusMeters = boundary == null
          ? pointFallbackRadiusMetersForZoom(_cameraZoom)
          : null;
      _restoredScope = null; // a fresh tap supersedes the restore
      _userTouched = true;
      // Tap supersedes search selection.
      _searchArea = null;
      _searchResultType = null;
      _searchResultSource = null;
      _selectedBounds = null;
      // _submittedSearchOpen already cleared in the immediate tap setState above.
    });
  }

  void _confirm() {
    final scope = confirmScope(
      boundary: _boundary,
      fallbackPoint: _fallbackPoint,
      fallbackRadiusMeters: _fallbackRadiusMeters,
      searchArea: _searchArea,
      restoredScope: _restoredScope,
    );
    final viaSearch =
        _searchArea != null && _boundary == null && _fallbackPoint == null;
    ref
        .read(unifiedAnalyticsProvider)
        .trackMapLocationPickerSelect(
          boundaryFound: scope.boundaryId != null,
          radiusMeters: scope.radiusMeters,
          restored: isRestoredConfirm(
            boundary: _boundary,
            fallbackPoint: _fallbackPoint,
            restoredScope: _restoredScope,
          ),
          method: viaSearch ? 'search' : 'tap',
          resultType: viaSearch ? _searchResultType : null,
          resultSource: viaSearch ? _searchResultSource : null,
        );
    Navigator.of(context).pop(scope);
  }

  String _confirmLabel(Lt l10n) {
    final boundary = _boundary;
    if (boundary != null) {
      return l10n.mapLocationPickerConfirmArea(boundary.name);
    }
    final searchArea = _searchArea;
    if (searchArea != null) {
      return l10n.mapLocationPickerConfirmArea(searchArea.boundary.name);
    }
    final restored = _restoredScope;
    if (restored != null && restored.displayName.isNotEmpty) {
      final firstPart = restored.displayName.split(', ').first;
      return l10n.mapLocationPickerConfirmArea(firstPart);
    }
    return l10n.mapLocationPickerConfirmPoint;
  }

  /// Enter/submit on the field runs the heavier deep search. Pin the results
  /// dropdown open first so the unfocus that `TextInputAction.search` triggers
  /// can't collapse it while the deep search is in flight or its results land.
  Future<void> _submitSearch(String raw) async {
    if (raw.trim().length < _search.minChars) return;
    setState(() => _submittedSearchOpen = true);
    await _search.submitQuery(raw);
  }

  Future<void> _handleSearchSelect(AreaPrediction p) async {
    final seq = ++_selectionSeq;
    _hover.onSelectionChanged();
    // Cancel any prior in-flight resolve and start a fresh token.
    _resolveCancel?.cancel('superseded');
    _resolveCancel = CancelToken();
    _searchDropdownFocused = false;
    _searchFocusNode.unfocus();
    setState(() {
      _resolving = true;
      _searchError = false;
      _submittedSearchOpen = false; // a pick supersedes the submitted search
      _userTouched =
          true; // set immediately so a late GPS fix can't recenter mid-select
    });
    ResolvedArea? area;
    try {
      area = await resolveSearchPrediction(
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
    if (!mounted || seq != _selectionSeq) {
      return; // superseded by a newer selection
    }
    _search
        .afterResolve(); // Places session ends on resolve — only for the winner
    if (area == null) {
      setState(() {
        _resolving = false;
        _searchError = true; // show l10n.mapLocationSearchError transiently
      });
      return;
    }
    final bounds = boundsConfigForArea(area.boundary);
    // Reflect the picked label in the field — suppress listener (programmatic set).
    _setSearchFieldText(boundaryPlaceLabel(area.boundary));
    setState(() {
      _resolving = false;
      _searchError = false;
      _searchArea = area;
      _searchResultType = p.type;
      _searchResultSource = p.source;
      _selectedBounds = bounds;
      // Search supersedes tap/restore.
      _boundary = null;
      _fallbackPoint = null;
      _tappedPoint = null; // search has no click point; pin uses its centroid
      _fallbackRadiusMeters = null;
      _restoredScope = null;
      _userTouched = true;
      // When degenerate/point bbox, center on the area centroid.
      if (bounds == null) {
        _center = (
          lat: area!.boundary.centroidLat,
          lng: area.boundary.centroidLon,
        );
      }
    });
  }

  /// Sets the search field text programmatically without triggering an
  /// autocomplete query. All internal writes must go through this helper.
  void _setSearchFieldText(String s) {
    _suppressSearchQuery = true;
    _searchTextController.text = s;
    _suppressSearchQuery = false;
  }

  void _clearSearch() {
    ++_selectionSeq; // invalidate any in-flight resolve
    _hover.onSelectionChanged();
    _resolveCancel?.cancel('cleared');
    _setSearchFieldText('');
    _search.reset();
    setState(() {
      _searchDropdownFocused = false;
      _submittedSearchOpen = false;
      _boundary = null;
      _fallbackPoint = null;
      _tappedPoint = null;
      _searchArea = null;
      _restoredScope = null;
      _selectedBounds = null;
      _searchResultType = null;
      _searchResultSource = null;
      _searchError = false;
      _resolving = false;
    });
  }

  void _handleSearchDropdownFocusChanged(bool focused) {
    if (!mounted || _searchDropdownFocused == focused) return;
    setState(() => _searchDropdownFocused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    final showDropdown = shouldShowSearchDropdown(
      searchEnabled: true,
      hasQueryText: _searchTextController.text.trim().isNotEmpty,
      fieldFocused: _searchFocused,
      dropdownFocused: _searchDropdownFocused,
      submittedSearchOpen: _submittedSearchOpen,
    );

    // req1: always show a center-of-search pin. It sits on the resolved
    // selection point (tap / boundary centroid / search / restored scope) when
    // there is one, otherwise on the live camera centre.
    final restoredMarker = (_restoredScope != null && _boundary == null)
        ? (lat: _restoredScope!.centerLat, lng: _restoredScope!.centerLng)
        : null;
    final selectionPoint = pickerSelectionCenter(
      tappedPoint: _tappedPoint,
      searchArea: _searchArea,
      restoredMarker: restoredMarker,
    );
    final pinPoint = pickerPinPoint(
      selectionPoint: selectionPoint,
      cameraCenter: _cameraCenter,
    );

    // req2: the user-location blue dot, rendered exactly like every other map
    // surface — the shared rule is "a real GPS fix only" (skip IP-fallback). A
    // dot outside the viewport is simply not drawn, so no explicit viewport
    // gating is needed to "hide it when outside".
    final locationState = ref.watch(locationProvider);
    final userLoc = locationState.lastLocation;
    final userPoint = (userLoc == null || locationState.isIpFallback)
        ? null
        : (lat: userLoc.lat, lng: userLoc.lon);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: MapboxMapWidget(
              centerLat: _center.lat,
              centerLng: _center.lng,
              centerToToken: _centerToToken,
              zoom: _kPickerInitialZoom,
              markers: const [],
              // req1: the center-of-search pin — the Soko teardrop
              // (`assets/pins/pin-search.png`) rendered on its own dedicated
              // symbol/annotation layer, bottom-anchored so the tip sits on the
              // point. Independent of the marker/cluster pipeline (mirrors the
              // user dot), so panning never re-triggers marker/bounds fitting.
              pickerPinLatLng: pinPoint,
              userDotLatLng: userPoint,
              // req3: the my-location button always frames the center-of-search
              // pin together with the user (fit-both ↔ zoom-user). Uses the
              // always-present pin point (selection, else map centre) so the
              // toggle engages even before the user picks a spot; _selectionSeq
              // restarts the toggle when the user picks a new spot.
              recenterAnchor: pinPoint,
              recenterResetKey: _selectionSeq,
              // PROD-3189: the picker shares the Map page's existing
              // center-on-me control. It hides until a location is available
              // and retains its walking → near-me zoom behaviour.
              showMyLocationButton: true,
              // Desktop browsers only — no pinch there, and this picker also
              // sets its granularity by zoom. Same rule as the redesigned
              // sheet, so the two pickers can't diverge on desktop.
              showZoomButtons: platformPrefersOnScreenZoomControls,
              // Keep the control below the floating back/title row (~44 px) and
              // the 52 px search field beneath it. The overlay above starts at
              // `padding.top + 12` (line ~999), so the button must carry the SAME
              // safe-area offset — otherwise on a notched device the search field
              // shifts down over the fixed-position button and hides it (the
              // button lives in MapboxMapWidget's full-bleed Stack, no SafeArea).
              topButtonsTopInset: MediaQuery.of(context).padding.top + 132,
              onMapTapLatLng: _handleTap,
              onCameraIdle: (camera) {
                final zoomChanged = camera.zoom != _cameraZoom;
                final centerChanged =
                    camera.centerLat != _cameraCenter.lat ||
                    camera.centerLng != _cameraCenter.lng;
                if (!zoomChanged && !centerChanged) return;
                setState(() {
                  _cameraZoom = camera.zoom;
                  // Backs the unselected center-of-search pin (req1); does NOT
                  // touch [_center] so tracking pan can't re-drive the camera.
                  _cameraCenter = (
                    lat: camera.centerLat,
                    lng: camera.centerLng,
                  );
                });
              },
              // req4: the picker no longer draws the selection polygon, the
              // point-fallback radius ring, or the hover-preview polygon.
              // Hover detection stays on so the floating area label + the
              // WYSIWYG tap-commit fast-path keep working.
              boundsConfig: _selectedBounds,
              onMapHoverLatLng: _hoverEnabled ? _hover.onHover : null,
              onMapHoverExit: _hoverEnabled ? _hover.onExit : null,
              // Location-status banner, bottom-left. Shares the hover name
              // pill's row (the same `16 + safe area + 56 + 12` the Positioned
              // below uses — keep the two in lockstep) so it clears the Confirm
              // CTA. The hover pill is centred AND desktop-pointer-only, where
              // the viewport is wide enough that the two don't meet.
              showLocationStatusBanners: true,
              locationBannerStyle: LocationBannerStyle.compact,
              bannerInset: EdgeInsets.fromLTRB(
                12,
                0,
                12,
                16 + MediaQuery.of(context).padding.bottom + 56 + 12,
              ),
              // Same reasoning as the scope sheet: land the camera on the fix
              // the user just turned on.
              onLocationEnabled: _recenterOnEnabledLocation,
            ),
          ),

          // Top overlay — floating back button + title, then the search field.
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 12,
            right: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Back button matches the /map screen (floating white chip);
                // the title states what the picker is for.
                Row(
                  children: [
                    const SokoBackButton(
                      variant: SokoBackButtonVariant.floating,
                      surfaceColor: Colors.white,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.mapLocationPickerTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppColors.sokoInk,
                          shadows: const [
                            Shadow(color: Colors.white, blurRadius: 8),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                MapLocationSearchField(
                  controller: _searchTextController,
                  focusNode: _searchFocusNode,
                  hintText: l10n.mapLocationSearchHint,
                  onSubmitted: _submitSearch,
                  onClear: _clearSearch,
                ),
                if (showDropdown)
                  Material(
                    elevation: 4,
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(12),
                    ),
                    // The "Load more results" row carries a background colour,
                    // so without clipping it would square off the rounded
                    // bottom corners.
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
                if (_searchError)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Material(
                      elevation: 2,
                      borderRadius: BorderRadius.circular(8),
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          l10n.mapLocationSearchError,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Hover name pill — bottom-centre above the Confirm CTA.
          if (_hoverEnabled &&
              _hover.hoverBoundary != null &&
              !_searchFocused &&
              !_searchError &&
              !showDropdown)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16 + MediaQuery.of(context).padding.bottom + 56 + 12,
              child: Center(
                child: Material(
                  elevation: 2,
                  borderRadius: BorderRadius.circular(20),
                  color: Theme.of(context).colorScheme.surface,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Text(
                      _hover.resolving
                          ? l10n.mapLocationHoverResolving
                          : boundaryPlaceLabel(_hover.hoverBoundary!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            ),

          // Bottom confirm CTA — enabled only once something is selected.
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.of(context).padding.bottom,
            child: SokoCtaButton(
              label: _confirmLabel(l10n),
              loading: _resolving,
              onPressed: _hasSelection && !_resolving ? _confirm : null,
            ),
          ),
        ],
      ),
    );
  }
}
