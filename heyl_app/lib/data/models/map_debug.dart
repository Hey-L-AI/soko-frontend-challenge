/// PROD-2971 — admin-only `/map/pins` **debug** block models.
///
/// The backend (PROD-2970) returns a nullable top-level `debug` object ONLY for
/// an admin request that sent `debug=true`; it's `null` on every normal path
/// (zero impact on the count-first pin models in `map_pin.dart`). These models
/// power the admin map debug overlay + panel: they describe **which area was
/// searched** (retrieval circle, sargable bbox, world grid, v2 selection rect),
/// the **retrieval** per entity leg, and **per-pin scoring** for pin-tap.
///
/// Contract agreed under PROD-2969 (umbrella) / PROD-2970 (backend) / PROD-2971
/// (this webapp work). Wire is snake_case; nested points are `{lat, lng}`.
///
/// Parsing is **fully tolerant**: a missing field is null, and a *type-drifted*
/// container (a scalar where a map/list is expected) degrades to null/empty via
/// [_asMap]/[_asList] rather than throwing — so a malformed debug block can
/// never discard the whole `/map/pins` response it rides on. [MapDebug.fromJson]
/// additionally wraps the parse in a try/catch as a total backstop (e.g. a
/// scalar drift on a leaf field): worst case the debug block is dropped for that
/// fetch and the pins still render.
library;

/// Cast [v] to a JSON map, or null if it isn't one (no throw on type-drift).
Map<String, dynamic>? _asMap(Object? v) => v is Map<String, dynamic> ? v : null;

/// Cast [v] to a list, or null if it isn't one (no throw on type-drift).
List<dynamic>? _asList(Object? v) => v is List ? v : null;

/// A `{lat, lng}` point (matches the response casing used everywhere in the
/// debug block).
class DebugLatLng {
  final double lat;
  final double lng;

  const DebugLatLng({required this.lat, required this.lng});

  static DebugLatLng? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final lat = (json['lat'] as num?)?.toDouble();
    final lng = (json['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return DebugLatLng(lat: lat, lng: lng);
  }
}

/// An axis-aligned lat/lng box: `{lat_min, lat_max, lng_min, lng_max}`. Used for
/// the sargable pre-filter bbox and each grid cell.
class DebugBbox {
  final double latMin;
  final double latMax;
  final double lngMin;
  final double lngMax;

  const DebugBbox({
    required this.latMin,
    required this.latMax,
    required this.lngMin,
    required this.lngMax,
  });

  static DebugBbox? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final latMin = (json['lat_min'] as num?)?.toDouble();
    final latMax = (json['lat_max'] as num?)?.toDouble();
    final lngMin = (json['lng_min'] as num?)?.toDouble();
    final lngMax = (json['lng_max'] as num?)?.toDouble();
    if (latMin == null || latMax == null || lngMin == null || lngMax == null) {
      return null;
    }
    return DebugBbox(
      latMin: latMin,
      latMax: latMax,
      lngMin: lngMin,
      lngMax: lngMax,
    );
  }
}

/// A `{sw, ne}` corner rectangle (the input viewport + the v2 selection rect).
class DebugRect {
  final DebugLatLng sw;
  final DebugLatLng ne;

  const DebugRect({required this.sw, required this.ne});

  static DebugRect? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final sw = DebugLatLng.fromJson(_asMap(json['sw']));
    final ne = DebugLatLng.fromJson(_asMap(json['ne']));
    if (sw == null || ne == null) return null;
    return DebugRect(sw: sw, ne: ne);
  }
}

/// A geodesic circle: `{center: {lat,lng}, radius_meters}`. The **retrieval
/// circle** is THE fetch area — the shape whose overhang past the visible box is
/// the source of most "missing/extra pin" bugs.
class DebugCircle {
  final DebugLatLng center;
  final double radiusMeters;

  const DebugCircle({required this.center, required this.radiusMeters});

  static DebugCircle? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final center = DebugLatLng.fromJson(_asMap(json['center']));
    final radius = (json['radius_meters'] as num?)?.toDouble();
    if (center == null || radius == null) return null;
    return DebugCircle(center: center, radiusMeters: radius);
  }
}

/// `debug.source_path` — which retrieval path each entity leg took
/// (`legacy | lateral | keyword | window`).
class MapDebugSourcePath {
  final String? venue;
  final String? event;

  const MapDebugSourcePath({this.venue, this.event});

