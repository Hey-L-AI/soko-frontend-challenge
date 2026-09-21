import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/environment.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../data/models/map_pin.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/clickable.dart';
import '../models/map_query.dart';
import '../providers/map_focus_session_provider.dart';
import '../providers/map_query_provider.dart';
import '../providers/map_search_executor.dart' show clearMapActiveSearch;
import '../providers/map_search_provider.dart';
import '../utils/map_labels.dart';
import '../utils/map_suggest_composer.dart' show MapSuggestSection;
import 'map_shortcut_chip.dart';
import 'tema_facet_sheet.dart';

/// PROD-2671 — the Map page filter model, restyled to the latest designs
/// (Figma `6917-18251`): four buttons — **De quem / O quê / Quando /
/// Tema** — that live in the results-drawer header and expand **upward**
/// into a floating option panel.
///
/// PROD-3043: both the button row ([MapFilterButtons]) and the option panel
/// ([MapFilterOptions]) live in the results drawer's **pinned footer** — the
/// strip below the scrolling results, outside the scroll view. That's what keeps
/// the filters reachable at every snap AND lets a filter stay open while the
/// user drags/scrolls the results.
///
/// (An earlier note here claimed the panel had to be a floating overlay in the
/// screen Stack "because a `DraggableScrollableSheet` clips its content". It
/// doesn't have to be: the drawer's peek height *grows* to include the open
/// option row, so the footer always has room for it — nothing to overflow.)
///
/// Everything here only reads/writes [MapQuery] via [MapQueryNotifier], so
/// the data layer is untouched by this UI (Decision #1).
///
/// v0 caveat: **Tema is a no-op** — the button renders like the others but
/// opens no panel. The two-layer parent→children facet model is a separate
/// backend-gated build (C1); the flat-facet stopgap was removed here.
enum MapFilterTab { who, what, when, tema }

/// Which filter panel is open (null = none). Lifted to a provider so the button
/// row and the option panel stay in sync across widget subtrees, and so a map
/// interaction (pan / zoom / tap-away) can close it.
final mapOpenFilterProvider = StateProvider<MapFilterTab?>((ref) => null);

/// Which filters the user has actually **picked a value in** (a selection),
/// vs. still sitting on their default. A touched filter reads as a pink value —
/// even if the picked value equals the default (the user chose it) — while an
/// untouched one shows the question word + "Padrão". De quem / Quando use this
/// (their default is a single tappable option); O quê derives from value≠default
/// instead (its "both" default isn't a discrete option). Session-scoped.
final mapTouchedFiltersProvider = StateProvider<Set<MapFilterTab>>(
  (ref) => <MapFilterTab>{},
);

/// Transient toast shown when the user taps the muted **Quando** button while
/// the query is venues-only — dates only filter events (Decision: Quando is
/// events-only in v0). Uses the design-system [showSoko] notification (info
/// variant by default) so it matches every other in-app toast and carries the
/// standard X dismiss — rather than a bare Material SnackBar.
void _showEventsOnlyNotice(WidgetRef ref, Lt l10n) {
  showSoko(ref, message: l10n.mapWhenEventsOnlyNotice);
}

/// One button's resolved display (computed in [MapFilterButtons]).
typedef _BtnDisplay = ({String label, bool showDefault, bool selected});

/// The four bottom question buttons — order **O quê · De quem · Quando · Tema**
/// (v0-1.html supersedes the Figma frame here). A button that is **active**
/// (the user picked a value — De quem/Quando: touched; O quê: type≠both; Tema:
/// any theme) reads **pink** with that value; otherwise grey with the question
/// word + a "Padrão" sub-label. While a panel is **open** the button shows the
/// question **word** (so the user knows what they're picking) + a light outline
/// and leading `+`, keeping the pink tint if it's active. Tema opens a modal
/// (never the in-header panel, never "Padrão"; a count once themes are picked).
///
/// The row **scrolls horizontally, edge-to-edge**, when the buttons don't fit
/// the width (like the shortcut chips); it stays centered when they do.
class MapFilterButtons extends ConsumerWidget {
  const MapFilterButtons({super.key});

