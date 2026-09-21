import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../providers/ai_consent_provider.dart';
import '../widgets/ai_disclosure_sheet.dart';

/// `/menu/ai-data` — "AI & data" settings (PROD-2265 Phase 2). The ongoing
/// review/revoke companion to the first-send consent gate (Apple Guideline
/// 5.1.1(i) / 5.1.2(i)). Lets the user re-read what's shared (the same
/// disclosure sheet) and withdraw consent — after which the next chat send
/// re-shows the consent gate. Mirrors `about_screen.dart`'s shell.
class AiDataScreen extends ConsumerWidget {
  const AiDataScreen({super.key});

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
              _Header(
                title: l10n.aiDataSettingsTitle,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _AiDataBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _Header({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: const Icon(
                LucideIcons.arrow_left,
                color: AppColors.sokoInk,
              ),
              onPressed: onBack,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            ),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _AiDataBody extends ConsumerWidget {
  const _AiDataBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final theme = Theme.of(context);
    final granted = ref.watch(aiConsentGrantedProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.aiDataScreenIntro, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  granted
                      ? LucideIcons.circle_check
                      : LucideIcons.circle_dashed,
                  size: 18,
                  color: AppColors.sokoInk,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  granted
                      ? l10n.aiDataConsentGrantedStatus
                      : l10n.aiDataConsentNotGrantedStatus,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SokoCtaButton(
            label: l10n.aiDataReviewButton,
            variant: SokoCtaVariant.ink,
            onPressed: () => AiDisclosureSheet.show(context, ref),
          ),
          if (granted) ...[
            const SizedBox(height: 12),
            SokoCtaButton(
              label: l10n.aiDataRevokeButton,
              variant: SokoCtaVariant.red,
              onPressed: () async {
                await revokeAiConsent(ref);
                if (!context.mounted) return;
                showSoko(ref, message: l10n.aiDataRevokedToast);
              },
            ),
          ],
        ],
      ),
    );
  }
}
