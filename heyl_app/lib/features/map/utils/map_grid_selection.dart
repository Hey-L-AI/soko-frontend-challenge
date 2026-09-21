/// PROD-2807 — custom world-grid pin selection (the FE's "what to display at
/// any given moment" role).
///
/// Turns the `/map/pins` candidate pool into the on-screen set: a
/// **world-anchored mercator grid** whose cells are ≈ one pin footprint, so at
/// most one pin per cell (spread + non-overlapping). Each single-occupancy cell
/// shows its pin; a cell holding ≥2 pins is a **dense pocket** and collapses
/// into a `+k` overflow bubble (tap → zoom → decluster). The grid level is
/// anchored to the camera zoom (footprint-sized cells) and coarsened until the
/// number of on-screen markers is within [kSelectionCap].
///
/// It consumes an optional per-pin `score` (relevance) when the backend
/// provides it, and **degrades gracefully to pure spatial** ordering when it is
/// absent or uniform (today's pool has no score) — ties always resolve by
/// nearest-to-cell-centre then id, so the selection is deterministic and stable
/// across pans (cells are anchored in world space, not screen space).
///
/// Pure Dart, platform-agnostic (web + native), and side-effect free — unit
/// tested in `test/features/map/map_grid_selection_test.dart`.
library;

import 'dart:math' as math;

import '../../../data/models/map_pin.dart';
import '../models/map_query.dart';

/// Max number of on-screen markers (individual pins + overflow bubbles).
/// Tunable — a clean map reads at ≲25 glyphs. v3 may make this density-aware.
const int kSelectionCap = 25;

/// PROD-2947 (FE-1): the higher marker cap for the **bounded** scopes
/// (`yours`/`following`). The backend's relevance selection allows up to 50
/// pins for these scopes at wide zoom (BE-3 per-scope bands: 50 ≤z13 / 25 >z13),
/// so the FE must not clamp them below that — it sends 50 as `selection_cap`
/// (an upper bound the server's per-zoom band still refines) and lets the v1
/// [selectPins] fallback keep up to 50 individual pins too. `all` stays at
/// [kSelectionCap] (25), already above the server's ~8 relevance band.
const int kSelectionCapBounded = 50;

/// The on-screen marker cap for a given map [source]: [kSelectionCapBounded]
/// (50) for the bounded scopes (`yours`/`following`), else [kSelectionCap] (25).
int selectionCapForSource(MapSource source) =>
    source == MapSource.all ? kSelectionCap : kSelectionCapBounded;

/// Target cell edge in screen pixels ≈ a pin's footprint (+ breathing room).
/// A cell this size keeps one-per-cell pins from visually touching. Tunable.
const double kTargetCellPx = 48.0;

/// Members closer than this (bounding-box diagonal, metres) are treated as the
/// **same place** — a bubble of them is "unsplittable": more zoom can't
/// separate them into individually-tappable pins, so the map hands off to the
/// cluster-focus flow (fade the rest + scope the drawer to these). Tunable.
const double kColocatedThresholdMeters = 25.0;

/// Mapbox GL uses 512 px tiles: at camera zoom `z` the whole world spans
/// `512 * 2^z` px, so a grid of `2^L` cells has cell edge `512 * 2^(z-L)` px.
const double _kTileSizePx = 512.0;

/// Web-Mercator projection is undefined at the poles — clamp latitude to the
/// standard Web-Mercator limit before projecting.
const double _kMaxMercatorLat = 85.05112878;

/// A geographic viewport rectangle + camera zoom, read from the map camera.
/// [neLng] may be < [swLng] when the viewport straddles the antimeridian.
class MapViewport {
  final double swLat;
  final double swLng;
  final double neLat;
  final double neLng;
  final double zoom;

  const MapViewport({
    required this.swLat,
    required this.swLng,
    required this.neLat,
    required this.neLng,
    required this.zoom,
  });