  /// Fold the open / active / muted state into a single display for a
  /// question button (De quem / O quê / Quando).
  static _BtnDisplay _resolve({
    required bool isOpen,
    required bool active,
    required bool muted,
    required String word,
    required String valueLabel,
  }) {
    // Open → plain **grey word** (no pink, no "Padrão"); the emphasis comes from
    // fading the *other* buttons (handled by the caller). Muted → grey word too.
    if (muted || isOpen) {
      return (label: word, showDefault: false, selected: false);
    }
    if (active) return (label: valueLabel, showDefault: false, selected: true);
    return (label: word, showDefault: true, selected: false);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final open = ref.watch(mapOpenFilterProvider);
    final touched = ref.watch(mapTouchedFiltersProvider);
    final q = ref.watch(mapQueryProvider);
    // Quando is events-only — when the user has narrowed to venues, it can't
    // do anything, so it's muted and a tap explains why instead of opening.
    final whenMuted = !q.dateApplies;
    // When a panel is open, fade every OTHER button so the emphasis lands on
    // the open one (Tema can't be "open" — it uses a modal — so it fades too).
    final anyOpen = open != null;

    // Tapping any question button is a proactive interaction → toggle its panel
    // AND mark it touched, so even landing on its default value reads pink (not
    // the grey "Padrão"). O quê's both-value shows "Ambos".
    void openAndTouch(MapFilterTab tab) {
      final notifier = ref.read(mapOpenFilterProvider.notifier);
      notifier.state = notifier.state == tab ? null : tab;
      ref
          .read(mapTouchedFiltersProvider.notifier)
          .update((prev) => {...prev, tab});
    }

    final what = _resolve(
      isOpen: open == MapFilterTab.what,
      active: touched.contains(MapFilterTab.what),
      muted: false,
      word: l10n.mapFilterWhat,
      valueLabel: mapTypeSummaryLabel(l10n, q.type) ?? l10n.mapTypeBoth,
    );
    final who = _resolve(
      isOpen: open == MapFilterTab.who,
      // PROD-3567 — a list is entered from the **search bar**, never by tapping
      // this button, so the session-scoped `touched` set never learns about it.
      // List mode is a selection by definition (Decision #46 makes it a corpus
      // scope), so it reads active on its own: pink, labelled "Zine".
      active: touched.contains(MapFilterTab.who) || q.isListMode,
      muted: false,
      word: l10n.mapFilterWho,
      valueLabel: mapSourceLabel(l10n, q.source),
    );
    final when = _resolve(
      isOpen: open == MapFilterTab.when,
      active: touched.contains(MapFilterTab.when),
      muted: whenMuted,
      word: l10n.mapFilterWhen,
      valueLabel: mapDateLabel(l10n, q.date),
    );
    final temaCount = q.facetFilters.length;
    final temaActive = temaCount > 0;

    final row = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _QuestionButton(
          label: what.label,
          showDefault: what.showDefault,
          selected: what.selected,
          open: open == MapFilterTab.what,
          faded: anyOpen && open != MapFilterTab.what,
          onTap: () => openAndTouch(MapFilterTab.what),
        ),
        const SizedBox(width: 6),
        _QuestionButton(
          label: who.label,
          showDefault: who.showDefault,
          selected: who.selected,
          open: open == MapFilterTab.who,
          faded: anyOpen && open != MapFilterTab.who,
          onTap: () => openAndTouch(MapFilterTab.who),
        ),
        const SizedBox(width: 6),
        _QuestionButton(
          label: when.label,
          showDefault: when.showDefault,
          selected: when.selected,
          open: !whenMuted && open == MapFilterTab.when,
          faded: anyOpen && open != MapFilterTab.when,
          muted: whenMuted,
          onTap: () {
            if (whenMuted) {
              ref.read(mapOpenFilterProvider.notifier).state = null;
              _showEventsOnlyNotice(ref, l10n);
            } else {
              openAndTouch(MapFilterTab.when);
            }
          },
        ),
        const SizedBox(width: 8),
        // Tema → opens the two-layer facet picker (modal sheet): no in-header
        // open cue, never "Padrão"; pink + count once themes are picked.
        _QuestionButton(
          label: temaActive ? l10n.mapTemaCount(temaCount) : l10n.mapTema,
          showDefault: false,
          selected: temaActive,
          open: false,
          faded: anyOpen,
          onTap: () async {
            ref.read(mapOpenFilterProvider.notifier).state = null;
            final result = await showTemaSheet(context, ref);
            if (result != null) {
              ref.read(mapQueryProvider.notifier).setFacetFilters(result);
            }
          },
        ),
      ],
    );

    // Edge-to-edge horizontal scroll: centered when the buttons fit, scrolling
    // (with a 12px end margin) when they don't — mirrors the shortcut chips.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth - 24),
          child: row,
        ),
      ),
    );
  }
}

/// The open filter's option row (De quem / O quê / Quando), rendered **inside**
/// the results drawer's pinned footer — directly above the question buttons
/// (Figma `6917-18257`) — so it reads as part of the drawer, not a floating
/// card. Reads [mapOpenFilterProvider]; renders nothing when no filter is open.
/// (The drawer's peek height grows to include this row; see [MapResultsSheet].)
class MapFilterOptions extends ConsumerStatefulWidget {
  const MapFilterOptions({super.key});

