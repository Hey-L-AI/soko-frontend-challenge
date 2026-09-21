import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';

/// The Figma mock's filter-chip chrome, shared by the Events and Places
/// filter strips (Descobre a cidade + shelf see-more pages): a flat
/// Soko-palette rounded rect (radius 9, height 32) with ink icon +
/// label. Selection adds an ink border + medium weight — the fill never
/// changes, keeping the flat look.

/// Facet-chip fill cycle, matching the mock's palette (sokoBlue is
/// reserved for the events time-range trigger). Assign by the facet's
/// stable catalog index — not display position — so a chip keeps its
/// color when selected chips float to the front of the strip.
const List<Color> _kChipPalette = [
  AppColors.sokoRed,
  AppColors.sokoLilac,
  AppColors.sokoYellow,
];

/// Fill for the facet at [catalogIndex] in its backend catalog.
Color sokoFilterChipFill(int catalogIndex) =>
    _kChipPalette[catalogIndex % _kChipPalette.length];

class SokoFilterChip extends StatelessWidget {
  const SokoFilterChip({
    super.key,
    required this.label,
    required this.fill,
    required this.selected,
    this.icon,
    this.trailing,
    this.onTap,
  });

  final String label;
  final Color fill;
  final bool selected;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: selected ? AppColors.sokoInk : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: AppColors.sokoInk),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontFamily: 'ZalandoSans',
              fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              fontSize: 13,
              height: 1.2,
              letterSpacing: -0.13,
              color: AppColors.sokoInk,
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 4), trailing!],
        ],
      ),
    );
    if (onTap == null) return chip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: chip),
    );
  }
}

/// Clear (✕) chip in the colored chrome — neutral ink-on-6% pill so it
/// reads as an action, not another category.
class SokoFilterClearChip extends StatelessWidget {
  const SokoFilterClearChip({
    super.key,
    required this.onTap,
    required this.semanticLabel,
  });

  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            height: 32,
            width: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sokoInk.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              LucideIcons.x,
              size: 15,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      ),
    );
  }
}
