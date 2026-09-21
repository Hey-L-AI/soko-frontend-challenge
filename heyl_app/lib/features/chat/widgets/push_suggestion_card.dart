import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/services/push_permission_state.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

/// In-chat card that suggests enabling push notifications.
///
/// Copy switches based on [sub]:
///  - osNotDetermined: prompt copy, CTA fires OS permission dialog
///  - osDenied: Settings copy, CTA opens [PushSettingsRedirectSheet]
///
/// Modelled on [LocationSuggestionCard].
class PushSuggestionCard extends StatelessWidget {
  final ReadySubState sub;
  final VoidCallback onPrimary;
  final VoidCallback onDismiss;

  const PushSuggestionCard({
    super.key,
    required this.sub,
    required this.onPrimary,
    required this.onDismiss,
  }) : assert(
          sub == ReadySubState.osNotDetermined ||
              sub == ReadySubState.osDenied,
          'PushSuggestionCard only renders for prompt-able sub-states',
        );

  bool get _isDenied => sub == ReadySubState.osDenied;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    const bubbleColor = AppColors.sokoShade5;
    const textColor = AppColors.sokoInk;
    const textSecondaryColor = AppColors.sokoShade3;

    final title =
        _isDenied ? l10n.pushCardDeniedTitle : l10n.pushCardPromptTitle;
    final body =
        _isDenied ? l10n.pushCardDeniedBody : l10n.pushCardPromptBody;
    final cta =
        _isDenied ? l10n.pushCardDeniedCta : l10n.pushCardPromptCta;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(LucideIcons.bell,
                    size: 18, color: AppColors.sokoInk),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: textColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: const TextStyle(
                          color: textSecondaryColor,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                Semantics(
                  label: l10n.pushCardDismissA11yLabel,
                  button: true,
                  child: InkWell(
                    onTap: onDismiss,
                    customBorder: const CircleBorder(),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(LucideIcons.x,
                          size: 18, color: AppColors.sokoShade3),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: onPrimary,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sokoPink,
                      foregroundColor: AppColors.sokoInk,
                    ),
                    child: Text(cta),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
