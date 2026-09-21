import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart' hide AuthMethod;
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../../shared/widgets/picker_select_row.dart';
import '../widgets/preferences_header.dart';

/// `/menu/preferences/language` — detail page for selecting the app
/// language. Tap on the Language tile in `/menu/preferences` opens this
/// screen via `_detailPage` (CupertinoPage slide on iOS, NoTransitionPage
/// on Android/web — matches other `/menu/*` detail screens).
class LanguageSettingsScreen extends ConsumerWidget {
  const LanguageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PreferencesHeader(
                title: l10n.preferencesLanguageDetailTitle,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _LanguageBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageBody extends ConsumerWidget {
  const _LanguageBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final currentLocale = ref.watch(localeProvider);
    final availableLocales = ref.watch(availableLocalesProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        PickerSelectRow(
          title: l10n.preferencesSystemDefault,
          subtitle: l10n.preferencesSystemDefaultSubtitle,
          isSelected: currentLocale == null,
          onTap: () => ref.read(localeProvider.notifier).resetToSystem(),
        ),
        const SizedBox(height: 8),
        ...availableLocales.map(
          (appLocale) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PickerSelectRow(
              title: appLocale.nativeName,
              subtitle: appLocale.displayName,
              isSelected:
                  currentLocale != null &&
                  currentLocale.languageCode == appLocale.locale.languageCode &&
                  currentLocale.countryCode == appLocale.locale.countryCode,
              onTap: () {
                final previousLanguage = currentLocale != null
                    ? (currentLocale.countryCode != null
                          ? '${currentLocale.languageCode}-${currentLocale.countryCode}'
                          : currentLocale.languageCode)
                    : null;
                final newLanguage = appLocale.locale.countryCode != null
                    ? '${appLocale.locale.languageCode}-${appLocale.locale.countryCode}'
                    : appLocale.locale.languageCode;
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackLanguageChange(
                      language: newLanguage,
                      previousLanguage: previousLanguage,
                    );

                ref.read(localeProvider.notifier).setLocale(appLocale.locale);
              },
            ),
          ),
        ),
      ],
    );
  }
}
