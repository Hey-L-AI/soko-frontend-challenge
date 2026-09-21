/// PROD-3124 — Map **dot hints** v0 (frontend-only).
///
/// The backend pins only the ~8 most relevant `/map/pins` results per
/// viewport, so a zoomed-out map gives no signal that the area is full of
/// results. Dot hints are small category-coloured circles rendered *beneath*
/// the pins for retrieved-but-not-pinned pool results — "there's more here,
/// zoom in". They are purely visual: not tappable, no ids in the render data.
///
/// v0 selects dots client-side from the response's `venues`/`events` pool
/// arrays minus everything already rendered (pins + stack members). The final
/// version (post beta feedback) will likely move selection server-side —
/// keep this engine self-contained so it can be deleted wholesale.
///
/// ⚠️ Deliberately does NOT touch `map_grid_selection.dart`: that file is the
/// byte-frozen cross-repo oracle (drift-guard + O7 golden fixtures parity-match
/// the backend's Python port). The few mercator/binning lines it shares are
/// duplicated here on purpose.
///
/// Pure Dart, platform-agnostic, side-effect free — unit tested in
/// `test/features/map/map_dot_hints_test.dart`.
library;

import 'dart:math' as math;

import '../../../data/models/map_pin.dart';
import '../../../shared/utils/map_dot_hints_render.dart';
import '../models/map_query.dart';
import 'map_grid_selection.dart'
    show MapSelection, MapViewport, feBaseGridLevel;

// The render half (MapDotHint, visual tokens, GeoJSON/radius builders) lives
// in shared/ so the map widgets can consume it without importing features/.
export '../../../shared/utils/map_dot_hints_render.dart';

// ── Tunables (plain constants by decision — no env vars, no flags) ──────────

/// Max dots on the wide band (zoom ≤ band edge). "Up to" semantics — the v0
/// ceiling is bounded by the response pool (~150 combined) anyway.
const int kDotCapWide = 200;

/// Max dots on the near band (zoom > band edge). (100 → 200, Zé 2026-07-15
/// tuning — one flat 200 max for now; the band structure stays for future
/// re-tuning.)
const int kDotCapNear = 200;

/// Band edges MIRROR the backend's pin bands (`MAP_PINS_SELECTION_BANDS` in
/// heyl-backend `config.py`): scope `all` switches at zoom 16, the bounded
/// scopes (`yours`/`following`) at 13. One tuning surface — if the backend
/// retunes its bands, retune these to match.
const double kDotBandEdgeZoomAll = 16.0;
const double kDotBandEdgeZoomBounded = 13.0;

/// Events' share of the dot allowance when BOTH entities are in scope. The
/// shares are independent — a leg that can't fill its share is NOT backfilled
/// by the other (the map simply shows fewer dots). Entity-filtered searches
/// give the requested entity 100%. (0.8 → 0.85, Zé 2026-07-15 tuning.)
const double kDotEventShare = 0.85;

// ── Colours ──────────────────────────────────────────────────────────────────

/// Fallback fill for a null/unmapped facet — the body colour of the single
/// generic `pin-default.png` (pink), same fallback rule as `mapPinKey`.
const String kDotHintFallbackColor = '#FFB9CC';

/// Primary-facet parent slug → dot fill. Keys are lock-step with
/// `kFacetPinKey` (shared/utils/map_pin_assets.dart); values are the pin PNGs' body
/// colours (sampled from the shipped assets, 2026-07-15) so a dot and its pin
/// always match. Art + music genuinely share the same yellow in the asset set.
const Map<String, String> kFacetDotColor = {
  // The six live parent facets. The other four entries are inert for two
  // different reasons (three are LENSES, never emitted as a result tag;
  // `sports` is a CHILD slug) — the full explanation lives on `kFacetPinKey`
  // in shared/utils/map_pin_assets.dart. Read it before changing either map:
  // they are lock-step by design.
  'eat_drink': '#F68686',
  'art': '#EDE77D',
  'music': '#EDE77D',
  'nightlife': '#E08EFB',
  'outdoors': '#B0F08B',
  'shopping': '#A597FF',
  // Inert — lenses.
  'family': '#E08EFB',
  'date_worthy': '#F68686',
  'free': '#B0EF8B',
  // Inert — a child slug; sports venues take the `outdoors` colour.
  'sports': '#8BDFFF',
};

