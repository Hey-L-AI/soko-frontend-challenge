import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../providers/place_filters_provider.dart';
import '../utils/facet_labels.dart';
import 'soko_filter_chip.dart';

/// Filter strip shown beneath the search-category selector when the Places
/// tab is active, and on the Near-you see-more page. Renders backend-owned
/// place type facets as multi-select chips; selected ids are sent to
/// `POST /places/search` as `facets`.
///
/// Chrome per the Figma mock (see-more redesign): flat Soko-palette pills
/// ([SokoFilterChip]) cycling by the facet's stable catalog index, ink
/// text/icons, ink border when selected.
class PlaceFiltersBar extends ConsumerStatefulWidget {
  /// Horizontal insets applied INSIDE the scroll view — see
  /// [EventFiltersBar.padding].
  final EdgeInsetsGeometry padding;

  /// Which surface these chips are filtering, for `filter_applied` /
  /// `filters_reset`. Defaulted to the legacy Discovery page so the existing
  /// series stay continuous; the v2 feed passes its own — see
  /// [EventFiltersBar.surface].
  final String surface;

  const PlaceFiltersBar({
    super.key,
    this.padding = EdgeInsets.zero,
    this.surface = 'discover_places',
  });

  @override
  ConsumerState<PlaceFiltersBar> createState() => _PlaceFiltersBarState();
}

class _PlaceFiltersBarState extends ConsumerState<PlaceFiltersBar> {
  /// Owns the strip's horizontal scroll so a selection can bring the
  /// chip back into view (selected chips float to the front — see
  /// [EventFiltersBar] for the rationale).
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToFront() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final selectedFacets = ref.watch(placeTypeFacetFilterProvider);
    final facetsAsync = ref.watch(placeTypeFacetsProvider);
    final facets = facetsAsync.valueOrNull ?? const <PlaceTypeFacet>[];
    final hasSelection = selectedFacets.isNotEmpty;

    // Selected facets float to the front of the strip, but each keeps the
    // fill color of its stable catalog index so selection never recolors.
    final indexed = facets.indexed.toList();
    final ordered = [
      ...indexed.where((e) => selectedFacets.contains(e.$2.id)),
      ...indexed.where((e) => !selectedFacets.contains(e.$2.id)),
    ];

    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: widget.padding,
      child: Row(
        children: [
          if (hasSelection)
            SokoFilterClearChip(
              semanticLabel: l10n.discoveryPlaceFilterClear,
              onTap: () {
                ref.read(placeTypeFacetFilterProvider.notifier).state =
                    const <String>{};
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackFiltersReset(
                      surface: widget.surface,
                      filterType: 'category',
                    );
              },
            ),
          for (final (position, entry) in ordered.indexed) ...[
            SizedBox(width: position == 0 && !hasSelection ? 0 : 8),
            SokoFilterChip(
              label: placeFacetLabel(l10n, entry.$2),
              icon: placeFacetIcon(entry.$2),
              fill: sokoFilterChipFill(entry.$1),
              selected: selectedFacets.contains(entry.$2.id),
              onTap: () => _toggleFacet(selectedFacets, entry.$2.id),
            ),
          ],
        ],
      ),
    );
  }

  void _toggleFacet(Set<String> current, String facetId) {
    final next = Set<String>.from(current);
    final added = !next.remove(facetId);
    if (added) next.add(facetId);
    ref.read(placeTypeFacetFilterProvider.notifier).state = next;
    ref
        .read(unifiedAnalyticsProvider)
        .trackFilterApplied(
          surface: widget.surface,
          filterType: 'category',
          value: facetId,
          selected: added,
        );
    // A newly-selected chip floats to the front — follow it so it stays
    // visible instead of vanishing off the scrolled viewport.
    if (added) _scrollToFront();
  }
}

/// Maps a place facet's stable backend [PlaceTypeFacet.labelKey] to a Lucide
/// leading glyph. Keyed on `label_key` (not the localized label) so the icon
/// survives translation. Unknown keys return null → the chip renders icon-less
/// rather than guessing, so a new backend facet still shows (just no glyph).
IconData? placeFacetIcon(PlaceTypeFacet facet) => switch (facet.labelKey) {
  'facet.eat_drink' => LucideIcons.utensils,
  'facet.bars_nightlife' => LucideIcons.martini,
  'facet.shops_markets' => LucideIcons.shopping_bag,
  'facet.arts_culture' => LucideIcons.palette,
  'facet.music_events' => LucideIcons.music,
  'facet.entertainment' => LucideIcons.drama,
  'facet.sights_heritage' => LucideIcons.landmark,
  'facet.outdoors_nature' => LucideIcons.trees,
  'facet.sports_fitness' => LucideIcons.dumbbell,
  'facet.learning_community' => LucideIcons.graduation_cap,
  _ => null,
};
