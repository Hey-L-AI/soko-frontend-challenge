import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';

class PolarityVisuals {
  final IconData icon;
  final Color background;
  final Color foreground;
  const PolarityVisuals({
    required this.icon,
    required this.background,
    required this.foreground,
  });
}

PolarityVisuals polarityVisuals(String polarity) {
  switch (polarity) {
    case 'prefer':
      return const PolarityVisuals(
        icon: LucideIcons.heart,
        background: AppColors.sokoPink,
        foreground: AppColors.sokoInk,
      );
    case 'avoid':
      return const PolarityVisuals(
        icon: LucideIcons.x,
        background: AppColors.sokoRed,
        foreground: Colors.white,
      );
    default:
      return PolarityVisuals(
        icon: LucideIcons.circle,
        background: AppColors.sokoShade5,
        foreground: AppColors.sokoShade3,
      );
  }
}
