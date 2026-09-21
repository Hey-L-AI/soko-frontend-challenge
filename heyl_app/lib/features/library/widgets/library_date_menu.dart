import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/glassmorphic_popup_menu.dart';
import '../providers/library_filter_provider.dart';
import 'library_month_calendar.dart';

/// Date calendar dropdown under [child].
class LibraryDateMenu extends ConsumerWidget {
  const LibraryDateMenu({
    super.key,
    required this.child,
    required this.onPicked,
    this.selectedDate,
    this.valueLabel,
    this.selected = false,
  });

  final Widget child;
  final DateTime? selectedDate;
  final ValueChanged<DateTime> onPicked;

  /// The picked date as it reads on the chip, or null while none is picked.
  ///
  /// The Tag inside is rendered with `provideSemantics: false`, so this node is
  /// the ONLY thing assistive tech hears for the whole trigger — the chip's own
  /// text is excluded along with the rest of its subtree. Announced as the
  /// node's `value`, which is the field screen readers pair with a label, so no
  /// new localized string is needed to say "Pick a date: Sep 15".
  final String? valueLabel;

  /// Whether the trigger is the joined, level-two half of a filter. Mirrors the
  /// `selected` state every sibling Tag exposes.
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(libraryEventHighlightDaysProvider);

    return GlassmorphicPopupMenu<void>(
      backgroundColor: AppColors.sokoShade5,
      border: Border.all(
        color: AppColors.sokoInk.withValues(alpha: 0.08),
        width: 1,
      ),
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      offset: const Offset(0, 8),
      menuPadding: EdgeInsets.zero,
      blurSigma: 0,
      panelBuilder: (dismiss) => LibraryMonthCalendar(
        selectedDate: selectedDate,
        eventDays: days,
        onPicked: (day) {
          onPicked(day);
          dismiss();
        },
      ),
      child: Semantics(
        button: true,
        label: Lt.of(context).libraryDateSemantic,
        value: valueLabel,
        selected: selected,
        child: child,
      ),
    );
  }
}
