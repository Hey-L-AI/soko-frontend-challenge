import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/locale_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../shared/widgets/glassmorphic_popup_menu.dart';

/// A compact locale picker button that shows a dropdown menu
class LocalePicker extends ConsumerWidget {
  /// When true, uses paper-colored text/icon for overlay mode (hero over dark image)
  final bool isOverlay;

  const LocalePicker({super.key, this.isOverlay = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLocale = ref.watch(localeProvider);
    final availableLocales = ref.watch(availableLocalesProvider);
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondaryColor = isOverlay
        ? AppColors.sokoPaper
        : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondary);
    // Find current AppLocale or use first available
    final currentAppLocale = AppLocale.fromLocale(currentLocale, availableLocales);

    // Display locale code: "EN", "PT", "BR"
    String getDisplayCode(Locale? locale) {
      if (locale == null) {
        return Localizations.localeOf(context).languageCode.toUpperCase();
      }
      final country = locale.countryCode;
      if (country != null && country.isNotEmpty) {
        return country.toUpperCase();
      }
      return locale.languageCode.toUpperCase();
    }
    final displayCode = getDisplayCode(currentLocale);

    // Only dark+hero uses overlay colors; light hero matches light non-hero
    final darkOverlay = isOverlay && isDark;

    // Dropdown bg/border matches nav pill container
    final popoverBg = darkOverlay
        ? Colors.white.withValues(alpha: 0.06)
        : (isDark
            ? Colors.white.withValues(alpha: 0.06)
            : (isOverlay
                ? AppColors.sokoPaper.withValues(alpha: 0.88)
                : Colors.white.withValues(alpha: 0.88)));
    final popoverBorder = isDark
        ? AppColors.sokoPaper.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.06);
    // Selected item matches selected nav pill
    final selectedBg = isDark
        ? AppColors.sokoPaper
        : AppColors.sokoDark.withValues(alpha: 0.85);
    final selectedTextColor = isDark ? AppColors.sokoDark : AppColors.sokoPaper;
    // Unselected text: code bold, name muted (matching nav pill text)
    final unselectedCodeColor = isDark ? AppColors.sokoPaper : AppColors.sokoDark;
    final unselectedNameColor = isDark
        ? AppColors.sokoPaper.withValues(alpha: 0.7)
        : AppColors.sokoDark.withValues(alpha: 0.6);

    return GlassmorphicPopupMenu<AppLocale>(
      tooltip: l10n.languagePickerTitle,
      offset: const Offset(-15, 8),
      backgroundColor: popoverBg,
      border: Border.all(color: popoverBorder, width: 1),
      items: availableLocales.map((appLocale) {
        final isSelected = currentAppLocale?.locale == appLocale.locale;

        return GlassmorphicMenuItem<AppLocale>(
          value: appLocale,
          child: _LocaleMenuItem(
            code: getDisplayCode(appLocale.locale),
            name: appLocale.nativeName,
            isSelected: isSelected,
            selectedBg: selectedBg,
            selectedTextColor: selectedTextColor,
            textPrimaryColor: unselectedCodeColor,
            textSecondaryColor: unselectedNameColor,
          ),
        );
      }).toList(),
      onSelected: (appLocale) async {
        print('[LocalePicker] Changing locale to: ${appLocale.locale}');

        // Track language change (Backend + Firebase analytics)
        final previousLanguage = currentLocale != null
            ? (currentLocale.countryCode != null
                ? '${currentLocale.languageCode}-${currentLocale.countryCode}'
                : currentLocale.languageCode)
            : null;
        final newLanguage = appLocale.locale.countryCode != null
            ? '${appLocale.locale.languageCode}-${appLocale.locale.countryCode}'
            : appLocale.locale.languageCode;
        ref.read(unifiedAnalyticsProvider).trackLanguageChange(
          language: newLanguage,
          previousLanguage: previousLanguage,
        );

        // Capture notifiers BEFORE async operation to avoid using ref after
        // the widget may have been rebuilt/disposed
        final localeNotifier = ref.read(localeProvider.notifier);
        final messageStartersNotifier =
            ref.read(messageStartersProvider.notifier);

        await localeNotifier.setLocale(appLocale.locale);
        print('[LocalePicker] Locale set, refreshing message starters...');
        // Refresh message starters to fetch in new locale
        messageStartersNotifier.refresh();
        print('[LocalePicker] Refresh triggered');
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.language,
            size: 16,
            color: textSecondaryColor,
          ),
          const SizedBox(width: 6),
          Text(
            displayCode,
            style: TextStyle(
              fontSize: isOverlay ? 16 : 14,
              fontWeight: isOverlay ? FontWeight.w300 : FontWeight.w500,
              color: textSecondaryColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// Individual locale menu item with hover highlight matching the selected style
class _LocaleMenuItem extends StatefulWidget {
  final String code;
  final String name;
  final bool isSelected;
  final Color selectedBg;
  final Color selectedTextColor;
  final Color textPrimaryColor;
  final Color textSecondaryColor;

  const _LocaleMenuItem({
    required this.code,
    required this.name,
    required this.isSelected,
    required this.selectedBg,
    required this.selectedTextColor,
    required this.textPrimaryColor,
    required this.textSecondaryColor,
  });

  @override
  State<_LocaleMenuItem> createState() => _LocaleMenuItemState();
}

class _LocaleMenuItemState extends State<_LocaleMenuItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final showHover = _isHovered && !widget.isSelected;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: widget.isSelected
              ? widget.selectedBg
              : (showHover
                  ? widget.selectedBg.withValues(
                      alpha: Theme.of(context).brightness == Brightness.dark ? 0.3 : 0.15)
                  : Colors.transparent),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.transparent, width: 1),
        ),
        child: Row(
          children: [
            Text(
              widget.code,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: widget.isSelected
                    ? widget.selectedTextColor
                    : widget.textPrimaryColor,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              widget.name,
              style: TextStyle(
                fontSize: 14,
                color: widget.isSelected
                    ? widget.selectedTextColor.withValues(alpha: 0.7)
                    : widget.textSecondaryColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