  @override
  ConsumerState<MapFilterOptions> createState() => _MapFilterOptionsState();
}

class _MapFilterOptionsState extends ConsumerState<MapFilterOptions> {
  void _track(String filter, [String? value]) {
    ref
        .read(unifiedAnalyticsProvider)
        .trackMapFilterChange(filter: filter, value: value);
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(mapOpenFilterProvider);
    if (open == null) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    final q = ref.watch(mapQueryProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: _panelFor(open, l10n, q),
    );
  }

  Widget _panelFor(MapFilterTab tab, Lt l10n, MapQuery q) {
    final notifier = ref.read(mapQueryProvider.notifier);
    switch (tab) {
      case MapFilterTab.who:
        return const _WhoPanel();
      case MapFilterTab.what:
        return _WhatPanel(
          type: q.type,
          onToggle: (type) {
            notifier.setType(type);
            _track('type', type.name);
          },
        );
      case MapFilterTab.when:
        return _WhenPanel(
          selected: q.date,
          onPick: (date) => _pickDate(date, notifier, q),
        );
      case MapFilterTab.tema:
        // Unreachable — the Tema button never opens a panel (v0 no-op).
        return const SizedBox.shrink();
    }
  }

  Future<void> _pickDate(
    MapDateFilter date,
    MapQueryNotifier notifier,
    MapQuery q,
  ) async {
    if (date == MapDateFilter.custom) {
      final now = DateTime.now();
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 2),
        initialDateRange: q.customRange,
      );
      if (range == null) return;
      notifier.setDate(MapDateFilter.custom, customRange: range);
    } else {
      notifier.setDate(date);
    }
    _track('date', date.name);
  }
}

// ---------------------------------------------------------------------------
// Option panels.
// ---------------------------------------------------------------------------

/// "De quem" — single-select source (the `/map/pins` `scope`, PROD-2737).
///
/// All three options are shown and tappable. "Tudo na Soko" (`all`) is
/// guest-safe and works for everyone. "As tuas" / "Que segues"
/// (`yours`/`following`) require a **real account** — the backend returns 422
/// `scope_requires_auth` for guests — so a guest who taps them gets the shared
/// Open-on-Soko login-prompt sheet (explaining the feature + offering sign-in)
/// instead of switching; a signed-in user (incl. the admin who reaches v0)
/// switches directly. "Sugeridas" stays hidden until the recommendations
/// engine (gap G1).
class _WhoPanel extends ConsumerWidget {
  const _WhoPanel();

  /// Apply a source pick, gating the account-only scopes for guests.
  Future<void> _select(BuildContext context, WidgetRef ref, MapSource s) async {
    void apply() {
      // Read at apply time, not before the auth gate: a guest can sign in in
      // between, and the query is free to change while that sheet is up.
      final wasList = ref.read(mapQueryProvider).isListMode;
      ref.read(mapQueryProvider.notifier).setSource(s);
      // PROD-3567 — picking another value is one of list mode's two exits, and
      // both go through the bar's own clear so the surfaces can't disagree.
      // `setSource` above already emptied the keyword in a single write, so
      // this only drops the bar's chrome + promoted pin; `'filter'` keeps the
      // refetch and the analytics attributed to the source pick below.
      if (wasList) clearMapActiveSearch(ref, trigger: 'filter');
      ref
          .read(unifiedAnalyticsProvider)
          .trackMapFilterChange(filter: 'source', value: s.name);
    }

    // "Tudo na Soko" is guest-safe; a signed-in user can pick any scope.
    if (s == MapSource.all || ref.read(isAuthenticatedProvider)) {
      apply();
      return;
    }

    // Guest picked As tuas / Que segues → these need a real account. Explain
    // + offer sign-in via the shared prompt (which preserves the return URL).
    // Shield the (web) Mapbox canvas while the sheet is open, like the Tema
    // sheet. Capture the shield notifier before the await — this panel can
    // unmount when the prompt navigates to /login.
    final l10n = Lt.of(context);
    final modal = ref.read(mapModalOpenProvider.notifier);
    modal.state = true;
    try {
      await requireAuth(
        context,
        ref,
        action: s == MapSource.yours
            ? l10n.mapScopeYoursAuthAction
            : l10n.mapScopeFollowingAuthAction,
        referrer: AuthReferrer.guestMapScope,
        onAuthenticated: apply,
      );
    } finally {
      modal.state = false;
    }
  }