/// The dot fill for [primaryFacet] — parent-slug lookup, falling back to the
/// generic pink when the facet is null or unmapped (mirrors `mapPinKey`).
String dotColorFor(FacetPair? primaryFacet) =>
    (primaryFacet == null ? null : kFacetDotColor[primaryFacet.parent]) ??
    kDotHintFallbackColor;

// ── Selection ────────────────────────────────────────────────────────────────

/// The dot allowance for [source] at [zoom] — wide cap on/below the scope's
/// band edge, near cap above it (edges mirror the backend pin bands).
int dotCapFor(MapSource source, double zoom) {
  final edge = source == MapSource.all
      ? kDotBandEdgeZoomAll
      : kDotBandEdgeZoomBounded;
  return zoom <= edge ? kDotCapWide : kDotCapNear;
}

/// The ids the dots must never double-represent: everything the map already
/// renders as a pin or counts inside a `+k` stack.
///
/// v2 (the live path): the RAW server selection — all representatives + every
/// stack's full member set. Viewport-independent, so the exclusion stays exact
/// while the live re-slice pans across the buffered ring.
/// v1 fallback (server `selection` absent / FE flag off): the settled
/// client-side selection's shown pins + bubble members.
Set<String> dotHintExclusionIds({
  MapServerSelection? serverSelection,
  MapSelection? settledSelection,
}) {
  if (serverSelection != null) {
    return {
      for (final p in serverSelection.representatives) p.id,
      for (final s in serverSelection.stacks) ...[
        for (final m in s.members) m.id,
        // Pre-1.26.0 servers send bare-string member_ids → `members` is empty;
        // the top-≤5 stack_members are then the only enumerable stack content.
        for (final m in s.stackMembers) m.id,
      ],
    };
  }
  final settled = settledSelection;
  if (settled == null) return const {};
  return {
    for (final p in settled.shown) p.id,
    for (final b in settled.bubbles) ...b.memberIds,
  };
}

/// Select the dot hints for the current viewport.
///
/// [venues]/[events] are the response pool arrays; [excludedIds] is
/// [dotHintExclusionIds]; [entity] is the request's entity filter
/// (`'venue'` | `'event'` | null = both, i.e. `MapQuery.entityWire`).
///
/// Behaviour (per the PROD-3124 spec):
/// 1. Only pool items with coordinates inside [viewport], minus [excludedIds].
/// 2. Per-entity allowances: [eventShare]/(1−share) of the cap when both
///    entities are in scope (independent, NO backfill); 100% when
///    entity-filtered.
/// 3. Spread + density: per entity, bin candidates into world-anchored
///    mercator grid cells at the selection base level, then round-robin over
///    the (sorted) occupied cells taking each cell's best-scored remaining
///    candidate per round — the first round covers every occupied cell, later
///    rounds award denser cells proportionally.
/// Deterministic: sorted cell keys + score-desc/id-asc within a cell.
///
/// [capOverride] and [eventShare] exist for the map debug panel's live-tuning
/// sliders (PROD-3124): they replace the band cap / [kDotEventShare] default
/// when the admin drags a knob. Production callers pass neither.
List<MapDotHint> selectDotHints({
  required List<MapPin> venues,
  required List<MapPin> events,
  required Set<String> excludedIds,
  required MapViewport viewport,
  required MapSource source,
  String? entity,
  int? capOverride,
  double eventShare = kDotEventShare,
}) {
  final cap = capOverride ?? dotCapFor(source, viewport.zoom);
  final int eventAllowance;
  final int venueAllowance;
  if (entity == 'event') {
    eventAllowance = cap;
    venueAllowance = 0;
  } else if (entity == 'venue') {
    eventAllowance = 0;
    venueAllowance = cap;
  } else {
    eventAllowance = (cap * eventShare).floor();
    venueAllowance = cap - eventAllowance;
  }

  final level = feBaseGridLevel(viewport.zoom);
  return [
    ..._allocate(events, excludedIds, viewport, level, eventAllowance),
    ..._allocate(venues, excludedIds, viewport, level, venueAllowance),
  ];
}

