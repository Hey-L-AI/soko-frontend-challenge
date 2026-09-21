import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import 'onboarding_card_entrance.dart';

/// The onboarding rituals covers carousel (Figma `7285:24353`): the Daily Drop
/// and Weekly Bundle promo covers side by side, each with a title + subtitle,
/// bracketed by a hairline divider like the zines/follow carousels.
///
/// Pure display: the two covers are static promo mockups (a brand-new user has
/// no generated drop/bundle yet), exported from Figma. Push/email consent is no
/// longer fired here — it's an explicit Yes/No delivered right after this
/// carousel (see `OnboardingDeliveryConsent`), so the OS prompt only fires when
/// the user answers Yes.
class OnboardingRitualsCarousel extends StatelessWidget {
  const OnboardingRitualsCarousel({
    super.key,
    required this.dailyTitle,
    required this.dailySubtitle,
    required this.weeklyTitle,
    required this.weeklySubtitle,
  });

  final String dailyTitle;
  final String dailySubtitle;
  final String weeklyTitle;
  final String weeklySubtitle;

  static const _dailyAsset = 'assets/onboarding/rituals/daily_drop_cover.png';
  static const _weeklyAsset =
      'assets/onboarding/rituals/weekly_bundle_cover.png';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
        const SizedBox(height: 12),
        // Cap the covers at the Figma content width (two 195 + 10 gap = 400) and
        // left-align: on mobile they fill the ≤400 content; on a wide web
        // viewport they stay Figma-sized instead of stretching full-width.
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: OnboardingCardEntrance(
                    index: 0,
                    child: _RitualCard(
                      asset: _dailyAsset,
                      title: dailyTitle,
                      subtitle: dailySubtitle,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OnboardingCardEntrance(
                    index: 1,
                    child: _RitualCard(
                      asset: _weeklyAsset,
                      title: weeklyTitle,
                      subtitle: weeklySubtitle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
      ],
    );
  }
}

/// One ritual cover card (Figma `7285:24357`): the 195×104 cover image, then a
/// bold title and a two-line grey subtitle.
class _RitualCard extends StatelessWidget {
  const _RitualCard({
    required this.asset,
    required this.title,
    required this.subtitle,
  });

  final String asset;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            // Figma cover is 195×104.
            aspectRatio: 195 / 104,
            child: Image.asset(asset, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.body(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.sokoInk,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.body(
            fontSize: 13,
            color: AppColors.sokoShade3,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}
