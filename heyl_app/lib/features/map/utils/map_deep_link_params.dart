import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/models/map_pin.dart';
import '../models/map_query.dart';
import '../widgets/map_filter_bar.dart' show MapFilterTab;

/// PROD-4124 — the `/map` URL contract: query params → a preselected
/// [MapQuery] state.
///
/// Parsing lives here, as a **pure function over a plain map**, so the whole
/// contract is testable without a router, a widget tree or a network. The route
/// assembles the raw values (including the web cold-start fallback, which is
/// router-shaped); everything after that is this file.
///
/// ## The contract (PROD-4123 scope-align round 1)
///
/// | Param | Form | Card |
/// |---|---|---|
/// | `entity` | `event` / `venue` / absent = both | A1 |
/// | `when` | a named window — see [kMapWhenWire] | A2 |
/// | `from` / `to` | ISO dates; **wins over `when`** when both are present | A2 |
/// | `tema` | `eat_drink/restaurants,music` | A3 |
/// | `q` | free text | A4 |
/// | `lat` / `lng` / `radius` | numbers, radius in metres | A5 |
///
/// **Nothing here can fail (A6).** An unknown key, an unparseable value or an
/// out-of-range number is dropped and the rest still applies. There is no error
/// path and no exception — the worst case a bad link can produce is a map with
/// fewer filters than the author intended, never a blank or broken one. That is
/// load-bearing rather than merely tidy: PROD-4125 lets a **server-supplied**
/// string reach this parser, so a value that could throw would be a banner that
/// takes the map down.
///
/// For the same reason this file is **strictly declarative**: it computes a
/// query and a camera, and nothing else. It must never navigate, send, write to
/// storage, or influence an auth gate. If a `/map` param ever gains a side
/// effect, `feed_action_routes.dart` must stop allowing params on `/map`.
@immutable
class MapDeepLinkParams {
  const MapDeepLinkParams({
    this.type,
    this.date,
    this.customRange,
    this.facetFilters,
    this.keyword,
    this.centerLat,
    this.centerLng,
    this.radiusMeters,
    this.touchedTabs = const <MapFilterTab>{},
  });

  /// Nothing was preselected — the map opens exactly as it does today.
  static const MapDeepLinkParams none = MapDeepLinkParams();

  final MapItemType? type;

  /// The resolved date window. Null when absent, unparseable, or **dropped as
  /// inert** — see [_dateApplies].
  final MapDateFilter? date;

  /// Set only when [date] is [MapDateFilter.custom].
  final DateTimeRange? customRange;

  final Set<FacetPair>? facetFilters;
  final String? keyword;

  final double? centerLat;
  final double? centerLng;

  /// Metres, already clamped to the API's 100–50 000 window (A5: clamped, never
  /// rejected — a slightly-wrong campaign link should still work).
  final double? radiusMeters;

  /// PROD-4123 card B3, as amended 2026-09-02.
  ///
  /// A filter-bar tab reads pink **iff the URL set it AND that value was
  /// actually applied** — including when the value equals the default, which is
  /// the whole point of the amendment (`?when=next_30_days` is a deliberate
  /// choice by the link's author, not an absence).
  ///
  /// ⚠️ **This cannot be recovered from the resulting [MapQuery].**
  /// `?when=next_30_days` and no `when` at all produce an identical query
  /// object, so "was it asked for?" has to travel as its own signal. That is
  /// the entire reason this field exists.
  ///
  /// Only `what` and `when` can appear:
  /// - `tema` lights off `MapQuery.facetFilters.length`, not this set, so a
  ///   facet needs no entry here (adding one would be inert, not wrong);
  /// - `who` has no param in this vocabulary (list mode drives it via
  ///   `MapQuery.isListMode` — PROD-4126).
  final Set<MapFilterTab> touchedTabs;

  /// Whether anything at all was preselected. The map skips every deep-link
  /// path when false, so a plain `/map` stays byte-identical to today.
  bool get isEmpty => !hasFilters && !hasCamera;

  bool get isNotEmpty => !isEmpty;