  /// Whether [lat]/[lng] falls inside the rectangle (antimeridian-aware on lng
  /// via the `swLng > neLng` wrap, matching `MapCameraState.contains`). Note:
  /// like the rest of the app's map surfaces, this assumes bounds are the
  /// normalised `[-180, 180]` form — a viewport literally straddling ±180°
  /// (Pacific; unreachable for this Europe-scoped app) is out of scope, as is
  /// the equivalent wrap in bubble-centroid averaging.
  bool contains(double lat, double lng) {
    if (lat < swLat || lat > neLat) return false;
    if (swLng <= neLng) return lng >= swLng && lng <= neLng;
    // Straddles the antimeridian: the box is [swLng, 180] ∪ [-180, neLng].
    return lng >= swLng || lng <= neLng;
  }
}

/// A `+k` overflow bubble: a dense/over-cap grid cell collapsed into one
/// marker. [count] is how many pool pins it stands in for; [centerLat]/
/// [centerLng] is the members' centroid — the anchor + the camera target when
/// the user taps to decluster. [hasEvents]/[hasVenues] drive the bubble colour
/// (event-only / venue-only / mixed), mirroring the old cluster colouring.
class OverflowBubble {
  /// Stable id for the render feature (`overflow_<cellKey>`), so the map source
  /// can diff/animate bubbles across selection passes.
  final String id;
  final double centerLat;
  final double centerLng;
  final int count;
  final List<String> memberIds;
  final bool hasEvents;
  final bool hasVenues;

  /// PROD-2671: the top-N (≤5) members in relevance order (most-relevant
  /// first) — the map draws a **stack of up to 5 teardrops**, one per member,
  /// front-to-back, keyed by each member's primary facet × entity.
  final List<MapPin> stackMembers;

  /// PROD-2671: ALL members in relevance order — the cluster-focus flow scopes
  /// the results drawer to exactly these.
  final List<MapPin> members;

  /// PROD-2671: venue / event counts within the cell — drive the bubble's
  /// "X venues" / "Y events" title.
  final int venueCount;
  final int eventCount;

  /// PROD-2671: true when the members are effectively **co-located** (within
  /// [kColocatedThresholdMeters]) — more zoom can't split them, so a tap opens
  /// the cluster-focus flow instead of zooming.
  final bool unsplittable;

  /// PROD-2906 (A6): true when the server saturated this cell's fetch, so
  /// [count] is a lower bound — the title renders "N+" instead of "N". Always
  /// false for the client-side `selectPins` path (the FE bins the exact pool);
  /// only the v2 server selection can set it, and it never trips at launch.
  final bool countCapped;

  const OverflowBubble({
    required this.id,
    required this.centerLat,
    required this.centerLng,
    required this.count,
    required this.memberIds,
    required this.hasEvents,
    required this.hasVenues,
    this.stackMembers = const [],
    this.members = const [],
    this.venueCount = 0,
    this.eventCount = 0,
    this.unsplittable = false,
    this.countCapped = false,
  });
}

/// The outcome of a selection pass: [shown] = the individually plotted pins
/// (this is also exactly the results grid, "map = grid", and the "Ver N
/// resultados" count, "count = shown"); [bubbles] = the `+k` overflow markers.
class MapSelection {
  final List<MapPin> shown;
  final List<OverflowBubble> bubbles;

  /// PROD-2671: ALL pins in the viewport (shown ∪ every bubble's members),
  /// relevance-ordered. The results drawer/grid lists these — clustering is a
  /// map-only visual de-clutter, so the list shows everything in view, not just
  /// the individually-plotted pins.
  final List<MapPin> visiblePins;

  /// PROD-2906: the world-grid level the coarsening loop settled on for this
  /// pass (`null` when the viewport had no pins to place). Observability only —
  /// the render/data layers don't consume it — but it's the authoritative value
  /// the server-side `selectPins` port (A6) must reproduce, so it's exported in
  /// the O7 parity fixtures (`test/features/map/fixtures/`).
  final int? level;

  /// PROD-2906 (A6): explicit "N results in view" for the v2 server selection.
  /// The server returns exact stack `count`s but only the top ≤5 members of
  /// each stack as full pins, so [visiblePins] (which the drawer hydrates)
  /// under-counts a stacked view — this carries the true total (representatives
  /// + Σ stack counts). Null for the client-side `selectPins` path, where
  /// [visiblePins] already holds every pin in view (so the count is exact).
  final int? totalInView;

