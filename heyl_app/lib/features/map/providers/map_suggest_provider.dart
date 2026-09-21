import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../data/models/area_prediction.dart';
import '../../../data/models/map_suggest.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/locale_provider.dart';
import '../utils/map_suggest_composer.dart';
import '../widgets/area_search_controller.dart';
import '../widgets/map_domain_tags.dart' show mapDomainTagIsOffered;
import '../widgets/map_suggest_rows.dart'
    show MapSuggestScopeKind, mapSuggestScopeKindOf;
import 'map_query_provider.dart';
import 'map_search_provider.dart';

/// PROD-3497 — orchestration for the v2 map-search typed dropdown.
///
/// Watches the focused-search text ([mapSearchProvider], which mirrors
/// keystrokes with no debounce by design) and drives the two suggestion
/// sources in parallel, each with its own 300 ms debounce + generation
/// guard + cancellation (B2/B5):
///
/// - **Backend lane** — `POST /map/suggest` (venues/events/lists) from ≥3
///   trimmed chars (#36). The last GOOD response stays visible while a new
///   fetch is in flight (B3) and after a failure (B6 quiet degradation).
/// - **Locations lane** — a reused [AreaSearchController] (`minChars: 3`,
///   same debounce/guard/session-token machinery as the location picker)
///   over `GET /geo/areas`; expanding the locations block fires the deep
///   `POST /geo/search` via [AreaSearchController.submitQuery] (#15).
///
/// The camera is frozen while the search mode is up (PROD-3496), so the
/// committed map-query center used for proximity bias is stable for the
/// whole focused session. Composition itself is pure — see
/// `map_suggest_composer.dart`; this notifier only owns fetching and the
/// expansion state.
@immutable
class MapSuggestState {
  const MapSuggestState({
    this.query = '',
    this.backend,
    this.backendLoading = false,
    this.backendFailed = false,
    this.locations = const [],
    this.locationsLoading = false,
    this.locationsFailed = false,
    this.expanded = const {},
  });

  /// Trimmed query the lanes are working on (live text, pre-debounce).
  final String query;

  /// Last GOOD backend response — may lag [query] while a fetch is in
  /// flight (B3) or after a failure (B6 keeps stale rows visible).
  final MapSuggestResponse? backend;
  final bool backendLoading;

  /// The latest completed backend attempt failed wholesale (transport).
  /// Per-domain engine failures ride in `backend.failedDomains` instead.
  final bool backendFailed;

  /// Location predictions (fast `/geo/areas`, or deep `/geo/search`
  /// results after the locations expander fired).
  final List<AreaPrediction> locations;
  final bool locationsLoading;
  final bool locationsFailed;

  /// Inline-expanded sections (#15). Reset on every query change.
  final Set<MapSuggestSection> expanded;

  bool get anyLoading => backendLoading || locationsLoading;

  MapSuggestState copyWith({
    String? query,
    MapSuggestResponse? backend,
    bool clearBackend = false,
    bool? backendLoading,
    bool? backendFailed,
    List<AreaPrediction>? locations,
    bool? locationsLoading,
    bool? locationsFailed,
    Set<MapSuggestSection>? expanded,
  }) {
    return MapSuggestState(
      query: query ?? this.query,
      backend: clearBackend ? null : (backend ?? this.backend),
      backendLoading: backendLoading ?? this.backendLoading,
      backendFailed: backendFailed ?? this.backendFailed,
      locations: locations ?? this.locations,
      locationsLoading: locationsLoading ?? this.locationsLoading,
      locationsFailed: locationsFailed ?? this.locationsFailed,
      expanded: expanded ?? this.expanded,
    );
  }
}

class MapSuggestNotifier extends StateNotifier<MapSuggestState> {
  MapSuggestNotifier({
    required Future<MapSuggestResponse> Function(
      String query,
      double latitude,
      double longitude,
      CancelToken cancelToken,
    )
    suggest,
    required ({double lat, double lng})? Function() center,
    required AreaSearchController areaSearch,
    MapSuggestSection? Function() domainScope = _unscoped,
    Duration debounce = const Duration(milliseconds: 300),
    this.onExpanded,
    this.onZeroResults,
  }) : _suggest = suggest,
       _center = center,
       _areaSearch = areaSearch,
       _domainScope = domainScope,
       _debounce = debounce,
       super(const MapSuggestState()) {
    _areaSearch.addListener(_onAreaSearchChanged);
  }

