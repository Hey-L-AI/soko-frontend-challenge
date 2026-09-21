import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/moderation.dart';
import '../../../features/discovery/widgets/discovery_shell.dart'
    show popOrFallback;
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import 'block_confirm_dialog.dart';
import 'report_sheet.dart';

/// PROD-2264 — wraps a caller-supplied [child] visual with the UGC
/// moderation popup (Report + Block when applicable). Each detail
/// screen passes the target inline — the cross-screen
/// `reportTargetProvider` bridge was retired together with the chrome
/// ⋮ button, so the popup no longer relies on a global slot.
///
/// "Block user" only appears when [authorUserId] is non-null —
/// non-attributed targets (events, places) get Report-only.
class ModerationMenuButton extends ConsumerWidget {
  final Widget child;
  final ReportTargetType targetType;
  final String targetId;
  final String? authorUserId;
  final String? authorDisplayLabel;

  const ModerationMenuButton({
    super.key,
    required this.child,
    required this.targetType,
    required this.targetId,
    this.authorUserId,
    this.authorDisplayLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    // Block requires an authenticated session — the `/blocks` endpoint
    // 401s on guest tokens, so the action is hidden for guests rather
    // than letting them tap into a dead-end.
    final canBlock = authorUserId != null && ref.watch(isAuthenticatedProvider);
    final labelStyle = AppTheme.body(fontSize: 14, color: AppColors.sokoInk);

    return PopupMenuButton<_ModerationAction>(
      tooltip: l10n.moderationActionMoreTooltip,
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      color: AppColors.sokoPaper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _ModerationAction.report,
          child: Row(
            children: [
              const Icon(LucideIcons.flag, size: 18, color: AppColors.sokoInk),
              const SizedBox(width: 12),
              Text(l10n.moderationMenuReport, style: labelStyle),
            ],
          ),
        ),
        if (canBlock)
          PopupMenuItem(
            value: _ModerationAction.block,
            child: Row(
              children: [
                const Icon(
                  LucideIcons.user_x,
                  size: 18,
                  color: AppColors.sokoInk,
                ),
                const SizedBox(width: 12),
                Text(l10n.moderationMenuBlockUser, style: labelStyle),
              ],
            ),
          ),
      ],
      onSelected: (action) async {
        switch (action) {
          case _ModerationAction.report:
            showReportSheet(
              context,
              targetType: targetType,
              targetId: targetId,
            );
          case _ModerationAction.block:
            final blockedUserId = authorUserId;
            if (blockedUserId == null) return;
            final blocked = await showBlockConfirmDialog(
              context,
              blockedUserId: blockedUserId,
              displayLabel: authorDisplayLabel,
              contextTargetType: targetType,
              contextTargetId: targetId,
            );
            // The list detail page IS the blocked user's content —
            // pop it so the demo (and the user) doesn't sit on a stale
            // surface that the block was supposed to remove.
            if (!blocked || !context.mounted) return;
            if (targetType == ReportTargetType.list) {
              popOrFallback(context);
            }
        }
      },
      child: child,
    );
  }
}

enum _ModerationAction { report, block }