  const MapSelection({
    this.shown = const [],
    this.bubbles = const [],
    this.visiblePins = const [],
    this.level,
    this.totalInView,
  });

  bool get isEmpty => shown.isEmpty && bubbles.isEmpty;

  /// The count of individually-plotted pins (map markers).
  int get shownCount => shown.length;

  /// The total results in view — what "Ver N resultados" counts (includes the
  /// results hidden inside clusters). Uses [totalInView] when the producer set
  /// it (the v2 server selection, whose stacks the FE can't fully enumerate),
  /// else the length of [visiblePins] (the exact client-side selection).
  int get visibleCount => totalInView ?? visiblePins.length;
}

/// Select the on-screen set from [pool] for the current [viewport].
///
/// [pool] is expected in the backend's relevance/nearest-first order — that
/// order is preserved as the spatial tie-break when `score` is absent/uniform.
/// [cap] bounds the number of markers; [targetCellPx] sets the footprint-sized
/// base grid level. See the library doc for the algorithm.
MapSelection selectPins({
  required List<MapPin> pool,
  required MapViewport viewport,
  int cap = kSelectionCap,
  double targetCellPx = kTargetCellPx,
}) {
  // 1. Keep only pins with coordinates that fall inside the viewport, tagging
  //    each with its pool position (the nearest-first spatial fallback order).
  final visible = <_IndexedPin>[];
  for (var i = 0; i < pool.length; i++) {
    final p = pool[i];
    final lat = p.lat;
    final lng = p.lng;
    if (lat == null || lng == null) continue;
    if (!viewport.contains(lat, lng)) continue;
    visible.add(_IndexedPin(p, i));
  }
  if (visible.isEmpty) return const MapSelection();

  // All viewport pins, relevance-ordered — the results list shows every one of
  // these (clustering only affects which are individually plotted on the map).
  final visiblePins = ([
    ...visible,
  ]..sort(_byRelevance)).map((ip) => ip.pin).toList(growable: false);

  // 2. Start at the finest (footprint-sized) level and coarsen until the number
  //    of occupied cells (= number of markers) is within the cap. Never go
  //    finer than the footprint level, so one-per-cell pins never overlap.
  final base = _baseLevel(viewport.zoom, targetCellPx);
  for (int level = base; level >= 0; level--) {
    final cells = _bin(visible, level);
    if (cells.length <= cap || level == 0) {
      return _assemble(cells, visiblePins, level);
    }
  }
  // Unreachable: level 0 is a single cell (≤ cap), so the loop always returns.
  return _assemble(_bin(visible, 0), visiblePins, 0);
}

