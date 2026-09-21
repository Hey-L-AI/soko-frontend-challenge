import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../glassmorphic_popup_menu.dart';

/// Single icon + label entry inside a [DSDropdownMenu].
///
/// `destructive` swaps the row's icon + label colour to Soko/Red — used
/// for delete-style actions (matches Figma `6353:31758`).
class DSDropdownMenuItem<T> {
  final T value;
  final IconData icon;
  final String label;
  final bool destructive;

  /// When true, a trailing checkmark marks this row as the current
  /// selection (used for single-choice menus like visibility). Default
  /// false leaves action-style menus (edit/delete) unchanged.
  final bool selected;

  const DSDropdownMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.destructive = false,
    this.selected = false,
  });
}

/// Soko design-system dropdown menu — a tooltip-style popover anchored
/// to a trigger widget, with rows of (14 px icon, 8 px gap, Mobile/B2
/// Reg label). Use this widget anywhere we want a small contextual
/// action menu; future visual changes (radius, hover, typography) live
/// here so every call site updates in lockstep.
///
/// Visual identity (locked, do not override per call site — see Figma
/// `6353:31759` "Overlay/Edit"):
///   - Surface: `AppColors.sokoShade5` (#F1E5E6 — solid).
///   - Border: 1 px `AppColors.sokoInk @ 8%`.
///   - Border radius: 6 px.
///   - No backdrop blur (Figma renders a flat fill).
///   - Hover: `sokoPaper @ 0.8` per row, 100 ms ease.
///   - Row chrome: 14 px Lucide icon + 8 px gap + Mobile/B2 Reg label.
///     Destructive rows use `AppColors.sokoRed` for both icon + label.
///
/// Position behaviour (inherited from [GlassmorphicPopupMenu]): the
/// popup auto-aligns to the trigger's screen side — left-side triggers
/// → left-aligned menu; right-side triggers → right-aligned. Use
/// [offset] to nudge the panel relative to the trigger; default `(0, 8)`
/// sits the menu 8 px below the trigger's bottom edge.
///
/// Example:
/// ```dart
/// DSDropdownMenu<_Action>(
///   semanticLabel: l10n.listActionEditMenu,
///   items: [
///     DSDropdownMenuItem(
///       value: _Action.edit,
///       icon: LucideIcons.pencil_line,
///       label: 'Edit zine',
///     ),
///     DSDropdownMenuItem(
///       value: _Action.delete,
///       icon: LucideIcons.trash_2,
///       label: 'Delete list',
///       destructive: true,
///     ),
///   ],
///   onSelected: (value) => ...,
///   child: const PencilTriggerChrome(),
/// )
/// ```
class DSDropdownMenu<T> extends StatelessWidget {
  /// Trigger widget — tapping it opens the menu anchored to this child.
  /// Pass the bare chrome; the widget itself supplies the gesture
  /// detector + a11y wrapping via [semanticLabel].
  final Widget child;

  /// Rows shown in the menu, top → bottom.
  final List<DSDropdownMenuItem<T>> items;

  /// Fires with the selected item's value when the user taps a row.
  final ValueChanged<T>? onSelected;

  /// Pixel offset of the menu's top-left from the trigger's bottom-left
  /// (or top-right for right-side triggers). Defaults to `(0, 8)`.
  final Offset offset;

  /// Accessibility label announced for the trigger button (screen
  /// readers). Skipped when null.
  final String? semanticLabel;

  const DSDropdownMenu({
    super.key,
    required this.child,
    required this.items,
    this.onSelected,
    this.offset = const Offset(0, 8),
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final menuItems = items.map((item) {
      final color = item.destructive ? AppColors.sokoRed : AppColors.sokoInk;
      return GlassmorphicMenuItem<T>(
        value: item.value,
        height: 40,
        padding: EdgeInsets.zero,
        child: _DSDropdownMenuRow(
          icon: item.icon,
          label: item.label,
          color: color,
          selected: item.selected,
        ),
      );
    }).toList();

    final wrappedChild = semanticLabel == null
        ? child
        : Semantics(label: semanticLabel, button: true, child: child);

    return GlassmorphicPopupMenu<T>(
      backgroundColor: AppColors.sokoShade5,
      border: Border.all(
        color: AppColors.sokoInk.withValues(alpha: 0.08),
        width: 1,
      ),
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      offset: offset,
      menuPadding: EdgeInsets.zero,
      blurSigma: 0,
      hoverColor: AppColors.sokoPaper.withValues(alpha: 0.8),
      items: menuItems,
      onSelected: onSelected,
      child: wrappedChild,
    );
  }
}

class _DSDropdownMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool selected;

  const _DSDropdownMenuRow({
    required this.icon,
    required this.label,
    required this.color,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'ZalandoSans',
              fontWeight: FontWeight.w300,
              fontSize: 14,
              height: 1.2,
              letterSpacing: -0.14,
              color: color,
            ),
          ),
          if (selected) ...[
            const SizedBox(width: 12),
            Icon(Icons.check, size: 15, color: color),
          ],
        ],
      ),
    );
  }
}
