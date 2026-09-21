import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

/// Bottom sheet shown when the user wants to enable notifications but
/// OS permission was previously denied. iOS doesn't let us re-prompt,
/// so we deep-link to the OS Settings page. The `source` arg is
/// emitted with the `settings_opened` analytic from the CTA — only
/// when `openAppSettings()` actually runs, not when the sheet appears.
class PushSettingsRedirectSheet extends ConsumerWidget {
  final String source;
  const PushSettingsRedirectSheet({super.key, required this.source});

  static Future<void> show(BuildContext context, {required String source}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PushSettingsRedirectSheet(source: source),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        decoration: const BoxDecoration(
          color: AppColors.sokoShade5,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.pushSettingsRedirectTitle,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.pushSettingsRedirectBody,
              style: const TextStyle(
                fontSize: 14,
                height: 1.4,
                color: AppColors.sokoShade3,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackPushSuggestion(
                      action: 'settings_opened',
                      source: source,
                    );
                await openAppSettings();
                if (context.mounted) Navigator.of(context).pop();
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.sokoPink,
                foregroundColor: AppColors.sokoInk,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(l10n.pushSettingsRedirectCta),
            ),
          ],
        ),
      ),
    );
  }
}
