import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/map_pin.dart';
import '../../../shared/widgets/map_marker_model.dart';
import '../models/map_query.dart';
import '../utils/map_deep_link_params.dart';

/// PROD-2671 — holds the live [MapQuery] (the durable seam). The filter UI
/// and the camera both write here; the data layer (`mapMarkersProvider`)
/// reads it. autoDispose is intentional: the Map page is a single screen,
/// so the query resets when the user leaves and comes back.
final mapQueryProvider =
    StateNotifierProvider.autoDispose<MapQueryNotifier, MapQuery>(
      (ref) => MapQueryNotifier(),
    );

/// True while a map modal sheet (e.g. Tema) is open. The map screen renders a
/// full-bleed [PointerInterceptor] over the (HTML platform-view) Mapbox canvas
/// while this is true, so drags on the sheet/barrier don't bleed through to the
/// map on web — Flutter's modal barrier alone doesn't block platform views.
final mapModalOpenProvider = StateProvider.autoDispose<bool>((ref) => false);

/// PROD-3833 — how far a settle may differ from the viewport we already hold
/// and still count as "the same view", as a fraction of that viewport's own
/// span. 2 % of a ~2 km viewport is ~40 m: comfortably above the rounding
/// between an arithmetic seed and a rectangle read off a live map, and far
/// below any pan a person would make on purpose.
const double kMapSettleViewportTolerance = 0.02;

/// Signed shortest difference between two longitudes, in degrees, correct
/// across the antimeridian (`179.9` and `-179.9` are 0.2° apart, not 359.8°).
double _lngDelta(double a, double b) {
  final d = (a - b) % 360.0; // Dart's % is non-negative here: [0, 360)
  return d > 180.0 ? d - 360.0 : d;
}

/// East-minus-west span in degrees, correct when the rect wraps the
/// antimeridian (where `swLng > neLng`; see [MapCameraState.contains]).
double _lngSpan(double west, double east) => (east - west) % 360.0;

/// PROD-3833 — does an incoming settle describe the viewport [s] already
/// holds, to within [kMapSettleViewportTolerance] of its span?
///
/// Compares the four EDGES rather than the centre + radius. Both derived
/// quantities come from the corners, so agreeing corners imply an agreeing
/// centre — and the reverse is not true, which is why the old `radiusMeters`
/// check was the wrong instrument as well as the wrong threshold.
///
/// Falls back to the pre-PROD-3833 scalar guards when either side has no
/// rectangle, which is the path a map still takes when the opening seed could
/// not compute one.
@visibleForTesting
bool settleWithinViewportTolerance(
  MapQuery s, {
  required double lat,
  required double lng,
  required double radiusMeters,
  double? neLat,
  double? neLng,
  double? swLat,
  double? swLng,
}) {
  if (!s.hasBounds ||
      neLat == null ||
      neLng == null ||
      swLat == null ||
      swLng == null) {
    return (s.centerLat! - lat).abs() <= 1e-5 &&
        (s.centerLng! - lng).abs() <= 1e-5 &&
        (s.radiusMeters - radiusMeters).abs() <= 1;
  }
  final latSpan = (s.neLat! - s.swLat!).abs();
  final lngSpan = _lngSpan(s.swLng!, s.neLng!);
  // A degenerate stored rect can't anchor a relative tolerance; treat any
  // settle against it as a real move so the query re-derives from the camera.
  if (latSpan <= 0 || lngSpan <= 0) return false;
  final latTol = latSpan * kMapSettleViewportTolerance;
  final lngTol = lngSpan * kMapSettleViewportTolerance;
  return (s.neLat! - neLat).abs() <= latTol &&
      (s.swLat! - swLat).abs() <= latTol &&
      _lngDelta(s.neLng!, neLng).abs() <= lngTol &&
      _lngDelta(s.swLng!, swLng).abs() <= lngTol;
}

class MapQueryNotifier extends StateNotifier<MapQuery> {
  MapQueryNotifier() : super(const MapQuery());

  /// PROD-3219: why the most recent committed query change happened — read by
  /// the map_screen results listener to tag `map_area_searched`. Values:
  /// 'initial' | 'pan' | 'area' | 'filter' | 'shortcut' | 'keyword' |
  /// 'selection' | 'list' | 'deep_link'. Set only when a change actually
  /// commits (so it always matches the resulting fetch).
  String _lastTrigger = 'initial';
  String get lastTrigger => _lastTrigger;