  /// PROD-3653 — the UNSELECTED Zine chip: open the search bar with the Zine
  /// domain tag preselected. This changes no execution — the user still picks a
  /// Zine from the results, through the existing `executeList` path. It only
  /// removes the need to know that typing was the way in.
  ///
  /// `domainUnbounded: true` is the chip's one special power: `/map/suggest`
  /// bounds every domain to the map's corpus, so under "As tuas" this picker
  /// would offer only the user's own Zines and there would be no route to
  /// anyone else's (PROD-3562's contract note). A **discovery** affordance has
  /// to be able to leave the corpus. A manual tap on the Zines tag in the row
  /// does not get this — `setDomain` clears the flag (Zé, 2026-08-05).
  void _pickZine(WidgetRef ref) {
    // Close the panel first. It lives in the drawer's pinned footer, which the
    // focused-mode scrim dims but does not unmount — leaving it open would dim
    // an expanded panel behind the search overlay and hand it back on exit.
    ref.read(mapOpenFilterProvider.notifier).state = null;
    ref
        .read(mapSearchProvider.notifier)
        .enterFocus(domain: MapSuggestSection.lists, domainUnbounded: true);
    // Read AFTER `enterFocus`, which seeds the text from an active search (F5)
    // — so `query_len` reports what the dropdown is actually about to search
    // on, the same thing the tag row's own events report.
    unawaited(
      ref
          .read(unifiedAnalyticsProvider)
          .trackMapSuggestDomainTag(
            domain: MapSuggestSection.lists.name,
            queryLen: ref.read(mapSearchProvider).text.length,
            source: 'who_chip',
          ),
    );
  }

  /// PROD-3653 — the SELECTED Zine chip's `✕`: list mode's first direct exit.
  ///
  /// Identical to what [_select] does when leaving list mode, deliberately:
  /// `setSource(MapSource.all)` clears the active list AND drops the keyword in
  /// **one** state write (a keyword typed inside a Zine means "within this
  /// Zine" — Decision #46), so the map refetches once; `clearMapActiveSearch`
  /// then drops the bar chrome + promoted pin.
  ///
  /// `MapSource.all` is guest-safe, so this needs no auth gate — unlike the
  /// "As tuas" / "A seguir" exits.
  void _clearZine(WidgetRef ref) {
    ref.read(mapQueryProvider.notifier).setSource(MapSource.all);
    clearMapActiveSearch(ref, trigger: 'filter');
    // Its own `filter` value rather than the generic `source`/`all` the other
    // exits log: one gesture, one event, and this is the only exit that sits
    // next to the Zine it clears. The resulting source is always `all`, so
    // nothing is lost by not double-firing.
    unawaited(
      ref
          .read(unifiedAnalyticsProvider)
          .trackMapFilterChange(filter: 'zine_clear'),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final q = ref.watch(mapQueryProvider);
    // Same gate `map_screen.dart` uses for the bar itself — read here so the
    // picker can never outlive the surface it opens.
    final searchV2 =
        EnvironmentConfig.mapSearchV2Enabled ||
        ref.watch(experimentServiceProvider.select((s) => s.enableMapSearchV2));

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 8,
      children: [
        // [MapSource.list] is never one of the *pickable* options: a list can
        // only be **added** via the search bar, never chosen from a list of
        // lists, so it has nothing to offer until one is active.
        for (final s in MapSource.values.where((s) => s != MapSource.list))
          _SmallChip(
            label: mapSourceLabel(l10n, s),
            selected: q.source == s,
            onTap: () => _select(context, ref, s),
          ),
        // PROD-3653 / Decision #52 — the Zine chip: ALWAYS the fourth option,
        // with two states. It supersedes PROD-3567's list-mode-only chip, which
        // rendered `onTap: null` because card D1 said a Zine could only ever be
        // *added* via the search bar.
        //
        //   unselected → "Zine +", opens the search bar with the Zine domain
        //                tag preselected (still the search bar; D1's substance
        //                survives, only its untappable letter is relaxed);
        //   selected   → the Zine's own name + a ✕ that clears it. The BODY
        //                stays inert, matching every other selected chip in
        //                this row — so changing Zine is ✕ then "Zine +", two
        //                steps, traded for the row behaving uniformly.
        //
        // Last in the row so the three permanent options keep their designed
        // positions. Width-capped because a Zine name is user-authored and
        // unbounded; only the label is flexible inside [_SmallChip], so the cap
        // can never eat the ✕.
        //
        // ⚠️ The UNSELECTED face is gated on the same `map-search-v2` flag as
        // the bar it opens. Without the flag `MapSearchBar` and
        // `MapSearchFocusedOverlay` are both unrendered (`map_screen.dart`
        // `showSearchBar`), so `Zine +` would set `focused = true`, fire
        // `map_search_opened`, and show the user **nothing** — a dead control,
        // which is the exact failure mode the PROD-3650 umbrella exists to
        // remove. The SELECTED face stays ungated: it is a label for a state
        // the user is already in, and PROD-3567 shipped it that way.
        if (q.isListMode)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: _SmallChip(
              label: q.activeListName?.trim().isNotEmpty ?? false
                  ? q.activeListName!.trim()
                  : mapSourceLabel(l10n, MapSource.list),
              selected: true,
              trailing: const Icon(
                LucideIcons.x,
                size: 14,
                color: AppColors.sokoInk,
              ),
              onTrailingTap: () => _clearZine(ref),
              trailingSemanticsLabel: l10n.mapWhoZineClear,
            ),
          )
        else if (searchV2)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: _SmallChip(
              label: mapSourceLabel(l10n, MapSource.list),
              selected: false,
              // The `+` is the whole reason this chip can sit next to three
              // that apply a filter instantly: it says "this opens
              // something", not "this selects something".
              leading: const Icon(
                LucideIcons.plus,
                size: 14,
                color: AppColors.sokoInk,
              ),
              onTap: () => _pickZine(ref),
              semanticsLabel: l10n.mapWhoZinePick,
            ),
          ),
      ],
    );
  }
}

