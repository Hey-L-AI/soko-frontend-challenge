import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/environment.dart';
import '../../core/services/unified_analytics_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/page_layout.dart';
import '../../core/utils/orientation_utils.dart';
import '../../providers/locale_provider.dart';
import '../../providers/theme_provider.dart';

/// Reusable header for authentication and onboarding screens
/// Matches Lovable design: language selector + theme toggle on right
class AuthHeader extends ConsumerWidget {
  /// Optional custom back button callback.
  /// When provided, overrides the default context.pop() behavior.
  final VoidCallback? onBack;

  /// Optional skip button callback (for onboarding)
  final VoidCallback? onSkip;

  /// Skip button label (localized)
  final String? skipLabel;

  const AuthHeader({super.key, this.onBack, this.onSkip, this.skipLabel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textPrimaryColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final currentLocale = ref.watch(localeProvider);
    final availableLocales = ref.watch(availableLocalesProvider);

    // Get current locale display code (e.g., "EN", "PT", "PT-BR")
    final currentAppLocale = AppLocale.fromLocale(
      currentLocale,
      availableLocales,
    );
    final displayCode = _getShortCode(currentAppLocale);

    final safeTop = OrientationUtils.safeTop(context, additionalPadding: 12);

    // PROD-2073: respect the canonical page-width container so the back
    // button and language selector sit at the edges of the same 480 px
    // column the screen body uses, rather than the full viewport.
    return Padding(
      padding: EdgeInsets.only(top: safeTop, bottom: 12),
      child: PageContent(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Back button (when pushed from guest mode or custom onBack) or spacer for centering
              if (onBack != null || GoRouter.of(context).canPop())
                SizedBox(
                  width: 40,
                  child: IconButton(
                    icon: Icon(
                      LucideIcons.arrow_left,
                      size: 20,
                      color: textSecondaryColor,
                    ),
                    onPressed: onBack ?? () => context.pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                )
              else
                const SizedBox(width: 40),

              const Spacer(),

              // Right side: Language + Theme + Skip (optional)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Language selector dropdown
                  _LanguageDropdown(
                    currentLocale: currentAppLocale,
                    availableLocales: availableLocales,
                    displayCode: displayCode,
                    textSecondaryColor: textSecondaryColor,
                    textPrimaryColor: textPrimaryColor,
                    onLocaleSelected: (locale) {
                      ref.read(localeProvider.notifier).setLocale(locale);
                    },
                  ),

                  // Theme toggle — hidden behind kill switch until dark mode
                  // is polished.
                  if (EnvironmentConfig.themeSwitchingEnabled) ...[
                    const SizedBox(width: 8),
                    _ThemeToggle(
                      isDark: isDark,
                      textSecondaryColor: textSecondaryColor,
                      textPrimaryColor: textPrimaryColor,
                      onToggle: () {
                        final brightness = Theme.of(context).brightness;
                        // Track theme change (Backend + Firebase analytics)
                        final newTheme = brightness == Brightness.light
                            ? AnalyticsTheme.dark
                            : AnalyticsTheme.light;
                        ref
                            .read(unifiedAnalyticsProvider)
                            .trackThemeChange(theme: newTheme);

                        ref
                            .read(themeModeProvider.notifier)
                            .toggleThemeMode(brightness);
                      },
                    ),
                  ],

                  // Skip button (optional, for onboarding)
                  if (onSkip != null) ...[
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: onSkip,
                      child: Text(
                        skipLabel ?? 'Skip',
                        style: TextStyle(
                          fontSize: 14,
                          color: textSecondaryColor,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getShortCode(AppLocale? locale) {
    if (locale == null) return 'EN';
    final country = locale.locale.countryCode;
    // For locales with country code (like pt_BR), show just the country code
    if (country != null && country.isNotEmpty) {
      return country.toUpperCase(); // Returns "BR" instead of "PT-BR"
    }
    return locale.locale.languageCode.toUpperCase(); // Returns "EN", "PT"
  }
}

/// Language dropdown button
class _LanguageDropdown extends StatelessWidget {
  final AppLocale? currentLocale;
  final List<AppLocale> availableLocales;
  final String displayCode;
  final Color textSecondaryColor;
  final Color textPrimaryColor;
  final Function(Locale) onLocaleSelected;

  const _LanguageDropdown({
    required this.currentLocale,
    required this.availableLocales,
    required this.displayCode,
    required this.textSecondaryColor,
    required this.textPrimaryColor,
    required this.onLocaleSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Locale>(
      offset: const Offset(0, 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      itemBuilder: (context) {
        return availableLocales.map((appLocale) {
          final isSelected = currentLocale?.locale == appLocale.locale;
          return PopupMenuItem<Locale>(
            value: appLocale.locale,
            child: Row(
              children: [
                Text(
                  appLocale.nativeName,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (isSelected) ...[
                  const Spacer(),
                  Icon(LucideIcons.check, size: 16, color: textPrimaryColor),
                ],
              ],
            ),
          );
        }).toList();
      },
      onSelected: onLocaleSelected,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.globe, size: 16, color: textSecondaryColor),
            const SizedBox(width: 6),
            Text(
              displayCode,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: textSecondaryColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Theme toggle button
class _ThemeToggle extends StatelessWidget {
  final bool isDark;
  final Color textSecondaryColor;
  final Color textPrimaryColor;
  final VoidCallback onToggle;

  const _ThemeToggle({
    required this.isDark,
    required this.textSecondaryColor,
    required this.textPrimaryColor,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Icon(
          isDark ? LucideIcons.sun : LucideIcons.moon,
          size: 16,
          color: textSecondaryColor,
        ),
      ),
    );
  }
}
