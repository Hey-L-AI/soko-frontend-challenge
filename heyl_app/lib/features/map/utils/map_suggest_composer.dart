/// PROD-3497 — pure composition of the v2 map-search typed dropdown.
///
/// Turns the two suggestion sources (BE `/map/suggest` buckets + client-side
/// `/geo/areas` location predictions) plus the expansion state into the flat
/// ordered entry list the dropdown renders. All rules are locked umbrella
/// decisions (PROD-3434): top slot (#38–#40), pinned general row (#13),
/// dynamic domain order with locations always last (#14 + Zé 2026-07-28),
/// per-domain caps + inline expanders (#8/#15, C5a), zero-matches → general
/// row only (#17), quiet failure row (B6/B7).
///
/// Pure functions only — no Riverpod, no I/O — so every composition rule is
/// unit-testable in isolation.
library;

import '../../../data/models/area_prediction.dart';
import '../../../data/models/map_suggest.dart';

/// Collapsed blocks with more than [kMapSuggestCollapsedThreshold] matches
/// show [kMapSuggestCollapsedVisible] rows + the expander (Decision #8).
const int kMapSuggestCollapsedThreshold = 3;
const int kMapSuggestCollapsedVisible = 2;

/// Inline expansion cap — up to 10 rows even if more exist (C5a).
const int kMapSuggestExpandedMax = 10;

/// PROD-3498 — whether the **lists (Zine) domain** is offered at all.
///
/// **ON since PROD-3568.** It was off for one reason only: selecting a list had
/// nowhere to go, because list-on-map mode (Decision #20) needs `/map/pins`
/// list scoping and `scope` was `all`/`yours`/`following`. A list row would
/// then have been the one dead row in the dropdown — worse than an absent
/// domain.
///
/// Everything it was waiting for has landed: the backend scope (PROD-3560),
/// the query seam (PROD-3565), execution + camera fit (PROD-3566) and the
/// "De quem?" chrome (PROD-3567). Kept as a constant rather than deleted so
/// the domain can be withdrawn in one line if it misbehaves in the wild, and
/// because the composer tests assert BOTH arms through it.
const bool kMapSuggestShowLists = true;

/// Sections the dropdown currently offers. Filters [kMapSuggestShowLists].
bool sectionIsOffered(MapSuggestSection section) =>
    kMapSuggestShowLists || section != MapSuggestSection.lists;

/// The four dropdown sections: the three BE domains + client-side locations.
enum MapSuggestSection { venues, events, lists, locations }

MapSuggestSection sectionForDomain(MapSuggestDomain domain) => switch (domain) {
  MapSuggestDomain.venues => MapSuggestSection.venues,
  MapSuggestDomain.events => MapSuggestSection.events,
  MapSuggestDomain.lists => MapSuggestSection.lists,
};

/// PROD-3652 — the inverse of [sectionForDomain]: the `/map/suggest` domain a
/// tag maps to, or **null for locations**.
///
/// Null is not "no scope" here — it is the load-bearing asymmetry of this
/// feature. Locations are composed client-side from `/geo/areas` + the deep
/// `/geo/search`, so scoping to them means *skipping* the backend call, not
/// parameterising it. Every caller must branch on the null rather than passing
/// it through as an omitted filter, which would silently mean "unscoped".
MapSuggestDomain? domainForSection(MapSuggestSection section) =>
    switch (section) {
      MapSuggestSection.venues => MapSuggestDomain.venues,
      MapSuggestSection.events => MapSuggestDomain.events,
      MapSuggestSection.lists => MapSuggestDomain.lists,
      MapSuggestSection.locations => null,
    };

/// One rendered dropdown row. The dropdown maps each entry to a fixed-height
/// row widget; FE‑3 (PROD-3498) attaches execution semantics per variant.
sealed class MapSuggestEntry {
  const MapSuggestEntry();
}

/// Top-slot repeat of the single BE top hit (Decision #38/#39 — the item
/// also stays inside its domain block).
class MapSuggestTopHitEntry extends MapSuggestEntry {
  const MapSuggestTopHitEntry(this.item);

  final MapSuggestItem item;
}

/// Top-slot repeat of the FE-computed location top hit (Decision #40 —
/// additive; never displaces the BE top hit).
class MapSuggestLocationTopHitEntry extends MapSuggestEntry {
  const MapSuggestLocationTopHitEntry(this.prediction);

