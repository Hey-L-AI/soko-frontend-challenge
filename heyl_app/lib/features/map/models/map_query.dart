import 'package:flutter/material.dart';

import '../../../data/models/map_pin.dart';

// PROD-2671 — the **durable seam** of the Map page (Decision #1).
//
// `MapQuery` is the single source of truth the data layer reads. The
// filter UI only ever reads/writes this model, so the (deferred) final
// filter design — 3-group vs "4 perguntas", labels, layout — can change
// without touching the query/fetch logic.

/// Where the map's items come from — the `/map/pins` `scope` (PROD-2737).
/// All three go through the **same radius-based `/map/pins` path** (identical
/// response shape, distance order, 300 cap) + settle-to-search, and all
/// render/fetch at any zoom — there is **no zoom floor** (the custom grid
/// selection + `+k` overflow bubbles + the 300-cap keep even a wide view
/// readable; PROD-2807).
///
/// - [yours] — the user's saved items (owned lists). Requires an authenticated
///   (non-guest) user; a guest gets 422 `scope_requires_auth`.
/// - [following] — items in followed public lists. Same auth requirement.
/// - [all] — "Tudo na Soko": the global discovery corpus (the default).
/// - [list] — PROD-3565: the items of ONE specific list ("Zine"), named by
///   [MapQuery.activeListId]. Decision #46 makes a list a **corpus scope**
///   rather than a search, so it joins this enum instead of riding a parallel
///   flag — which is what keeps `selectionCapForSource`, `dotCapFor`,
///   `ignore_radius` and `isDefaultFilters` correct **by construction**
///   (review card B8: "mirror `yours` exactly"). Unlike yours/following it
///   does NOT require an account — public lists are guest-readable.
///
/// [list] is declared **last** deliberately: `_WhoPanel` renders one chip per
/// `MapSource.values`, so appending keeps the existing three in their designed
/// order. That panel skips `list` in the loop and renders the active list
/// separately (PROD-3567) — it is a *selected* option, never a pickable one.
enum MapSource { yours, following, all, list }

/// Which item kinds to plot.
enum MapItemType { all, events, places }

/// Date window for events. Chips (Decision #24): Hoje · Amanhã · Esta semana ·
/// Este fim de semana · Próxima semana · Próximos 30 dias · Outra data.
/// Declaration order = the Quando picker's display order (it iterates
/// [MapDateFilter.values]).
enum MapDateFilter {
  today,
  tomorrow,
  thisWeek,
  thisWeekend,
  nextWeek,
  next30Days,
  custom,
}

@immutable
class MapQuery {
  /// Map centre (from the settled camera, or the seeded user location).
  /// Null until the first location/camera fix — the data layer treats a
  /// null centre as "not ready" and fetches nothing.
  final double? centerLat;
  final double? centerLng;

  /// Search radius in metres (derived from the visible viewport on
  /// settle). Clamped to the API window (100 m – 50 km).
  final double radiusMeters;

  /// Current camera zoom (from the settled camera).
  final double zoom;

  /// PROD-2807 — the settled viewport rectangle (NE + SW corners). The grid
  /// selection picks the on-screen set within this rect. Null until the first
  /// camera settle; the selection falls back to a centre+radius box meanwhile.
  final double? neLat;
  final double? neLng;
  final double? swLat;
  final double? swLng;

  final MapSource source;
  final MapItemType type;
  final MapDateFilter date;

  /// Only meaningful when [date] is [MapDateFilter.custom].
  final DateTimeRange? customRange;

  /// Selected Tema facets — `{parent, child}` pairs sent to `/map/pins` +
  /// `/map/hydrate` as `facet_filters`. Empty = no Tema filter.
  final Set<FacetPair> facetFilters;

  /// Free-text keyword. Composes with the other filters.
  final String keyword;

  /// PROD-3565 — the active list's id when [source] is [MapSource.list].
  /// Sent as `/map/pins` `list_id`; the backend accepts the **UUID or the
  /// slug**, so no resolve step is needed before the call.
  final String? activeListId;

  /// The active list's display name. Carried here purely so the chrome
  /// ("De quem?", PROD-3567) can label the scope without re-fetching the list.
  /// Never sent to the backend.
  final String? activeListName;

  const MapQuery({
    this.centerLat,
    this.centerLng,
    this.radiusMeters = 5000,
    this.zoom = 13,
    this.neLat,
    this.neLng,
    this.swLat,
    this.swLng,
    this.source = MapSource.all,
    this.type = MapItemType.all,
    this.date = MapDateFilter.next30Days,
    this.customRange,
    this.facetFilters = const {},
    this.keyword = '',
    this.activeListId,
    this.activeListName,
  });

  bool get hasCenter => centerLat != null && centerLng != null;