/// "O quê" — two toggles (Sítios / Eventos). Selecting neither (or both)
/// means "both" (`MapItemType.all`); selecting one narrows to it.
class _WhatPanel extends StatelessWidget {
  const _WhatPanel({required this.type, required this.onToggle});

  final MapItemType type;
  final ValueChanged<MapItemType> onToggle;

  /// Resolve a tap on the [tapped] chip into the next [MapItemType].
  ///
  /// When both chips are selected ([MapItemType.all]), tapping one isolates to
  /// that chip — i.e. it deselects the *other* one. Otherwise only one chip is
  /// selected, and tapping either lands on "both" (adding the other chip, or
  /// folding "deselect the sole chip" back to showing everything).
  MapItemType _onTap(MapItemType tapped) {
    if (type == MapItemType.all) return tapped;
    return MapItemType.all;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // When the type is "all" (both), render both chips as selected.
    final placesOn = type == MapItemType.all || type == MapItemType.places;
    final eventsOn = type == MapItemType.all || type == MapItemType.events;

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 8,
      children: [
        _SmallChip(
          label: l10n.mapWhatPlaces,
          selected: placesOn,
          onTap: () => onToggle(_onTap(MapItemType.places)),
        ),
        _SmallChip(
          label: l10n.mapTypeEvents,
          selected: eventsOn,
          onTap: () => onToggle(_onTap(MapItemType.events)),
        ),
      ],
    );
  }
}

/// "Quando" — single-select date window (Decision #24). The six options wrap
/// to multiple rows since they don't fit one line.
class _WhenPanel extends StatelessWidget {
  const _WhenPanel({required this.selected, required this.onPick});

  final MapDateFilter selected;
  final ValueChanged<MapDateFilter> onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 8,
      children: [
        for (final d in MapDateFilter.values)
          _SmallChip(
            label: mapDateLabel(l10n, d),
            selected: selected == d,
            onTap: () => onPick(d),
          ),
      ],
    );
  }
}

/// Horizontal, scrollable row of shortcut chips shown just below the search
/// bar (Figma `6917-18137`). v0 renders **10 inert "shortcut placeholder"**
/// chips — the real labels + behaviour arrive when the shortcut feature is
/// built, so they're no-op (null `onTap`) and read as not-yet-active.
///
/// The list spans the **full viewport width** (its host is edge-to-edge) so
/// chips bleed to the left/right edges while scrolling; the [_edgeInset] start/
/// end padding gives the first/last chip a margin at rest.
/// PROD-2671 — the horizontal quick-filter shortcuts under the search field.
///
/// While the filters are at their default ([MapQuery.isDefaultFilters]) this
/// shows the shortcut chips; each tap applies a preset filter combination in one
/// change. Once any filter is non-default (via a shortcut OR a manual edit in
/// the bar below), the whole row collapses to a single centered **"Reset all
/// filters"** button that reverts to defaults and brings the shortcuts back.
class MapShortcutChips extends ConsumerWidget {
  const MapShortcutChips({super.key, this.onSearchThisArea});

  /// PROD-2993 — invoked by this row's "Search this area" state. Owned by
  /// `MapScreen`, because acting on it means moving the camera and ending the
  /// highlight session, neither of which a filter row has any business doing.
  final VoidCallback? onSearchThisArea;

  static const double _edgeInset = 15;

