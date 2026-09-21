import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Shared 5-tick strength meter — the single user-facing scale on the Memory
/// page. Bars 1-4 come from organic signal; the 5th bar is user-only (a "+"
/// pin — see `certaintyTicks`). Borderless so it sits cleanly inside a
/// coloured chip or a metadata strip. Certainty (the 0..1 confidence float)
/// still drives ranking server-side, but is no longer shown to the user —
/// one scale, not two.
class MemoryTicks extends StatelessWidget {
  final int ticks; // 1..5

  /// Bar geometry. Defaults match the compact in-chip meter; the provenance
  /// panel passes larger values so the (interactive) meter reads clearly.
  final double barWidth;
  final double barHeight;
  final double gap;

  const MemoryTicks({
    super.key,
    required this.ticks,
    this.barWidth = 2.5,
    this.barHeight = 8,
    this.gap = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gap),
            child: Container(
              width: barWidth,
              height: barHeight,
              decoration: BoxDecoration(
                color: i < ticks
                    ? AppColors.sokoInk
                    : AppColors.sokoInk.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(barWidth / 2),
              ),
            ),
          ),
      ],
    );
  }
}
