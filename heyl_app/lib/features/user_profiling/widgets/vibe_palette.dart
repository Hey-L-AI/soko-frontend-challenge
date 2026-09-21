import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Client-side colour assignments for vibe-card backgrounds and interest
/// chips. The backend's `UserProfilingOption` does not carry colour data;
/// this map is keyed by the stable option IDs documented in
/// `data/models/user_profiling_models.dart` (S1_A..S4_C).
class VibePalette {
  VibePalette._();

  static const Color fallback = Color(0xFFE0E0E0);

  static const Map<String, Color> _vibeColors = {
    // Morning (S1)
    'S1_A': Color(0xFFD8A4FF),
    'S1_B': Color(0xFFB7E78F),
    'S1_C': Color(0xFFE89B91),
    // Activity (S2)
    'S2_A': Color(0xFF9D9FF0),
    'S2_B': Color(0xFFE5DD60),
    'S2_C': Color(0xFFB7E78F),
    // Food (S3)
    'S3_A': Color(0xFF8FD4F0),
    'S3_B': Color(0xFFE89B91),
    'S3_C': Color(0xFFE5DD60),
    // Night (S4) — palette extended, distinct from morning/activity/food
    'S4_A': Color(0xFFFFA86B),
    'S4_B': Color(0xFFB088E8),
    'S4_C': Color(0xFFF0D4B7),
  };

  /// Rotating palette for interest chips (selected state). Index-based,
  /// not ID-based, since interest IDs change with editorial updates.
  /// Pulled from the canonical Soko brand tokens so onboarding shares
  /// the same accent vocabulary as the rest of the app.
  static const List<Color> _interestColors = [
    AppColors.sokoGreen,
    AppColors.sokoBlue,
    AppColors.sokoYellow,
    AppColors.sokoLilac,
  ];

  static Color forOption(String optionId) => _vibeColors[optionId] ?? fallback;

  static Color interestColorAt(int index) =>
      _interestColors[index % _interestColors.length];
}