  /// Default for [_domainScope] — the unscoped dropdown, i.e. every behaviour
  /// that predates PROD-3652. A default rather than a required argument
  /// deliberately: it keeps the pre-existing provider tests constructing a
  /// bare notifier unchanged, so any breakage in them is a real regression
  /// rather than churn from this ticket.
  static MapSuggestSection? _unscoped() => null;

  /// PROD-3500 — `map_suggest_expanded` / `map_suggest_zero_results`, wired to
  /// analytics by the provider. Optional and injected (not read off a [Ref])
  /// so both rules stay assertable against a bare notifier, like the fetch
  /// functions above.
  final void Function(MapSuggestSection section)? onExpanded;
  final void Function(String query)? onZeroResults;

  static const int _minChars = 3;

  final Future<MapSuggestResponse> Function(
    String query,
    double latitude,
    double longitude,
    CancelToken cancelToken,
  )
  _suggest;
  final ({double lat, double lng})? Function() _center;
  final AreaSearchController _areaSearch;

  /// PROD-3652 — the selected domain tag, read at call time like [_center]
  /// rather than mirrored into this notifier's state.
  ///
  /// Same discipline PROD-3662 applied to the corpus scope, for the same
  /// reason: one source of truth (`mapSearchProvider`), read when it's needed,
  /// so there is no second copy to drift. This notifier only needs it to pick
  /// a LANE; the request itself reads the same provider inside the `suggest`
  /// closure below.
  final MapSuggestSection? Function() _domainScope;
  final Duration _debounce;

  Timer? _timer;
  CancelToken? _cancel;
  int _generation = 0;

  /// The locations controller, exposed for FE‑3 (PROD-3498): location
  /// execution must resolve through the SAME controller so the Places
  /// session token spans type→pick (then call `afterResolve()`).
  AreaSearchController get areaSearch => _areaSearch;

  /// Live-text hook (wired by the provider to [mapSearchProvider]). The
  /// bar mirrors keystrokes with no debounce — both lanes debounce here.
  void onTextChanged(String raw) {
    final trimmed = raw.trim();
    if (trimmed == state.query) return;

    // A new query invalidates any pending/in-flight backend work and the
    // expansion state (#15 — expanded blocks don't survive retyping).
    _timer?.cancel();
    _cancel?.cancel('new query');
    _generation++;

    // The locations lane owns its own debounce/guard/minChars.
    _areaSearch.onQueryChanged(trimmed);

    if (trimmed.length < _minChars) {
      // 0–2 chars: no suggestions (#36). B4 — clearing also drops results.
      state = state.copyWith(
        query: trimmed,
        clearBackend: true,
        backendLoading: false,
        backendFailed: false,
        expanded: const {},
      );
      return;
    }

    // ≥3 chars — keep previous results visible while fetching (B3).
    state = state.copyWith(
      query: trimmed,
      backendLoading: true,
      backendFailed: false,
      expanded: const {},
    );
    final generation = _generation;
    final cancel = _cancel = CancelToken();
    _timer = Timer(_debounce, () => _runLane(trimmed, generation, cancel));
  }