  final AreaPrediction prediction;
}

/// The pinned "Search events or venues related to 'X'" row (Decision #13 —
/// keyword search never runs automatically; hidden while a block is
/// expanded).
class MapSuggestGeneralSearchEntry extends MapSuggestEntry {
  const MapSuggestGeneralSearchEntry(this.query);

  final String query;
}

/// A venue/event/list suggestion row inside its domain block.
class MapSuggestItemEntry extends MapSuggestEntry {
  const MapSuggestItemEntry(this.domain, this.item);

  final MapSuggestDomain domain;
  final MapSuggestItem item;
}

/// A location suggestion row (client-composed domain).
class MapSuggestLocationEntry extends MapSuggestEntry {
  const MapSuggestLocationEntry(this.prediction);

  final AreaPrediction prediction;
}

/// Arrow-led "view other {section}…" row (Decision #8/#15). For
/// [MapSuggestSection.locations] tapping it ALSO triggers the deep
/// `/geo/search` (the only two-tier domain).
class MapSuggestExpanderEntry extends MapSuggestEntry {
  const MapSuggestExpanderEntry(this.section);

  final MapSuggestSection section;
}

/// The collapse line under an expanded block (C5a).
class MapSuggestCollapseEntry extends MapSuggestEntry {
  const MapSuggestCollapseEntry(this.section);

  final MapSuggestSection section;
}

/// PROD-3662 — the muted marker above the locations block while a scope is
/// active (Decision #55, which amends #26's no-headers rule for this one row).
///
/// Locations are the one domain a corpus scope **cannot** bound: they're
/// composed client-side from the geo provider, and a place belongs to no Zine.
/// Without this line the scope banner would be making a promise about rows it
/// doesn't cover. Never emitted unbounded — there is nothing to disclaim.
class MapSuggestLocationsScopeMarkerEntry extends MapSuggestEntry {
  const MapSuggestLocationsScopeMarkerEntry();
}

/// Quiet "Couldn't search — tap to retry" row (B6/B7): rendered once when
/// any source failed AND has nothing to show; tap re-fires the failed
/// lanes. Sources that failed but still have stale rows keep showing them
/// instead (quiet degradation).
class MapSuggestRetryEntry extends MapSuggestEntry {
  const MapSuggestRetryEntry();
}

