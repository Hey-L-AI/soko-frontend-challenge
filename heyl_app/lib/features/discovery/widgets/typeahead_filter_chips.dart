import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// Filter for the chat-input typeahead (PROD-1909). [all] merges every
/// data source; the others narrow to a single type.
enum TypeaheadFilter { all, events, places, zines }

/// All / Events / Places chip row rendered above the composer in the
/// typeahead overlay. Uses the same `BtSqIco` design-system primitive as
/// the action-bar search tabs so visual treatment matches across surfaces.
class TypeaheadFilterChips extends StatelessWidget {
  final TypeaheadFilter selected;
  final ValueChanged<TypeaheadFilter> onChanged;

  const TypeaheadFilterChips({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final entries = <(TypeaheadFilter, String, Color?)>[
      // "All" has no category — keep the default selected (Soko/Pink).
      (TypeaheadFilter.all, l10n.discoveryChatTypeaheadFilterAll, null),
      (
        TypeaheadFilter.events,
        l10n.discoveryCategoryEvents,
        AppColors.sokoEvent,
      ),
      (
        TypeaheadFilter.places,
        l10n.discoveryCategoryPlaces,
        AppColors.sokoVenue,
      ),
      (
        TypeaheadFilter.zines,
        l10n.discoveryCategoryZines,
        AppColors.sokoListAccent,
      ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            BtSqIco(
              icon: null,
              label: entries[i].$2,
              variant: entries[i].$1 == selected
                  ? BtSqIcoVariant.selected
                  : BtSqIcoVariant.idle,
              selectedBackgroundOverride: entries[i].$3,
              onTap: () => onChanged(entries[i].$1),
            ),
            if (i < entries.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}