  /// The Restaurants Tema — the `eat_drink` parent's `restaurants` child
  /// (matches `facet.eat_drink.restaurants` in the discovery catalog).
  static const FacetPair _restaurantsFacet = FacetPair(
    parent: 'eat_drink',
    child: 'restaurants',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isDefault = ref.watch(
      mapQueryProvider.select((q) => q.isDefaultFilters),
    );

    // PROD-2993 — **"Search this area" is the third state of this slot**, and it
    // outranks the other two.
    //
    // It appears only while the user has panned the map during a results-
    // highlight session: the pool is frozen, so the pins they're looking at
    // describe an area we haven't searched. That state is transient and it is
    // *wrong* — offering the way out of it beats offering "Reset all filters",
    // which is persistent, and which comes straight back the moment this clears.
    // Give reset priority instead and the feature would silently have no escape
    // hatch whenever any filter happened to be on.
    final cameraDirty = ref.watch(
      mapFocusSessionProvider.select((s) => s?.cameraDirty ?? false),
    );
    if (cameraDirty) {
      return SizedBox(
        height: 30,
        child: Center(
          child: MapShortcutChip(
            label: l10n.mapSearchThisArea,
            color: Colors.white,
            icon: Icons.search,
            onTap: onSearchThisArea,
          ),
        ),
      );
    }

    // Non-default filters → a single centered "Reset all filters" button that
    // clears the query AND the filter-bar highlights (back to a fresh landing).
    if (!isDefault) {
      return SizedBox(
        height: 30,
        child: Center(
          // PROD-2996: same colorful shortcut-chip shape, white fill.
          child: MapShortcutChip(
            label: l10n.mapShortcutResetFilters,
            color: Colors.white,
            onTap: () => _reset(ref),
          ),
        ),
      );
    }

    // Day-adaptive week shortcut: Mon–Thu points at the rest of THIS week; once
    // it's Fri–Sun (this week is nearly over and its weekend is the separate
    // "this weekend" chip), it points at NEXT week instead.
    final earlyWeek = DateTime.now().weekday <= DateTime.thursday;

    // PROD-2996: each shortcut gets a colour. Only Restaurantes maps to a real
    // facet colour (the restaurants/eat_drink red); the rest are an arbitrary
    // assignment from the remaining palette (the shortcuts don't filter a single
    // facet). Chips render icon-free (intended divergence from Figma).
    final chips = <({String label, Color color, VoidCallback onTap})>[
      // PROD-3673 — Events today: the narrowest, most immediate slice, so it
      // leads the row. Green because it IS `AppColors.sokoEvent`; alongside
      // Restaurantes this is the second chip whose colour means something
      // rather than being an arbitrary pick from the leftover palette.
      (
        label: l10n.mapShortcutEventsToday,
        color: AppColors.sokoGreen,
        onTap: () => _apply(
          ref,
          type: MapItemType.events,
          source: MapSource.all,
          date: MapDateFilter.today,
          shortcut: 'today',
        ),
      ),
      // My saved ones: everything I've saved, next 30 days. `yours` needs auth.
      (
        label: l10n.mapShortcutSaved,
        color: AppColors.sokoLilac,
        onTap: () => _applySaved(context, ref),
      ),
      // What's on this/next week: events, everything on Soko.
      (
        label: earlyWeek ? l10n.mapShortcutThisWeek : l10n.mapShortcutNextWeek,
        color: AppColors.sokoBlue,
        onTap: () => _apply(
          ref,
          type: MapItemType.events,
          source: MapSource.all,
          date: earlyWeek ? MapDateFilter.thisWeek : MapDateFilter.nextWeek,
          shortcut: 'this_week',
        ),
      ),
      // Restaurants: venues, Restaurants Tema.
      (
        label: l10n.mapShortcutRestaurants,
        color: AppColors.sokoRed,
        onTap: () => _apply(
          ref,
          type: MapItemType.places,
          source: MapSource.all,
          date: MapDateFilter.next30Days,
          facets: {_restaurantsFacet},
          shortcut: 'restaurants',
        ),
      ),
      // What's on this weekend: events, everything on Soko.
      (
        label: l10n.mapShortcutThisWeekend,
        color: AppColors.sokoYellow,
        onTap: () => _apply(
          ref,
          type: MapItemType.events,
          source: MapSource.all,
          date: MapDateFilter.thisWeekend,
          shortcut: 'this_weekend',
        ),
      ),
    ];

    return SizedBox(
      height: 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _edgeInset),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => MapShortcutChip(
          label: chips[i].label,
          color: chips[i].color,
          onTap: chips[i].onTap,
        ),
      ),
    );
  }

  /// Apply a shortcut's filters AND mirror them onto the bottom filter bar's
  /// **touched** (pink) highlights, so the bar reads exactly as if the user had
  /// picked those values themselves. Only the tabs the shortcut narrows to a
  /// **non-default** value are marked touched (Tema highlights off its own
  /// count, so it isn't in the touched set).
  void _apply(
    WidgetRef ref, {
    required MapItemType type,
    required MapSource source,
    required MapDateFilter date,
    Set<FacetPair> facets = const {},
    // PROD-3219: the shortcut-chip id for analytics ('this_week' | 'restaurants'
    // | 'this_weekend'). Null when called internally (e.g. from `_applySaved`,
    // which logs its own 'saved' event) so we don't double-count.
    String? shortcut,
  }) {
    ref
        .read(mapQueryProvider.notifier)
        .applyShortcut(
          type: type,
          source: source,
          date: date,
          facetFilters: facets,
        );
    ref.read(mapTouchedFiltersProvider.notifier).state = {
      if (source != MapSource.all) MapFilterTab.who,
      if (type != MapItemType.all) MapFilterTab.what,
      if (date != MapDateFilter.next30Days) MapFilterTab.when,
    };
    if (shortcut != null) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackMapFilterChange(filter: 'shortcut', value: shortcut);
    }
  }

  /// Reset everything to a fresh-landing state: default filters + no touched
  /// highlights (so the bottom bar drops back to grey "Padrão" on every button).
  void _reset(WidgetRef ref) {
    ref.read(mapQueryProvider.notifier).resetFilters();
    // PROD-3567 — list mode's other exit (card D2: reset drops the list exactly
    // as it drops a "Yours" selection; `resetFilters` did that above, in one
    // write). Routed through the bar's own clear so both exits agree, and so
    // the bar stops showing an active search whose keyword reset just wiped —
    // which is true of every reset, not only a list one. `setKeyword` inside
    // no-ops here; `'filter'` leaves the 'reset' event below the only one.
    clearMapActiveSearch(ref, trigger: 'filter');
    ref.read(mapTouchedFiltersProvider.notifier).state = <MapFilterTab>{};
    // PROD-3219: "reset all filters" chip.
    ref.read(unifiedAnalyticsProvider).trackMapFilterChange(filter: 'reset');
  }

  /// "My saved ones" → both entities + `yours` + next 30 days. `yours` needs a
  /// real account, so a guest gets the shared Open-on-Soko login prompt (mirrors
  /// the "De quem → As tuas" gate in [_WhoPanel]) before the filter applies.
  Future<void> _applySaved(BuildContext context, WidgetRef ref) async {
    // PROD-3219: log the chip tap on tap (even for a guest who then hits the
    // auth gate). `apply()` calls `_apply` WITHOUT a `shortcut`, so the actual
    // filter application doesn't double-log.
    ref
        .read(unifiedAnalyticsProvider)
        .trackMapFilterChange(filter: 'shortcut', value: 'saved');
    void apply() => _apply(
      ref,
      type: MapItemType.all,
      source: MapSource.yours,
      date: MapDateFilter.next30Days,
    );

    if (ref.read(isAuthenticatedProvider)) {
      apply();
      return;
    }

    final l10n = Lt.of(context);
    final modal = ref.read(mapModalOpenProvider.notifier);
    modal.state = true;
    try {
      await requireAuth(
        context,
        ref,
        action: l10n.mapScopeYoursAuthAction,
        referrer: AuthReferrer.guestMapScope,
        onAuthenticated: apply,
      );
    } finally {
      modal.state = false;
    }
  }
}