/// Compose the dropdown for a ≥2-char query. The widget layer owns the
/// 0-char (history/explainer) and 1-char (nothing) ladder states (#36).
///
/// [backend] is the LAST GOOD response (B3 — may lag the live query while a
/// fetch is in flight; the caller keeps it visible). [backendTransportFailed]
/// = the latest completed attempt failed wholesale; per-domain engine
/// failures ride in `backend.failedDomains`. [expanded] holds the inline-
/// expanded sections; expansion hides the general row (#13).
/// [scopeBounded] (PROD-3662) = the map's corpus is narrower than all of Soko,
/// so `/map/suggest` returned only in-corpus rows. It adds exactly one thing
/// here — the marker above the (still global) locations block. Everything else
/// it changes is copy, which lives in the widget layer. **Zero matches under a
/// scope stays Decision #17**: the general row alone, no "no results" message —
/// suggest is a NAME match while that row runs the full keyword search, so an
/// empty dropdown never licenses the claim that the corpus is empty.
/// Defaults to false, which is the unbounded corpus and today's behaviour.
///
/// [domainScope] (PROD-3652) = the selected domain tag, or null for the
/// unscoped dropdown. **Do not confuse it with [scopeBounded]**: that one is
/// the CORPUS (whose stuff — a Zine, yours, everyone's); this one is the
/// DOMAIN (what kind of thing). They are orthogonal and compose — a user can
/// be inside a Zine *and* scoped to Events — so the corpus chrome is emitted
/// in both arms.
///
/// A scoped view is a different shape, not a filtered one:
///
/// - **no top slot.** The backend suppresses `is_top_hit` when scoped because
///   the unambiguity gap is cross-domain by construction; the FE-computed
///   location top hit (#40) is suppressed here for exactly that reason.
/// - **no expander, no collapse.** `has_more` is always false when scoped (25
///   is a product ceiling with no deeper tier), so an expander could never
///   fetch anything — and [_addBlock] would cap the block at
///   [kMapSuggestExpandedMax], silently discarding 15 of the 25 the tag was
///   tapped to reveal. **The tag IS the expansion.**
/// - **the general row stays.** Execution is untouched by the tag, so it
///   remains the dropdown's one guaranteed action (#13).
List<MapSuggestEntry> composeMapSuggestDropdown({
  required String query,
  required MapSuggestResponse? backend,
  required bool backendTransportFailed,
  required List<AreaPrediction> locations,
  required bool locationsFailed,
  required Set<MapSuggestSection> expanded,
  bool scopeBounded = false,
  MapSuggestSection? domainScope,
}) {
  final entries = <MapSuggestEntry>[];
  final suggesting = query.trim().length >= 3;
  if (domainScope != null) {
    return _composeDomainScoped(
      entries: entries,
      query: query,
      suggesting: suggesting,
      domainScope: domainScope,
      backend: backend,
      backendTransportFailed: backendTransportFailed,
      locations: locations,
      locationsFailed: locationsFailed,
      scopeBounded: scopeBounded,
    );
  }

  // ---- Top slot (#38/#39/#40) — only meaningful once suggestions run.
  MapSuggestItem? beTopHit;
  if (suggesting && backend != null) {
    for (final domain in MapSuggestDomain.values) {
      if (!sectionIsOffered(sectionForDomain(domain))) continue;
      for (final item in backend.bucketFor(domain).items) {
        if (item.isTopHit) {
          beTopHit = item;
          break;
        }
      }
      if (beTopHit != null) break;
    }
  }
  final locationTopHit = suggesting
      ? computeLocationTopHit(query, locations)
      : null;
  if (beTopHit != null) entries.add(MapSuggestTopHitEntry(beTopHit));
  // PROD-3662 — the marker attaches to the FIRST location row, wherever that
  // is. A floated top hit (#40) sits above the general row and the domain
  // blocks, so marking only the block below would leave the one location row
  // most people actually see undisclaimed under a banner promising a corpus it
  // isn't in. Emitted once, like any section header. (Codex review.)
  var locationsMarked = false;
  if (locationTopHit != null) {
    if (scopeBounded) {
      entries.add(const MapSuggestLocationsScopeMarkerEntry());
      locationsMarked = true;
    }
    entries.add(MapSuggestLocationTopHitEntry(locationTopHit));
  }

  // ---- Pinned general row (#13) — hidden while any block is expanded.
  // Only sections that currently RENDER rows count as expanded: a stale
  // expansion (e.g. the locations deep search came back empty, or a
  // refetch emptied a bucket) must neither suppress the general row —
  // the dropdown's one guaranteed action — nor leave an un-collapsible
  // phantom block. (Codex review, PR #1229.)
  bool sectionHasRows(MapSuggestSection section) =>
      sectionIsOffered(section) &&
      switch (section) {
        MapSuggestSection.locations => locations.isNotEmpty,
        MapSuggestSection.venues => backend?.venues.items.isNotEmpty ?? false,
        MapSuggestSection.events => backend?.events.items.isNotEmpty ?? false,
        MapSuggestSection.lists => backend?.lists.items.isNotEmpty ?? false,
      };
  final activeExpanded = <MapSuggestSection>{
    for (final section in expanded)
      if (suggesting && sectionHasRows(section)) section,
  };
  if (activeExpanded.isEmpty) {
    entries.add(MapSuggestGeneralSearchEntry(query.trim()));
  }

  if (!suggesting) return entries;

  // ---- Domain blocks: BE domains ordered by best score (#14, shared
  // scorer makes scores comparable), locations always last (Zé 2026-07-28
  // — geo predictions carry no comparable score).
  final beDomains =
      MapSuggestDomain.values
          .where(
            (d) =>
                sectionIsOffered(sectionForDomain(d)) &&
                ((backend?.bucketFor(d).items.isNotEmpty) ?? false),
          )
          .toList()
        ..sort(
          (a, b) => _bestScore(backend!, b).compareTo(_bestScore(backend, a)),
        );

  for (final domain in beDomains) {
    final section = sectionForDomain(domain);
    final items = backend!.bucketFor(domain).items;
    _addBlock(
      entries,
      section,
      items.length,
      activeExpanded.contains(section),
      (i) => MapSuggestItemEntry(domain, items[i]),
    );
  }

  if (locations.isNotEmpty) {
    // Decision #55 — disclaim the one block the scope doesn't reach, directly
    // above it so it reads as that block's header and not as a global note.
    // Skipped when the top slot already carried it (see `locationsMarked`).
    if (scopeBounded && !locationsMarked) {
      entries.add(const MapSuggestLocationsScopeMarkerEntry());
    }
    _addBlock(
      entries,
      MapSuggestSection.locations,
      locations.length,
      activeExpanded.contains(MapSuggestSection.locations),
      (i) => MapSuggestLocationEntry(locations[i]),
    );
  }

  // ---- Quiet failure row (B6/B7): one row when any failed source has
  // nothing on screen. A failed source with stale rows keeps them instead.
  final beFailedEmpty =
      (backendTransportFailed && backend == null) ||
      (backend != null &&
          backend.failedDomains.isNotEmpty &&
          MapSuggestDomain.values.any(
            (d) =>
                sectionIsOffered(sectionForDomain(d)) &&
                backend.domainFailed(d) &&
                backend.bucketFor(d).items.isEmpty,
          ));
  final locationsFailedEmpty = locationsFailed && locations.isEmpty;
  if (beFailedEmpty || locationsFailedEmpty) {
    entries.add(const MapSuggestRetryEntry());
  }

  return entries;
}

