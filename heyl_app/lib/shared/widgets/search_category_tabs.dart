import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../core/theme/app_colors.dart';
import '../../features/discovery/providers/search_category_provider.dart';
import '../../l10n/generated/l10n.dart';
import 'bt_sq_ico.dart';

/// Row of the search-category pills (Zines / Eventos / Sítios, optionally
/// preceded by `All`) used by both `DiscoverySearchOverlay` and
/// `ListsSearchOverlay`.
///
/// Visual contract owned here:
///   - Lucide icons (book_open / calendar / map_pin) + localised labels
///     (`discoveryCategory*`); the optional `All` pill (PROD-2086) is
///     label-only.
///   - 4 px horizontal gap between pills.
///   - Centred when the strip fits in the viewport; horizontally
///     scrollable when it doesn't. iPhone-SE-class widths in pt / pt-BR /
///     en still show the trailing pill (scrolls into view rather than
///     getting clipped at the screen edge), while wider viewports keep
///     the centred look.
///   - Selected pill paints Soko/Pink, others paint as outlined idle.
///
/// State is owned by the caller — pass [selected] from the appropriate
/// state provider (Discovery uses `searchCategoryProvider`, Lists uses
/// `listsSearchCategoryProvider`). The widget stays unaware of which
/// surface mounted it so the two pages remain decoupled.
class SearchCategoryTabs extends StatelessWidget {
  final DiscoverySearchCategory selected;
  final ValueChanged<DiscoverySearchCategory> onSelect;

  /// PROD-2026 — when `true`, render an "All" pill as the FIRST tab,
  /// before Zines / Eventos / Sítios. Used by the `/yours` hub search
  /// to expose a stacked-results view across all three categories.
  /// Discovery surfaces leave this off (default) so their result
  /// pages keep the existing 3-tab layout.
  ///
  /// PROD-2086 — the "All" pill renders label-only (no icon) so the
  /// four-pill row fits inside iPhone widths in every locale; the
  /// abstract `layers` glyph it used to carry was the least semantic
  /// of the four anyway.
  final bool includeAll;

  /// Optional map of `Key`s applied to each category chip. The
  /// product tour wires up `GlobalKey`s here so the looping demo
  /// cursor (see `_TourDescobreTabsCursor`) can find each chip's
  /// screen position. Categories absent from the map render their
  /// chip with no `key` — the map is sparse on purpose.
  final Map<DiscoverySearchCategory, Key>? chipKeys;

  /// When `true`, the pills stretch to fill the row in equal shares
  /// (each wrapped in `Expanded`, `BtSqIco.expand`) instead of the
  /// centred / horizontally-scrolling content-sized layout. Discovery
  /// turns this on so the Events / Sítios / Zines row spans the full
  /// width; the `/yours` hub leaves it off (keeps its scrollable 4-pill
  /// row).
  final bool fillWidth;

  /// Optional override of the category order. Defaults to the Discovery order
  /// (Events / Places / Zines). The profile Saved tab passes a Zines-first
  /// order. Any leading `All` pill (when [includeAll]) still renders before
  /// these.
  final List<DiscoverySearchCategory>? categoryOrder;

  const SearchCategoryTabs({
    super.key,
    required this.selected,
    required this.onSelect,
    this.includeAll = false,
    this.chipKeys,
    this.fillWidth = false,
    this.categoryOrder,
  });

  // Events first (the default + only filterable category), then Places,
  // with Zines last. The optional leading `All` pill (PROD-2026) still
  // renders before these on surfaces that opt in via `includeAll`.
  static const List<DiscoverySearchCategory> _baseCategories = [
    DiscoverySearchCategory.eventos,
    DiscoverySearchCategory.sitios,
    DiscoverySearchCategory.zines,
  ];

  /// Per-category icon. The `all` pill is intentionally absent —
  /// it renders label-only (PROD-2086).
  static const Map<DiscoverySearchCategory, IconData> _icons = {
    DiscoverySearchCategory.zines: LucideIcons.book_open,
    DiscoverySearchCategory.eventos: LucideIcons.calendar,
    DiscoverySearchCategory.sitios: LucideIcons.map_pin,
    DiscoverySearchCategory.leitores: LucideIcons.user,
  };

