import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/dropdown/ds_dropdown_menu.dart';
import '../models/library_filter.dart';
import '../providers/library_filter_provider.dart';
import 'library_glyph.dart';

/// Sort + list/grid strip under the category chips.
class LibrarySortBar extends ConsumerWidget {
  const LibrarySortBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lt = Lt.of(context);
    final sort = ref.watch(librarySortProvider);
    final view = ref.watch(libraryViewProvider);
    final style = AppTheme.mobileB2Reg(color: AppColors.sokoInk);

    final sortLabel = switch (sort) {
      LibrarySort.recent => lt.librarySortOrderRecent,
      LibrarySort.alphabetical => lt.librarySortOrderAlphabetical,
      LibrarySort.chronological => lt.librarySortOrderChronological,
    };
    final viewLabel = view == LibraryViewMode.list
        ? lt.libraryViewList
        : lt.libraryViewGrid;
    final viewAsset = view == LibraryViewMode.list
        ? LibraryGlyph.listAsset
        : LibraryGlyph.gridAsset;

    return Row(
      children: [
        DSDropdownMenu<LibrarySort>(
          semanticLabel: lt.librarySortSemantic,
          items: [
            for (final s in LibrarySort.values)
              DSDropdownMenuItem(
                value: s,
                icon: switch (s) {
                  LibrarySort.recent => LucideIcons.clock,
                  LibrarySort.alphabetical => LucideIcons.a_large_small,
                  LibrarySort.chronological => LucideIcons.calendar,
                },
                label: switch (s) {
                  LibrarySort.recent => lt.librarySortRecent,
                  LibrarySort.alphabetical => lt.librarySortAlphabetical,
                  LibrarySort.chronological => lt.librarySortChronological,
                },
                selected: s == sort,
              ),
          ],
          onSelected: (s) => ref.read(librarySortProvider.notifier).state = s,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LibraryGlyph.ink(LibraryGlyph.arrowDownAsset),
              const SizedBox(width: 6),
              Text(sortLabel, style: style),
            ],
          ),
        ),
        const Spacer(),
        DSDropdownMenu<LibraryViewMode>(
          semanticLabel: lt.libraryViewSemantic,
          items: [
            DSDropdownMenuItem(
              value: LibraryViewMode.list,
              icon: LucideIcons.list,
              label: lt.libraryViewList,
              selected: view == LibraryViewMode.list,
            ),
            DSDropdownMenuItem(
              value: LibraryViewMode.grid,
              icon: LucideIcons.layout_grid,
              label: lt.libraryViewGrid,
              selected: view == LibraryViewMode.grid,
            ),
          ],
          onSelected: (v) => ref.read(libraryViewProvider.notifier).state = v,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LibraryGlyph.ink(viewAsset),
              const SizedBox(width: 6),
              Text(viewLabel, style: style),
            ],
          ),
        ),
      ],
    );
  }
}