/// PROD-3652 — the domain-scoped arm. See [composeMapSuggestDropdown] for why
/// this is a different shape rather than a filter over the unscoped one.
///
/// Exactly one block renders, and it renders **whole** — no `_addBlock`, so no
/// collapsed-threshold trimming and no [kMapSuggestExpandedMax] ceiling. That
/// bypass is the point of the ticket: the backend serves up to 25 when scoped,
/// and the collapsed path would have shown 2 of them behind an expander that
/// tops out at 10.
List<MapSuggestEntry> _composeDomainScoped({
  required List<MapSuggestEntry> entries,
  required String query,
  required bool suggesting,
  required MapSuggestSection domainScope,
  required MapSuggestResponse? backend,
  required bool backendTransportFailed,
  required List<AreaPrediction> locations,
  required bool locationsFailed,
  required bool scopeBounded,
}) {
  final isLocations = domainScope == MapSuggestSection.locations;

  // No top slot (see the doc comment) — the pinned general row is the first
  // thing in a scoped view, and #13's "hidden while a block is expanded"
  // carve-out cannot apply because nothing is expandable here.
  entries.add(MapSuggestGeneralSearchEntry(query.trim()));

  if (!suggesting) return entries;

  if (isLocations) {
    if (locations.isNotEmpty) {
      // Decision #55 still holds, and holds harder: a corpus scope reaches
      // locations even less than it reaches anything else, so a view made
      // ENTIRELY of locations must carry the disclaimer.
      if (scopeBounded) {
        entries.add(const MapSuggestLocationsScopeMarkerEntry());
      }
      for (final prediction in locations) {
        entries.add(MapSuggestLocationEntry(prediction));
      }
    }
    // The backend lane never ran under this tag (`_runLane` skips it), so it
    // cannot have failed and must not be consulted here.
    if (locationsFailed && locations.isEmpty) {
      entries.add(const MapSuggestRetryEntry());
    }
    return entries;
  }

  final domain = domainForSection(domainScope)!;
  final items = backend?.bucketFor(domain).items ?? const <MapSuggestItem>[];
  for (final item in items) {
    entries.add(MapSuggestItemEntry(domain, item));
  }

  // Judged over the scoped domain ALONE. The other two buckets come back empty
  // by contract, and `failed_domains` reports only attempted domains — so
  // consulting them would be reading fields the request never asked to be
  // filled.
  //
  // The transport arm deliberately does NOT require `backend == null`, unlike
  // the unscoped path. B6 keeps a failed source's STALE ROWS instead of a retry
  // row — but `items.isEmpty` already establishes there are none for this
  // domain, and a stale response from a *different* scope can leave `backend`
  // non-null with this bucket empty. Requiring null there would render the
  // general row alone after a failed fetch: no rows, no retry, and
  // `map_suggest_zero_results` suppressed by `backendFailed` — a failure with
  // no signal anywhere. (Codex review, round 2.)
  final failedEmpty =
      items.isEmpty &&
      (backendTransportFailed || (backend?.domainFailed(domain) ?? false));
  if (failedEmpty) entries.add(const MapSuggestRetryEntry());

  return entries;
}