  /// Whether any **query filter** was preselected — deliberately separate from
  /// [hasCamera], which changes the camera and nothing else.
  ///
  /// The distinction is not cosmetic: `MapQuery` has no value equality, so
  /// `copyWith` with every argument null still yields a *new* object, and
  /// `StateNotifier` notifies on any non-identical assignment. A camera-only
  /// link like `/map?lat=…&lng=…` would therefore write an equivalent query,
  /// wake `MapPinsNotifier`, and — on an already-mounted map, where a centre
  /// already exists — fire a `/map/pins` for the **old** area moments before
  /// the camera move requests the new one.
  ///
  /// Found by codex review. The in-flight cancel means only one request ever
  /// *completes*, which is why it was invisible; it is still a wasted round
  /// trip and a spuriously stamped `'deep_link'` trigger.
  bool get hasFilters =>
      type != null || date != null || facetFilters != null || keyword != null;

  /// Whether a usable centre came out of the URL. Requires **both** coordinates
  /// — a lone `lat` is meaningless and is dropped rather than half-applied.
  bool get hasCamera => centerLat != null && centerLng != null;

  /// Value equality, and it is load-bearing rather than decorative:
  /// `MapScreen.didUpdateWidget` uses it to tell "a new link arrived" from "the
  /// tree rebuilt". The route builds a fresh instance on **every** rebuild, so
  /// an identity comparison would re-apply the same filters — and each
  /// re-application is a `/map/pins` request.
  @override
  bool operator ==(Object other) =>
      other is MapDeepLinkParams &&
      other.type == type &&
      other.date == date &&
      other.customRange == customRange &&
      setEquals(other.facetFilters, facetFilters) &&
      other.keyword == keyword &&
      other.centerLat == centerLat &&
      other.centerLng == centerLng &&
      other.radiusMeters == radiusMeters &&
      setEquals(other.touchedTabs, touchedTabs);

  @override
  int get hashCode => Object.hash(
    type,
    date,
    customRange,
    facetFilters == null ? null : Object.hashAllUnordered(facetFilters!),
    keyword,
    centerLat,
    centerLng,
    radiusMeters,
    Object.hashAllUnordered(touchedTabs),
  );

  /// Parse the raw query values into a validated, fully-resolved set of
  /// preselections. Total: every malformed input resolves to an absent field.
  static MapDeepLinkParams parse(Map<String, String?> raw) {
    final type = _parseType(raw['entity']);

    // A2 — an explicit range beats a named window when both are present.
    final range = _parseRange(raw['from'], raw['to']);
    final named = range == null ? _parseWhen(raw['when']) : null;
    final dateAsked = range != null || named != null;

    // B1 — dates are events-only. A date sent with a venues-only query is
    // dropped here rather than carried and ignored downstream, so `date` means
    // "applied" everywhere below it, and the B3 tab set falls out for free.
    final dateApplies = dateAsked && type != MapItemType.places;

    final facets = _parseFacets(raw['tema']);
    final keyword = _parseKeyword(raw['q']);
    final lat = _parseLat(raw['lat']);
    final lng = _parseLng(raw['lng']);
    final hasCamera = lat != null && lng != null;

    return MapDeepLinkParams(
      type: type,
      date: dateApplies ? (range != null ? MapDateFilter.custom : named) : null,
      customRange: dateApplies ? range : null,
      facetFilters: facets,
      keyword: keyword,
      centerLat: hasCamera ? lat : null,
      centerLng: hasCamera ? lng : null,
      radiusMeters: hasCamera ? _parseRadius(raw['radius']) : null,
      touchedTabs: {
        if (type != null) MapFilterTab.what,
        if (dateApplies) MapFilterTab.when,
      },
    );
  }

  static MapItemType? _parseType(String? v) => switch (v) {
    'event' => MapItemType.events,
    'venue' => MapItemType.places,
    _ => null,
  };

  static MapDateFilter? _parseWhen(String? v) =>
      v == null ? null : kMapWhenWire[v];

  /// An explicit `from`/`to` window. Both are required, both must parse, and
  /// `from` must not be after `to` — anything else is dropped whole (A6). The
  /// end is pushed to the end of its day so `from=X&to=X` means "all of X"
  /// rather than a zero-width window that matches nothing.
  static DateTimeRange? _parseRange(String? from, String? to) {
    if (from == null || to == null) return null;
    final start = _parseYmd(from);
    final end = _parseYmd(to);
    if (start == null || end == null) return null;
    final endExclusive = end.add(const Duration(days: 1));
    if (!endExclusive.isAfter(start)) return null;
    return DateTimeRange(start: start, end: endExclusive);
  }

