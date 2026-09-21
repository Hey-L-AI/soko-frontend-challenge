import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';

/// One flat-coloured answer card for a vibe step (multi-select 1-2).
/// Background colour comes from `VibePalette.forOption(optionId)`; this
/// widget is colour-agnostic and just renders what it's given.
class VibeCard extends StatelessWidget {
  final String label;
  final Color backgroundColor;
  final bool selected;
  final bool atCap;
  final VoidCallback? onTap;

  const VibeCard({
    super.key,
    required this.label,
    required this.backgroundColor,
    this.selected = false,
    this.atCap = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = !selected && atCap;
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Semantics(
        button: true,
        selected: selected,
        enabled: !disabled,
        label: label,
        child: ExcludeSemantics(
          child: GestureDetector(
            onTap: disabled ? null : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: backgroundColor,
                // Figma 6614:15148 — radius 6, 2px sokoInk border always
                // (selection is communicated by the chip, not the border).
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.sokoInk, width: 2),
              ),
              padding: const EdgeInsets.all(20),
              child: Row(
                // Bottom-align label + chip — Figma uses `items-end` so the
                // chip lands at the lower-right corner of the card.
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: AppTheme.displayPrimary(
                        fontSize: 26,
                        fontWeight: FontWeight.w400,
                        color: AppColors.sokoInk,
                        height: 1.0,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _CheckCircle(selected: selected),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckCircle extends StatelessWidget {
  final bool selected;
  const _CheckCircle({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppColors.sokoInk : Colors.transparent,
        border: Border.all(color: AppColors.sokoInk, width: 2),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
          : null,
    );
  }
}
