import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/dropdown/ds_dropdown_menu.dart';
import '../providers/event_filters_provider.dart';
import '../utils/facet_labels.dart';
import 'soko_filter_chip.dart';

/// Filter strip shown beneath the search-category selector when the Events
/// tab is active, and on the Happening see-more page. A single
/// horizontally-scrollable row:
///   1. a time-range trigger that opens a [DSDropdownMenu] (predefined
///      windows — Anytime / Today / Tomorrow / This week / This weekend /
///      This month; no calendar), and
///   2. the product-facing category facet chips ([CategoryFacet]) fetched
///      from the backend-owned catalog, multi-select.
///
/// Chrome per the Figma mock (see-more redesign): flat Soko-palette pills
/// ([SokoFilterChip]) — sokoRed / sokoLilac / sokoYellow cycling by the
/// facet's stable catalog index, sokoBlue reserved for the time-range
/// trigger — ink text/icons, ink border when selected.
///
/// State lives in `eventTimeRangeProvider` + `eventFacetFilterProvider`;
/// the chips themselves come from `eventCategoryFacetsProvider` (the
/// backend-owned facet catalog, PROD-2369), and
/// `discoverySearchResultsProvider` sends those selections to the events
/// search endpoint.
class EventFiltersBar extends ConsumerStatefulWidget {
  /// Horizontal insets applied INSIDE the scroll view, so chips scroll
  /// flush past the edge while resting content respects the margin.
  /// The Discovery overlay renders inside an already-padded column and
  /// passes zero (default); the see-more pages pass 16.
  final EdgeInsetsGeometry padding;

  /// Which surface these chips are filtering, for `filter_applied` /
  /// `filters_reset`.
  ///
  /// **Defaulted, and the default is the legacy Discovery page.** The strip is
  /// mounted on three surfaces now — Discovery's search overlay, the Happening
  /// see-more page, and (since the facets came back) the v2 feed — and until
  /// this existed all three reported `discover_events`, so feed facet usage was
  /// indistinguishable from Discovery's in PostHog. The default keeps the
  /// pre-existing surfaces' series continuous; the feed passes its own.
  final String surface;

  const EventFiltersBar({
    super.key,
    this.padding = EdgeInsets.zero,
    this.surface = 'discover_events',
  });

  @override
  ConsumerState<EventFiltersBar> createState() => _EventFiltersBarState();
}

class _EventFiltersBarState extends ConsumerState<EventFiltersBar> {
  /// Owns the strip's horizontal scroll so a selection can bring the
  /// chip back into view: selected chips float to the front, and a chip
  /// tapped deep in the scrolled tail would otherwise teleport off-view
  /// to the left, reading as "my chip disappeared".
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
    final selectedRange = ref.watch(eventTimeRangeProvider);
    final selectedFacets = ref.watch(eventFacetFilterProvider);
    final facetsAsync = ref.watch(eventCategoryFacetsProvider);

