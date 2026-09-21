import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/unified_analytics_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/auth_gating.dart';
import '../../l10n/generated/l10n.dart';

/// Placeholder widget shown to guest (unauthenticated) users for features
/// that require sign-in.
///
/// Can be used in two modes:
/// - Full-page mode (default): Centered content for entire screens
/// - Compact mode: Smaller inline placeholder for sections
class GuestFeaturePlaceholder extends ConsumerWidget {
  /// Icon to display in the circular container
  final IconData icon;

  /// Title text (e.g., "Memories", "Saved"). If null, title is hidden.
  final String? title;

  /// Subtitle explaining what this feature does when signed in
  final String subtitle;

  /// Optional callback when sign up button is pressed.
  ///
  /// If null, falls back to [navigateToLoginPreservingReturn] — a hard nav
  /// is right here (this placeholder *is* the explanation surface), but it
  /// must preserve the return URL or OAuth drops the user on `/home`
  /// instead of back here (PROD-3142).
  final VoidCallback? onSignUp;

  /// Whether to use compact mode for inline section placeholders.
  /// Compact mode uses smaller sizes and different padding.
  final bool compact;

  const GuestFeaturePlaceholder({
    super.key,
    required this.icon,
    this.title,
    required this.subtitle,
    this.onSignUp,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final textSecondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textPrimaryColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;

    if (compact) {
      return _buildCompact(
        context,
        ref,
        l10n,
        primaryColor,
        textPrimaryColor,
        textSecondaryColor,
      );
    }

    return _buildFullPage(
      context,
      ref,
      l10n,
      primaryColor,
      textPrimaryColor,
      textSecondaryColor,
    );
  }

  Widget _buildFullPage(
    BuildContext context,
    WidgetRef ref,
    Lt l10n,
    Color primaryColor,
    Color textPrimaryColor,
    Color textSecondaryColor,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Icon container
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primaryColor.withValues(alpha: 0.1),
                border: Border.all(
                  color: primaryColor.withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: Icon(icon, size: 40, color: primaryColor),
            ),
            const SizedBox(height: 24),

            // Title (optional — skip when page header already shows it)
            if (title != null) ...[
              Text(
                title!,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: textPrimaryColor,
                ),
              ),
              const SizedBox(height: 8),
            ],

            // Subtitle
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: textSecondaryColor,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),

            // Sign up button (outlined style, consistent with lists page)
            TextButton(
              onPressed:
                  onSignUp ??
                  () => navigateToLoginPreservingReturn(
                    context,
                    ref,
                    referrer: AuthReferrer.guestFeaturePlaceholder,
                  ),
              style: TextButton.styleFrom(
                foregroundColor: primaryColor,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: primaryColor),
                ),
              ),
              child: Text(
                l10n.authButtonSignIn,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompact(
    BuildContext context,
    WidgetRef ref,
    Lt l10n,
    Color primaryColor,
    Color textPrimaryColor,
    Color textSecondaryColor,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icon container (smaller for compact mode)
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primaryColor.withValues(alpha: 0.1),
            ),
            child: Icon(icon, size: 28, color: primaryColor),
          ),
          const SizedBox(height: 16),

          // Title
          if (title != null) ...[
            Text(
              title!,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textPrimaryColor,
              ),
            ),
            const SizedBox(height: 4),
          ],

          // Subtitle
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: textSecondaryColor,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),

          // Sign up button (compact style)
          TextButton(
            onPressed:
                onSignUp ??
                () => navigateToLoginPreservingReturn(
                  context,
                  ref,
                  referrer: AuthReferrer.guestFeaturePlaceholder,
                ),
            style: TextButton.styleFrom(
              foregroundColor: primaryColor,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: primaryColor),
              ),
            ),
            child: Text(
              l10n.authButtonSignIn,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
