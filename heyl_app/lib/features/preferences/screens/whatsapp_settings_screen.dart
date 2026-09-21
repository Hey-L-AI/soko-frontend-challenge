import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../../shared/widgets/picker_select_row.dart';
import '../widgets/preferences_header.dart';

/// `/menu/preferences/whatsapp` — detail page for selecting the
/// preferred Soko WhatsApp number/region. Reached from the WhatsApp
/// tile on `/menu/preferences`. Mirrors `LanguageSettingsScreen`.
class WhatsappSettingsScreen extends ConsumerWidget {
  const WhatsappSettingsScreen({super.key});

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
                title: l10n.preferencesWhatsApp,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _WhatsappBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _WhatsappBody extends ConsumerWidget {
  const _WhatsappBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final user = ref.watch(currentUserProvider);
    final accountState = ref.watch(accountProvider);
    final numbers = user?.availableWhatsappNumbers ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          l10n.preferencesWhatsAppSubtitle,
          style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
        ),
        const SizedBox(height: 12),
        ...numbers.map(
          (whatsAppNumber) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PickerSelectRow(
              title: whatsAppNumber.region,
              subtitle: '+${whatsAppNumber.phone}',
              isSelected: whatsAppNumber.isCurrent,
              isLoading: accountState.isLoading && whatsAppNumber.isCurrent,
              onTap: accountState.isLoading
                  ? null
                  : () async {
                      await ref
                          .read(accountProvider.notifier)
                          .updateWhatsappPreference(whatsAppNumber.phone);
                    },
            ),
          ),
        ),
        if (accountState.error != null) ...[
          const SizedBox(height: 8),
          Text(
            accountState.error!,
            style: const TextStyle(color: AppColors.error, fontSize: 13),
          ),
        ],
      ],
    );
  }
}