  static MapDebugSourcePath? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MapDebugSourcePath(
      venue: json['venue'] as String?,
      event: json['event'] as String?,
    );
  }
}

/// One grid cell: its box + (only when `debug_cell_counts` was requested) how
/// many items fell in it.
class MapDebugGridCell {
  final DebugBbox box;
  final int? count;

  const MapDebugGridCell({required this.box, this.count});

  static MapDebugGridCell? fromJson(Map<String, dynamic>? json) {
    final box = DebugBbox.fromJson(json);
    if (box == null) return null;
    return MapDebugGridCell(box: box, count: (json?['count'] as num?)?.toInt());
  }
}

/// `debug.area.grid` — the world grid geometry the server settled on. Cell
/// counts are present only when `debug_cell_counts=true` was sent.
class MapDebugGrid {
  /// `cell_size_deg` as a `{lat, lng}` degree pair.
  final DebugLatLng? cellSizeDeg;
  final int? cellsAcross;
  final int? occupiedCells;
  final List<MapDebugGridCell> cells;

  const MapDebugGrid({
    this.cellSizeDeg,
    this.cellsAcross,
    this.occupiedCells,
    this.cells = const [],
  });

  static MapDebugGrid? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MapDebugGrid(
      cellSizeDeg: DebugLatLng.fromJson(_asMap(json['cell_size_deg'])),
      cellsAcross: (json['cells_across'] as num?)?.toInt(),
      occupiedCells: (json['occupied_cells'] as num?)?.toInt(),
      cells: (_asList(json['cells']) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MapDebugGridCell.fromJson)
          .whereType<MapDebugGridCell>()
          .toList(growable: false),
    );
  }
}

/// `debug.area.input` — the raw request geometry the server received.
class MapDebugAreaInput {
  final DebugLatLng? center;
  final double? radiusMeters;

  /// Present only on a v2 request (viewport rect + zoom).
  final DebugRect? viewportRect;
  final double? zoom;

  const MapDebugAreaInput({
    this.center,
    this.radiusMeters,
    this.viewportRect,
    this.zoom,
  });

  static MapDebugAreaInput? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MapDebugAreaInput(
      center: DebugLatLng.fromJson(_asMap(json['center'])),
      radiusMeters: (json['radius_meters'] as num?)?.toDouble(),
      viewportRect: DebugRect.fromJson(_asMap(json['viewport_rect'])),
      zoom: (json['zoom'] as num?)?.toDouble(),
    );
  }
}

/// `debug.area.selection_viewport` — the v2 server-side selection parameters
/// (null on a v1 request). Echoes the grid level / band cap / suppression the
/// server used, for drift-diffing against the FE constants.
class MapDebugSelectionViewport {
  final DebugRect? rect;
  final double? marginFrac;
  final int? gridLevel;
  final int? bandCap;
  final bool? clustersAllowed;
  final bool? lowZoomSuppressed;

  const MapDebugSelectionViewport({
    this.rect,
    this.marginFrac,
    this.gridLevel,
    this.bandCap,
    this.clustersAllowed,
    this.lowZoomSuppressed,
  });

  static MapDebugSelectionViewport? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MapDebugSelectionViewport(
      // sw/ne live inline on selection_viewport (not nested under a `rect` key).
      rect: DebugRect.fromJson(json),
      marginFrac: (json['margin_frac'] as num?)?.toDouble(),
      gridLevel: (json['grid_level'] as num?)?.toInt(),
      bandCap: (json['band_cap'] as num?)?.toInt(),
      clustersAllowed: json['clusters_allowed'] as bool?,
      lowZoomSuppressed: json['low_zoom_suppressed'] as bool?,
    );
  }
}

/// `debug.area` — the geometry bundle the overlay draws:
/// input · retrieval circle (the fetch area) · sargable bbox · grid · v2 rect.
class MapDebugArea {
  final MapDebugAreaInput? input;
  final DebugCircle? retrievalCircle;
  final DebugBbox? sargableBbox;
  final MapDebugGrid? grid;
  final MapDebugSelectionViewport? selectionViewport;

  const MapDebugArea({
    this.input,
    this.retrievalCircle,
    this.sargableBbox,
    this.grid,
    this.selectionViewport,
  });

