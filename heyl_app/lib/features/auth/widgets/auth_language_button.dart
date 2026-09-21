import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../providers/locale_provider.dart';

/// Bare PopupMenuButton with a globe icon + 2-letter locale code, used as
/// the auth-funnel language picker. Bare-styled (no chip background, no
/// border, no elevation) to match the menu sub-screens (`AuthHeader`,
/// `account_screen.dart`, etc.).
///
/// Originally lived inline in `AuthShell` as a Positioned top-right
/// overlay; extracted so the login screen can render it inline next to
/// the phone input (the shell suppresses its overlay on `/login`).
class AuthLanguageButton extends ConsumerWidget {
  const AuthLanguageButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLocale = ref.watch(localeProvider);
    final availableLocales = ref.watch(availableLocalesProvider);
    // When the user hasn't made an explicit pick, `localeProvider` is null and
    // the app renders in the system-resolved locale (MaterialApp.locale = null).
    // Label from THAT resolved locale, never a hardcoded 'EN', so the globe can
    // never claim English while the UI is actually Portuguese — the tell that a
    // pick was silently dropped back to the system default.
    final effectiveLocale = currentLocale ?? Localizations.localeOf(context);
    final displayCode = _displayCodeFor(effectiveLocale);

    return PopupMenuButton<Locale>(
      tooltip: '',
      offset: const Offset(0, 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      itemBuilder: (context) {
        return availableLocales.map((appLocale) {
          final isSelected = currentLocale == appLocale.locale;
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
                  const Icon(
                    LucideIcons.check,
                    size: 16,
                    color: AppColors.sokoInk,
                  ),
                ],
              ],
            ),
          );
        }).toList();
      },
      onSelected: (locale) =>
          ref.read(localeProvider.notifier).setLocale(locale),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.globe, size: 16, color: AppColors.sokoInk),
            const SizedBox(width: 6),
            Text(
              displayCode,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _displayCodeFor(Locale locale) {
    final country = locale.countryCode;
    if (country != null && country.isNotEmpty) {
      return country.toUpperCase();
    }
    return locale.languageCode.toUpperCase();
  }
}
