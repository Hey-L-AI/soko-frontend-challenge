import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/models.dart';
import '../utils/profiling_strings.dart';
import 'vibe_palette.dart';

/// Grid of interest chips for the multi-select step. Selected chips fill
/// with a rotating accent colour from [VibePalette]; unselected chips show
/// a thin outline only.
class InterestChipGrid extends StatelessWidget {
  final List<UserProfilingOption> options;
  final List<String> selectedIds;
  final int max;
  final ValueChanged<String> onToggle;

  const InterestChipGrid({
    super.key,
    required this.options,
    required this.selectedIds,
    required this.onToggle,
    this.max = 2,
  });

  @override
  Widget build(BuildContext context) {
    final atCap = selectedIds.length >= max;
    // Figma 6614:14997 — content-sized chips, 6 px gap on both axes,
    // centered. `Wrap` naturally produces 2-per-row when labels fit and
    // a solo centered row when a label is too wide to share (e.g.
    // "Comunidade e voluntariado").
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < options.length; i++) _buildChip(context, i, atCap),
      ],
    );
  }

  Widget _buildChip(BuildContext context, int i, bool atCap) {
    final opt = options[i];
    final selected = selectedIds.contains(opt.id);
    final disabled = atCap && !selected;
    return _Chip(
      label: profilingString(context, opt.labelKey),
      icon: opt.icon,
      selected: selected,
      disabled: disabled,
      accent: VibePalette.interestColorAt(i),
      onTap: disabled ? null : () => onToggle(opt.id),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String? icon;
  final bool selected;
  final bool disabled;
  final Color accent;
  final VoidCallback? onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.disabled,
    required this.accent,
    this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Figma 6614:14997 — radius 6, 40px height, 14h × 10v padding, 8px
    // icon→label gap, Zalando Sans Light 14. Selected fills with the
    // rotating Soko accent (green / blue / yellow / lilac); unselected
    // stays transparent. Border is the canonical 1px `sokoInk @ 8%`
    // (`AppColors.sokoInk8`) in both states.
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? accent : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.sokoInk8, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Text(icon!, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: AppTheme.body(
                  fontSize: 13,
                  fontWeight: FontWeight.w300,
                  color: AppColors.sokoInk,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
