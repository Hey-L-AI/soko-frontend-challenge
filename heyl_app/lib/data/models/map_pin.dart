/// PROD-2736 — slim, count-first models for `POST /map/pins`.
///
/// Pins are intentionally slim: each carries only id / entity / lat / lng +
/// facet tags. The card content (name, image, …) comes from
/// `POST /map/hydrate` for the visible window of ids (count-first + lazy
/// grid, Decision #29).
library;

import 'map_debug.dart';
import 'recurrence_phase.dart';

/// A `{parent, child}` facet handle. Used both on results (`primary_facet` /
/// `secondary_facets`) and in the request (`facet_filters`) — the on-wire
/// shape is identical. `child` is the **slug** (e.g. `bars`), or null for a
/// whole-parent selection / a result that maps to a parent but no curated
/// child chip.
class FacetPair {
  final String parent;
  final String? child;

  const FacetPair({required this.parent, this.child});

  static FacetPair? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final parent = json['parent'] as String?;
    if (parent == null) return null;
    return FacetPair(parent: parent, child: json['child'] as String?);
  }

  /// PROD-3829 — read a `primary_facet` off a raw payload without ever
  /// throwing, whatever arrives in that slot.
  ///
  /// [fromJson] already handles null and a parentless object, but every call
  /// site had to cast first (`json['primary_facet'] as Map<String, dynamic>?`)
  /// and **that cast throws** if the backend ever sends a scalar, a list, or a
  /// `Map` with non-string keys. This is a field no payload sends yet, being
  /// parsed ahead of the server that will send it — precisely the situation
  /// where a shape surprise is plausible, and where the blast radius is wide
  /// (list maps, the lists hub, and both detail pages parse it). A malformed
  /// facet should cost the pin its art, not take down the page.
  ///
  /// Anything unparseable resolves to null → the generic pink `pin-default`.
  static FacetPair? readFrom(
    Map<String, dynamic> json, [
    String key = 'primary_facet',
  ]) {
    final raw = json[key];
    if (raw is! Map) return null;
    final parent = raw['parent'];
    if (parent is! String) return null;
    final child = raw['child'];
    return FacetPair(parent: parent, child: child is String ? child : null);
  }

  Map<String, dynamic> toJson() => {
    'parent': parent,
    if (child != null) 'child': child,
  };

  @override
  bool operator ==(Object other) =>
      other is FacetPair && other.parent == parent && other.child == child;

  @override
  int get hashCode => Object.hash(parent, child);
}

/// One slim map pin.
///
/// ⚠️ For an **event**, [id] is the matched **occurrence id** (not the event
/// id) — round-trip it into `/map/hydrate` `event_occurrence_ids`. For a
/// detail-page tap, resolve the real `event_id` from the hydrated card.
class MapPin {
  final String id;

  /// `'venue'` | `'event'`.
  final String entity;
  final double? lat;
  final double? lng;

  /// PROD-2868 — display name for the pin: venue name / event title. Nullable
  /// by contract ("a missing name must never drop a pin"); the caption falls
  /// back to a localized placeholder when it's null/blank.
  final String? name;

  /// Filter-aware primary facet (drives pin colour later). Null → default pin.
  final FacetPair? primaryFacet;
  final List<FacetPair> secondaryFacets;

  /// Per-pin relevance score, normalized `[0,1]` (higher = more relevant).
  /// **Live** behind the backend flag `MAP_PINS_RELEVANCE_SCORING` (PROD-2942 /
  /// BE-2); when the flag is off the server returns a constant `1.0`, and older
  /// v1 responses may omit it (null). Two consumers:
  ///  • the grid selection orders the shown set by it (degrades to pure spatial
  ///    when null/uniform — [map_grid_selection.dart]);
  ///  • PROD-2947 (FE-1) sizes pins by it — the live values are tightly
  ///    clustered, so each pin's score is ranked against the fetched pool
  ///    (`ScoreNormalizer`, per entity) and the rank drives `icon-size`
  ///    (0.85×–1.15×); a flat/null pool → baseline.
  final double? score;

  /// PROD-3378 (BE-6) / PROD-3379 — confident recurrence phase for the chips
  /// ("Primeiros dias" / "Últimos dias"). **Event pins only** (venue pins are always
  /// null). Populated only when the server flag `MAP_PINS_RELEVANCE_SCORING`
  /// is on (same gate as [score]); null everywhere else (mid-run, neutral,
  /// non-recurring, unknown/late-ingested, or flag off). Parsed
  /// forward-compatibly — an unrecognised value degrades to null. See
  /// [recurrencePhaseFromWire].
  final RecurrencePhase? recurrencePhase;

  const MapPin({
    required this.id,
    required this.entity,
    this.lat,
    this.lng,
    this.name,
    this.primaryFacet,
    this.secondaryFacets = const [],
    this.score,
    this.recurrencePhase,
  });

