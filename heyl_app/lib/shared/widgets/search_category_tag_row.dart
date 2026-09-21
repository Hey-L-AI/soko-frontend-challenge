// PROD-4081 — the search category selector, as the shared Tag row.
//
// The sibling of [SearchCategoryTabs], and its replacement on the two surfaces
// that search: "Descobre a cidade" and the Procura screen. The feed renders the
// same row through `FeedFilterBar`, which is the point — one control across all
// three, per Zé (2026-08-31).
//
// **`SearchCategoryTabs` is NOT deleted.** It still serves the `/lists` hub
// (which needs the "All" pill this row has no concept of) and the public
// profile's Saved tab. Those two were not in scope, and quietly restyling them
// to match would have been a change nobody asked for on screens this ticket
// does not touch.
//
// **`leitores` is labelled "Pessoas" here, and that is now its only name.**
// Discovery was the sole surface that ever rendered the category — the `/lists`
// hub and the Saved tab never include it — so moving Discovery onto this row
// retires "Leitores" outright rather than creating a second name for one thing.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../features/discovery/providers/search_category_provider.dart';
import '../../l10n/generated/l10n.dart';
import 'soko_tag_chip.dart';

/// Per-category glyph. Identical to the feed's filter row, which is what lets
/// the two read as one control rather than two that happen to share a shape.
const Map<DiscoverySearchCategory, IconData> kSearchCategoryIcons = {
  DiscoverySearchCategory.eventos: LucideIcons.calendar,
  DiscoverySearchCategory.sitios: LucideIcons.map_pin,
  DiscoverySearchCategory.zines: LucideIcons.book_open,
  DiscoverySearchCategory.leitores: LucideIcons.user,
};

/// The order both search surfaces render. `all` is deliberately absent — it is
/// a `/lists`-hub concept and that hub keeps [SearchCategoryTabs].
const List<DiscoverySearchCategory> kSearchCategoryTagOrder = [
  DiscoverySearchCategory.eventos,
  DiscoverySearchCategory.sitios,
  DiscoverySearchCategory.zines,
  DiscoverySearchCategory.leitores,
];

String searchCategoryTagLabel(DiscoverySearchCategory c, Lt l10n) =>
    switch (c) {
      DiscoverySearchCategory.eventos => l10n.feedFilterEventos,
      DiscoverySearchCategory.sitios => l10n.feedFilterSitios,
      DiscoverySearchCategory.zines => l10n.feedFilterZines,
      // The feed's word, and now the only one — see the note at the top.
      DiscoverySearchCategory.leitores => l10n.feedFilterPessoas,
      // Unreachable on these two surfaces; the switch stays exhaustive so a
      // future caller that does pass `all` fails to compile rather than
      // rendering a blank chip.
      DiscoverySearchCategory.all => l10n.discoveryCategoryAll,
    };

class SearchCategoryTagRow extends StatelessWidget {
  final DiscoverySearchCategory selected;
  final ValueChanged<DiscoverySearchCategory> onSelect;

  /// Defaults to [kSearchCategoryTagOrder].
  final List<DiscoverySearchCategory>? categoryOrder;

  /// Sparse per-category `Key`s.
  ///
  /// **Load-bearing on Discovery**: the product tour's looping demo cursor
  /// reads these `GlobalKey`s to find each chip's screen position
  /// (`product_tour_host.dart`, `_TourDescobreTabsCursor`). Dropping the
  /// forwarding when Discovery moved off `SearchCategoryTabs` would have left
  /// the tour pointing at nothing — silently, since a missing key is not an
  /// error.
  final Map<DiscoverySearchCategory, Key>? chipKeys;

  /// Forwarded to [SokoTagBar.escapeHorizontalPadding] — the host page's
  /// horizontal padding, which the row grows back out of so it runs
  /// edge-to-edge like the feed's.
  final double escapeHorizontalPadding;

  const SearchCategoryTagRow({
    super.key,
    required this.selected,
    required this.onSelect,
    this.categoryOrder,
    this.chipKeys,
    this.escapeHorizontalPadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final categories = categoryOrder ?? kSearchCategoryTagOrder;

    return SokoTagBar(
      escapeHorizontalPadding: escapeHorizontalPadding,
      items: [
        for (final category in categories)
          SokoTagBarItem(
            id: category,
            child: KeyedSubtree(
              key: chipKeys?[category],
              child: SokoTagChip(
                label: searchCategoryTagLabel(category, l10n),
                icon: kSearchCategoryIcons[category],
                selected: category == selected,
                onTap: () => onSelect(category),
              ),
            ),
          ),
      ],
    );
  }
}