/// PROD-2906 (A6) — build the FE render [MapSelection] from the server's v2
/// [MapServerSelection], trimmed to the live [viewport].
///
/// This is the v2 counterpart of [selectPins]: v1 re-runs [selectPins] on every
/// pan, but v2 CAN'T (the server owns the selection). Instead the FE
/// **re-slices** the buffered server result — the server returns the settled
/// viewport + a 1-cell ring, and this filters `representatives` / `stacks` down
/// to whatever the live [viewport] currently shows (via [MapViewport.contains]).
/// The pool itself refetches only on settle.
///
/// The drawer list ([MapSelection.visiblePins]) is `representatives` ∪ every
/// stack's full `member_ids` (each `{id, entity}` since 1.26.0 / sync doc `12`,
/// so all are hydratable — `mapGridProvider` buckets by entity and windows the
/// hydrate). Against a pre-1.26.0 server (bare-string `member_ids`) a stack's
/// `members` is empty and it falls back to the top ≤5 `stack_members`; there the
/// exact "N in view" still rides in [MapSelection.totalInView] (`representatives`
/// + Σ stack `count`), which `visiblePins` would otherwise under-count. Once the
/// full members are present, `totalInView == visiblePins.length` (count matches
/// the list). Teardrops always come from `stack_members` (they carry the facet).
MapSelection selectionFromServer(
  MapServerSelection selection,
  MapViewport viewport,
) {
  // Representatives → shown pins, trimmed to the live viewport rect.
  final shown = <MapPin>[];
  for (final p in selection.representatives) {
    final lat = p.lat;
    final lng = p.lng;
    if (lat == null || lng == null) continue;
    if (!viewport.contains(lat, lng)) continue;
    shown.add(p);
  }

  // Stacks → overflow bubbles, trimmed by stack centre.
  final bubbles = <OverflowBubble>[];
  final visible = <MapPin>[...shown];
  var stackTotal = 0;
  for (final s in selection.stacks) {
    if (!viewport.contains(s.centerLat, s.centerLng)) continue;
    // Teardrops: the top ≤5 stack_members (entity + facet → pin art).
    final teardrops = s.stackMembers
        .map((m) => m.toPin())
        .toList(growable: false);
    // Full drawer/cluster-focus member set: every `member_ids` entry ({id,
    // entity} → bucketable for /map/hydrate). Falls back to the teardrops
    // against a pre-1.26.0 server that still sends bare id strings (then
    // `s.members` is empty — see MapServerStack), preserving the top-5 interim.
    final fullMembers = s.members.isNotEmpty
        ? s.members.map((m) => m.toPin()).toList(growable: false)
        : teardrops;
    bubbles.add(
      OverflowBubble(
        id: s.id,
        centerLat: s.centerLat,
        centerLng: s.centerLng,
        count: s.count,
        countCapped: s.countCapped,
        memberIds: fullMembers.map((p) => p.id).toList(growable: false),
        hasEvents: s.hasEvents,
        hasVenues: s.hasVenues,
        stackMembers: teardrops,
        // The cluster-focus drawer scopes to the FULL member set (each carries
        // entity, so /map/hydrate can bucket them); grid hydration is windowed.
        members: fullMembers,
        venueCount: s.venueCount,
        eventCount: s.eventCount,
        unsplittable: s.unsplittable,
      ),
    );
    stackTotal += s.count;
    visible.addAll(fullMembers);
  }

  return MapSelection(
    shown: shown,
    bubbles: bubbles,
    visiblePins: visible,
    level: selection.level,
    // Exact "N in view" (representatives + every stack's full count), which the
    // hydratable visiblePins under-counts once stacks are present.
    totalInView: shown.length + stackTotal,
  );
}

/// The finest grid level whose cells are ≈ [targetCellPx] wide at [zoom].
/// `cellPx = 512 * 2^(zoom - L)` ⇒ `L = zoom + log2(512 / targetCellPx)`.
int _baseLevel(double zoom, double targetCellPx) {
  final l = zoom + _log2(_kTileSizePx / targetCellPx);
  return l.round().clamp(1, 24);
}

/// PROD-2971 — public accessor for the FE's base grid level at a given [zoom],
/// so the admin debug panel can diff it against the server-reported `grid_level`
/// and surface client/server grid drift.
int feBaseGridLevel(double zoom, {double targetCellPx = kTargetCellPx}) =>
    _baseLevel(zoom, targetCellPx);

/// Bin [pins] into world-grid cells at [level]. Cells are anchored to the world
/// origin (a pin keeps its cell as the camera pans), keyed `"cx:cy"`.
Map<String, List<_IndexedPin>> _bin(List<_IndexedPin> pins, int level) {
  final n = 1 << level; // 2^level cells across the world per axis
  final cells = <String, List<_IndexedPin>>{};
  for (final ip in pins) {
    final mx = _mercX(ip.pin.lng!);
    final my = _mercY(ip.pin.lat!);
    final cx = (mx * n).floor().clamp(0, n - 1);
    final cy = (my * n).floor().clamp(0, n - 1);
    (cells['$cx:$cy'] ??= <_IndexedPin>[]).add(ip);
  }
  return cells;
}

