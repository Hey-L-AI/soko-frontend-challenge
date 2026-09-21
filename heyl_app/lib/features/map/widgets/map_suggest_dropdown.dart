import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/area_prediction.dart';
import '../../../data/models/map_suggest.dart';
import '../../../data/models/map_search_history.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/locale_provider.dart';
import '../models/map_query.dart';
import '../providers/map_query_provider.dart';
import '../providers/map_search_executor.dart';
import '../providers/map_search_history_provider.dart';
import '../providers/map_search_provider.dart';
import '../providers/map_suggest_provider.dart';
import '../../../shared/widgets/search/unified_search_expander.dart';
import '../../../shared/widgets/search/unified_search_models.dart';
import '../../../shared/widgets/search/unified_search_results.dart';
import '../utils/map_boundary_scope.dart';
import '../utils/map_suggest_composer.dart';
import 'map_domain_tags.dart' show mapDomainTagLabel;
import 'map_past_searches_panel.dart';
import 'map_suggest_rows.dart';

/// PROD-3497 — the typed-suggestion dropdown content for the map's focused
/// search mode. Mounted into `MapSearchFocusedOverlay.dropdownContent`
/// (the FE‑1 slot); the overlay owns panel chrome, sizing and scrolling,
/// so this widget must stay intrinsically sized (a Column, never a lazy
/// list).
///
/// Ladder states (#36): 0 chars → past searches / explainer / guest state
/// (PROD-3499's `MapPastSearchesPanel`) · 1 char → nothing · ≥2 chars →
/// the composed entry list (general row alone until suggestions start
/// at ≥3).
class MapSuggestDropdown extends ConsumerWidget {
  const MapSuggestDropdown({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = ref.watch(mapSearchProvider.select((s) => s.text)).trim();
    final state = ref.watch(mapSuggestProvider);
    // PROD-3662 — the corpus, read through the same predicate the request
    // uses, so the chrome can never announce a bound that wasn't sent.
    // PROD-3653 — that predicate is now the EFFECTIVE scope: the `Zine +` chip
    // drops the corpus from the request, and this is the read that keeps the
    // banner honest about it (no banner, because nothing was bounded).
    final scope = ref.watch(
      mapEffectiveSuggestScopeProvider.select((s) => s.kind),
    );
    final listName = ref.watch(
      mapQueryProvider.select((q) => q.activeListName),
    );

    // PROD-3652 — the DOMAIN tag (what kind of thing), not to be confused with
    // `scope` above (the corpus — whose stuff). Orthogonal, and they compose.
    //
    // The EFFECTIVE tag, not the raw selection: a tag the current corpus can't
    // offer scopes nothing, and this must agree with what the fetch lane did.
    final domainScope = ref.watch(mapEffectiveDomainProvider);

    final banner = scope == null
        ? null
        : MapSuggestScopeBanner(
            scope: scope,
            listName: listName,
            onClear: () => _clearScope(ref),
          );

    if (text.isEmpty) {
      // PROD-3652 — with a tag selected, prompt for the text the tag has
      // nothing to filter yet. It outranks past searches (which are global and
      // untyped, so they'd ignore the tag the user just set) and sits BELOW the
      // banner rather than replacing it, because the corpus statement is still
      // true and still needs its ×.
      final prompt = domainScope == null
          ? null
          : _ScopedPrompt(domain: domainScope);
      if (banner != null) {
        // Decision #54 — under a scope the 0-char state is the banner ALONE: no
        // history rows, no explainer, no guest placeholder. Past searches are
        // global and can't be scoped, so showing them under a banner that says
        // "A pesquisar em X" would be the banner's first lie. Accepted cost:
        // history is unreachable until the user clears the scope or types.
        return prompt == null
            ? banner
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [banner, prompt],
              );
      }
      if (prompt != null) return prompt;
      // PROD-3499: history rows for signed-in users (empty → the D25
      // explainer), the login explainer for guests. Untouched when unbounded.
      return const MapPastSearchesPanel();
    }
    // 1 char: no suggestions (#36) — but the banner stays, so it doesn't
    // blink out of existence for exactly one keystroke.
    if (text.length < 2) return banner ?? const SizedBox.shrink();

    final entries = composeMapSuggestDropdown(
      query: text,
      backend: state.backend,
      backendTransportFailed: state.backendFailed,
      locations: state.locations,
      locationsFailed: state.locationsFailed,
      expanded: state.expanded,
      scopeBounded: scope != null,
      domainScope: domainScope,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Above the progress bar as well as the rows: the banner frames
        // everything in the card, including the fact that a fetch is running.
        if (banner != null) banner,
        // B3 — previous results stay visible while fetching; this thin bar
        // is the only in-flight signal (no blanking between keystrokes).
        if (state.anyLoading)
          const LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: Colors.transparent,
            color: AppColors.sokoShade3,
          ),
        ..._entryRows(context, ref, entries, scope, state.expanded),
      ],
    );
  }

  /// Renders the composed entries into rows, inserting a coloured + iconed
  /// section pill before each domain/location block (unified-search) and popping
  /// in the rows an expander reveals. The pure composer is untouched — the
  /// grouping is read back off the flat entry list here, in the widget layer, so
  /// the map keeps its compact fixed-height rows.
  List<Widget> _entryRows(
    BuildContext context,
    WidgetRef ref,
    List<MapSuggestEntry> entries,
    MapSuggestScopeKind? scope,
    Set<MapSuggestSection> expanded,
  ) {
    final out = <Widget>[];
    MapSuggestSection? currentSection;
    final perSectionIndex = <MapSuggestSection, int>{};
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final section = _blockSectionOf(entry);
      if (section != null && section != currentSection) {
        currentSection = section;
        out.add(_sectionPill(context, section));
      }
      Widget row = _rowFor(context, ref, entry, i, scope);
      // Pop the rows an expander revealed (those past the collapsed preview).
      if (section != null &&
          (entry is MapSuggestItemEntry || entry is MapSuggestLocationEntry)) {
        final idx = perSectionIndex[section] ?? 0;
        perSectionIndex[section] = idx + 1;
        if (expanded.contains(section) && idx >= kMapSuggestCollapsedVisible) {
          row = UnifiedSearchPopIn(child: row);
        }
      }
      out.add(row);
    }
    return out;
  }

  /// The section a block-row entry belongs to, or null for the top slot, the
  /// general row, expanders, markers and retry (which start no block).
  MapSuggestSection? _blockSectionOf(MapSuggestEntry entry) => switch (entry) {
    MapSuggestItemEntry(:final domain) => sectionForDomain(domain),
    MapSuggestLocationEntry() => MapSuggestSection.locations,
    _ => null,
  };

  Widget _sectionPill(BuildContext context, MapSuggestSection section) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: UnifiedSectionPill(
          category: _categoryForSection(section),
          label: mapDomainTagLabel(l10n, section),
        ),
      ),
    );
  }

  SokoSearchCategory _categoryForSection(MapSuggestSection section) =>
      switch (section) {
        MapSuggestSection.venues => SokoSearchCategory.venues,
        MapSuggestSection.events => SokoSearchCategory.events,
        MapSuggestSection.lists => SokoSearchCategory.zines,
        MapSuggestSection.locations => SokoSearchCategory.locations,
      };

  /// PROD-3662 — the banner's ×. Identical to picking "Tudo na Soko" in
  /// "De quem?", by routing through the same two writers rather than inventing
  /// a third: `clearList` for a Zine, `setSource(all)` otherwise.
  ///
  /// That inheritance includes their **asymmetric** keyword rule, which is
  /// deliberate and predates this ticket: leaving a **list** drops the keyword
  /// (PROD-3567 — a keyword typed inside a Zine means "within this Zine", and
  /// re-pointing it at all of Soko would silently change what the user
  /// searched), while leaving `yours`/`following` **keeps** it, as a plain
  /// scope change always has. Not re-litigated here; routing through the
  /// existing writers is what keeps it consistent with the "De quem?" picker,
  /// which is the whole point of the ×.
  ///
  /// The `/map/pins` refetch this triggers is DEFERRED while the search mode is
  /// open — see `MapPinsNotifier`. Everything the user can see updates now: the
  /// banner disappears, the "De quem?" chip flips, and the suggestion lane
  /// refetches unbounded.
  void _clearScope(WidgetRef ref) {
    final notifier = ref.read(mapQueryProvider.notifier);
    if (ref.read(mapQueryProvider).isListMode) {
      notifier.clearList();
    } else {
      notifier.setSource(MapSource.all);
    }
  }

  /// [rank] is the entry's 0-based VISUAL position in the composed list —
  /// what `map_suggest_selected` reports, so it counts the pinned general row
  /// and any expander sitting above this one.
  Widget _rowFor(
    BuildContext context,
    WidgetRef ref,
    MapSuggestEntry entry,
    int rank,
    MapSuggestScopeKind? scope,
  ) {
    final l10n = Lt.of(context);
    final notifier = ref.read(mapSuggestProvider.notifier);
    return switch (entry) {
      MapSuggestTopHitEntry(:final item) => MapSuggestItemRow(
        item: item,
        onTap: () => _handleSelection(ref, entry, rank),
      ),
      MapSuggestLocationTopHitEntry(:final prediction) => MapSuggestLocationRow(
        prediction: prediction,
        onTap: () => _handleSelection(ref, entry, rank),
      ),
      MapSuggestGeneralSearchEntry(:final query) => MapSuggestGeneralRow(
        query: query,
        scope: scope,
        onTap: () => _handleSelection(ref, entry, rank),
      ),
      MapSuggestLocationsScopeMarkerEntry() =>
        const MapSuggestLocationsScopeMarkerRow(),
      MapSuggestItemEntry(:final item) => MapSuggestItemRow(
        item: item,
        onTap: () => _handleSelection(ref, entry, rank),
      ),
      MapSuggestLocationEntry(:final prediction) => MapSuggestLocationRow(
        prediction: prediction,
        onTap: () => _handleSelection(ref, entry, rank),
      ),
      MapSuggestExpanderEntry(:final section) => MapSuggestExpanderRow(
        label: switch (section) {
          MapSuggestSection.venues => l10n.mapSuggestExpandVenues,
          MapSuggestSection.events => l10n.mapSuggestExpandEvents,
          MapSuggestSection.lists => l10n.mapSuggestExpandZines,
          MapSuggestSection.locations => l10n.mapSuggestExpandLocations,
        },
        onTap: () => notifier.toggleExpanded(section),
      ),
      MapSuggestCollapseEntry(:final section) => MapSuggestCollapseRow(
        onTap: () => notifier.toggleExpanded(section),
      ),
      MapSuggestRetryEntry() => MapSuggestRetryRow(onRetry: notifier.retry),
    };
  }

  /// PROD-3498 — dispatch a selected row into the per-type map execution.
  ///
  /// The executor owns everything downstream, including leaving focused mode
  /// (which is what unfreezes the camera). Nothing here awaits: a tap must
  /// feel instant, and the only asynchronous case (resolving a location) shows
  /// its result when it lands.
  void _handleSelection(WidgetRef ref, MapSuggestEntry entry, int rank) {
    final executor = ref.read(mapSearchExecutorProvider);
    switch (entry) {
      case MapSuggestGeneralSearchEntry(:final query):
        _track(ref, type: 'keyword', rank: rank);
        _record(
          ref,
          type: MapSearchHistoryType.keyword,
          label: query,
          queryText: query,
        );
        unawaited(executor.executeKeyword(query));
      case MapSuggestTopHitEntry(:final item):
      case MapSuggestItemEntry(item: final item):
        _track(ref, type: item.type, rank: rank);
        _executeItem(ref, executor, item);
      case MapSuggestLocationTopHitEntry(:final prediction):
      case MapSuggestLocationEntry(prediction: final prediction):
        _track(ref, type: 'location', rank: rank);
        unawaited(_executeLocation(ref, executor, prediction));
      // Expander / collapse / retry act on the suggestion state itself and
      // are wired at the row, not here. The locations scope marker is inert
      // by design — it's a disclaimer, not an action (Decision #55).
      case MapSuggestExpanderEntry():
      case MapSuggestCollapseEntry():
      case MapSuggestRetryEntry():
      case MapSuggestLocationsScopeMarkerEntry():
        break;
    }
  }

  /// PROD-3500 — `map_suggest_selected`, the dropdown's core outcome.
  ///
  /// Fires here rather than in the executor for two reasons: `rank` and
  /// `query_len` are facts only this surface has, and the executor is also
  /// reached by past-search re-execution (which has its own
  /// `map_past_search_used`) — emitting there would double-count every
  /// history tap. A keyword search reached from OUTSIDE the dropdown is
  /// counted instead by the executor-side `map_area_searched{trigger:
  /// 'keyword'}` / `map_filter_change{filter:'keyword'}`, which is why no
  /// producer needs to emit on its own behalf.
  ///
  /// Emitted for the top-hit variants too, so Decision #39's repeated row
  /// produces two events at two different ranks — deliberate, and documented
  /// on the contract entry.
  void _track(WidgetRef ref, {required String type, required int rank}) {
    unawaited(
      ref
          .read(unifiedAnalyticsProvider)
          .trackMapSuggestSelected(
            type: type,
            rank: rank,
            queryLen: ref.read(mapSearchProvider).text.trim().length,
          ),
    );
  }

  /// PROD-3499 history write. The **producer** records, not the executor —
  /// the past-searches path already bumps recency before it dispatches, so
  /// recording inside the executor would double-write there; and only the
  /// producer reliably knows the label and thumbnail to store.
  ///
  /// Fire-and-forget by contract: `recordSelection` swallows its own failures
  /// (guests are 401 by design), so a history write can never delay or break
  /// the execution the user actually asked for.
  void _record(
    WidgetRef ref, {
    required MapSearchHistoryType type,
    required String label,
    String? targetId,
    String? queryText,
    String? imageUrl,
  }) {
    unawaited(
      ref
          .read(mapSearchHistoryProvider.notifier)
          .recordSelection(
            type: type,
            targetId: targetId,
            queryText: queryText,
            displayLabel: label,
            imageUrl: imageUrl,
          ),
    );
  }

  void _executeItem(
    WidgetRef ref,
    MapSearchExecutor executor,
    MapSuggestItem item,
  ) {
    switch (item.type) {
      case 'venue':
        _record(
          ref,
          type: MapSearchHistoryType.venue,
          label: item.name,
          targetId: item.id,
          imageUrl: item.imageUrl,
        );
        unawaited(
          executor.executeVenue(
            venueId: item.id,
            label: item.name,
            latitude: item.latitude,
            longitude: item.longitude,
            imageUrl: item.imageUrl,
          ),
        );
      case 'event':
        // The CANONICAL event id is what history stores (PROD-3495 contract),
        // never the occurrence id — a re-execution must resolve the event.
        _record(
          ref,
          type: MapSearchHistoryType.event,
          label: item.name,
          targetId: item.id,
          imageUrl: item.imageUrl,
        );
        unawaited(
          executor.executeEvent(
            // `id` is the canonical event id; `occurrenceId` is the matched
            // `/map/pins` pin, which lets the promoted pin coincide with a
            // real one instead of doubling it.
            eventId: item.id,
            label: item.name,
            occurrenceId: item.occurrenceId,
            latitude: item.latitude,
            longitude: item.longitude,
            imageUrl: item.imageUrl,
          ),
        );
      case 'list':
        // PROD-3566 — no resolve before dispatch, deliberately. `/map/pins`
        // takes the list's UUID *or* slug, and suggest already gave us both
        // the id and the display name, so a `getList` round-trip here would
        // only delay the camera. (The history path resolves for a different
        // reason: there a 404 IS the staleness signal, Decision #21.)
        _record(
          ref,
          type: MapSearchHistoryType.list,
          label: item.name,
          targetId: item.id,
          imageUrl: item.imageUrl,
        );
        unawaited(
          executor.executeList(
            listId: item.id,
            name: item.name,
            source: MapListOpenSource.suggest,
            // PROD-3568/PROD-3647 — the server decides ownership (strict
            // `owner_id` match) and ships the verdict on the suggest item, so
            // this path is exact WITHOUT the `getList` round-trip it exists to
            // avoid. See [MapListOwnership].
            isOwn: item.isOwn,
          ),
        );
    }
  }

  /// Locations resolve through the SAME [AreaSearchController] the suggestions
  /// came from, so the Google Places session token spans type→pick (that is
  /// what makes the autocomplete calls free); `afterResolve()` then ends the
  /// session for the winning pick only. Deep-search predictions already carry
  /// their resolved area, so most picks cost no request at all.
  Future<void> _executeLocation(
    WidgetRef ref,
    MapSearchExecutor executor,
    AreaPrediction prediction,
  ) async {
    final controller = ref.read(mapSuggestProvider.notifier).areaSearch;
    // Captured BEFORE the await: `ref` is a WidgetRef and this widget can be
    // gone by the time the resolve lands (executing closes the dropdown).
    final history = ref.read(mapSearchHistoryProvider.notifier);
    // Read lazily: a deep-search prediction already carries its resolved area,
    // so the common pick costs no request — and no API client either.
    final area = await resolveSearchPrediction(
      prediction,
      () => ref
          .read(geoApiProvider)
          .resolveArea(
            id: prediction.id,
            sessionToken: controller.sessionToken,
            locale:
                ref.read(localeProvider)?.languageCode ??
                WidgetsBinding.instance.platformDispatcher.locale.languageCode,
          ),
    );
    controller.afterResolve();
    // A resolve that fails or comes back empty leaves the map untouched — the
    // dropdown is already closed, so there is nothing to un-render.
    if (area == null) return;
    // Recorded only once the resolve succeeded, so history never accumulates
    // a location that can't be re-executed. `target_id` is the `/geo/areas`
    // prediction id verbatim, per the PROD-3495 contract.
    unawaited(
      history.recordSelection(
        type: MapSearchHistoryType.location,
        targetId: prediction.id,
        displayLabel: prediction.name,
      ),
    );
    await executor.executeLocation(area);
  }
}

/// PROD-3652 — the 0-char state under a selected domain tag: a prompt to type,
/// in place of the past-searches list.
///
/// The swap is deliberate rather than additive. History is global and untyped,
/// so it cannot honour the tag the user just set — offering a Zine they once
/// opened under a "Sítios" tag would be the same category of lie Decision #54
/// removed from the scoped 0-char state. The tag has narrowed the question; the
/// only thing missing is the text.
class _ScopedPrompt extends StatelessWidget {
  const _ScopedPrompt({required this.domain});

  final MapSuggestSection domain;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Interpolates the tag's own label, so the prompt names the thing the user
    // just tapped in exactly the words the tag used.
    return MapSuggestExplainer(
      text: l10n.mapSuggestScopedPrompt(mapDomainTagLabel(l10n, domain)),
    );
  }
}
