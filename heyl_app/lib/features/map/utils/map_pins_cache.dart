/// PROD-3657 — an in-memory cache of `/map/pins` **pools**, so panning or
/// zooming back over ground the user already covered re-paints immediately
/// instead of waiting for another round trip.
///
/// ## The rule that makes this safe
///
/// **The cache must never gate a request.** `MapPinsNotifier` fetches on settle
/// exactly as it did before; the cache only *pre-paints* while that response is
/// in flight, and the response always wins when it lands. The worst case is
/// therefore what the user sees today — the cache can only ever make pins
/// arrive sooner, never withhold fresher ones. That is a structural property,
/// not something to test for.
///
/// ## What is (and isn't) cached
///
/// Only the **pins**. [MapPinsCache.put] stores a pins-only copy: no
/// `selection`, no `debug`. On the v2 path the server's `selection` is computed
/// for a *specific viewport + zoom*, so replaying it at a different camera would
/// show a stale shown-vs-dotted split. Cached pins are camera-independent (they
/// are geolocated and every consumer filters by viewport); a cached selection is
/// not, so the cache is built so it cannot hold one.
///
/// A pre-paint therefore arrives with `selection == null`, which routes the map
/// through the client-side `selectPins` path for the current camera — the right
/// answer for the camera the user is actually looking at.
///
/// `capped` rides along unchanged: a partial pool stays honestly marked partial,
/// and the fetch that is already in flight fills it in.
///
/// ## Eviction
///
/// Two independent limits, whichever bites first:
///
/// - a **[kMapPinsCacheTtl] TTL** per entry;
/// - a **bounded LRU** of [kMapPinsCacheMaxEntries] entries across all filter
///   signatures.
///
/// The bound is derived from a measurement, not a guess — see
/// [kMapPinsCacheMaxEntries].
///
/// Pure Dart, platform-agnostic, side-effect free (the caller supplies `now`) —
/// unit tested in `test/features/map/utils/map_pins_cache_test.dart`.
library;

import 'dart:math' as math;

import '../../../data/models/map_pin.dart';
import '../models/map_query.dart';
import 'map_grid_selection.dart' show MapViewport;

// ── Tunables ────────────────────────────────────────────────────────────────

/// How long a cached pool may be served. Past this the entry is not consulted
/// (and is dropped on the next touch) — events start and end, venues open and
/// close, and a five-minute-old pool is old enough to be worth a blank frame.
const Duration kMapPinsCacheTtl = Duration(minutes: 5);

/// Max cached pools, across every filter signature.
///
/// **Measured, not guessed** (2026-08-04): a real staging `/map/pins` response
/// for a 5 km Lisbon radius returns 150 pins (75 venues + 75 events, `capped:
/// true`) and costs **≈ 686 bytes per pin on the Dart heap** — ~100 KiB per
/// entry — against 282 B/pin on the wire. (Measured by holding 200 separately
/// decoded pools and reading `ProcessInfo.currentRss`; separately decoded so no
/// string is shared between entries, which is the pessimistic case and exactly
/// what a pan-around cache holds.)
///
/// So 32 entries ≈ **3.2 MiB** at the observed response size, and ≈ 6.4 MiB if
/// the backend ever returns its documented 300-pin ceiling. 32 distinct settle
/// areas inside a five-minute window is already a lot of panning — in practice
/// the TTL bites first — so this buys the whole realistic working set without
/// putting a phone under memory pressure.
const int kMapPinsCacheMaxEntries = 32;

/// How much of the current viewport a cached entry must cover before it is
/// served. Below this a pre-paint would show a sliver of pins along one edge and
/// read as "barely anything here", which is worse than the honest stale frame it
/// replaces. 0.9 tolerates a return to *approximately* the previous camera (the
/// realistic case — a settle almost never reproduces an exact camera) while
/// refusing a genuinely different area.
const double kMapPinsCacheMinCoverage = 0.9;

// ── Entry ───────────────────────────────────────────────────────────────────

/// One cached pool: the pins, the viewport they were fetched for, and when.
class MapPinsCacheEntry {
  /// The [MapQuery.filterSignature] this pool was fetched under.
  ///
  /// Held as its own field rather than parsed back out of the map key: the
  /// signature embeds the raw keyword, so prefix-matching a concatenated key
  /// would let a keyword containing the delimiters (`||@`) impersonate another
  /// search's bucket and be served its pins (codex review). An exact `==` has
  /// no such escaping game to lose.
  final String signature;

