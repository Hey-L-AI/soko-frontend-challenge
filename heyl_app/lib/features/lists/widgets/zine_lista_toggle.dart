import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../providers/unified_list_provider.dart';

/// Single labeled view-mode toggle (Figma `Bt_Sq_ToggleView`, `7660:28046`).
/// A [BtSqIco] `normal` chip showing the CURRENT view mode — 📖 Zine /
/// ☰ Lista — that flips straight to the other mode on tap (no segmented
/// track, no chevron). The icon + label cross-fade so the change reads as a
/// state flip rather than a silent relabel, matching the sibling
/// [VisibilityMenuChip] on the same action row.
///
/// Height 40 / radius 6 / Soko/Shade5-family fill so it sits flush with the
/// surrounding `Bt_Sq_Ico` header action chrome.
class ZineListaToggle extends StatelessWidget {
  final ListViewMode currentMode;
  final ValueChanged<ListViewMode> onModeChanged;

  const ZineListaToggle({
    super.key,
    required this.currentMode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isZine = currentMode == ListViewMode.zine;
    // Tapping the pill switches TO the other mode; the chip always shows the
    // mode currently in effect.
    final next = isZine ? ListViewMode.list : ListViewMode.zine;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: BtSqIco(
        // Re-key on the mode so the switcher animates the icon+label swap on
        // every toggle instead of mutating the chip in place.
        key: ValueKey(currentMode),
        icon: isZine ? LucideIcons.book_open : LucideIcons.list,
        label: isZine
            ? l10n.listPageHeaderToggleZine
            : l10n.listPageHeaderToggleLista,
        variant: BtSqIcoVariant.normal,
        onTap: () => onModeChanged(next),
      ),
    );
  }
}