// ---------------------------------------------------------------------------
// Building blocks.
// ---------------------------------------------------------------------------

/// One of the 4 bottom question buttons — a map-local, fixed-height (48) button
/// matching the DS [BtSqIco] chrome (r6, Ink @ 6% idle / Soko/Pink when
/// [selected], Zalando-Light 14). Fixed height so all four align whether they
/// show a single-line [label] or, when [showDefault], the [label] + a small grey
/// "Padrão" sub-label.
///
/// [open] (its panel is open) adds a hairline outline; the caller keeps it grey
/// (not [selected]/pink) and fades every other button ([faded]) so the emphasis
/// lands on the open one. [muted] dims the button but keeps it tappable (the tap
/// explains). [faded] dims non-open buttons while another panel is open — but a
/// **hover** over a faded button cancels the fade (web) so it's easy to target.
class _QuestionButton extends StatefulWidget {
  const _QuestionButton({
    required this.label,
    required this.selected,
    required this.open,
    required this.onTap,
    this.showDefault = false,
    this.muted = false,
    this.faded = false,
  });

  final String label;
  final bool showDefault;
  final bool selected;
  final bool open;
  final bool muted;
  final bool faded;
  final VoidCallback onTap;

  @override
  State<_QuestionButton> createState() => _QuestionButtonState();
}

class _QuestionButtonState extends State<_QuestionButton> {
  static const double _height = 48;

  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    const ink = AppColors.sokoInk;