  static MapDebugArea? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MapDebugArea(
      input: MapDebugAreaInput.fromJson(_asMap(json['input'])),
      retrievalCircle: DebugCircle.fromJson(_asMap(json['retrieval_circle'])),
      sargableBbox: DebugBbox.fromJson(_asMap(json['sargable_bbox'])),
      grid: MapDebugGrid.fromJson(_asMap(json['grid'])),
      selectionViewport: MapDebugSelectionViewport.fromJson(
        _asMap(json['selection_viewport']),
      ),
    );
  }
}

/// One retrieval leg's stats: `{fetched, capped, budget, ms}`.
class MapDebugRetrievalLeg {
  final int? fetched;
  final bool? capped;
  final int? budget;
  final double? ms;

  const MapDebugRetrievalLeg({this.fetched, this.capped, this.budget, this.ms});

  static MapDebugRetrievalLeg? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MapDebugRetrievalLeg(
      fetched: (json['fetched'] as num?)?.toInt(),
      capped: json['capped'] as bool?,
      budget: (json['budget'] as num?)?.toInt(),
      ms: (json['ms'] as num?)?.toDouble(),
    );
  }
}

/// `debug.retrieval` — per-entity retrieval stats.
class MapDebugRetrieval {
  final MapDebugRetrievalLeg? venue;
  final MapDebugRetrievalLeg? event;

  const MapDebugRetrieval({this.venue, this.event});

  static MapDebugRetrieval? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MapDebugRetrieval(
      venue: MapDebugRetrievalLeg.fromJson(_asMap(json['venue'])),
      event: MapDebugRetrievalLeg.fromJson(_asMap(json['event'])),
    );
  }
}

/// One scoring axis with a raw + normalized value, plus the signal that fed it.
class ScoreAxis {
  final double? raw;
  final double? norm;

  /// Extra signal fields carried alongside (e.g. `list_count`, `rating`,
  /// `review_count`) — kept as a raw map so the panel can render whatever the
  /// backend attaches without a new field per axis.
  final Map<String, dynamic> extras;

  const ScoreAxis({this.raw, this.norm, this.extras = const {}});

  static ScoreAxis? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final extras = <String, dynamic>{
      for (final e in json.entries)
        if (e.key != 'raw' && e.key != 'norm') e.key: e.value,
    };
    return ScoreAxis(
      raw: (json['raw'] as num?)?.toDouble(),
      norm: (json['norm'] as num?)?.toDouble(),
      extras: extras,
    );
  }
}

/// `personalization` sub-block on a per-pin breakdown (null when personalization
/// didn't apply).
class ScorePersonalization {
  final String? level;
  final double? weight;

  /// `axes` — free-form per-axis personalization contributions.
  final Map<String, dynamic> axes;

  const ScorePersonalization({this.level, this.weight, this.axes = const {}});

  static ScorePersonalization? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return ScorePersonalization(
      level: json['level'] as String?,
      weight: (json['weight'] as num?)?.toDouble(),
      axes: _asMap(json['axes']) ?? const {},
    );
  }
}

/// One pin's scoring breakdown (the `debug.pins[]` entries). Looked up on
/// pin-tap by `(entity, id)` — see [MapDebug.breakdownFor].
///
/// The shape is **entity-dependent** (BE heads-up 2026-07-09): **venues** carry
/// [listBoost] / [qualitySignal] / [blendList]/[blendQuality] / [personalization];
/// **events** carry only [timeRelevance] (+ [meiliRelevance] on free-text
/// queries). Both carry [distanceM] / [cellX]/[cellY]. Every field is nullable,
/// and the panel renders only the axes actually present — so it's robust to the
/// venue/event split without hard-branching on [entity].
class MapPinScoreBreakdown {
  final String id;
  final String entity;
  final double? score;

  // Venue axes.
  final ScoreAxis? listBoost;
  final ScoreAxis? qualitySignal;

  /// `blend_weights` — `{list, quality}` blend proportions (venues).
  final double? blendList;
  final double? blendQuality;
  final ScorePersonalization? personalization;

  // Event axes (bare numbers, not raw/norm objects).
  /// `time_relevance` ∈ [0,1] — half-life-7d decay; 0.5 when the start time is
  /// unknown. Events only.
  final double? timeRelevance;

  /// `meili_relevance` — present ONLY on free-text/keyword event queries.
  final double? meiliRelevance;

  // Shared axes.
  final double? distanceM;
  final int? cellX;
  final int? cellY;