double _bestScore(MapSuggestResponse backend, MapSuggestDomain domain) {
  var best = 0.0;
  for (final item in backend.bucketFor(domain).items) {
    if (item.score > best) best = item.score;
  }
  return best;
}

void _addBlock(
  List<MapSuggestEntry> entries,
  MapSuggestSection section,
  int length,
  bool isExpanded,
  MapSuggestEntry Function(int index) rowAt,
) {
  if (isExpanded) {
    final visible = length < kMapSuggestExpandedMax
        ? length
        : kMapSuggestExpandedMax;
    for (var i = 0; i < visible; i++) {
      entries.add(rowAt(i));
    }
    entries.add(MapSuggestCollapseEntry(section));
  } else if (length > kMapSuggestCollapsedThreshold) {
    for (var i = 0; i < kMapSuggestCollapsedVisible; i++) {
      entries.add(rowAt(i));
    }
    entries.add(MapSuggestExpanderEntry(section));
  } else {
    for (var i = 0; i < length; i++) {
      entries.add(rowAt(i));
    }
  }
}

// ---------------------------------------------------------------------------
// Decision #40 — FE-side location top hit
// ---------------------------------------------------------------------------

/// Portuguese connective stopwords: name tokens that need not be consumed
/// for a location to qualify (Decision #40).
const Set<String> _kStopwords = {'de', 'da', 'do', 'das', 'dos', 'e'};

/// The single unambiguous near-exact location match, or null (Decision #40,
/// confirmed by Zé 2026-07-28):
///
/// - normalize query + name (lowercase, strip diacritics), tokenize;
/// - every query token matches a distinct name token EXACTLY, except the
///   LAST query token which may match as a prefix;
/// - every non-stopword name token must be consumed;
/// - more than one qualifying prediction → ambiguous → none floats;
/// - no client-side typo tolerance (v1).
AreaPrediction? computeLocationTopHit(
  String query,
  List<AreaPrediction> predictions,
) {
  final queryTokens = _tokenize(query);
  if (queryTokens.isEmpty) return null;

  AreaPrediction? qualifying;
  for (final prediction in predictions) {
    if (!_qualifies(queryTokens, _tokenize(prediction.name))) continue;
    if (qualifying != null) return null; // >1 qualifying → ambiguous.
    qualifying = prediction;
  }
  return qualifying;
}

bool _qualifies(List<String> queryTokens, List<String> nameTokens) {
  if (nameTokens.isEmpty) return false;
  final consumed = List<bool>.filled(nameTokens.length, false);
  if (!_assign(queryTokens, 0, nameTokens, consumed)) return false;
  for (var i = 0; i < nameTokens.length; i++) {
    if (!consumed[i] && !_kStopwords.contains(nameTokens[i])) return false;
  }
  return true;
}

/// Backtracking assignment of query tokens to distinct name tokens (token
/// counts are tiny, so this stays trivial). The last query token
/// prefix-matches; all earlier ones must match exactly.
bool _assign(
  List<String> queryTokens,
  int queryIndex,
  List<String> nameTokens,
  List<bool> consumed,
) {
  if (queryIndex == queryTokens.length) return true;
  final token = queryTokens[queryIndex];
  final isLast = queryIndex == queryTokens.length - 1;
  for (var i = 0; i < nameTokens.length; i++) {
    if (consumed[i]) continue;
    final matches = isLast
        ? nameTokens[i].startsWith(token)
        : nameTokens[i] == token;
    if (!matches) continue;
    consumed[i] = true;
    if (_assign(queryTokens, queryIndex + 1, nameTokens, consumed)) {
      return true;
    }
    consumed[i] = false;
  }
  return false;
}

List<String> _tokenize(String raw) => _stripDiacritics(raw.toLowerCase())
    .split(RegExp(r'[^a-z0-9]+'))
    .where((t) => t.isNotEmpty)
    .toList(growable: false);

const Map<String, String> _kDiacritics = {
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ç': 'c',
  'ñ': 'n',
  'ý': 'y',
};

String _stripDiacritics(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_kDiacritics[char] ?? char);
  }
  return buffer.toString();
}
