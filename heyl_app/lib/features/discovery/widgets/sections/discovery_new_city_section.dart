import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';

/// Expectation-setting hero shown between the scallop divider and the
/// action bar on the Discovery page when the user's selected city is NOT
/// backend-marked "open" for discovery (`GeoCity.isOpen == false`, PROD-3675 —
/// gated by [isCurrentCitySupportedProvider]) (Figma `6346:12059`).
///
/// Layout (from frame `6346:12059`, 399 × 310):
///   30 px top padding
///   115 × 115 illustration (`soko-seating-and-reading.webp`, transparent
///     background — renders directly against the page)
///   30 px gap
///   Headline — Season Mix TRIAL Light 42 / 0.94 / -0.84, centered
///   10 px gap
///   Subtitle — Zalando Sans Light 14 / 1.2 / -0.14, centered
///   30 px bottom padding
class DiscoveryNewCitySection extends StatelessWidget {
  const DiscoveryNewCitySection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/illustrations/soko-seating-and-reading.webp',
            width: 115,
            height: 115,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 30),
          Text(
            l10n.discoveryNewCityHeadline,
            textAlign: TextAlign.center,
            style: AppTheme.displayPrimary(
              fontSize: 42,
              fontWeight: FontWeight.w300,
              color: inkColor,
              height: 0.94,
              letterSpacing: -0.84,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.discoveryNewCitySubtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: inkColor,
            ),
          ),
        ],
      ),
    );
  }
}