  const MapPinScoreBreakdown({
    required this.id,
    required this.entity,
    this.score,
    this.listBoost,
    this.qualitySignal,
    this.blendList,
    this.blendQuality,
    this.personalization,
    this.timeRelevance,
    this.meiliRelevance,
    this.distanceM,
    this.cellX,
    this.cellY,
  });

  static MapPinScoreBreakdown? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final entity = json['entity'] as String?;
    if (id == null || entity == null) return null;
    final breakdown = _asMap(json['score_breakdown']);
    final blend = _asMap(breakdown?['blend_weights']);
    final cell = _asMap(breakdown?['cell']);
    return MapPinScoreBreakdown(
      id: id,
      entity: entity,
      score: (json['score'] as num?)?.toDouble(),
      listBoost: ScoreAxis.fromJson(_asMap(breakdown?['list_boost'])),
      qualitySignal: ScoreAxis.fromJson(_asMap(breakdown?['quality_signal'])),
      blendList: (blend?['list'] as num?)?.toDouble(),
      blendQuality: (blend?['quality'] as num?)?.toDouble(),
      personalization: ScorePersonalization.fromJson(
        _asMap(breakdown?['personalization']),
      ),
      timeRelevance: (breakdown?['time_relevance'] as num?)?.toDouble(),
      meiliRelevance: (breakdown?['meili_relevance'] as num?)?.toDouble(),
      distanceM: (breakdown?['distance_m'] as num?)?.toDouble(),
      cellX: (cell?['x'] as num?)?.toInt(),
      cellY: (cell?['y'] as num?)?.toInt(),
    );
  }
}

/// The top-level `debug` block on `MapPinsResponse` (admin + `debug=true` only).
class MapDebug {
  final int? pinsVersion;
  final MapDebugSourcePath? sourcePath;
  final bool? radiusEnforced;
  final MapDebugArea? area;
  final MapDebugRetrieval? retrieval;

  /// Per-pin score breakdowns, keyed by `'<entity>:<id>'` so a venue id-string
  /// and an occurrence id-string can never alias. Look up on pin-tap via
  /// [breakdownFor].
  final Map<String, MapPinScoreBreakdown> pinBreakdowns;

  /// The original, unparsed `debug` JSON — kept verbatim so the panel's
  /// copy-to-clipboard hands the BE team EVERYTHING the server sent (including
  /// any fields we don't model), which is what you want when filing a bug.
  final Map<String, dynamic> raw;

  const MapDebug({
    this.pinsVersion,
    this.sourcePath,
    this.radiusEnforced,
    this.area,
    this.retrieval,
    this.pinBreakdowns = const {},
    this.raw = const {},
  });

  /// Look up a pin's breakdown by its `entity` + `id` (the same id we receive on
  /// the pin — occurrence id for events). Null when the payload has no entry.
  MapPinScoreBreakdown? breakdownFor({
    required String entity,
    required String id,
  }) => pinBreakdowns['$entity:$id'];

  /// Accepts the raw `debug` value (`Object?`) so a type-drifted block (a scalar
  /// where the object was expected) degrades to null at the call site instead of
  /// throwing in `MapPinsResponse.fromJson`.
  static MapDebug? fromJson(Object? raw) {
    final json = _asMap(raw);
    if (json == null) return null;
    // Total backstop: a leaf type-drift the granular `_asMap`/`_asList` guards
    // don't cover (e.g. a scalar where a number was expected) must never bubble
    // up and discard the whole `/map/pins` response — worst case we drop the
    // debug block for this fetch and the pins still render.
    try {
      final breakdowns = <String, MapPinScoreBreakdown>{};
      for (final entry in _asList(json['pins']) ?? const []) {
        if (entry is! Map<String, dynamic>) continue;
        final b = MapPinScoreBreakdown.fromJson(entry);
        if (b != null) breakdowns['${b.entity}:${b.id}'] = b;
      }
      return MapDebug(
        pinsVersion: (json['pins_version'] as num?)?.toInt(),
        sourcePath: MapDebugSourcePath.fromJson(_asMap(json['source_path'])),
        radiusEnforced: json['radius_enforced'] as bool?,
        area: MapDebugArea.fromJson(_asMap(json['area'])),
        retrieval: MapDebugRetrieval.fromJson(_asMap(json['retrieval'])),
        pinBreakdowns: breakdowns,
        raw: json,
      );
    } catch (_) {
      return null;
    }
  }
}