  /// PROD-3652 — pick the lane for the current domain tag. **The two are not
  /// symmetric**, which is the whole reason this exists:
  ///
  /// - venues/events/lists are `/map/suggest` domains → the backend lane,
  ///   scoped, which is *cheaper* than unscoped (the other two domains aren't
  ///   queried at all).
  /// - **locations is not a `/map/suggest` domain.** Scoping to it means
  ///   skipping that call entirely and firing the DEEP `POST /geo/search` —
  ///   the same second tier the locations expander already triggers (#15).
  ///   Asking `/map/suggest` for it would 422, and omitting the filter would
  ///   silently mean "unscoped".
  ///
  /// ⚠️ [AreaSearchController.submitQuery] is **not internally debounced** — it
  /// fires immediately by design (it's the submit path). Calling it per
  /// keystroke would cost a deep multi-provider search per character, so it is
  /// reached only from here, behind [_debounce]. It bumps the controller's own
  /// generation, so it deterministically supersedes the shallow `/geo/areas`
  /// result racing it from the same keystroke.
  Future<void> _runLane(String query, int generation, CancelToken cancel) {
    if (_domainScope() == MapSuggestSection.locations) {
      // The backend lane is not merely skipped, it is CLEARED: leaving the
      // previous response in place would let the composer keep rendering
      // venue/event rows under a Locations tag (B3 keeps stale rows on
      // purpose, but only ones the current scope could still return).
      if (generation == _generation && mounted) {
        state = state.copyWith(clearBackend: true, backendLoading: false);
      }
      return _areaSearch.submitQuery(query);
    }
    return _runBackend(query, generation, cancel);
  }

  Future<void> _runBackend(
    String query,
    int generation,
    CancelToken cancel,
  ) async {
    final center = _center();
    if (center == null) {
      // No committed map center (map not ready) — the backend lane needs
      // one; locations still work. Not an error state.
      if (generation != _generation || !mounted) return;
      state = state.copyWith(backendLoading: false);
      return;
    }
    try {
      final response = await _suggest(query, center.lat, center.lng, cancel);
      if (generation != _generation || !mounted) return;
      state = state.copyWith(
        backend: response,
        backendLoading: false,
        backendFailed: false,
      );
      _maybeEmitZeroResults();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      if (generation != _generation || !mounted) return;
      // B6 — quiet: keep whatever rows we had; the composer renders the
      // retry row only when there's nothing to show.
      state = state.copyWith(backendLoading: false, backendFailed: true);
    } catch (_) {
      if (generation != _generation || !mounted) return;
      state = state.copyWith(backendLoading: false, backendFailed: true);
    }
  }

  /// Re-fires the backend lane when the map center becomes available
  /// AFTER the user already typed. Without this, typing before the map's
  /// first camera/location fix would permanently suppress backend
  /// suggestions for that query — `_runBackend` skips quietly on a null
  /// center and nothing else re-triggers it. (Codex review, PR #1229.)
  /// Wired by the provider to `mapQueryProvider.hasCenter`.
  void onMapCenterAvailable() {
    if (state.query.length < _minChars) return;
    // PROD-3652 — there is no backend lane to rescue under a Locations tag,
    // and its "nothing here" state is indistinguishable from the one this
    // method exists to fix (both are a null `backend`, not loading, not
    // failed). Without this guard, the map's first centre fix would fire the
    // one `/map/suggest` call that tag must never make.
    if (_domainScope() == MapSuggestSection.locations) return;
    // Only when the lane has nothing: a response, an in-flight fetch or a
    // failed attempt (retry row) all mean the center was already there.
    if (state.backend != null || state.backendLoading || state.backendFailed) {
      return;
    }
    _timer?.cancel();
    _cancel?.cancel('center available');
    _generation++;
    state = state.copyWith(backendLoading: true);
    final cancel = _cancel = CancelToken();
    unawaited(_runBackend(state.query, _generation, cancel));
  }

  /// PROD-3662 — the corpus changed under a live query: the scope banner's ×,
  /// or a "De quem?" change made before the bar was opened. Re-runs the backend
  /// lane for the current query so the rows agree with the banner that just
  /// changed.
  ///
  /// **Immediate, no debounce** — this is one deliberate tap, not typing, and
  /// the 300 ms exists only to collapse keystrokes (same reasoning as [retry]).
  ///
  /// Previous rows deliberately stay visible while the refetch runs (B3). Safe
  /// here specifically: the only scope change reachable while the dropdown is
  /// open is the × (the "De quem?" buttons are under the scrim, inert), and
  /// un-scoping can only WIDEN the corpus — so the stale rows are always a
  /// subset of what is about to replace them, never something the new corpus
  /// excludes.
  ///
  /// The locations lane is untouched: geography belongs to no corpus, which is
  /// exactly why it carries its own marker row (Decision #55).
  void onScopeChanged() {
    if (state.query.length < _minChars) return;
    _timer?.cancel();
    _cancel?.cancel('scope changed');
    _generation++;
    state = state.copyWith(backendLoading: true, backendFailed: false);
    final cancel = _cancel = CancelToken();
    unawaited(_runLane(state.query, _generation, cancel));
  }

