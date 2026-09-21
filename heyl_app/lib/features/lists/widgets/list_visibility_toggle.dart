import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/user_list.dart';
import '../../../l10n/generated/l10n.dart';

/// Three-pill segmented control for picking [ListVisibility]
/// (Public · Followers · Private). One pill is always selected. Used on
/// [CreateZineScreen] above the name input and on the Zine Details screen in
/// edit mode (below the title). The Details **non-edit** action row uses the
/// compact menu-based [VisibilityMenuChip] instead — no room for a segmented
/// control among the action buttons.
class ListVisibilityToggle extends StatelessWidget {
  const ListVisibilityToggle({
    super.key,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final ListVisibility selected;
  final bool enabled;
  final ValueChanged<ListVisibility> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.sokoInk.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _VisibilityPill(
            label: l10n.listsVisibilityPublic,
            isSelected: selected == ListVisibility.public,
            enabled: enabled,
            onTap: () => onSelect(ListVisibility.public),
          ),
          const SizedBox(width: 4),
          _VisibilityPill(
            label: l10n.listsVisibilityPrivate,
            isSelected: selected == ListVisibility.private,
            enabled: enabled,
            onTap: () => onSelect(ListVisibility.private),
          ),
        ],
      ),
    );
  }
}

class _VisibilityPill extends StatelessWidget {
  const _VisibilityPill({
    required this.label,
    required this.isSelected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.sokoInk : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w500 : FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: isSelected
                  ? AppColors.sokoPaper
                  : AppColors.sokoInk.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}