/// PROD-3124 dot tap — inject [promoted] into [sel]'s shown pins so a
/// dot-tapped item renders as a full captioned pin even when the relevance
/// selection didn't pick it for this viewport.
///
/// No-ops when: nothing is promoted, the promoted item has no coordinates or
/// is outside [viewport], or the selection already shows it (the settle after
/// the fly-to usually re-selects it naturally — dedupe by id). Joins
/// [MapSelection.visiblePins] (the drawer list) and bumps
/// [MapSelection.totalInView] only when it wasn't already counted (it may sit
/// inside a stack's members).
MapSelection withPromotedPin(
  MapSelection sel,
  MapPin? promoted,
  MapViewport viewport,
) {
  if (promoted == null) return sel;
  final lat = promoted.lat;
  final lng = promoted.lng;
  if (lat == null || lng == null) return sel;
  if (!viewport.contains(lat, lng)) return sel;
  if (sel.shown.any((p) => p.id == promoted.id)) return sel;
  final alreadyListed = sel.visiblePins.any((p) => p.id == promoted.id);
  return MapSelection(
    shown: [...sel.shown, promoted],
    bubbles: sel.bubbles,
    visiblePins: alreadyListed
        ? sel.visiblePins
        : [...sel.visiblePins, promoted],
    level: sel.level,
    totalInView: sel.totalInView == null
        ? null
        : (alreadyListed ? sel.totalInView : sel.totalInView! + 1),
  );
}

/// One entity leg: filter → bin → round-robin up to [allowance].
List<MapDotHint> _allocate(
  List<MapPin> candidates,
  Set<String> excludedIds,
  MapViewport viewport,
  int level,
  int allowance,
) {
  if (allowance <= 0 || candidates.isEmpty) return const [];

  final eligible = <MapPin>[];
  for (final p in candidates) {
    final lat = p.lat;
    final lng = p.lng;
    if (lat == null || lng == null) continue;
    if (!viewport.contains(lat, lng)) continue;
    if (excludedIds.contains(p.id)) continue;
    eligible.add(p);
  }
  if (eligible.isEmpty) return const [];

  // Bin into world-anchored mercator cells (same lattice family as the pin
  // selection, duplicated locally — see the library doc's oracle note).
  final n = 1 << level;
  final cells = <String, List<MapPin>>{};
  for (final p in eligible) {
    final cx = (_mercX(p.lng!) * n).floor().clamp(0, n - 1);
    final cy = (_mercY(p.lat!) * n).floor().clamp(0, n - 1);
    (cells['$cx:$cy'] ??= <MapPin>[]).add(p);
  }
  for (final members in cells.values) {
    members.sort(_byScoreThenId);
  }

  final keys = cells.keys.toList()..sort();
  final out = <MapDotHint>[];
  var taken = 0;
  var round = 0;
  var progressed = true;
  while (taken < allowance && progressed) {
    progressed = false;
    for (final key in keys) {
      final members = cells[key]!;
      if (round >= members.length) continue;
      final p = members[round];
      out.add(
        MapDotHint(
          id: p.id,
          entity: p.entity,
          lat: p.lat!,
          lng: p.lng!,
          colorHex: dotColorFor(p.primaryFacet),
        ),
      );
      taken++;
      progressed = true;
      if (taken >= allowance) break;
    }
    round++;
  }
  return out;
}

/// score desc (nulls last) → id asc. (No pool-order tiebreak here — dots don't
/// need the pin selection's nearest-first fallback; id keeps it deterministic.)
int _byScoreThenId(MapPin a, MapPin b) {
  final sa = a.score;
  final sb = b.score;
  if (sa != sb) {
    if (sa == null) return 1;
    if (sb == null) return -1;
    final c = sb.compareTo(sa);
    if (c != 0) return c;
  }
  return a.id.compareTo(b.id);
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