  /// PROD-3565 — whether ONE specific list is the current corpus.
  ///
  /// Requires **both** halves: the scope value AND an id. They are only ever
  /// written together (`setList`/`clearList`), so a half-set state means a bug
  /// upstream — and this getter refusing to call it "list mode" is what stops
  /// that bug reaching the wire as a `scope=list` with no `list_id` (422).
  bool get isListMode => source == MapSource.list && activeListId != null;

  /// Whether the **filter** state (source / type / date / Tema / keyword) is at
  /// its default — i.e. nothing has been narrowed. Ignores the camera fields
  /// ([centerLat]/[zoom]/bounds), which track location, not filtering. Drives
  /// the shortcut row ↔ "Reset all filters" swap (`MapShortcutChips`): default
  /// → show the shortcut chips; non-default → show the reset button.
  bool get isDefaultFilters =>
      source == MapSource.all &&
      type == MapItemType.all &&
      date == MapDateFilter.next30Days &&
      customRange == null &&
      facetFilters.isEmpty &&
      keyword.trim().isEmpty;

  /// Whether a settled viewport rectangle is available for grid selection.
  bool get hasBounds =>
      neLat != null && neLng != null && swLat != null && swLng != null;

  /// Whether the Quando (date) filter has any effect. Dates are an
  /// events-only concept in v0 (venues would need an "open now" model that
  /// isn't built), so a venues-only query ignores the date entirely. The
  /// chosen [date] is still kept in state, so it re-applies the moment events
  /// are included again.
  bool get dateApplies => type != MapItemType.places;

  /// The `/map/pins` `entity` value: 'event' / 'venue' / null (= both).
  String? get entityWire => switch (type) {
    MapItemType.events => 'event',
    MapItemType.places => 'venue',
    MapItemType.all => null,
  };

  /// The `/map/pins` `scope` value: 'yours' / 'following' / 'list' / null
  /// (= `all`, the server default). Omitting for [MapSource.all] keeps the
  /// request body minimal, mirroring [entityWire]'s null-for-both convention.
  ///
  /// Non-null for every **bounded** scope, which is exactly what
  /// `MapPinsNotifier._fetch` keys `ignore_radius` off — so a list gets the
  /// radius gate skipped for free (PROD-3565 pt 3: a curated list may span
  /// cities and should show whole at any zoom).
  /// `list` is gated on [isListMode], not merely on [source]: a half-set state
  /// (`source == list` with no id) would otherwise send `scope=list` with no
  /// `list_id` — the exact 422 [listIdWire] exists to prevent. Gating both
  /// getters on the same predicate keeps the pair inseparable, so the request
  /// degrades to the default corpus instead of erroring.
  String? get scopeWire => switch (source) {
    MapSource.yours => 'yours',
    MapSource.following => 'following',
    MapSource.list => isListMode ? 'list' : null,
    MapSource.all => null,
  };

  /// PROD-3662 — whether the corpus is **narrower than all of Soko**.
  ///
  /// Defined as `scopeWire != null` on purpose rather than `source != all`: the
  /// two differ for the half-set list state, and it is the WIRE that decides
  /// what the user is actually getting. A `source == list` with no id sends no
  /// scope, so the suggestions come back Soko-wide — and a banner claiming
  /// otherwise would be the one thing this feature exists to prevent.
  ///
  /// Drives every scope-aware surface in the typed dropdown (Decisions
  /// #53–#55): the banner, the general row's copy, the locations marker, and
  /// the banner-only 0-char state.
  bool get isScopeBounded => scopeWire != null;

  /// The `/map/pins` `list_id` value — non-null **only** in list mode.
  ///
  /// The backend **422s a `list_id` sent on any other scope** (deliberately: a
  /// silently-ignored one would let the client believe its request was bounded
  /// to a list when it wasn't). Routing every send through this getter rather
  /// than reading [activeListId] directly makes that error unreachable from the
  /// data layer, no matter what the notifier does.
  String? get listIdWire => isListMode ? activeListId : null;

  /// Compact signature of the active filters — the dedup key behind
  /// `map_area_searched`, so a genuine filter change at the same spot still
  /// logs while pure repeat pans collapse (PROD-3219/3500).
  ///
  /// Includes [activeListId] because [source] alone reads `'list'` for *every*
  /// list: without the id, opening a second list at the same camera would be
  /// swallowed as a repeat of the first and never logged (PROD-3565 pt 5).
  ///
  /// Includes [customRange] because [date] alone reads `'custom'` for *every*
  /// hand-picked window: without the dates, moving the window while staying on
  /// "Outra data" changes what the backend returns but leaves the signature
  /// identical (PROD-3656, codex review). That silently swallowed the
  /// `map_area_searched` log, and — since the signature is also the "same
  /// search?" key for the map's pin caches/promotions — would let results from
  /// the previous window survive the change.
  ///
  /// Lives on the model rather than in `MapScreen` so it can be tested without
  /// standing up the whole map screen — it is a pure derivation of this query,
  /// exactly like [scopeWire] and [entityWire].
  String get filterSignature {
    final facets =
        facetFilters.map((f) => '${f.parent}/${f.child ?? ''}').toList()
          ..sort();
    return '${source.name}|${type.name}|${date.name}|$_customRangeKey'
        '|${keyword.trim()}|${facets.join(",")}|${activeListId ?? ''}';
  }