    // The catalog may still be loading or have failed; the time-range filter
    // stays usable regardless. On error we simply render no category chips
    // (events still browse via geo/date/text) rather than surfacing a failure
    // in this secondary chrome.
    final facets = facetsAsync.valueOrNull ?? const <CategoryFacet>[];
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
          _TimeRangeDropdown(
            selected: selectedRange,
            onSelected: (range) {
              ref.read(eventTimeRangeProvider.notifier).state = range;
              ref
                  .read(unifiedAnalyticsProvider)
                  .trackFilterApplied(
                    surface: widget.surface,
                    filterType: 'when',
                    value: range.name,
                  );
            },
          ),
          // The clear (✕) chip only appears once at least one category is
          // selected; tapping it clears the selection back to the
          // all-categories state.
          if (hasSelection) ...[
            const SizedBox(width: 8),
            SokoFilterClearChip(
              semanticLabel: l10n.discoveryEventFilterClear,
              onTap: () {
                ref.read(eventFacetFilterProvider.notifier).state =
                    const <String>{};
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackFiltersReset(
                      surface: widget.surface,
                      filterType: 'category',
                    );
              },
            ),
          ],
          for (final (catalogIndex, facet) in ordered) ...[
            const SizedBox(width: 8),
            SokoFilterChip(
              label: eventFacetLabel(l10n, facet),
              icon: eventFacetIcon(facet),
              fill: sokoFilterChipFill(catalogIndex),
              selected: selectedFacets.contains(facet.id),
              onTap: () => _toggleFacet(selectedFacets, facet.id),
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
    ref.read(eventFacetFilterProvider.notifier).state = next;
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

/// Time-range trigger + [DSDropdownMenu] in the colored-chip chrome:
/// always sokoBlue (the mock's "Esta semana" chip); the ink border marks
/// an applied range so the filter is visible without opening the menu.
class _TimeRangeDropdown extends StatelessWidget {
  const _TimeRangeDropdown({required this.selected, required this.onSelected});

  final EventTimeRange selected;
  final ValueChanged<EventTimeRange> onSelected;

  static const Map<EventTimeRange, IconData> _icons = {
    EventTimeRange.anytime: LucideIcons.calendar,
    EventTimeRange.today: LucideIcons.calendar_check,
    EventTimeRange.tomorrow: LucideIcons.calendar_plus,
    EventTimeRange.thisWeek: LucideIcons.calendar_range,
    EventTimeRange.weekend: LucideIcons.calendar_days,
    EventTimeRange.thisMonth: LucideIcons.calendar_clock,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return DSDropdownMenu<EventTimeRange>(
      semanticLabel: l10n.discoveryEventFilterTimeAnytime,
      offset: const Offset(0, 8),
      items: [
        for (final range in EventTimeRange.values)
          DSDropdownMenuItem(
            value: range,
            icon: _icons[range]!,
            label: eventTimeRangeLabel(l10n, range),
          ),
      ],
      onSelected: onSelected,
      child: SokoFilterChip(
        label: eventTimeRangeLabel(l10n, selected),
        icon: _icons[selected],
        fill: AppColors.sokoBlue,
        selected: selected != EventTimeRange.anytime,
        trailing: const Icon(
          LucideIcons.chevron_down,
          size: 15,
          color: AppColors.sokoInk,
        ),
      ),
    );
  }
}

/// Localized label for a time-range option. Public so any surface that
/// mounts the strip shares the same vocabulary.
String eventTimeRangeLabel(Lt l10n, EventTimeRange range) => switch (range) {
  EventTimeRange.anytime => l10n.discoveryEventFilterTimeAnytime,
  EventTimeRange.today => l10n.discoveryEventFilterTimeToday,
  EventTimeRange.tomorrow => l10n.discoveryEventFilterTimeTomorrow,
  EventTimeRange.thisWeek => l10n.discoveryEventFilterTimeThisWeek,
  EventTimeRange.weekend => l10n.discoveryEventFilterTimeWeekend,
  EventTimeRange.thisMonth => l10n.discoveryEventFilterTimeThisMonth,
};

/// Maps a facet's stable backend [CategoryFacet.labelKey] to a Lucide leading
/// glyph. Keyed on `label_key` (not the localized label) so the icon survives
/// translation. Unknown keys return null → the chip renders icon-less rather
/// than guessing, so a new backend facet still shows (just without a glyph).
IconData? eventFacetIcon(CategoryFacet facet) => switch (facet.labelKey) {
  'facet.music' => LucideIcons.music,
  'facet.arts_culture' => LucideIcons.palette,
  'facet.food_drink' => LucideIcons.utensils,
  'facet.nightlife' => LucideIcons.martini,
  'facet.learning' => LucideIcons.graduation_cap,
  'facet.family' => LucideIcons.baby,
  'facet.outdoors_wellbeing' => LucideIcons.trees,
  'facet.sports' => LucideIcons.dumbbell,
  'facet.community' => LucideIcons.users,
  'facet.networking' => LucideIcons.handshake,
  'facet.markets_shopping' => LucideIcons.shopping_bag,
  _ => null,
};
