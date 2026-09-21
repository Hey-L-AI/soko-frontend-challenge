import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/search/unified_search_models.dart';
import '../providers/map_query_provider.dart';
import '../providers/map_search_provider.dart';
import '../utils/map_suggest_composer.dart';
import 'map_shortcut_chip.dart';
import 'map_suggest_rows.dart' show MapSuggestScopeKind, mapSuggestScopeKindOf;

/// PROD-3652 — the domain tags offered in the focused search bar, in order.
///
/// **This list is the extensibility seam.** Adding a domain later means adding
/// one entry here plus its label in [mapDomainTagLabel] — never touching the
/// layout, the toggle, or the fetch. Order follows the umbrella
/// (location · venue · event · zine); locations leads because it is the one
/// domain whose rows are places rather than things.
const List<MapSuggestSection> kMapDomainTags = <MapSuggestSection>[
  MapSuggestSection.locations,
  MapSuggestSection.venues,
  MapSuggestSection.events,
  MapSuggestSection.lists,
];

/// The unified [SokoSearchCategory] a map domain section maps to — the seam that
/// lets the map reuse the shared icons + section pills.
SokoSearchCategory sokoCategoryForMapSection(MapSuggestSection section) =>
    switch (section) {
      MapSuggestSection.locations => SokoSearchCategory.locations,
      MapSuggestSection.venues => SokoSearchCategory.venues,
      MapSuggestSection.events => SokoSearchCategory.events,
      MapSuggestSection.lists => SokoSearchCategory.zines,
    };

/// Unified-search: the filter glyph each domain tag carries, from the SINGLE
/// source ([SokoSearchCategoryChrome.icon]) so the chip, the section pill and
/// every other surface read as one.
IconData mapDomainTagIcon(MapSuggestSection section) =>
    sokoCategoryForMapSection(section).icon;

/// The tag's label. Each is its own ARB key rather than a reuse of the "O quê"
/// filter's (`mapTypePlaces` etc.): those name a *filter value* on a different
/// surface, and one string serving two surfaces is how the two silently
/// diverge the first time either is reworded.
String mapDomainTagLabel(Lt l10n, MapSuggestSection section) =>
    switch (section) {
      MapSuggestSection.locations => l10n.mapDomainTagLocations,
      MapSuggestSection.venues => l10n.mapDomainTagVenues,
      MapSuggestSection.events => l10n.mapDomainTagEvents,
      MapSuggestSection.lists => l10n.mapDomainTagZines,
    };

/// Whether [section] can be offered as a tag right now.
///
/// Two independent gates, both real:
///
/// 1. [sectionIsOffered] — the `kMapSuggestShowLists` kill switch, so the Zine
///    domain is withdrawn from the dropdown and this row by one constant.
/// 2. **A list corpus hides the Zine tag** (Zé, 2026-08-04). Inside a Zine the
///    backend drops the lists domain outright, so the tag could only ever
///    return an empty block — the "button that can never fetch anything" this
///    umbrella exists to remove. It is not fixable server-side today either:
///    the scoped-corpus resolver has no `list` branch and would fall through
///    to the viewer's *followed* lists, which is wrong rather than empty.
///    The user's route to another Zine is the scope banner's ×, which clears
///    the corpus and — because this is read reactively — brings the tag back
///    in the same frame.
///
/// Keyed on [mapSuggestScopeKindOf] rather than `MapQuery.isListMode` on
/// purpose: that resolver reads `scopeWire`, the value actually sent, so the
/// tag can never disagree with the request. A half-set list state reads
/// unbounded on both sides at once.
bool mapDomainTagIsOffered(
  MapSuggestSection section, {
  required MapSuggestScopeKind? corpus,
}) {
  if (!sectionIsOffered(section)) return false;
  if (section == MapSuggestSection.lists &&
      corpus == MapSuggestScopeKind.list) {
    return false;
  }
  return true;
}

/// PROD-3652 — the horizontal, edge-to-edge row of domain tags shown while the
/// search bar is focused. Tapping one restricts the SUGGESTIONS to that domain
/// (and asks the backend for a deeper page of it); execution is untouched.
///
/// Rendered by `MapSearchFocusedOverlay` in the shortcut-chips slot, above the
/// scrim so it stays lit while the rest of the page dims. It deliberately uses
/// the same [MapShortcutChip] and the same 15 px edge padding as
/// `MapShortcutChips`, whose slot it takes over — the two rows must read as
/// the same control, because to the user they occupy the same place.
class MapDomainTagRow extends ConsumerWidget {
  const MapDomainTagRow({super.key});

  /// Start/end padding, matching `MapShortcutChips._edgeInset`. It is what
  /// makes the first and last chip sit inset at rest while the row still
  /// bleeds off both screen edges as it scrolls.
  static const double _edgeInset = 15;

  /// Row height, matching the chip and the shortcut row it replaces.
  static const double height = 30;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final selected = ref.watch(mapSearchProvider.select((s) => s.domain));
    // Reactive by design: the scope banner's × writes the query, this rebuilds,
    // and the Zine tag reappears in the same frame with no re-open. Watch, not
    // read — a one-shot read here is the way this behaviour rots.
    final corpus = ref.watch(mapQueryProvider.select(mapSuggestScopeKindOf));

    final tags = <MapSuggestSection>[
      for (final section in kMapDomainTags)
        if (mapDomainTagIsOffered(section, corpus: corpus)) section,
    ];

    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _edgeInset),
        itemCount: tags.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final section = tags[i];
          final isSelected = section == selected;
          return MapShortcutChip(
            label: mapDomainTagLabel(l10n, section),
            // Unified-search: the filter glyph now leads the tag, matching the
            // grouped result section pills.
            icon: mapDomainTagIcon(section),
            // Selection rides the chip's existing `color`, so the shared
            // component needed no new API. White also picks up its floating
            // shadow, which is what keeps an unselected tag legible over the
            // dimmed map.
            color: isSelected ? AppColors.sokoPink : Colors.white,
            semanticsSelected: isSelected,
            onTap: () => _onTap(ref, section, isSelected: isSelected),
          );
        },
      ),
    );
  }

  void _onTap(
    WidgetRef ref,
    MapSuggestSection section, {
    required bool isSelected,
  }) {
    // Re-tapping the selected tag clears it — the row has no separate "all"
    // entry, so the selected tag is its own off switch.
    final next = isSelected ? null : section;
    ref.read(mapSearchProvider.notifier).setDomain(next);
    if (next == null) return;
    // PROD-3652 — select only, never deselect. A deselect is a return to the
    // default, not demand for a domain, and counting it would make the metric
    // read as twice the interest that exists. Same rule as
    // `map_suggest_expanded`, whose `toggleExpanded` serves both directions
    // for the same reason.
    unawaited(
      ref
          .read(unifiedAnalyticsProvider)
          .trackMapSuggestDomainTag(
            domain: section.name,
            queryLen: ref.read(mapSearchProvider).text.trim().length,
            source: 'tag_row',
          ),
    );
  }
}
