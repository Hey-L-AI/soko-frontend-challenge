// Unified search — the grouped results list, on its own.
//
// This is the part that must look identical on every surface: coloured + iconed
// section header pill, 56 px thumbnail rows, the chat-style "View other …"
// expander that pops its extra rows in. [UnifiedContentSearch] stacks it under the
// shared input + chip row; the feed (its input/chips live in the morphing
// Procura row) and the map (its own search bar + domain chips) mount it directly.

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../soko_tag.dart';
import 'unified_search_expander.dart';
import 'unified_search_models.dart';
import 'unified_search_result_row.dart';

class UnifiedSearchResults extends StatelessWidget {
  const UnifiedSearchResults({
    super.key,
    required this.sections,
    required this.expanderLabel,
    required this.collapseLabel,
    this.loading = false,
    this.query = '',
    this.emptyLabel,
    this.showLikeButtons = false,
    this.provenance,
    this.onLikeToggled,
  });

  final List<UnifiedSearchSection> sections;
  final String Function(BuildContext, SokoSearchCategory) expanderLabel;
  final String collapseLabel;
  final bool loading;
  final String query;
  final String? emptyLabel;
  final bool showLikeButtons;
  final String? provenance;
  final void Function(UnifiedSearchRow row, bool nowLiked)? onLikeToggled;

  bool get _hasResults => sections.any((s) => s.rows.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    if (loading && !_hasResults) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sokoPink,
            ),
          ),
        ),
      );
    }
    if (query.isNotEmpty && !loading && !_hasResults) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(
          emptyLabel ?? '',
          textAlign: TextAlign.center,
          style: AppTheme.body(fontSize: 14, color: AppColors.sokoShade3),
        ),
      );
    }
    if (!_hasResults) return const SizedBox.shrink();

    final blocks = <Widget>[];
    for (final section in sections) {
      if (section.rows.isEmpty) continue;
      if (blocks.isNotEmpty) blocks.add(const SizedBox(height: 16));
      // The first block sits right under the chips — no leading divider (that
      // top separator reads as a stray line under the filter row); later blocks
      // keep the hairline as their separator.
      blocks.addAll(_buildSection(context, section, isFirst: blocks.isEmpty));
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
    // Stale-while-revalidating: a refetch keeps the previous results on screen
    // (so the list doesn't blank out on every keystroke) and floats a small
    // spinner over them so it's clear a new search is running.
    if (!loading) return content;
    return Stack(
      children: [
        content,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.sokoPaper,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.sokoInk.withValues(alpha: 0.08),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sokoPink,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSection(
    BuildContext context,
    UnifiedSearchSection section, {
    bool isFirst = false,
  }) {
    final rows = section.rows;
    final canExpand =
        section.onToggleExpand != null &&
        rows.length > kUnifiedSearchCollapsedCount;
    final visibleCount = section.expanded
        ? rows.length
        : rows.length.clamp(0, kUnifiedSearchCollapsedCount);

    final widgets = <Widget>[
      if (!isFirst) ...[
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
        const SizedBox(height: 10),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: UnifiedSectionPill(
          category: section.category,
          label: section.label,
        ),
      ),
      const SizedBox(height: 10),
    ];

    for (var i = 0; i < visibleCount; i++) {
      final rowWidget = UnifiedSearchResultRow(
        key: ValueKey(rows[i].rowKey),
        row: rows[i],
        category: section.category,
        showLike: showLikeButtons,
        provenance: provenance,
        onLikeToggled: onLikeToggled,
      );
      // Rows revealed by expanding (beyond the collapsed preview) pop in.
      widgets.add(
        i >= kUnifiedSearchCollapsedCount
            ? UnifiedSearchPopIn(child: rowWidget)
            : rowWidget,
      );
    }

    if (canExpand) {
      widgets.add(
        UnifiedSearchExpanderRow(
          label: section.expanded
              ? collapseLabel
              : expanderLabel(context, section.category),
          collapse: section.expanded,
          onTap: section.onToggleExpand!,
        ),
      );
    }

    return widgets;
  }
}

/// The coloured + iconed section-header pill (calendar/store/book/user + label),
/// exposed so bespoke result layouts (e.g. the feed's guest wall) match the list.
class UnifiedSectionPill extends StatelessWidget {
  const UnifiedSectionPill({
    super.key,
    required this.category,
    required this.label,
  });

  final SokoSearchCategory category;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SokoTag(
      background: sectionPillColor(category),
      leading: Icon(category.icon, size: 14, color: AppColors.sokoInk),
      child: Text(label, style: SokoTag.textStyle),
    );
  }
}
