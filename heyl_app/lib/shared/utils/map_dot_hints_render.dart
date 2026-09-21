/// PROD-3124 — dot-hint RENDER tokens + builders, shared by the web + native
/// map widgets so the two platforms' `heyl-dot-hints` layers can't drift
/// (same rule as `map_debug_overlay.dart`). The selection half — which pool
/// results become dots — lives in `features/map/utils/map_dot_hints.dart`.
library;

/// One dot hint — coordinates, identity, and resolved fill colour. The id +
/// entity exist for the dot TAP path (PROD-3124: tapping a dot flies to it
/// and promotes the item to a captioned pin); the render layer itself only
/// paints colour + position.
class MapDotHint {
  final String id;

  /// `'venue'` | `'event'` — buckets the promoted item on tap.
  final String entity;
  final double lat;
  final double lng;
  final String colorHex;

  const MapDotHint({
    required this.id,
    required this.entity,
    required this.lat,
    required this.lng,
    required this.colorHex,
  });

  @override
  bool operator ==(Object other) =>
      other is MapDotHint &&
      other.id == id &&
      other.entity == entity &&
      other.lat == lat &&
      other.lng == lng &&
      other.colorHex == colorHex;

  @override
  int get hashCode => Object.hash(id, entity, lat, lng, colorHex);
}

// ── Visual tokens (plain constants by decision — tune freely) ───────────────

/// Dot fill diameter (px) at the reference multiplier [_kDotAnchorSize]
/// (the zoom 14–17 working plateau). The radius scales with zoom via the
/// dots' own curve [kDotHintSizeStops] — see [dotRadiusStopsFlat].
const double kDotHintDiameterPx = 10.0;

/// Zoom-interpolated size multipliers for the dots, as `(zoom, size)` pairs
/// (Mapbox `interpolate ['linear']`, clamped to the endpoint sizes outside
/// the range). Originally this reused the pins' curve
/// (`MapPinIconTokens.iconSizeStops`), but the low end is tuned
/// independently (2026-07-15, Zé): dots **shrink** when zoomed out —
/// 0.2× at zoom ≤ 11, rising linearly to the 0.3× plateau at 14 — instead
/// of growing like the pins' 0.4×, so a zoomed-out map stays pins-first.
/// The top end still mirrors the pins (0.3× → 0.4× across 17–18).
const List<(double zoom, double size)> kDotHintSizeStops = [
  (11, 0.2),
  (14, 0.3),
  (17, 0.3),
  (18, 0.4),
];

/// The multiplier at which a dot renders at exactly [kDotHintDiameterPx] —
/// the 14–17 plateau value.
const double _kDotAnchorSize = 0.3;

/// Outline width (px). Colour = sokoInk (matches `AppColors.sokoInk`).
const double kDotHintStrokePx = 1.0;
const String kDotHintStrokeColor = '#44131D';

/// Opacity of the WHOLE dot — fill and outline both. (0.7 → 0.6, Zé
/// 2026-07-15 tuning.)
const double kDotHintOpacity = 0.6;

/// Progressive reveal: pins paint instantly on settle; dots then fade in
/// 0 → [kDotHintOpacity] via a Mapbox paint-property transition, so they never
/// grab attention. The delay lets the pins land first.
const int kDotFadeDelayMs = 400;
const int kDotFadeDurationMs = 800;

/// PROD-3124 — dot tap: the zoom the camera flies to when a dot is tapped
/// (street level, where the promoted item renders as a captioned pin).
const double kDotHintFocusZoom = 17.0;

/// Dot tap hit radius (screen px) — the 10 px dot plus finger forgiveness.
const double kDotHintHitRadiusPx = 16.0;

/// The dots as a GeoJSON FeatureCollection (Dart map) for the
/// `heyl-dot-hints` source — web `jsify`s it, native `jsonEncode`s it. Each
/// feature carries its resolved fill in `properties.dot_color`, so ONE circle
/// layer paints every colour via `['get', 'dot_color']` (see
/// docs/learnings/mapbox-one-source-many-shapes-data-driven-color.md).
Map<String, dynamic> buildDotHintsFeatureCollection(List<MapDotHint> dots) => {
  'type': 'FeatureCollection',
  'features': [
    for (final d in dots)
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [d.lng, d.lat],
        },
        // id/entity ride along for the tap path (dot tap → fly + promote).
        'properties': {'dot_color': d.colorHex, 'id': d.id, 'entity': d.entity},
      },
  ],
};

/// PROD-3656 — the item ids in a [buildDotHintsFeatureCollection]. Cheap
/// identity for a dot set, without rebuilding the [MapDotHint] objects.
Set<String> dotHintIdsOf(Map<String, dynamic>? fc) {
  final features = fc?['features'];
  if (features is! List) return const {};
  final out = <String>{};
  for (final f in features) {
    if (f is! Map) continue;
    final props = f['properties'];
    if (props is! Map) continue;
    final id = props['id'];
    if (id is String) out.add(id);
  }
  return out;
}

/// PROD-3656 — is [next] a **removal-only** delta on the already-revealed
/// [previous] dot set?
///
/// The reveal in `_syncDotHints` snaps the layer to 0 opacity before swapping
/// the data and fades it back over [kDotFadeDelayMs] + [kDotFadeDurationMs] —
/// 1.2 s. That is right for a settle (dots are rebuilt, and they should land
/// after the pins), but wrong for an auto-promotion: a dot that just became a
/// pin should simply stop being drawn, without blinking every other dot on the
/// map. When nothing is *added*, the surviving dots keep their opacity and only
/// the data swaps.
///
/// False for an empty [next] (there is nothing left to keep revealed) and for
/// any set that introduces an id, which falls back to the full reveal.
bool isDotHintRemovalOnly(Set<String> previous, Set<String> next) =>
    next.isNotEmpty &&
    next.length <= previous.length &&
    previous.containsAll(next);

/// Parse a [buildDotHintsFeatureCollection] back into dots — the native tap
/// path hit-tests geometrically against these (its circle layers aren't
/// reliably queryable). Skips malformed features defensively.
List<MapDotHint> dotHintsFromFeatureCollection(Map<String, dynamic>? fc) {
  final features = fc?['features'];
  if (features is! List) return const [];
  final out = <MapDotHint>[];
  for (final f in features) {
    if (f is! Map) continue;
    final geom = f['geometry'];
    final props = f['properties'];
    if (geom is! Map || props is! Map) continue;
    final coords = geom['coordinates'];
    final id = props['id'];
    final entity = props['entity'];
    final color = props['dot_color'];
    if (coords is! List || coords.length < 2) continue;
    if (id is! String || entity is! String || color is! String) continue;
    final lng = coords[0];
    final lat = coords[1];
    if (lng is! num || lat is! num) continue;
    out.add(
      MapDotHint(
        id: id,
        entity: entity,
        lat: lat.toDouble(),
        lng: lng.toDouble(),
        colorHex: color,
      ),
    );
  }
  return out;
}

/// Flattened `[zoom0, radius0, zoom1, radius1, …]` stops for the dot layer's
/// `circle-radius` interpolate expression — [kDotHintSizeStops] normalized so
/// the [_kDotAnchorSize] plateau (zoom 14–17) renders the dot at
/// [kDotHintDiameterPx]: 6.7 px diameter at zoom ≤ 11, 10 px across 14–17,
/// 13.3 px at zoom ≥ 18.
List<double> dotRadiusStopsFlat() => [
  for (final (zoom, size) in kDotHintSizeStops) ...[
    zoom,
    (kDotHintDiameterPx / 2) * (size / _kDotAnchorSize),
  ],
];
