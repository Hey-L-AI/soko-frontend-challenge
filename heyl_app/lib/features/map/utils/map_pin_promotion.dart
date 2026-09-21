/// PROD-3656 — **auto-promotion**: spend the on-screen marker slots a zoom-in
/// frees, from the pool that is already in memory.
///
/// On the v2 path (server-side selection, live at 100%) a camera move re-slices
/// by *trimming* the server's chosen set to the new viewport
/// (`selectionFromServer`) — it cannot add. So zooming in drops representatives
/// out of view and leaves the view sparser than it needs to be: the remaining
/// pool results stay dots (`map_dot_hints.dart`) until a new `/map/pins`
/// response lands. This engine picks which of those pool results are promoted
/// into pins in the meantime — no network, no refetch.
///
/// PROD-3690 governs *when* and *how many*: a pass runs only once the camera has
/// **settled** (never mid-gesture) and only when a whole zoom level was crossed,
/// and it tops the view up to at most [kMaxAutoPromotedTotal] pins. The
/// settle-gating is also what makes promoted pins animate in — both renderers
/// skip arming the per-pin reveal while `_cameraMoving`.
///
/// The v1 fallback ([selectPins]) needs none of this: it selects from the pool
/// rather than trimming a server set, so it already spends every slot.
///
/// ⚠️ Deliberately does NOT touch `map_grid_selection.dart`: that file is the
/// byte-frozen cross-repo oracle (drift-guard + O7 golden fixtures parity-match
/// the backend's Python port). The few mercator/binning lines it shares are
/// duplicated here on purpose — same rule as `map_dot_hints.dart`.
///
/// Pure Dart, platform-agnostic, side-effect free — unit tested in
/// `test/features/map/utils/map_pin_promotion_test.dart`.
library;

import 'dart:math' as math;

import '../../../data/models/map_pin.dart';
import 'map_grid_selection.dart'
    show
        MapSelection,
        MapViewport,
        feBaseGridLevel,
        selectPins,
        selectionCapForSource;

// ── Tunables (plain constants by decision — no env vars, no flags) ──────────

/// PROD-3690 — the ceiling on **total displayed pins** while auto-promoting.
///
/// A pass promotes only while fewer than this many pins are on screen, and
/// stops the moment the total reaches it. Gate and ceiling are therefore the
/// same rule.
///
/// ⚠️ Deliberately NOT derived from [selectionCapForSource]. That cap (25 for
/// `all`, 50 for the bounded scopes) has no relationship to what the map
/// actually draws on the v2 path: the applied cap comes from the backend's
/// `MAP_PINS_SELECTION_BANDS` config — for `scope=all`, **8** below z16 and 20
/// above. Measured against staging 2026-08-05, `/map/pins` returned **8**
/// representatives regardless of viewport size, the `selection_cap` sent (25 or
/// 50), `target_cell_px`, city or zoom. Budgeting promotions against 25 is what
/// made PROD-3656 churn — a zoom-in was licensed to take the map from 8 pins to
/// 25, and at z15→z16 (where only 1 of the 8 survives the viewport trim) it
/// could promote 24.
///
/// (The `selection_cap` request field was read on **no** backend code path and
/// PROD-3731 stopped sending it; PROD-3701 is the backend half. That does not
/// change this constant — the point was always to stop deriving the ceiling
/// from a number the server doesn't use.)
///
/// 4 is half of that measured 8, so a promotion tops the view up without
/// crowding out the higher-scoring pins the landing response brings. Measured
/// effect: silent at z12–z14 (enough pins survive the trim), +1/+3/+1 at
/// z14→15 / z15→16 / z16→17.
///
/// The server's 8 is config, not a contract — it is JSON-env-overridable and
/// retunes with no redeploy — hence a named constant here rather than anything
/// computed from it.
const int kMaxAutoPromotedTotal = 4;