  /// Selected-chip fill. The Figma see-more/overlay redesign settles on
  /// Soko/Pink for every category (superseding the PROD-2221 per-category
  /// tints), so selection reads as one consistent signal across the row.
  /// The override flows through [BtSqIco.selectedBackgroundOverride].
  static const Map<DiscoverySearchCategory, Color> _selectedColors = {
    DiscoverySearchCategory.zines: AppColors.sokoPink,
    DiscoverySearchCategory.eventos: AppColors.sokoPink,
    DiscoverySearchCategory.sitios: AppColors.sokoPink,
    DiscoverySearchCategory.leitores: AppColors.sokoPink,
    DiscoverySearchCategory.all: AppColors.sokoPink,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final labels = <DiscoverySearchCategory, String>{
      DiscoverySearchCategory.zines: l10n.discoveryCategoryZines,
      DiscoverySearchCategory.eventos: l10n.discoveryCategoryEvents,
      DiscoverySearchCategory.sitios: l10n.discoveryCategoryPlaces,
      DiscoverySearchCategory.leitores: l10n.discoveryCategoryReaders,
      DiscoverySearchCategory.all: l10n.discoveryCategoryAll,
    };

    final categories = <DiscoverySearchCategory>[
      if (includeAll) DiscoverySearchCategory.all,
      ...(categoryOrder ?? _baseCategories),
    ];

    // Full-width mode: the pills span the whole row in equal shares.
    if (fillWidth) {
      return _FullWidthTabsRow(
        categories: categories,
        selected: selected,
        onSelect: onSelect,
        labels: labels,
        icons: _icons,
        selectedColors: _selectedColors,
        chipKeys: chipKeys,
      );
    }

    // "Center when fits, scroll when overflows": LayoutBuilder hands the
    // viewport width to a ConstrainedBox(minWidth:) so the inner Row is
    // always at least as wide as the viewport. When chips fit, the Row
    // uses MainAxisAlignment.center to centre them in the surplus space.
    // When chips overflow, the Row sizes to its content (still ≥ minWidth)
    // and SingleChildScrollView lets the user scroll horizontally.
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // `clipBehavior: none` lets the focus/press ring overflow the
          // viewport without getting clipped at the edges, matching the
          // previous Row's behaviour.
          clipBehavior: Clip.none,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < categories.length; i++) ...[
                  KeyedSubtree(
                    key: chipKeys?[categories[i]],
                    child: BtSqIco(
                      icon: _icons[categories[i]],
                      label: labels[categories[i]]!,
                      variant: categories[i] == selected
                          ? BtSqIcoVariant.selected
                          : BtSqIcoVariant.idle,
                      // PROD-2221 — only applied when the chip is the
                      // active filter; idle chips ignore the override.
                      selectedBackgroundOverride: categories[i] == selected
                          ? _selectedColors[categories[i]]
                          : null,
                      onTap: () => onSelect(categories[i]),
                    ),
                  ),
                  if (i < categories.length - 1) const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Full-width static tab row. Each pill gets an equal share of the row.
class _FullWidthTabsRow extends StatelessWidget {
  final List<DiscoverySearchCategory> categories;
  final DiscoverySearchCategory selected;
  final ValueChanged<DiscoverySearchCategory> onSelect;
  final Map<DiscoverySearchCategory, String> labels;
  final Map<DiscoverySearchCategory, IconData> icons;
  final Map<DiscoverySearchCategory, Color> selectedColors;
  final Map<DiscoverySearchCategory, Key>? chipKeys;

  const _FullWidthTabsRow({
    required this.categories,
    required this.selected,
    required this.onSelect,
    required this.labels,
    required this.icons,
    required this.selectedColors,
    required this.chipKeys,
  });

  static const double _gap = 4;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < categories.length; i++) {
      final cat = categories[i];
      children.add(
        Expanded(
          child: KeyedSubtree(
            key: chipKeys?[cat],
            child: BtSqIco(
              icon: icons[cat],
              label: labels[cat]!,
              expand: true,
              variant: cat == selected
                  ? BtSqIcoVariant.selected
                  : BtSqIcoVariant.idle,
              selectedBackgroundOverride: cat == selected
                  ? selectedColors[cat]
                  : null,
              onTap: () => onSelect(cat),
            ),
          ),
        ),
      );
      if (i < categories.length - 1) children.add(const SizedBox(width: _gap));
    }
    return Row(children: children);
  }
}
