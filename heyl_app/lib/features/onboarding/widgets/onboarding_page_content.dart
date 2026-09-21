import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';

/// A single page of onboarding content with image, title, and subtitle
/// Matches Lovable mockup: w-[200px] h-[400px] rounded-xl shadow-xl
class OnboardingPageContent extends StatelessWidget {
  final String imagePath;
  final String title;
  final String subtitle;

  const OnboardingPageContent({
    super.key,
    required this.imagePath,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimaryColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final textSecondaryColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;

    return Column(
      children: [
        // Screenshot image in phone frame - Lovable: w-[200px] h-[400px]
        Expanded(
          child: Center(
            child: Container(
              width: 200,
              height: 400,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12), // rounded-xl
                border: Border.all(color: borderColor, width: 1),
                boxShadow: [
                  // shadow-xl
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 25,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.asset(
                  imagePath,
                  fit: BoxFit.contain,
                  width: 200,
                  height: 400,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),

        // Title and subtitle
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              // Title - text-2xl font-display font-bold
              Text(
                title,
                style: AppTheme.display(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: textPrimaryColor,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // Subtitle - text-sm text-muted-foreground
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 14,
                  color: textSecondaryColor,
                  height: 1.5, // leading-relaxed
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