  /// PROD-3652 — a domain tag was selected, deselected or swapped. Re-runs the
  /// lane for the current query so the rows agree with the tag that just
  /// changed.
  ///
  /// **Immediate, no debounce** — one deliberate tap, not typing; the 300 ms
  /// exists only to collapse keystrokes (same reasoning as [onScopeChanged]
  /// and [retry]).
  ///
  /// [expanded] is cleared, not carried: a scoped view renders no expanders at
  /// all (the tag *is* the expansion), and a stale expansion surviving a
  /// deselect would re-expand a block the user never opened in that view.
  ///
  /// Below `_minChars` this still clears the backend rather than returning
  /// early — the 0-char state under a tag is the prompt-to-type, and leaving
  /// the previous response would render rows beneath it.
  ///
  /// [previous] is the tag being left, and it matters for exactly one
  /// transition — see [_realignGeoLane].
  void onDomainChanged({MapSuggestSection? previous}) {
    _timer?.cancel();
    _cancel?.cancel('domain changed');
    _generation++;
    _realignGeoLane(previous);
    if (state.query.length < _minChars) {
      state = state.copyWith(
        clearBackend: true,
        backendLoading: false,
        backendFailed: false,
        expanded: const {},
      );
      return;
    }
    state = state.copyWith(
      backendLoading: true,
      backendFailed: false,
      expanded: const {},
    );
    final cancel = _cancel = CancelToken();
    unawaited(_runLane(state.query, _generation, cancel));
  }

  /// Leaving the Locations tag must put the geo lane back on its SHALLOW tier.
  ///
  /// The two lanes cancel independently: `_cancel`/`_generation` guard the
  /// backend lane, while [AreaSearchController] owns its own token and
  /// generation. So bumping ours does nothing to an in-flight deep
  /// `/geo/search` — it lands afterwards through the controller listener and
  /// writes `state.locations` regardless of which tag is now selected.
  ///
  /// Two ways that shows up, both wrong and both silent:
  /// - back on the **unscoped** dropdown, the locations block renders DEEP
  ///   results for a query whose second tier the user never asked to expand
  ///   (#15 makes that tier an explicit gesture);
  /// - if the deep call **failed**, `locationsFailed` raises the retry row for
  ///   a lane the current view never invoked.
  ///
  /// `reset()` then `onQueryChanged()` is the same pair [retry] uses, and for
  /// the same reason: the controller dedupes identical queries, so it has to be
  /// reset before it will re-run. Rotating the Places session token is correct
  /// here too — this is a fresh attempt at a different tier.
  void _realignGeoLane(MapSuggestSection? previous) {
    if (previous != MapSuggestSection.locations) return;
    if (_domainScope() == MapSuggestSection.locations) return;
    final query = state.query;
    _areaSearch.reset();
    if (query.length >= _minChars) _areaSearch.onQueryChanged(query);
  }

  /// Expander / collapse tap (#15). Expanding LOCATIONS also fires the
  /// deep `/geo/search` — fetch, not just reveal (the only two-tier
  /// domain); its results land through the controller listener.
  void toggleExpanded(MapSuggestSection section) {
    final expanded = Set<MapSuggestSection>.from(state.expanded);
    if (!expanded.add(section)) {
      expanded.remove(section);
    } else {
      // PROD-3500 — expand only. A collapse is not demand for more results,
      // and this method serves both.
      onExpanded?.call(section);
      if (section == MapSuggestSection.locations) {
        unawaited(_areaSearch.submitQuery(state.query));
      }
    }
    state = state.copyWith(expanded: expanded);
  }