/// How far **below** the zoom a promotion was made at a settled view must be
/// before that promotion is released.
///
/// This is the "materially different viewport" line of the PROD-3656 rule:
/// a promotion is sticky for the viewport it was made in (the response for that
/// same view merges additively and never demotes it), but a zoom-out releases
/// it and the fresh server selection governs. Half a zoom level is comfortably
/// past pinch rubber-banding while still catching any deliberate zoom-out.
const double kPromotionReleaseZoomDelta = 0.5;

// ── Pool ordering ────────────────────────────────────────────────────────────

/// Interleave venues + events (both nearest-first) so the spatial-fallback
/// order of a pool pass mixes nearby places and events. Score, when present,
/// re-sorts this inside [selectPins] / [selectPromotedPins].
///
/// Shared by the selection providers and by [selectPromotedPins] so a promoted
/// pin's tie-break order is the same one `selectPins` would have used.
List<MapPin> interleaveMapPool(MapPinsResponse resp) {
  final v = resp.venues;
  final e = resp.events;
  final out = <MapPin>[];
  final n = math.max(v.length, e.length);
  for (var i = 0; i < n; i++) {
    if (i < v.length) out.add(v[i]);
    if (i < e.length) out.add(e[i]);
  }
  return out;
}

// ── Selection ────────────────────────────────────────────────────────────────

/// A marker already on screen — its anchor point is what makes its grid cell
/// occupied, so a promotion never lands on top of it.
typedef PromotionAnchor = ({double lat, double lng});

/// Pick up to [limit] pool results to promote into plotted pins for [viewport].
///
/// [pool] is the interleaved response pool ([interleaveMapPool]);
/// [excludedIds] are the ids already represented on the map (the raw server
/// selection's representatives + every stack member, any live promotions, and
/// the dot-tap promotion) — see `dotHintExclusionIds`, which produces exactly
/// the first part of that set; [occupied] are the anchor points of the markers
/// already drawn.
///
/// Spread rule: candidates are binned into the same world-anchored mercator
/// lattice the pin selection uses, at the **live** zoom's footprint level
/// ([feBaseGridLevel]) — cells that already hold a marker are skipped entirely
/// and each remaining cell contributes at most one promotion. That is what
/// keeps a promoted pin from landing under an existing teardrop or under
/// another promotion; without it, promoting by relevance alone would cluster
/// promotions exactly where the map is densest.
///
/// Deterministic: best-per-cell by score desc → pool index asc → id asc, then
/// the same total order across cells (ids are unique, so no ties survive).
List<MapPin> selectPromotedPins({
  required List<MapPin> pool,
  required Set<String> excludedIds,
  required Iterable<PromotionAnchor> occupied,
  required MapViewport viewport,
  required int limit,
}) {
  if (limit <= 0 || pool.isEmpty) return const [];

  final level = feBaseGridLevel(viewport.zoom);
  final n = 1 << level;
  String cellKey(double lat, double lng) {
    final cx = (_mercX(lng) * n).floor().clamp(0, n - 1);
    final cy = (_mercY(lat) * n).floor().clamp(0, n - 1);
    return '$cx:$cy';
  }

  final occupiedCells = <String>{
    for (final a in occupied) cellKey(a.lat, a.lng),
  };

  // Best candidate per free cell.
  final best = <String, _Candidate>{};
  for (var i = 0; i < pool.length; i++) {
    final p = pool[i];
    final lat = p.lat;
    final lng = p.lng;
    if (lat == null || lng == null) continue;
    if (!viewport.contains(lat, lng)) continue;
    if (excludedIds.contains(p.id)) continue;
    final key = cellKey(lat, lng);
    if (occupiedCells.contains(key)) continue;
    final candidate = _Candidate(p, i);
    final current = best[key];
    if (current == null || _byRelevance(candidate, current) < 0) {
      best[key] = candidate;
    }
  }
  if (best.isEmpty) return const [];

  final ranked = best.values.toList()..sort(_byRelevance);
  return ranked.take(limit).map((c) => c.pin).toList(growable: false);
}