/// Turn binned cells into individual pins (1 member) + overflow bubbles (≥2).
///
/// A cell is entirely a pin or entirely a bubble — no pool pin is ever silently
/// dropped, so `shown ∪ bubble members == visible` (map = grid = count holds).
MapSelection _assemble(
  Map<String, List<_IndexedPin>> cells,
  List<MapPin> visiblePins,
  int level,
) {
  final shown = <_IndexedPin>[];
  final bubbles = <OverflowBubble>[];
  // Iterate in sorted cell-key order so bubble emission is deterministic
  // regardless of map iteration order (stable diffing on the render side).
  final keys = cells.keys.toList()..sort();
  for (final key in keys) {
    final members = cells[key]!;
    if (members.length == 1) {
      shown.add(members.first);
    } else {
      bubbles.add(_bubbleFor(key, members));
    }
  }
  // Relevance order for the results grid: score desc, then nearest-first
  // (pool order) as the spatial fallback when score is absent/uniform.
  shown.sort(_byRelevance);
  return MapSelection(
    shown: shown.map((ip) => ip.pin).toList(growable: false),
    bubbles: bubbles,
    visiblePins: visiblePins,
    level: level,
  );
}

/// score desc (nulls last) → pool index asc (nearest-first) → id asc.
int _byRelevance(_IndexedPin a, _IndexedPin b) {
  final sa = a.pin.score;
  final sb = b.pin.score;
  if (sa != sb) {
    if (sa == null) return 1;
    if (sb == null) return -1;
    final c = sb.compareTo(sa); // higher score first
    if (c != 0) return c;
  }
  if (a.order != b.order) return a.order.compareTo(b.order);
  return a.pin.id.compareTo(b.pin.id);
}

/// Build a `+k` bubble anchored at the members' centroid.
OverflowBubble _bubbleFor(String cellKey, List<_IndexedPin> members) {
  var sumLat = 0.0;
  var sumLng = 0.0;
  var hasEvents = false;
  var hasVenues = false;
  var venueCount = 0;
  var eventCount = 0;
  var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
  final ids = <String>[];
  for (final ip in members) {
    final lat = ip.pin.lat!;
    final lng = ip.pin.lng!;
    sumLat += lat;
    sumLng += lng;
    if (lat < minLat) minLat = lat;
    if (lat > maxLat) maxLat = lat;
    if (lng < minLng) minLng = lng;
    if (lng > maxLng) maxLng = lng;
    if (ip.pin.isEvent) {
      hasEvents = true;
      eventCount++;
    } else {
      hasVenues = true;
      venueCount++;
    }
    ids.add(ip.pin.id);
  }
  final n = members.length;
  final centerLat = sumLat / n;
  final centerLng = sumLng / n;
  // Relevance order (front of the stack / top of the drawer list first).
  final ordered = ([
    ...members,
  ]..sort(_byRelevance)).map((ip) => ip.pin).toList(growable: false);
  // Co-located? Bounding-box diagonal in metres (equirectangular is plenty at
  // this scale). Below the threshold → more zoom can't separate them.
  final latM = (maxLat - minLat) * 111320.0;
  final lngM =
      (maxLng - minLng) * 111320.0 * math.cos(centerLat * math.pi / 180.0);
  final unsplittable =
      math.sqrt(latM * latM + lngM * lngM) < kColocatedThresholdMeters;
  return OverflowBubble(
    id: 'overflow_$cellKey',
    centerLat: centerLat,
    centerLng: centerLng,
    count: n,
    memberIds: ids,
    hasEvents: hasEvents,
    hasVenues: hasVenues,
    stackMembers: ordered.take(5).toList(growable: false),
    members: ordered,
    venueCount: venueCount,
    eventCount: eventCount,
    unsplittable: unsplittable,
  );
}

/// A pool pin tagged with its original pool index (nearest-first order), used
/// as the spatial tie-break when `score` is absent or uniform.
class _IndexedPin {
  final MapPin pin;
  final int order;
  const _IndexedPin(this.pin, this.order);
}

double _log2(double x) => math.log(x) / math.ln2;

/// Normalised Web-Mercator X in [0, 1).
double _mercX(double lng) => (lng + 180.0) / 360.0;

/// Normalised Web-Mercator Y in [0, 1) (0 = north edge, 1 = south edge).
double _mercY(double lat) {
  final clamped = lat.clamp(-_kMaxMercatorLat, _kMaxMercatorLat);
  final s = math.sin(clamped * math.pi / 180.0);
  return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
}