  /// B6 retry-row tap — re-fires only the failed lanes for the current
  /// query, immediately (no debounce).
  void retry() {
    if (state.query.length < _minChars) return;
    final backendNeedsRetry =
        state.backendFailed ||
        (state.backend?.failedDomains.isNotEmpty ?? false);
    if (backendNeedsRetry) {
      _timer?.cancel();
      _cancel?.cancel('retry');
      _generation++;
      state = state.copyWith(backendLoading: true, backendFailed: false);
      final cancel = _cancel = CancelToken();
      unawaited(_runBackend(state.query, _generation, cancel));
    }
    if (state.locationsFailed) {
      // The controller dedupes identical queries — reset first to force a
      // re-run (also rotates the Places session token, which is correct
      // for a fresh attempt).
      final query = state.query;
      _areaSearch.reset();
      // PROD-3652 — retry the tier the user is actually looking at. Under a
      // Locations tag the rows came from the DEEP `/geo/search`, so replaying
      // `onQueryChanged` would quietly demote them to the shallow
      // `/geo/areas` tier: a "retry" that succeeds and returns strictly less
      // than what failed. Everywhere else shallow is what failed and shallow
      // is what to re-run.
      if (_domainScope() == MapSuggestSection.locations) {
        unawaited(_areaSearch.submitQuery(query));
      } else {
        _areaSearch.onQueryChanged(query);
      }
    }
  }

  void _onAreaSearchChanged() {
    if (!mounted) return;
    state = state.copyWith(
      locations: _areaSearch.results,
      locationsLoading: _areaSearch.loading,
      locationsFailed: _areaSearch.error != null,
    );
    _maybeEmitZeroResults();
  }

  /// Queries already counted as zero-results. A SET, not a last-seen slot:
  /// backspacing and retyping re-runs both lanes for a query we've already
  /// counted, and one person fumbling a spelling is one coverage gap, not
  /// three. Lives as long as the focused session (the provider is
  /// autoDispose), so it stays small.
  final Set<String> _zeroResultsCounted = <String>{};

  /// PROD-3500 — `map_suggest_zero_results`.
  ///
  /// Called ONLY from the two settle points, never speculatively: a lane that
  /// hasn't started yet looks identical to one that came back empty, and
  /// firing on that would count "still typing" as a coverage gap.
  ///
  /// Deliberately excluded, because each is a different outcome the user sees:
  /// a failed lane (renders the retry row), and a missing map centre
  /// ([_runBackend] returns early leaving `backend` null — the lane never ran).
  /// Emptiness is judged over the OFFERED sections only, so a response whose
  /// only hits are lists still counts as zero — zero is what the dropdown
  /// shows while `kMapSuggestShowLists` is false.
  /// PROD-3652 — under a tag this is judged over the RENDERED lane only.
  /// Judging the unscoped way would break it in both directions: under
  /// `locations` the backend lane is deliberately cleared, so the `backend ==
  /// null` guard would swallow a genuinely empty deep geo result forever; and
  /// under `venues`/`events`/`lists` a non-empty `state.locations` — rows the
  /// scoped view does not render — would suppress the event while the user
  /// stares at an empty block. Both are the coverage gap this metric exists to
  /// count.
  void _maybeEmitZeroResults() {
    if (onZeroResults == null) return;
    final query = state.query;
    if (query.length < _minChars || _zeroResultsCounted.contains(query)) return;
    if (state.anyLoading) return;

    final domainScope = _domainScope();
    final backend = state.backend;

    if (domainScope == MapSuggestSection.locations) {
      // Only the geo lane renders, so only its failure and its rows count.
      if (state.locationsFailed || state.locations.isNotEmpty) return;
    } else if (domainScope != null) {
      // Only the scoped bucket renders. `failedDomains` reports attempted
      // domains only, so a scoped response can never implicate another one.
      if (state.backendFailed) return;
      if (backend == null) return;
      final domain = domainForSection(domainScope)!;
      if (backend.domainFailed(domain)) return;
      if (backend.bucketFor(domain).items.isNotEmpty) return;
    } else {
      if (state.backendFailed || state.locationsFailed) return;
      if (backend == null || backend.failedDomains.isNotEmpty) return;
      if (state.locations.isNotEmpty) return;
      final offeredHasRows = MapSuggestDomain.values.any(
        (d) =>
            sectionIsOffered(sectionForDomain(d)) &&
            backend.bucketFor(d).items.isNotEmpty,
      );
      if (offeredHasRows) return;
    }

    _zeroResultsCounted.add(query);
    onZeroResults!(query);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cancel?.cancel('disposed');
    _areaSearch.removeListener(_onAreaSearchChanged);
    _areaSearch.dispose();
    super.dispose();
  }
}