/// The anchor points of everything [sel] already draws — representative pins
/// and `+k` bubble centres. Feeds [selectPromotedPins]'s `occupied`.
List<PromotionAnchor> promotionAnchorsOf(MapSelection sel) => [
  for (final p in sel.shown)
    if (p.lat != null && p.lng != null) (lat: p.lat!, lng: p.lng!),
  for (final b in sel.bubbles) (lat: b.centerLat, lng: b.centerLng),
];

/// The anchor points of [pins] that have coordinates.
List<PromotionAnchor> promotionAnchorsOfPins(Iterable<MapPin> pins) => [
  for (final p in pins)
    if (p.lat != null && p.lng != null) (lat: p.lat!, lng: p.lng!),
];

/// The subset of [pins] whose coordinates fall inside [viewport].
List<MapPin> pinsInViewport(Iterable<MapPin> pins, MapViewport viewport) => [
  for (final p in pins)
    if (p.lat != null && p.lng != null && viewport.contains(p.lat!, p.lng!)) p,
];

/// Inject [promoted] into [sel]'s shown pins — the list counterpart of
/// PROD-3124's `withPromotedPin`.
///
/// Skips anything without coordinates, outside [viewport], or already shown.
/// Joins [MapSelection.visiblePins] (the drawer list) and bumps
/// [MapSelection.totalInView] only for pins that weren't already counted — a
/// promotion made before a settle may well be a stack member of the response
/// that lands after it, and must not be double-counted then.
MapSelection withAutoPromotions(
  MapSelection sel,
  List<MapPin> promoted,
  MapViewport viewport,
) {
  if (promoted.isEmpty) return sel;
  final shownIds = <String>{for (final p in sel.shown) p.id};
  final listedIds = <String>{for (final p in sel.visiblePins) p.id};
  final addShown = <MapPin>[];
  final addListed = <MapPin>[];
  for (final p in promoted) {
    final lat = p.lat;
    final lng = p.lng;
    if (lat == null || lng == null) continue;
    if (!viewport.contains(lat, lng)) continue;
    if (!shownIds.add(p.id)) continue;
    addShown.add(p);
    if (listedIds.add(p.id)) addListed.add(p);
  }
  if (addShown.isEmpty) return sel;
  return MapSelection(
    shown: [...sel.shown, ...addShown],
    bubbles: sel.bubbles,
    visiblePins: [...sel.visiblePins, ...addListed],
    level: sel.level,
    totalInView: sel.totalInView == null
        ? null
        : sel.totalInView! + addListed.length,
  );
}

/// score desc (nulls last) → pool index asc (nearest-first) → id asc. Mirrors
/// the frozen oracle's `_byRelevance`, over this file's own candidate type.
int _byRelevance(_Candidate a, _Candidate b) {
  final sa = a.pin.score;
  final sb = b.pin.score;
  if (sa != sb) {
    if (sa == null) return 1;
    if (sb == null) return -1;
    final c = sb.compareTo(sa);
    if (c != 0) return c;
  }
  if (a.order != b.order) return a.order.compareTo(b.order);
  return a.pin.id.compareTo(b.pin.id);
}

/// A pool pin tagged with its pool position (the nearest-first fallback order).
class _Candidate {
  final MapPin pin;
  final int order;
  const _Candidate(this.pin, this.order);
}

// Web-Mercator helpers — duplicated from the frozen selection oracle (see
// library doc). Normalised to [0, 1).
const double _kMaxMercatorLat = 85.05112878;

double _mercX(double lng) => (lng + 180.0) / 360.0;

double _mercY(double lat) {
  final clamped = lat.clamp(-_kMaxMercatorLat, _kMaxMercatorLat);
  final s = math.sin(clamped * math.pi / 180.0);
  return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
}