  /// Pins only — never a `selection` (see the library doc).
  final MapPinsResponse response;

  /// The viewport the pool was fetched for. Drives [MapPinsCache.bestFor]'s
  /// coverage test, and is what makes a cached pool safe to reuse: the entry
  /// knows the area it can speak for.
  final MapViewport viewport;

  final DateTime storedAt;

  const MapPinsCacheEntry({
    required this.signature,
    required this.response,
    required this.viewport,
    required this.storedAt,
  });

  bool isExpired(DateTime now) => now.difference(storedAt) >= kMapPinsCacheTtl;
}

// ── Cache ───────────────────────────────────────────────────────────────────

/// A bounded, TTL'd LRU of `/map/pins` pools keyed by
/// [MapQuery.filterSignature] + the camera the pool was fetched for.
///
/// Keying the bucket on `filterSignature` gives "clear the cache on a new
/// search, but not on zoom or pan" **for free** — a filter change, a new
/// keyword or a different Zine produces a different signature, so the old
/// entries are simply never consulted — instead of hand-maintaining a list of
/// invalidating triggers. (`filterSignature` also carries the custom date range
/// since PROD-3656; before that, moving the hand-picked window would have looked
/// like the same search here.)
///
/// It deliberately does **not** know about auth: signing in or out changes what
/// `yours`/`following` mean without changing the signature, so the owner clears
/// the whole cache on an identity change ([clear]).
class MapPinsCache {
  MapPinsCache({
    this.maxEntries = kMapPinsCacheMaxEntries,
    this.minCoverage = kMapPinsCacheMinCoverage,
  });

  final int maxEntries;
  final double minCoverage;

  /// Insertion-ordered: Dart's `LinkedHashMap` iterates in insertion order, so
  /// re-inserting on access makes the FIRST key the least-recently-used one.
  final Map<String, MapPinsCacheEntry> _entries = {};

  int get length => _entries.length;

  /// Store [response]'s pins for [query]. No-op when the query has no viewport
  /// to speak for — an entry that can't state its area can never be served.
  void put(MapQuery query, MapPinsResponse response, DateTime now) {
    final viewport = _viewportOf(query);
    if (viewport == null) return;
    final key = _keyFor(query, viewport);
    // Re-insert so the entry lands at the most-recently-used end.
    _entries.remove(key);
    _entries[key] = MapPinsCacheEntry(
      signature: query.filterSignature,
      // Pins only — a cached `selection` is meaningless away from its camera,
      // and `debug` is admin diagnostics for one specific request.
      response: MapPinsResponse(
        venues: response.venues,
        events: response.events,
        counts: response.counts,
        capped: response.capped,
      ),
      viewport: viewport,
      storedAt: now,
    );
    _evict(now);
  }

  /// The best pool to pre-paint [query] with, or null.
  ///
  /// Considers only entries under the same [MapQuery.filterSignature] that are
  /// unexpired and cover at least [minCoverage] of the current viewport. Among
  /// those, prefers the **closest zoom** (so pin density is as apt as possible),
  /// then the most recent. Serving is an LRU touch.
  MapPinsResponse? bestFor(MapQuery query, DateTime now) {
    final viewport = _viewportOf(query);
    if (viewport == null) return null;
    final signature = query.filterSignature;

    String? bestKey;
    MapPinsCacheEntry? best;
    for (final e in _entries.entries) {
      final entry = e.value;
      if (entry.signature != signature) continue;
      if (entry.isExpired(now)) continue;
      if (_coverage(entry.viewport, viewport) < minCoverage) continue;
      if (best == null || _isBetter(entry, best, viewport)) {
        best = entry;
        bestKey = e.key;
      }
    }
    if (best == null) return null;
    // LRU touch — a pool the user keeps coming back to should outlive one they
    // passed through once.
    _entries.remove(bestKey);
    _entries[bestKey!] = best;
    return best.response;
  }