  bool get isEvent => entity == 'event';

  static MapPin? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final entity = json['entity'] as String?;
    if (id == null || entity == null) return null;
    return MapPin(
      id: id,
      entity: entity,
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
      name: json['name'] as String?,
      score: (json['score'] as num?)?.toDouble(),
      recurrencePhase: recurrencePhaseFromWire(json['recurrence_phase']),
      primaryFacet: FacetPair.fromJson(
        json['primary_facet'] as Map<String, dynamic>?,
      ),
      secondaryFacets:
          ((json['secondary_facets'] as List<dynamic>?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(FacetPair.fromJson)
              .whereType<FacetPair>()
              .toList(growable: false),
    );
  }
}

/// Post-gate counts for a `/map/pins` settle. Exact on the no-text path; an
/// estimate when a free-text `query` is present. Reflect only the requested
/// entity(ies).
class MapCounts {
  final int venues;
  final int events;
  final int total;

  const MapCounts({this.venues = 0, this.events = 0, this.total = 0});

  static MapCounts fromJson(Map<String, dynamic>? json) {
    if (json == null) return const MapCounts();
    return MapCounts(
      venues: json['venues'] as int? ?? 0,
      events: json['events'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
    );
  }
}

/// PROD-2906 (A6) — a v2 stack member: `{id, entity}` (+ optional
/// [primaryFacet]). Two uses on [MapServerStack]:
///   • [MapServerStack.stackMembers] — the top ≤5 teardrops, which carry
///     [primaryFacet] for the pin art.
///   • [MapServerStack.members] — ALL members (from `member_ids`, 1.26.0), as
///     `{id, entity}` only ([primaryFacet] null; the drawer hydrates full cards
///     by id, so the facet isn't needed there).
/// Either way [entity] buckets the member into `/map/hydrate`'s `venue_ids` vs
/// `event_occurrence_ids`.
class MapStackMember {
  final String id;
  final String entity; // 'venue' | 'event'
  final FacetPair? primaryFacet;

  const MapStackMember({
    required this.id,
    required this.entity,
    this.primaryFacet,
  });

  bool get isEvent => entity == 'event';

  /// A lightweight [MapPin] for the teardrop / drawer ref (lat/lng/name null —
  /// the teardrop is drawn at the stack centre, and the drawer hydrates by id).
  MapPin toPin() => MapPin(id: id, entity: entity, primaryFacet: primaryFacet);

  static MapStackMember? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final entity = json['entity'] as String?;
    if (id == null || entity == null) return null;
    return MapStackMember(
      id: id,
      entity: entity,
      primaryFacet: FacetPair.fromJson(
        json['primary_facet'] as Map<String, dynamic>?,
      ),
    );
  }
}

/// PROD-2906 (A6) — a v2 server overflow stack: a dense grid cell the server
/// collapsed into a `+k` marker. The FE maps this onto its render-side
/// `OverflowBubble` (`map_grid_selection.dart`).
///
/// [members] holds ALL members in pool order as `{id, entity}` objects (A6,
/// OpenAPI 1.26.0 — sync doc `12`), so every one is bucketable and hydratable
/// by id via `/map/hydrate` (bucket on [MapStackMember.entity]). [stackMembers]
/// is the top ≤5 (with `primary_facet`) — the drawn teardrops.
///
/// **Back-compat:** pre-1.26.0 the wire sent `member_ids` as bare id strings
/// (no entity). [fromJson] skips non-object entries, so [members] is EMPTY
/// against a stale server; the FE then falls back to [stackMembers] (top-5) for
/// that stack's drawer list. So the client rides both shapes safely.
class MapServerStack {
  final String id; // 'overflow_<cellKey>'
  final double centerLat;
  final double centerLng;
  final int count;

  /// True when the cell saturated the fetch (so [count] is a lower bound). The
  /// FE renders the title as "N+" then. Default false — never trips at launch.
  final bool countCapped;
  final int venueCount;
  final int eventCount;
  final bool hasVenues;
  final bool hasEvents;

  /// Members are co-located (<25 m) — a tap opens cluster-focus, not a zoom.
  final bool unsplittable;

  /// ALL members in pool order as `{id, entity}` (from `member_ids`). Empty
  /// against a pre-1.26.0 server (bare-string entries are skipped — see the
  /// class doc); `length == count` otherwise.
  final List<MapStackMember> members;

  /// Top ≤5 members in relevance order (with facet) — the drawn teardrops.
  final List<MapStackMember> stackMembers;

  const MapServerStack({
    required this.id,
    required this.centerLat,
    required this.centerLng,
    required this.count,
    this.countCapped = false,
    this.venueCount = 0,
    this.eventCount = 0,
    this.hasVenues = false,
    this.hasEvents = false,
    this.unsplittable = false,
    this.members = const [],
    this.stackMembers = const [],
  });