  /// Seed the centre once from the user's location, before the first
  /// camera settle — so the initial fetch can run even if the map hasn't
  /// emitted a `moveend` yet. No-op once a centre exists.
  ///
  /// PROD-3833 — prefer [seedViewport]. A centre alone leaves `hasBounds`
  /// false, which forces `pins_version=1` and guarantees a second, superseding
  /// request once the map finally reports its viewport. This remains the
  /// fallback for the one case that cannot compute a rectangle: the map's box
  /// has not been laid out yet.
  void seedCenter(double lat, double lng) {
    if (state.hasCenter) return;
    _lastTrigger = 'initial';
    state = state.copyWith(centerLat: lat, centerLng: lng);
  }

  /// PROD-3833 — seed the **whole opening camera** (centre + viewport rect +
  /// zoom + radius) in ONE state write, before Mapbox exists.
  ///
  /// This is what makes the first `/map/pins` the *final* one: with bounds
  /// present the request goes out as `pins_version=2` with the real rectangle,
  /// so the pre-emitted settle that `_startOpenSettle` fires once the map loads
  /// re-states a camera we already have and [onCameraSettled]'s drift tolerance
  /// absorbs it. Before this, the seeded request was always a v1 placeholder
  /// that the settle cancelled and replaced — one wasted round trip per map
  /// open, and the useful one did not start until the basemap had finished
  /// loading.
  ///
  /// One write, not four, because [mapPinsProvider] fetches on every
  /// [MapQuery] change; four writes would be four requests.
  ///
  /// No-op once a centre exists, exactly like [seedCenter] — the opening camera
  /// is seeded once and the live camera owns it afterwards.
  void seedViewport(MapCameraState cam) {
    if (state.hasCenter) return;
    _lastTrigger = 'initial';
    state = state.copyWith(
      centerLat: cam.centerLat,
      centerLng: cam.centerLng,
      radiusMeters: cam.radiusMeters,
      zoom: cam.zoom,
      neLat: cam.neLat,
      neLng: cam.neLng,
      swLat: cam.swLat,
      swLng: cam.swLng,
    );
  }

  /// Apply the settled camera (Mapbox `moveend`). Ignores sub-threshold
  /// drift so we don't refetch on noise. The viewport corners ([neLat] …
  /// [swLng]) feed the grid selection (PROD-2807).
  void onCameraSettled({
    required double lat,
    required double lng,
    required double radiusMeters,
    required double zoom,
    double? neLat,
    double? neLng,
    double? swLat,
    double? swLng,
    // PROD-3219: 'pan' for a normal browse settle, 'area' when the user
    // explicitly committed via "Search this area" (`_commitLiveCameraToQuery`).
    String trigger = 'pan',
  }) {
    final s = state;
    // PROD-3833 — a settle that re-states the rectangle we already hold is not
    // a move, even when the numbers differ in the last few metres.
    //
    // The opening settle is exactly that case: `MapScreen` now seeds the
    // opening viewport arithmetically and `_startOpenSettle` later pre-emits
    // the same viewport read back off a real map. The two agree to within
    // rounding — container size vs the LayoutBuilder box, Mapbox's own
    // transform, a drawer inset measured after a row wrapped — but not to the
    // metre, and the old guard's `radiusMeters` threshold is **1 m** against a
    // ~2 km half-diagonal (0.05 %). Nothing survives that, so without a
    // tolerance the settle would refetch and the seed would be wasted again.
    //
    // Scaled to the viewport's own span rather than a fixed distance, so it
    // means the same thing at every zoom. A real pan moves the camera by a
    // large fraction of the viewport and always clears it; this only absorbs
    // settles that describe the view already on screen. (It is deliberately
    // general rather than a one-shot opening latch — spurious settles have
    // been observed beyond the opening pair, and each one costs a cancelled
    // in-flight request plus a fresh one.)
    final moved =
        !s.hasCenter ||
        // PROD-2807: the grid selection needs the viewport rect, so a first
        // settle that finally carries bounds must commit even if the centre /
        // zoom / radius drift is otherwise sub-threshold. Still reachable when
        // the opening seed could not compute a rect (no laid-out map box).
        (!s.hasBounds && neLat != null) ||
        (s.zoom - zoom).abs() > 0.01 ||
        !settleWithinViewportTolerance(
          s,
          lat: lat,
          lng: lng,
          neLat: neLat,
          neLng: neLng,
          swLat: swLat,
          swLng: swLng,
          radiusMeters: radiusMeters,
        );
    if (!moved) return;
    _lastTrigger = trigger;
    state = s.copyWith(
      centerLat: lat,
      centerLng: lng,
      radiusMeters: radiusMeters,
      zoom: zoom,
      neLat: neLat,
      neLng: neLng,
      swLat: swLat,
      swLng: swLng,
    );
  }