  /// Pins from OTHER cached pools under the same signature whose viewport
  /// intersects [viewport] — the "widened pool" PROD-3656's auto-promotion
  /// draws on, minus anything [exclude] already holds.
  ///
  /// This is what makes a `capped: true` response recoverable: the current pool
  /// is the 300-nearest for *its* centre, so a differently-centred fetch a
  /// moment ago may hold results inside the current view that this one dropped.
  /// Intersection-filtered first, so a pan-heavy session scans one or two
  /// entries rather than all [maxEntries].
  List<MapPin> extraPoolFor(
    MapQuery query,
    MapViewport viewport,
    DateTime now, {
    required Set<String> exclude,
  }) {
    final signature = query.filterSignature;
    final seen = <String>{...exclude};
    final out = <MapPin>[];
    for (final entry in _entries.values) {
      if (entry.signature != signature) continue;
      if (entry.isExpired(now)) continue;
      if (!_intersects(entry.viewport, viewport)) continue;
      for (final p in [...entry.response.venues, ...entry.response.events]) {
        final lat = p.lat;
        final lng = p.lng;
        if (lat == null || lng == null) continue;
        if (!viewport.contains(lat, lng)) continue;
        if (!seen.add(p.id)) continue;
        out.add(p);
      }
    }
    return out;
  }

  /// Drop everything. The owner calls this on an auth identity change: signing
  /// in or out changes what `yours`/`following` return for an unchanged
  /// [MapQuery.filterSignature], so nothing fetched on one side of that boundary
  /// may be served on the other.
  void clear() => _entries.clear();

  /// Drop expired entries, then the least-recently-used until within bounds.
  void _evict(DateTime now) {
    _entries.removeWhere((_, e) => e.isExpired(now));
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Closest zoom wins; ties go to the more recent entry.
  bool _isBetter(
    MapPinsCacheEntry candidate,
    MapPinsCacheEntry incumbent,
    MapViewport target,
  ) {
    final dc = (candidate.viewport.zoom - target.zoom).abs();
    final di = (incumbent.viewport.zoom - target.zoom).abs();
    if ((dc - di).abs() > 1e-9) return dc < di;
    return candidate.storedAt.isAfter(incumbent.storedAt);
  }

  /// `signature@sw,ne,zoom` — the signature scopes the bucket, the camera keeps
  /// two different areas of the same search from overwriting each other.
  String _keyFor(MapQuery q, MapViewport v) =>
      '${q.filterSignature}@${_r(v.swLat)},${_r(v.swLng)},'
      '${_r(v.neLat)},${_r(v.neLng)},${v.zoom.toStringAsFixed(2)}';

  static String _r(double d) => d.toStringAsFixed(5);

  /// The settled viewport rect, or null when the query has no camera yet.
  /// Deliberately NOT the centre+radius approximation the selection falls back
  /// to: an entry with a guessed area would claim coverage it can't back up.
  static MapViewport? _viewportOf(MapQuery q) {
    if (!q.hasBounds) return null;
    return MapViewport(
      swLat: q.swLat!,
      swLng: q.swLng!,
      neLat: q.neLat!,
      neLng: q.neLng!,
      zoom: q.zoom,
    );
  }
}

/// The fraction of [target]'s area that [cached] covers, in [0, 1].
///
/// Plain lat/lng rectangle overlap: both rects come from the same camera on the
/// same map, so the projection distortion is identical on each and cancels out
/// of the ratio. Antimeridian-straddling viewports are out of scope here for the
/// same reason they are in `MapViewport.contains` (Europe-scoped app) — such a
/// rect simply scores 0 and the cache declines to serve it.
double _coverage(MapViewport cached, MapViewport target) {
  final tw = target.neLng - target.swLng;
  final th = target.neLat - target.swLat;
  if (tw <= 0 || th <= 0) return 0;
  final ow =
      math.min(cached.neLng, target.neLng) -
      math.max(cached.swLng, target.swLng);
  final oh =
      math.min(cached.neLat, target.neLat) -
      math.max(cached.swLat, target.swLat);
  if (ow <= 0 || oh <= 0) return 0;
  return (ow * oh) / (tw * th);
}

/// Do the two rects overlap at all?
bool _intersects(MapViewport a, MapViewport b) =>
    a.swLng < b.neLng &&
    b.swLng < a.neLng &&
    a.swLat < b.neLat &&
    b.swLat < a.neLat;