  /// Parse one `member_ids` entry. 1.26.0: `{id, entity}` object. Pre-1.26.0:
  /// a bare id string with no entity → not bucketable, so skip it (the drawer
  /// falls back to [stackMembers] for this stack).
  static MapStackMember? _memberFromJson(dynamic entry) =>
      entry is Map<String, dynamic> ? MapStackMember.fromJson(entry) : null;

  static MapServerStack? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final lat = (json['center_lat'] as num?)?.toDouble();
    final lng = (json['center_lng'] as num?)?.toDouble();
    if (id == null || lat == null || lng == null) return null;
    return MapServerStack(
      id: id,
      centerLat: lat,
      centerLng: lng,
      count: json['count'] as int? ?? 0,
      countCapped: json['count_capped'] as bool? ?? false,
      venueCount: json['venue_count'] as int? ?? 0,
      eventCount: json['event_count'] as int? ?? 0,
      hasVenues: json['has_venues'] as bool? ?? false,
      hasEvents: json['has_events'] as bool? ?? false,
      unsplittable: json['unsplittable'] as bool? ?? false,
      members: ((json['member_ids'] as List<dynamic>?) ?? const [])
          .map(_memberFromJson)
          .whereType<MapStackMember>()
          .toList(growable: false),
      stackMembers: ((json['stack_members'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MapStackMember.fromJson)
          .whereType<MapStackMember>()
          .toList(growable: false),
    );
  }
}

/// PROD-2906 (A6) — the v2 server-side selection payload (the `selection` field
/// on [MapPinsResponse]). Present only when the request sent `pins_version=2`
/// AND the server flag `MAP_PINS_V2_SELECTION` is on; null otherwise (the FE
/// then falls back to its client-side `selectPins` over [MapPinsResponse.venues]
/// / [MapPinsResponse.events]).
///
/// [representatives] are the shown pins (relevance order); [stacks] are the
/// overflow markers (cell-key order). The FE trims both to the live viewport on
/// pan (the server returns viewport + a 1-cell ring buffer).
class MapServerSelection {
  /// The world-grid level the server settled on (null when nothing was in the
  /// viewport / below `Z_min`). Observability parity with the FE engine.
  final int? level;
  final List<MapPin> representatives;
  final List<MapServerStack> stacks;

  /// True when `zoom < Z_min`: [stacks] is empty by design and
  /// [representatives] is a small capped individual-pin set (O8). At launch
  /// this is true at every web zoom (`Z_min` = 18 = the web ceiling).
  final bool lowZoomSuppressed;

  const MapServerSelection({
    this.level,
    this.representatives = const [],
    this.stacks = const [],
    this.lowZoomSuppressed = false,
  });

  static MapServerSelection? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MapServerSelection(
      level: json['level'] as int?,
      representatives: ((json['representatives'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MapPin.fromJson)
          .whereType<MapPin>()
          .toList(growable: false),
      stacks: ((json['stacks'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MapServerStack.fromJson)
          .whereType<MapServerStack>()
          .toList(growable: false),
      lowZoomSuppressed: json['low_zoom_suppressed'] as bool? ?? false,
    );
  }
}

/// `POST /map/pins` response: slim venue + event pins (nearest-to-centre,
/// stable order), post-gate [counts], and [capped] (true when the true total
/// exceeds the combined 300-nearest cap; [counts] still report true totals).
///
/// PROD-2906: [selection] carries the v2 server-side selection when the request
/// opted in (`pins_version=2`) and the server flag is on; null → the FE runs its
/// own `selectPins` over [venues]/[events] (which stay populated regardless).
class MapPinsResponse {
  final List<MapPin> venues;
  final List<MapPin> events;
  final MapCounts counts;
  final bool capped;
  final MapServerSelection? selection;

  /// PROD-2971 — admin-only diagnostics block, present only when the request
  /// sent `debug=true` as an admin; null on every normal path (the slim pin
  /// models above are untouched). See [MapDebug].
  final MapDebug? debug;

  const MapPinsResponse({
    this.venues = const [],
    this.events = const [],
    this.counts = const MapCounts(),
    this.capped = false,
    this.selection,
    this.debug,
  });

  factory MapPinsResponse.fromJson(Map<String, dynamic> json) {
    List<MapPin> pins(String key) => ((json[key] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MapPin.fromJson)
        .whereType<MapPin>()
        .toList(growable: false);
    return MapPinsResponse(
      venues: pins('venues'),
      events: pins('events'),
      counts: MapCounts.fromJson(json['counts'] as Map<String, dynamic>?),
      capped: json['capped'] as bool? ?? false,
      selection: MapServerSelection.fromJson(
        json['selection'] as Map<String, dynamic>?,
      ),
      debug: MapDebug.fromJson(json['debug']),
    );
  }
}
