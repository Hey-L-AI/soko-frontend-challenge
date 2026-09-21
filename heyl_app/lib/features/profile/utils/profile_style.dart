import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Figma design tokens for the social-profile surfaces (node 7058:19395 —
/// "Soko_Profile"). Body text is Zalando Sans (Light 300 / Medium 500); the
/// display name is Season Mix. Ink text is `AppColors.sokoInk`; secondary tones
/// are ink at 50% / 30% / 8%.
///
/// Shared across the profile, edit-profile, follow-requests and follow-button
/// surfaces so they read with one type system.
class Pt {
  /// Mobile/H1 — display name.
  static const name = TextStyle(
    fontFamily: 'SeasonMix',
    fontSize: 42,
    height: 0.9,
    letterSpacing: -0.42,
    fontWeight: FontWeight.w400,
    color: AppColors.sokoInk,
  );

  /// Mobile/H2 — private-state / screen headings.
  static const display = TextStyle(
    fontFamily: 'SeasonMix',
    fontSize: 32,
    height: 0.95,
    letterSpacing: -0.32,
    fontWeight: FontWeight.w400,
    color: AppColors.sokoInk,
  );

  /// Mobile/B1 Reg — section titles.
  static const b1 = TextStyle(
    fontFamily: 'ZalandoSans',
    fontSize: 18,
    height: 1.0,
    letterSpacing: -0.36,
    fontWeight: FontWeight.w300,
    color: AppColors.sokoInk,
  );

  /// Mobile/B1 Bold — emphasised titles (zine name, row name).
  static const b1Bold = TextStyle(
    fontFamily: 'ZalandoSans',
    fontSize: 18,
    height: 1.0,
    letterSpacing: -0.36,
    fontWeight: FontWeight.w500,
    color: AppColors.sokoInk,
  );

  /// Mobile/B2 Reg — everything else (handle, stats, bio, tags, buttons, tabs).
  static const b2 = TextStyle(
    fontFamily: 'ZalandoSans',
    fontSize: 14,
    height: 1.2,
    letterSpacing: -0.14,
    fontWeight: FontWeight.w300,
    color: AppColors.sokoInk,
  );

  /// Mobile/B2 Bold — emphasised small text (button labels, pill labels).
  static const b2Bold = TextStyle(
    fontFamily: 'ZalandoSans',
    fontSize: 14,
    height: 1.2,
    letterSpacing: -0.14,
    fontWeight: FontWeight.w500,
    color: AppColors.sokoInk,
  );
}

Color get pInk50 => AppColors.sokoInk.withValues(alpha: 0.5);
Color get pInk30 => AppColors.sokoInk.withValues(alpha: 0.3);
Color get pInk8 => AppColors.sokoInk.withValues(alpha: 0.08);
