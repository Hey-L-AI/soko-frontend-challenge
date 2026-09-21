import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';

/// Header row used by `/menu/preferences` and its detail screens (e.g.
/// `/menu/preferences/language`). Mirrors the chrome used by other
/// `/menu/*` detail screens: back arrow + centered title + invisible
/// trailing spacer for symmetry.
class PreferencesHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const PreferencesHeader({
    super.key,
    required this.title,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: const Icon(
                LucideIcons.arrow_left,
                color: AppColors.sokoInk,
              ),
              onPressed: onBack,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            ),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}
