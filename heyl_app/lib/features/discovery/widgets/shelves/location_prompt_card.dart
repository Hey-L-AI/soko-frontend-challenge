import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/clickable.dart';
import '../../../../shared/widgets/soko_cta_button.dart';

/// Shared presentation for the Discovery location prompt cards (the "enable
/// location" CTA and the "share precise location" prompt). Purely visual —
/// callers own the action and dismissal behaviour.
class LocationPromptCard extends StatelessWidget {
  const LocationPromptCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.ctaLabel,
    required this.ctaIcon,
    required this.onCta,
    required this.dismissLabel,
    required this.onDismiss,
    this.ctaLoading = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final String ctaLabel;
  final IconData ctaIcon;
  final VoidCallback? onCta;
  final bool ctaLoading;
  final String dismissLabel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.sokoShade5,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.sokoPink.withValues(alpha: 0.55)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, size: 28, color: AppColors.sokoInk),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppTheme.displayPrimary(
                  fontSize: 28,
                  fontWeight: FontWeight.w300,
                  color: AppColors.sokoInk,
                  height: 1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: AppTheme.body(
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  height: 1.35,
                  color: AppColors.sokoInkSecondary,
                ),
              ),
              const SizedBox(height: 16),
              SokoCtaButton(
                label: ctaLabel,
                icon: ctaIcon,
                loading: ctaLoading,
                onPressed: onCta,
              ),
              const SizedBox(height: 10),
              Center(
                child: Clickable(
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      dismissLabel,
                      style: AppTheme.body(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: AppColors.sokoInkSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