/// PROD-3652 — the domain tag actually IN FORCE: the user's selection, or null
/// when the current corpus makes that selection unofferable.
///
/// Every consumer reads this rather than `MapSearchState.domain` directly, so
/// "a tag that cannot be shown cannot scope anything" holds **at the read
/// site** instead of depending on a listener having fired. That distinction is
/// load-bearing: `mapSuggestProvider` is `autoDispose` and is mounted by the
/// dropdown, so `enterFocus(domain: lists)` from a closed bar — PROD-3653's
/// entry point — sets the tag while nothing is listening. `ref.listen` only
/// reacts to CHANGES, so the listeners below would never see that initial
/// state, and the first keystroke would send `domain=lists` + `scope=list`.
/// (Codex review, round 4.)
///
/// The listeners still clear the stored selection, so state does not quietly
/// drift; this provider is what makes the behaviour correct regardless.
final mapEffectiveDomainProvider = Provider.autoDispose<MapSuggestSection?>((
  ref,
) {
  final selected = ref.watch(mapSearchProvider.select((s) => s.domain));
  if (selected == null) return null;
  final corpus = ref.watch(mapQueryProvider.select(mapSuggestScopeKindOf));
  return mapDomainTagIsOffered(selected, corpus: corpus) ? selected : null;
});

/// PROD-3653 — the corpus actually IN FORCE for `/map/suggest`, in all three
/// forms at once: the two wire values and the copy enum.
///
/// Normally that is just the map's own query. It is **null across the board**
/// while a `domainUnbounded` tag is in force — the "De quem?" panel's `Zine +`
/// chip, which is a discovery affordance and must reach Zines the current
/// corpus would exclude (PROD-3562's contract note: under `scope=yours` the
/// lists bucket holds only the viewer's own).
///
/// One provider returning all three forms, rather than a bool each consumer
/// re-applies, because the banner and the request **must not be able to
/// disagree**. `MapQuery.isScopeBounded` puts it plainly: a banner claiming a
/// bound the request didn't send "is the one thing this feature exists to
/// prevent". Deriving them together makes that unreachable instead of
/// conventional.
///
/// `listId` drops with `scope` for the same reason the pair is gated together
/// on [MapQuery]: a `list_id` on any other scope is a **422**.
///
/// That branch is **unreachable today, by construction, and stays anyway**:
/// suppression requires `domain == lists` (enforced in `enterFocus`) *and* that
/// the tag is offerable, which excludes the list corpus — the only corpus where
/// `listIdWire` is non-null. Writing `corpus.$2` here would therefore be a no-op
/// now and a 422 the day someone widens the flag to another domain. Two dead
/// characters against a whole-endpoint failure is the right trade.
final mapEffectiveSuggestScopeProvider =
    Provider.autoDispose<
      ({String? wire, String? listId, MapSuggestScopeKind? kind})
    >((ref) {
      // Select the triple, not the query: the query changes on every camera
      // move, and this must only rebuild when the corpus actually does.
      final corpus = ref.watch(
        mapQueryProvider.select(
          (q) => (q.scopeWire, q.listIdWire, mapSuggestScopeKindOf(q)),
        ),
      );
      // Suppression counts only while the tag it belongs to is itself in force
      // — an unofferable selection scopes nothing, so it must not unscope
      // anything either.
      final unbounded = ref.watch(
        mapSearchProvider.select((s) => s.domainUnbounded),
      );
      if (unbounded && ref.watch(mapEffectiveDomainProvider) != null) {
        return (wire: null, listId: null, kind: null);
      }
      return (wire: corpus.$1, listId: corpus.$2, kind: corpus.$3);
    });