    const labelStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w300,
      height: 1.2,
      color: ink,
    );

    final Widget content;
    if (widget.showDefault) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelStyle,
          ),
          const SizedBox(height: 1),
          Text(
            l10n.mapFilterDefault,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w300,
              height: 1.1,
              color: ink.withValues(alpha: 0.5),
            ),
          ),
        ],
      );
    } else {
      content = Text(
        widget.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: labelStyle,
      );
    }

    final shape = RoundedRectangleBorder(
      side: BorderSide(
        color: widget.open ? ink.withValues(alpha: 0.30) : Colors.transparent,
      ),
      borderRadius: BorderRadius.circular(6),
    );

    Widget button = Material(
      color: widget.selected ? AppColors.sokoPink : ink.withValues(alpha: 0.06),
      shape: shape,
      child: InkWell(
        onTap: widget.onTap,
        customBorder: shape,
        child: SizedBox(
          height: _height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(widthFactor: 1, child: content),
          ),
        ),
      ),
    );

    // Hover cancels the fade (web) so a faded button is easy to target; muted's
    // own dim stays. A single opacity pass — faded (unless hovered) wins.
    final effectiveFaded = widget.faded && !_hovered;
    final opacity = effectiveFaded ? 0.4 : (widget.muted ? 0.45 : 1.0);
    if (opacity < 1.0) button = Opacity(opacity: opacity, child: button);

    return MouseRegion(
      onEnter: (_) {
        if (widget.faded && !_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: button,
    );
  }
}

/// Small flat chip — Figma `Bt_Sq_Ico` small (h24, r2): [AppColors.sokoPink]
/// when [selected], else [AppColors.sokoPaper] + an Ink8 hairline border;
/// Zalando-Light 14. Shared by the De quem / O quê / Quando option panels
/// (tappable) and the shortcut row (a null [onTap] → display-only, no ripple,
/// for the v0 placeholders).
class _SmallChip extends StatelessWidget {
  const _SmallChip({
    required this.label,
    required this.selected,
    this.onTap,
    this.leading,
    this.trailing,
    this.onTrailingTap,
    this.trailingSemanticsLabel,
    this.semanticsLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// PROD-3653 — a small glyph before the label. The `Zine +` chip's `+`: its
  /// three neighbours apply a filter on tap, this one opens the search overlay,
  /// and without an affordance it looks identical while behaving differently.
  final Widget? leading;

  /// PROD-3653 — a small glyph after the label, optionally tappable **on its
  /// own** ([onTrailingTap]) while the chip body stays inert. That split is the
  /// whole point of the selected Zine chip: re-tapping an already-selected chip
  /// does nothing in this row, but its `✕` must still clear the Zine.
  final Widget? trailing;
  final VoidCallback? onTrailingTap;
  final String? trailingSemanticsLabel;

  /// Overrides the label announced to screen readers. The visible label is a
  /// bare noun ("Zine"); a11y wants the *action* ("Choose a Zine").
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      side: selected
          ? BorderSide.none
          : const BorderSide(color: AppColors.sokoInk8),
      borderRadius: BorderRadius.circular(2),
    );
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // Replaces what a screen reader announces, without touching `data` —
      // so `find.text` and the visible chip are unaffected.
      semanticsLabel: semanticsLabel,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        height: 1.2,
        letterSpacing: -0.14,
        color: AppColors.sokoInk,
      ),
    );
    final content = SizedBox(
      height: 24,
      child: Padding(
        // Trailing padding drops to 0 when there's a trailing control: its own
        // 24×24 target supplies the inset, and doubling up would push the glyph
        // off-centre.
        padding: EdgeInsets.only(left: 6, right: trailing == null ? 6 : 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 3)],
            // Flexible, not Expanded: the row hugs its content so the chip can
            // size to the label, and the caller's `maxWidth` cap is what
            // ellipsizes. Only the LABEL is flexible, so a long Zine name can
            // never be shortened at the ✕'s expense.
            Flexible(child: text),
            if (trailing != null)
              // A full-height 24×24 opaque target. The row's chips are 24 tall
              // and `_SmallChip` is shared with the O quê / Quando panels, so a
              // 44 pt box would both restyle those and overlap the Wrap's
              // 8 px runSpacing. Deliberate divergence, recorded in the PR.
              Semantics(
                button: onTrailingTap != null,
                label: trailingSemanticsLabel,
                child: Clickable(
                  onTap: onTrailingTap,
                  child: SizedBox(
                    height: 24,
                    width: 24,
                    child: Center(child: trailing),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return Material(
      color: selected ? AppColors.sokoPink : AppColors.sokoPaper,
      shape: shape,
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, customBorder: shape, child: content),
    );
  }
}
