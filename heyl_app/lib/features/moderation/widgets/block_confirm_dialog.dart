import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/moderation.dart';
import '../../../features/discovery/providers/following_shelf_provider.dart';
import '../../../features/discovery/providers/recommended_shelf_provider.dart';
import '../../../features/lists/providers/unified_list_provider.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/lists_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../providers/blocked_users_provider.dart';
import '../providers/moderation_provider.dart';

/// PROD-2264 — Modal confirmation before blocking a user. Pops on
/// cancel, submits the `POST /blocks` call on confirm. Dispatches a
/// toast on every outcome; analytics fires only on real success (not on
/// 400 self-block / 404 missing-user errors).
///
/// Returns `true` to the caller when the block landed, `false` (or
/// `null` → coerced to `false`) otherwise. Callers use the result to
/// decide whether to pop the underlying page (e.g. exit a list detail
/// owned by the just-blocked user).
Future<bool> showBlockConfirmDialog(
  BuildContext context, {
  required String blockedUserId,
  String? displayLabel,
  ReportTargetType? contextTargetType,
  String? contextTargetId,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => _BlockConfirmDialog(
      blockedUserId: blockedUserId,
      displayLabel: displayLabel,
      contextTargetType: contextTargetType,
      contextTargetId: contextTargetId,
    ),
  );
  return result ?? false;
}

class _BlockConfirmDialog extends ConsumerStatefulWidget {
  final String blockedUserId;
  final String? displayLabel;
  final ReportTargetType? contextTargetType;
  final String? contextTargetId;

  const _BlockConfirmDialog({
    required this.blockedUserId,
    this.displayLabel,
    this.contextTargetType,
    this.contextTargetId,
  });

  @override
  ConsumerState<_BlockConfirmDialog> createState() =>
      _BlockConfirmDialogState();
}

class _BlockConfirmDialogState extends ConsumerState<_BlockConfirmDialog> {
  bool _submitting = false;

  Future<void> _confirm() async {
    setState(() => _submitting = true);
    final controller = ref.read(reportSubmissionControllerProvider);
    final result = await controller.block(
      BlockCreateRequest(
        blockedUserId: widget.blockedUserId,
        contextTargetType: widget.contextTargetType,
        contextTargetId: widget.contextTargetId,
      ),
    );
    if (!mounted) return;
    final l10n = Lt.of(context);

    switch (result) {
      case BlockSubmissionSuccess():
        try {
          await ref
              .read(unifiedAnalyticsProvider)
              .trackUserBlock(
                blockedUserId: widget.blockedUserId,
                contextTargetType: widget.contextTargetType?.toJson(),
              );
        } catch (_) {
          // Analytics failure must not block the user flow.
        }
        if (!mounted) return;
        // Hide the blocked user's content immediately by recording the
        // block in the session-local set. The Discovery shelves and
        // search-results provider watch [blockedUserIdsProvider] and
        // filter blocked-author rows out client-side without a refetch
        // — that's the primary defense, so the user sees the block
        // take effect on every surface as soon as the dialog closes.
        ref
            .read(blockedUsersProvider.notifier)
            .addLocalBlock(widget.blockedUserId);
        // Belt-and-suspenders: also invalidate the buckets whose state
        // isn't already author-filtered (legacy lists shelves) and the
        // list-detail provider for the page the action was triggered
        // from, so a follow-up backend filter takes effect on the next
        // read. Safe to remove once every surface watches
        // [blockedUserIdsProvider] directly.
        ref.invalidate(listsProvider);
        ref.invalidate(followingShelfProvider);
        ref.invalidate(recommendedShelfProvider);
        final ctxTargetId = widget.contextTargetId;
        if (widget.contextTargetType == ReportTargetType.list &&
            ctxTargetId != null) {
          ref.invalidate(unifiedListProvider(ctxTargetId));
        }
        if (!mounted) return;
        Navigator.of(context).pop(true);
        showSoko(
          ref,
          message: l10n.moderationBlockSuccessToast,
          variant: SokoVariant.success,
        );
      case BlockSubmissionSelfTarget():
      case BlockSubmissionTargetNotFound():
      case BlockSubmissionError():
        setState(() => _submitting = false);
        showSoko(
          ref,
          message: l10n.moderationBlockFailureToast,
          variant: SokoVariant.error,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return AlertDialog(
      backgroundColor: AppColors.sokoPaper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      title: Text(
        l10n.moderationBlockDialogTitle,
        style: AppTheme.subtitle(color: AppColors.sokoInk),
      ),
      content: Text(
        l10n.moderationBlockDialogBody,
        style: AppTheme.body(fontSize: 14, color: AppColors.sokoInk),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(
            l10n.moderationBlockDialogCancel,
            style: AppTheme.body(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.sokoInk,
            ),
          ),
        ),
        SokoCtaButton(
          label: l10n.moderationBlockDialogConfirm,
          variant: SokoCtaVariant.red,
          loading: _submitting,
          expand: false,
          onPressed: _submitting ? null : _confirm,
        ),
      ],
    );
  }
}