final mapSuggestProvider =
    StateNotifierProvider.autoDispose<MapSuggestNotifier, MapSuggestState>((
      ref,
    ) {
      final mapApi = ref.watch(mapApiProvider);
      final geoApi = ref.watch(geoApiProvider);

      // PROD-3986 follow-up — full BCP-47 via `apiLocaleCodeProvider`, not a
      // bare `languageCode`. `Locale('pt')` and `Locale('pt','BR')` both yield
      // `'pt'`, which made a Brazilian user look Portuguese to the geo
      // endpoints. The provider already falls back to the platform locale, so
      // the guest case this used to spell out by hand is covered.
      // NOTE: this feeds `geoApi.searchAreas`/`deepSearch` ONLY. `/map/suggest`
      // is `additionalProperties: false` with no `locale` field — adding one
      // there is a 422, not an ignored key.
      String localeOf() => ref.read(apiLocaleCodeProvider) ?? 'en';
      ({double lat, double lng})? center() {
        final query = ref.read(mapQueryProvider);
        final lat = query.centerLat;
        final lng = query.centerLng;
        if (lat == null || lng == null) return null;
        return (lat: lat, lng: lng);
      }

      final notifier = MapSuggestNotifier(
        suggest: (query, latitude, longitude, cancelToken) {
          // PROD-3662 — read the corpus at CALL time, like `center()` above,
          // so a scope change never has to be threaded through the notifier's
          // state. `scopeWire`/`listIdWire` are the same pair `/map/pins`
          // sends and are gated together on `isListMode`, so a half-set list
          // state degrades to the unbounded corpus instead of 422-ing.
          // PROD-3653 — through the EFFECTIVE scope, so the one entry point
          // that must search outside the corpus (the `Zine +` chip) unscopes
          // the request and the banner in the same read.
          final scope = ref.read(mapEffectiveSuggestScopeProvider);
          // PROD-3652 — same call-time discipline as the corpus above, off the
          // same single source of truth the notifier's `domainScope` reads.
          // `locations` never reaches here (`_runLane` takes the geo path), and
          // if it somehow did, `domainForSection` maps it to null — omitting
          // the filter — rather than to a value `/map/suggest` would 422 on.
          // Reading the EFFECTIVE domain, so an unofferable selection can never
          // reach the wire even if no listener has run yet.
          final tag = ref.read(mapEffectiveDomainProvider);
          return mapApi.suggest(
            query: query,
            latitude: latitude,
            longitude: longitude,
            domain: tag == null ? null : domainForSection(tag),
            scope: scope.wire,
            listId: scope.listId,
            cancelToken: cancelToken,
          );
        },
        center: center,
        domainScope: () => ref.read(mapEffectiveDomainProvider),
        areaSearch: AreaSearchController(
          minChars: MapSuggestNotifier._minChars,
          search: (q, token, cancel) {
            final c = center();
            return geoApi.searchAreas(
              q: q,
              sessionToken: token,
              locale: localeOf(),
              nearLat: c?.lat,
              nearLng: c?.lng,
              cancelToken: cancel,
            );
          },
          deepSearch: (q, cancel) {
            final c = center();
            return geoApi.deepSearch(
              q: q,
              locale: localeOf(),
              nearLat: c?.lat,
              nearLng: c?.lng,
              cancelToken: cancel,
            );
          },
        ),
        // Read lazily inside the callbacks — see `mapSearchProvider` for why
        // (the analytics service needs a live Firebase app).
        onExpanded: (section) => unawaited(
          ref
              .read(unifiedAnalyticsProvider)
              .trackMapSuggestExpanded(domain: section.name),
        ),
        onZeroResults: (query) => unawaited(
          ref
              .read(unifiedAnalyticsProvider)
              .trackMapSuggestZeroResults(queryLen: query.length),
        ),
      );

      // The bar mirrors keystrokes into mapSearchProvider with no debounce;
      // exitFocus atomically clears the text, which resets both lanes (B4).
      ref.listen(mapSearchProvider.select((s) => s.text), (_, next) {
        notifier.onTextChanged(next);
      });

      // Early typing before the map's first center fix: re-fire the backend
      // lane the moment a center exists (it skips quietly without one).
      ref.listen(mapQueryProvider.select((q) => q.hasCenter), (_, hasCenter) {
        if (hasCenter) notifier.onMapCenterAvailable();
      });

      // PROD-3662 — the corpus changed (the banner's ×). Keyed on the exact
      // pair that goes on the wire, not on `source`, so the listener and the
      // request can never disagree about what "bounded" means.
      // PROD-3652 — a selected tag must never survive out of sight. The Zine
      // tag is not rendered under `scope=list`, so a selection that outlives
      // that transition would keep scoping the dropdown to a domain the
      // backend drops there, with no visible control to undo it.
      //
      // Enforced HERE rather than in the row so the invariant is structural
      // rather than a property of what happens to be painted — a widget must
      // not write provider state during build, and the row is the only other
      // place it could live.
      //
      // Returns true when it cleared. **Both listeners below bail on true**,
      // and the ordering is the point: clearing writes `domain = null`, which
      // re-enters the domain listener and reruns the lanes unscoped from
      // there. Whichever listener runs first, the tag is gone before any fetch
      // is issued for it — so `domain=lists` + `scope=list`, which is empty by
      // contract, is never sent. (Codex review, rounds 2 and 3.)
      bool clearUnofferableDomain() {
        final selected = ref.read(mapSearchProvider).domain;
        if (selected == null) return false;
        final corpus = mapSuggestScopeKindOf(ref.read(mapQueryProvider));
        if (mapDomainTagIsOffered(selected, corpus: corpus)) return false;
        ref.read(mapSearchProvider.notifier).setDomain(null);
        return true;
      }

      ref.listen(mapQueryProvider.select((q) => (q.scopeWire, q.listIdWire)), (
        previous,
        next,
      ) {
        if (previous == next) return;
        // Declared above this listener, not after it: entering a Zine with the
        // Zine tag selected would otherwise refetch once for a tag that is
        // about to be cleared.
        if (clearUnofferableDomain()) return;
        // PROD-3653 — while the request is suppressed it is `(null, null)`
        // *whatever* the corpus is, so a corpus change cannot change it and a
        // refetch would buy nothing. Checked AFTER the clear above, which owns
        // the case where the new corpus makes the tag unofferable (and takes
        // the suppression down with it). Stateless on purpose: tracking the
        // last effective pair in a closure is how a listener starts drifting
        // from the thing it is supposed to mirror. (Codex review, round 1.)
        if (ref.read(mapSearchProvider).domainUnbounded &&
            ref.read(mapEffectiveDomainProvider) != null) {
          return;
        }
        notifier.onScopeChanged();
      });

      // PROD-3652 — a domain tag was selected, deselected or swapped. Separate
      // from the text listener above because a tag change re-runs the lanes
      // with the text UNCHANGED, which `onTextChanged` short-circuits on.
      //
      // The offerability check is repeated here because the corpus listener
      // cannot see `enterFocus(domain: lists)` fired while the map is ALREADY
      // in a Zine — nothing about the corpus changed, and that is precisely
      // PROD-3653's entry point.
      //
      // PROD-3653 — keyed on the PAIR, not on `domain` alone. Clearing the
      // corpus suppression leaves the domain equal (`(lists, unbounded)` →
      // `(lists, bounded)`), and swallowing that transition would leave the
      // dropdown showing results fetched under the other scope.
      ref.listen(
        mapSearchProvider.select((s) => (s.domain, s.domainUnbounded)),
        (previous, next) {
          if (previous == next) return;
          if (clearUnofferableDomain()) return;
          notifier.onDomainChanged(previous: previous?.$1);
        },
      );

      return notifier;
    });