  /// Pick one of the three *pickable* corpus scopes. Entering list mode is
  /// [setList]'s job — it needs an id, which this signature can't carry, and a
  /// `source == list` with no id is a half-set state the wire has to defend
  /// against. Rejected here so it can't be created in the first place.
  void setSource(MapSource source) {
    if (source == MapSource.list) {
      assert(false, 'Use setList(id:, name:) to enter list mode.');
      return;
    }
    if (source == state.source) return;
    _lastTrigger = 'filter';
    // PROD-3565 — moving to any other scope LEAVES list mode, so the list id
    // must go with it. Two reasons, and either alone would be enough:
    // Decision #46 gives "De quem?" radio semantics (picking another value
    // exits the list), and a stale `list_id` riding along on `scope=yours`
    // is a **422** from the backend, not a harmless extra field.
    // `list` was rejected above, so this always leaves list mode.
    //
    // PROD-3567 — leaving a list also drops the keyword, in this SAME write so
    // the map refetches once. A keyword typed while a list is active means
    // "within this Zine" (Decision #46: the two surfaces compose); carrying it
    // over to another corpus would silently re-point the user's search at
    // something they never searched. Deliberately scoped to the list exit —
    // a plain source change (all → yours) keeps its keyword, as it always has.
    final leavingList = state.source == MapSource.list;
    state = state.copyWith(
      source: source,
      clearActiveList: true,
      keyword: leavingList ? '' : null,
    );
  }

  void setType(MapItemType type) {
    if (type == state.type) return;
    _lastTrigger = 'filter';
    state = state.copyWith(type: type);
  }

  void setDate(MapDateFilter date, {DateTimeRange? customRange}) {
    _lastTrigger = 'filter';
    state = state.copyWith(
      date: date,
      customRange: customRange,
      clearCustomRange: date != MapDateFilter.custom,
    );
  }

  /// Commit the Tema selection (the Tema config sheet returns the full set on
  /// "Ok"). Empty set clears the Tema filter.
  void setFacetFilters(Set<FacetPair> facetFilters) {
    _lastTrigger = 'filter';
    state = state.copyWith(facetFilters: facetFilters);
  }

  /// [trigger] defaults to `'keyword'` — the user typed or cleared a keyword
  /// search, which is the reason the refetch happens.
  ///
  /// Pass something else when the keyword is only being cleared as a **side
  /// effect** of another action, so the resulting `map_area_searched` is
  /// attributed to what the user actually did (PROD-3500). This matches how
  /// [applyShortcut] and [resetFilters] already behave — both wipe the keyword
  /// yet tag `'shortcut'` / `'filter'`, never `'keyword'`.
  void setKeyword(String keyword, {String trigger = 'keyword'}) {
    if (keyword == state.keyword) return;
    _lastTrigger = trigger;
    state = state.copyWith(keyword: keyword);
  }

  /// Apply a shortcut chip: set the whole **filter** state to defaults + the
  /// shortcut's overrides in one change (one refetch), leaving the camera
  /// ([MapQuery.centerLat]/zoom/bounds) untouched. Any field the shortcut
  /// doesn't set lands on its default, so a shortcut always produces a clean,
  /// predictable view (e.g. "Restaurants" = venues + that Tema, source/date at
  /// default).
  void applyShortcut({
    required MapItemType type,
    required MapSource source,
    required MapDateFilter date,
    Set<FacetPair> facetFilters = const {},
  }) {
    _lastTrigger = 'shortcut';
    state = state.copyWith(
      type: type,
      source: source,
      date: date,
      clearCustomRange: true,
      facetFilters: facetFilters,
      keyword: '',
      // A shortcut sets `source` explicitly (never to `list`), so it leaves
      // list mode — and must drop the id with it or the request 422s.
      clearActiveList: true,
    );
  }

