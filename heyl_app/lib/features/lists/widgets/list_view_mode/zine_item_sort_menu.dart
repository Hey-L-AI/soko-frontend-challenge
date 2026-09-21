import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../data/models/models.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/dropdown/ds_dropdown_menu.dart';
import '../../providers/unified_list_provider.dart';

/// Sort trigger for the list-view body — mirrors the Biblioteca sort chip
/// (`LibrarySortBar`) so the two surfaces read as one control.
///
/// The menu carries a fourth entry above the three wire values: "Original
/// order", which sends no `sort` at all. That is the BE's way of asking for
/// the list's own stored sequence, including an owner's hand-arranged one, so
/// it is a real choice rather than a reset affordance.
class ZineItemSortMenu extends ConsumerWidget {
  final String listId;

  const ZineItemSortMenu({super.key, required this.listId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lt = Lt.of(context);
    final sort = ref.watch(unifiedListProvider(listId).select((s) => s.sort));

    String labelFor(ZineItemSort? s) => switch (s) {
      null => lt.listSortOriginal,
      ZineItemSort.recent => lt.listSortRecent,
      ZineItemSort.alphabetical => lt.listSortAlphabetical,
      ZineItemSort.chronological => lt.listSortChronological,
    };
    IconData iconFor(ZineItemSort? s) => switch (s) {
      null => LucideIcons.list_ordered,
      ZineItemSort.recent => LucideIcons.clock,
      ZineItemSort.alphabetical => LucideIcons.a_large_small,
      ZineItemSort.chronological => LucideIcons.calendar,
    };

    // A single arrow pointing the way this sort actually runs, read off the
    // backend's ORDER BY (heyl-backend `crud/user_list_items.py`), not guessed:
    //
    //   recent        added_at DESC                    -> down
    //   alphabetical  coalesce(title, name) ASC        -> up
    //   chronological next occurrence ASC (soonest)    -> up
    //
    // `null` gets no arrow on purpose. Omitting `sort` yields whatever the list
    // stores: `added_at` DESC on a default list, `sort_order` ASC once an owner
    // has arranged one. `UserList.sort_mode` is not modelled client-side, so the
    // direction is genuinely unknown here and an arrow would be wrong half the
    // time.
    IconData triggerIconFor(ZineItemSort? s) => switch (s) {
      null => LucideIcons.list_ordered,
      ZineItemSort.recent => LucideIcons.arrow_down,
      ZineItemSort.alphabetical => LucideIcons.arrow_up,
      ZineItemSort.chronological => LucideIcons.arrow_up,
    };

    // `null` first so the list's own order stays the obvious way back.
    const options = <ZineItemSort?>[null, ...ZineItemSort.values];

    return DSDropdownMenu<int>(
      semanticLabel: lt.listSortSemantic,
      items: [
        for (var i = 0; i < options.length; i++)
          DSDropdownMenuItem(
            // Indices, not the enum: `null` is a selectable value here and
            // `DSDropdownMenu.onSelected` cannot express it.
            value: i,
            icon: iconFor(options[i]),
            label: labelFor(options[i]),
            selected: options[i] == sort,
          ),
      ],
      onSelected: (i) => unawaited(
        ref.read(unifiedListProvider(listId).notifier).setSort(options[i]),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(triggerIconFor(sort), size: 14, color: AppColors.sokoInk),
          const SizedBox(width: 6),
          Text(
            labelFor(sort),
            style: AppTheme.mobileB2Reg(color: AppColors.sokoInk),
          ),
        ],
      ),
    );
  }
}