  /// A strict `yyyy-mm-dd` calendar date, or null.
  ///
  /// **`DateTime.tryParse` is not usable here**, and the reason is worse than
  /// "it is lenient": it *overflows silently into a different date*, so a typo
  /// does not fail — it succeeds at something else. Measured on Dart 3.10.9:
  ///
  ///   `2026-02-31` → 2026-03-03  ·  `2026-09-99` → 2026-12-08
  ///   `2026-13-01` → **2027**-01-01  ·  `2026-00-10` → **2025**-12-10
  ///
  /// A mistyped month therefore rolls the **year**, and the map would filter a
  /// window nobody asked for while looking perfectly healthy. That is precisely
  /// the silently-wrong-filter this contract exists to prevent, and it matters
  /// more once PROD-4125 lets a server-supplied string reach here.
  ///
  /// Round-tripping the components is what makes it strict: construct the
  /// `DateTime`, then require it to still hold the numbers we fed it. Anything
  /// the calendar had to normalise comes back different and is dropped.
  /// (Found by codex review.)
  static DateTime? _parseYmd(String v) {
    final m = _kYmd.firstMatch(v.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final parsed = DateTime(y, mo, d);
    if (parsed.year != y || parsed.month != mo || parsed.day != d) return null;
    return parsed;
  }

  /// `eat_drink/restaurants,music` → `{(eat_drink, restaurants), (music, null)}`.
  ///
  /// Slugs are **server vocabulary** (`GET /discovery/facets`) and are passed
  /// through opaquely — the app deliberately holds no enum of them, so a facet
  /// added backend-side works with no release. An entry the server does not
  /// know simply returns nothing for that facet; that is the backend's call to
  /// make, not ours to pre-empt.
  ///
  /// Returns null (rather than an empty set) when nothing usable is present, so
  /// "no `tema` param" and "`tema=,,`" both leave the query's facets untouched
  /// instead of clearing them.
  static Set<FacetPair>? _parseFacets(String? v) {
    if (v == null) return null;
    // Dropped whole rather than truncated, unlike the keyword: cutting a facet
    // list mid-slug would leave a *partial* slug that can still be slug-shaped
    // (`arts_cult`), i.e. a silently wrong filter — the one outcome this
    // contract will not produce. A 2 KB `tema` is not a real link.
    if (v.length > kMapDeepLinkMaxRawValueLen) return null;
    if (v.trim().isEmpty) return null;
    final out = <FacetPair>{};
    for (final part in v.split(',')) {
      if (out.length >= kMapDeepLinkMaxFacets) break;
      final t = part.trim();
      if (t.isEmpty) continue;
      final slash = t.indexOf('/');
      if (slash < 0) {
        final parent = _validSlug(t);
        if (parent != null) out.add(FacetPair(parent: parent));
        continue;
      }
      final parent = _validSlug(t.substring(0, slash).trim());
      final rawChild = t.substring(slash + 1).trim();
      // A parentless pair is meaningless (`/bars`) — the wire requires a
      // parent, so drop it rather than send something that 422s.
      if (parent == null) continue;
      final child = rawChild.isEmpty ? null : _validSlug(rawChild);
      // A present-but-invalid child is dropped WITH its pair rather than
      // silently widened to the whole parent: `eat_drink/<garbage>` asked for
      // something narrower than `eat_drink`, and answering the broader question
      // is a wrong answer, not a lenient one.
      if (rawChild.isNotEmpty && child == null) continue;
      out.add(FacetPair(parent: parent, child: child));
    }
    return out.isEmpty ? null : out;
  }

  /// A facet slug, or null if it cannot be one.
  ///
  /// Slugs stay **opaque** — the app holds no enum of them, so a facet added
  /// backend-side works with no release. This checks only shape, never
  /// membership: lowercase alphanumerics plus `_`/`-`, within
  /// [kMapDeepLinkMaxSlugLen]. Every slug the catalog actually uses
  /// (`eat_drink`, `arts_culture`, `restaurants`) passes, so the whitelist
  /// costs no forward-compatibility while stopping a server-supplied blob from
  /// reaching `/map/pins`. (Hardening from codex review.)
  static String? _validSlug(String s) {
    if (s.isEmpty || s.length > kMapDeepLinkMaxSlugLen) return null;
    return _kSlug.hasMatch(s) ? s : null;
  }

  /// Truncated rather than dropped past the cap: a keyword is free text, and a
  /// user whose long query is shortened still gets a sensible search, whereas
  /// dropping it entirely silently widens the result set.
  static String? _parseKeyword(String? v) {
    if (v == null) return null;
    // Bound the RAW value before trimming: `trim()` scans the whole string, so
    // testing its length afterwards bounds the result but not the work.
    // Truncation is safe here in a way it is not for facets — a shortened
    // free-text query is a narrower search, not a different one.
    final raw = v.length > kMapDeepLinkMaxRawValueLen
        ? v.substring(0, kMapDeepLinkMaxRawValueLen)
        : v;
    final t = raw.trim();
    if (t.isEmpty) return null;
    return t.length <= kMapDeepLinkMaxKeywordLen
        ? t
        : t.substring(0, kMapDeepLinkMaxKeywordLen).trim();
  }

  static double? _parseLat(String? v) {
    final d = v == null ? null : double.tryParse(v);
    if (d == null || d.isNaN || d < -90 || d > 90) return null;
    return d;
  }

  static double? _parseLng(String? v) {
    final d = v == null ? null : double.tryParse(v);
    if (d == null || d.isNaN || d < -180 || d > 180) return null;
    return d;
  }

  /// A5 — **clamped, not rejected.** An out-of-range radius still opens the map
  /// at the nearest legal value; only an unparseable one falls back to the
  /// default. Mirrors the clamp `MapApi` applies on the wire, so the opening
  /// zoom frames the area the first request actually queries.
  static double? _parseRadius(String? v) {
    final d = v == null ? null : double.tryParse(v);
    if (d == null || d.isNaN) return null;
    return d.clamp(kMapDeepLinkMinRadiusM, kMapDeepLinkMaxRadiusM);
  }
}

/// The `when` vocabulary — URL spelling → [MapDateFilter].
///
/// Snake-case rather than the Dart enum's camelCase because a URL is read by
/// people and written by campaign tooling, neither of which should have to know
/// Dart's naming. [MapDateFilter.custom] is deliberately absent: an explicit
/// window is expressed with `from`/`to`, so there is exactly one way to say
/// each thing.
const Map<String, MapDateFilter> kMapWhenWire = {
  'today': MapDateFilter.today,
  'tomorrow': MapDateFilter.tomorrow,
  'this_week': MapDateFilter.thisWeek,
  'this_weekend': MapDateFilter.thisWeekend,
  'next_week': MapDateFilter.nextWeek,
  'next_30_days': MapDateFilter.next30Days,
};

/// The API's radius window (`MapPinsRequest.radius_meters`), mirrored so a
/// deep-linked camera cannot ask for an area the first fetch would clamp.
const double kMapDeepLinkMinRadiusM = 100;
const double kMapDeepLinkMaxRadiusM = 50000;

/// Input bounds. These exist because PROD-4125 makes the values
/// **server-supplied**: without them a feed banner could hand the app a
/// multi-megabyte keyword or ten thousand facet parts, all of which the parser
/// would dutifully forward to `/map/pins`. Generous enough that no real link
/// meets them. (Hardening from codex review.)
const int kMapDeepLinkMaxFacets = 20;
const int kMapDeepLinkMaxSlugLen = 64;
const int kMapDeepLinkMaxKeywordLen = 200;

/// Ceiling on a **raw** query value, checked before any splitting or trimming.
///
/// The output caps above bound what reaches `/map/pins`; this bounds what the
/// parser *does*. Without it `v.split(',')` allocates every segment before the
/// facet loop can stop, and `v.trim()` scans the whole string before its length
/// is tested — so the caps read as bounds while the work stayed unbounded.
/// (Second-round codex finding.)
///
/// Honest about severity: the string is already in memory (the URL was parsed
/// to get here), so this is amplification, not a new DoS vector. It is here
/// because a stated bound should be true. 2048 is far above any real link — 20
/// facets at 64 chars is 1300 — so nothing legitimate meets it.
const int kMapDeepLinkMaxRawValueLen = 2048;

/// A strict `yyyy-mm-dd`. Anchored, and digits only — see [MapDeepLinkParams].
final RegExp _kYmd = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Facet slug shape (never membership — the catalog is server-side).
final RegExp _kSlug = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

/// Every query key `/map` understands. The route reads exactly these, which is
/// what makes an unknown key a no-op rather than an error (A6).
///
/// `list`, `area` and `city` are **not** here yet — they arrive with PROD-4126
/// and PROD-4127. When they do, they take precedence over `lat`/`lng` per card
/// A7 (`list` > `area` > `lat`/`lng`).
const List<String> kMapDeepLinkParamKeys = [
  'entity',
  'when',
  'from',
  'to',
  'tema',
  'q',
  'lat',
  'lng',
  'radius',
];