  /// PROD-4124 — apply a `/map` deep link's preselected filters in **one
  /// write**, leaving the camera to the caller.
  ///
  /// One write is not a style preference. `MapPinsNotifier` listens to this
  /// provider with `fireImmediately: true` and fetches on **every** change, so
  /// applying five filters as five writes would be five requests.
  ///
  /// Unlike [applyShortcut], this does **not** reset the fields it wasn't
  /// given. A shortcut means "this exact view"; a deep link means "the map,
  /// with these things preselected", and the difference shows on the second
  /// arrival — a `?q=` link landing on an already-filtered map should add its
  /// keyword, not silently wipe the user's Tema.
  ///
  /// Ordering note for the opening path: call this **before** the camera is
  /// seeded. `MapPinsNotifier._fetch` bails on `!hasCenter`, so a filter write
  /// with no centre yet costs nothing, and the camera seed that follows issues
  /// the single fetch with every filter already in place.
  ///
  /// On the re-arrival path (a link landing on an open map) the query does have
  /// a centre, so this write does fetch; a camera change immediately after
  /// cancels it (`_fetch` cancels the in-flight token first), leaving one
  /// completed request rather than two.
  /// Gated on [MapDeepLinkParams.hasFilters], **not** `isNotEmpty`: a
  /// camera-only link (`/map?lat=…&lng=…`) has nothing to say about the query,
  /// and writing an equivalent-but-new [MapQuery] would still notify
  /// `MapPinsNotifier` — fetching the OLD area on an already-mounted map,
  /// moments before the camera move asks for the new one. Caught in codex
  /// review; the in-flight cancel hid it by leaving only one *completed*
  /// request.
  void applyDeepLink(MapDeepLinkParams params) {
    if (!params.hasFilters) return;
    _lastTrigger = 'deep_link';
    state = state.copyWith(
      type: params.type,
      date: params.date,
      // `?from=&to=` arrives as `date: custom` + a range; a named window must
      // drop any stale range, or `filterSignature` keeps splitting on a window
      // the query no longer uses.
      customRange: params.customRange,
      clearCustomRange:
          params.date != null && params.date != MapDateFilter.custom,
      facetFilters: params.facetFilters,
      keyword: params.keyword,
    );
  }

  /// Reset every filter to its default (source=all, type=both, date=next 30
  /// days, no
  /// Tema, no keyword), keeping the current camera. Backs the "Reset all
  /// filters" button; afterwards [MapQuery.isDefaultFilters] is true again.
  void resetFilters() {
    _lastTrigger = 'filter';
    state = state.copyWith(
      source: MapSource.all,
      type: MapItemType.all,
      date: MapDateFilter.next30Days,
      clearCustomRange: true,
      facetFilters: const {},
      keyword: '',
      // PROD-3565 / review card D2 — "Reset all filters" removes the list,
      // exactly as it clears a "Yours" selection. This reverses the intuition
      // two reviewers had (that reset should preserve the list); it was
      // overruled deliberately, because if a list is a scope like any other,
      // reset must treat it like any other.
      clearActiveList: true,
    );
  }

  /// PROD-3565 — enter list mode: ONE specific list becomes the map's corpus.
  ///
  /// [id] is the list's UUID **or** slug (the backend accepts either, so the
  /// caller never needs a resolve round-trip just to satisfy this). [name] is
  /// carried only so the "De quem?" chrome can label the scope.
  ///
  /// Per Decisions #20/#28 entering a list **resets the four filters to their
  /// defaults** — "reset" meaning *default*, not *absent*: the default date
  /// window still applies, and review card B7 has the list's events follow it.
  /// All of it lands in a single state write, so the fetch runs once.
  void setList({required String id, required String name}) {
    _lastTrigger = 'list';
    state = state.copyWith(
      source: MapSource.list,
      activeListId: id,
      activeListName: name,
      type: MapItemType.all,
      date: MapDateFilter.next30Days,
      clearCustomRange: true,
      facetFilters: const {},
      keyword: '',
    );
  }

  /// PROD-3565 — leave list mode, back to the default `all` corpus.
  ///
  /// Public because FE‑2 (PROD-3566) calls it on the **404 back-out** path: a
  /// list can stop being visible between the suggest response and the tap
  /// (unshared, deleted, moderated), and every authorization failure comes back
  /// as 404 by design.
  ///
  /// PROD-3566 — drops the keyword too, in this SAME write, exactly as
  /// [setSource] does when it leaves list mode. This is list mode's third
  /// exit and the reason applies hardest here: a keyword typed inside a list
  /// means "within this Zine", and the Zine has just ceased to exist — quietly
  /// re-running that search against all of Soko is more surprising than on the
  /// other two exits, not less. The bar's own chrome is the caller's to clear
  /// (`clearMapActiveSearch`), which by then costs no extra write.
  void clearList() {
    if (state.source != MapSource.list && state.activeListId == null) return;
    _lastTrigger = 'filter';
    state = state.copyWith(
      source: MapSource.all,
      clearActiveList: true,
      keyword: '',
    );
  }
}