  /// The custom window as `yyyy-mm-dd..yyyy-mm-dd`, or empty when no custom
  /// window is in play. Only meaningful while [date] is [MapDateFilter.custom]
  /// — a stale range parked behind another chip must not split the signature.
  String get _customRangeKey {
    final r = customRange;
    if (date != MapDateFilter.custom || r == null) return '';
    String ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}'
        '-${d.day.toString().padLeft(2, '0')}';
    return '${ymd(r.start)}..${ymd(r.end)}';
  }

  MapQuery copyWith({
    double? centerLat,
    double? centerLng,
    double? radiusMeters,
    double? zoom,
    double? neLat,
    double? neLng,
    double? swLat,
    double? swLng,
    MapSource? source,
    MapItemType? type,
    MapDateFilter? date,
    DateTimeRange? customRange,
    bool clearCustomRange = false,
    Set<FacetPair>? facetFilters,
    String? keyword,
    String? activeListId,
    String? activeListName,
    // `?? this.x` can't express "set to null", so leaving list mode needs an
    // explicit flag — same shape as [clearCustomRange] above.
    bool clearActiveList = false,
  }) {
    return MapQuery(
      centerLat: centerLat ?? this.centerLat,
      centerLng: centerLng ?? this.centerLng,
      radiusMeters: radiusMeters ?? this.radiusMeters,
      zoom: zoom ?? this.zoom,
      neLat: neLat ?? this.neLat,
      neLng: neLng ?? this.neLng,
      swLat: swLat ?? this.swLat,
      swLng: swLng ?? this.swLng,
      source: source ?? this.source,
      type: type ?? this.type,
      date: date ?? this.date,
      customRange: clearCustomRange ? null : (customRange ?? this.customRange),
      facetFilters: facetFilters ?? this.facetFilters,
      keyword: keyword ?? this.keyword,
      activeListId: clearActiveList
          ? null
          : (activeListId ?? this.activeListId),
      activeListName: clearActiveList
          ? null
          : (activeListName ?? this.activeListName),
    );
  }

  /// Resolve [date] (+ [customRange]) to a concrete [DateTimeRange],
  /// anchored on [now]. Used by both the global event search (start/end
  /// date params) and the list-scope calendar loader (from/to window).
  DateTimeRange dateRange(DateTime now) {
    final startOfToday = DateTime(now.year, now.month, now.day);
    switch (date) {
      case MapDateFilter.today:
        return DateTimeRange(
          start: startOfToday,
          end: startOfToday.add(const Duration(days: 1)),
        );
      case MapDateFilter.tomorrow:
        final tomorrow = startOfToday.add(const Duration(days: 1));
        return DateTimeRange(
          start: tomorrow,
          end: tomorrow.add(const Duration(days: 1)),
        );
      case MapDateFilter.thisWeek:
        // Today → the end of the current week (Sunday). End (exclusive) = the
        // upcoming Monday 00:00, which is exactly where [nextWeek] begins — so
        // on Monday this is the full Mon–Sun, on Thursday it's Thu–Sun, on
        // Sunday just today.
        final daysToNextMonday = (DateTime.monday - now.weekday + 7) % 7 == 0
            ? 7
            : (DateTime.monday - now.weekday + 7) % 7;
        return DateTimeRange(
          start: startOfToday,
          end: startOfToday.add(Duration(days: daysToNextMonday)),
        );
      case MapDateFilter.thisWeekend:
        // Upcoming Saturday → end of Sunday (this week's weekend).
        final daysToSaturday = (DateTime.saturday - now.weekday + 7) % 7;
        final sat = startOfToday.add(Duration(days: daysToSaturday));
        return DateTimeRange(start: sat, end: sat.add(const Duration(days: 2)));
      case MapDateFilter.nextWeek:
        final daysToNextMonday = (DateTime.monday - now.weekday + 7) % 7 == 0
            ? 7
            : (DateTime.monday - now.weekday + 7) % 7;
        final mon = startOfToday.add(Duration(days: daysToNextMonday));
        return DateTimeRange(start: mon, end: mon.add(const Duration(days: 7)));
      case MapDateFilter.next30Days:
        return DateTimeRange(
          start: startOfToday,
          end: startOfToday.add(const Duration(days: 30)),
        );
      case MapDateFilter.custom:
        return customRange ??
            DateTimeRange(
              start: startOfToday,
              end: startOfToday.add(const Duration(days: 7)),
            );
    }
  }
}
