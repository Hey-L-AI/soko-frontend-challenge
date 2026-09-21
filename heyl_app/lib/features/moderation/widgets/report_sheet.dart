import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/moderation.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../providers/moderation_provider.dart';

/// PROD-2264 — Shared bottom sheet that lets the user submit a UGC
/// moderation report against any [ReportTargetType]. Reason picker +
/// optional free-text details + Submit. On success / rate-limit / 404
/// dispatches the appropriate Soko toast and pops; on generic failure
/// stays open so the user can retry.
Future<void> showReportSheet(
  BuildContext context, {
  required ReportTargetType targetType,
  required String targetId,
}) {
  // Direct [showModalBottomSheet] — not the [showBottomSheetWithHiddenNav]
  // helper — because the report sheet opens from detail pages where
  // collapsing the bottom nav under the modal scrim causes a visible
  // layout shift on the page behind the sheet. The scrim already covers
  // the nav, so the hide animation adds nothing.
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppColors.sokoInkSecondary,
    useRootNavigator: true,
    useSafeArea: false,
    builder: (sheetContext) =>
        _ReportSheet(targetType: targetType, targetId: targetId),
  );
}

class _ReportSheet extends ConsumerStatefulWidget {
  final ReportTargetType targetType;
  final String targetId;

  const _ReportSheet({required this.targetType, required this.targetId});

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  ReportReason? _reason;
  final TextEditingController _detailsController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() => _submitting = true);

    final result = await ref
        .read(reportSubmissionControllerProvider)
        .submit(
          ReportCreateRequest(
            targetType: widget.targetType,
            targetId: widget.targetId,
            reason: reason,
            details: _detailsController.text.trim().isEmpty
                ? null
                : _detailsController.text.trim(),
          ),
        );

    if (!mounted) return;

    final l10n = Lt.of(context);
    switch (result) {
      case ReportSubmissionSuccess(:final report):
        try {
          await ref
              .read(unifiedAnalyticsProvider)
              .trackContentReport(
                targetType: widget.targetType.toJson(),
                reason: reason.toJson(),
                idempotentHit: report.idempotentHit,
              );
        } catch (_) {
          // Analytics failure must not block the user-facing flow.
        }
        if (!mounted) return;
        Navigator.of(context).pop();
        showSoko(
          ref,
          message: l10n.moderationReportSuccessToast,
          variant: SokoVariant.success,
        );
      case ReportSubmissionRateLimited():
        Navigator.of(context).pop();
        showSoko(
          ref,
          message: l10n.moderationReportRateLimitToast,
          variant: SokoVariant.error,
        );
      case ReportSubmissionTargetNotFound():
        Navigator.of(context).pop();
        showSoko(
          ref,
          message: l10n.moderationReportFailureToast,
          variant: SokoVariant.error,
        );
      case ReportSubmissionError():
        setState(() => _submitting = false);
        showSoko(
          ref,
          message: l10n.moderationReportFailureToast,
          variant: SokoVariant.error,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return DSSheetShell(
      header: _Header(title: l10n.moderationReportSheetTitle),
      bodyPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.moderationReportSheetSubtitle,
              style: AppTheme.body(
                fontSize: 14,
                color: AppColors.sokoInkSecondary,
              ),
            ),
            const SizedBox(height: 16),
            ..._reasonOptions(l10n).entries.map(
              (entry) => _ReasonTile(
                reason: entry.key,
                label: entry.value,
                selected: _reason == entry.key,
                onTap: _submitting
                    ? null
                    : () => setState(() => _reason = entry.key),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.moderationReportDetailsLabel,
              style: AppTheme.body(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoShade3,
              ),
            ),
            const SizedBox(height: 8),
            SokoTextField(
              controller: _detailsController,
              hintText: l10n.moderationReportDetailsHint,
              maxLines: 3,
              minLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
      ),
      footer: _SubmitFooter(
        label: l10n.moderationReportSubmitButton,
        onSubmit: _submit,
        enabled: _reason != null && !_submitting,
        loading: _submitting,
      ),
    );
  }

  /// Reasons exposed to the user, in picker order. The retired
  /// `hate_speech` and `violence_threats` reasons, plus `impersonation`
  /// and `doxxing` (listed in the Community Guidelines but absent from the
  /// enum entirely), are covered by "Other" with free-text details.
  /// Flagged as an OpenAPI gap in
  /// `docs/investigations/context/prod-2264-ugc-moderation.md` §5.
  Map<ReportReason, String> _reasonOptions(Lt l10n) => {
    ReportReason.incorrectInformation:
        l10n.moderationReportReasonIncorrectInformation,
    ReportReason.repeatedContent: l10n.moderationReportReasonRepeatedContent,
    ReportReason.spam: l10n.moderationReportReasonSpam,
    ReportReason.harassment: l10n.moderationReportReasonHarassment,
    ReportReason.sexuallyExplicit: l10n.moderationReportReasonExplicit,
    ReportReason.other: l10n.moderationReportReasonOther,
  };
}

class _Header extends StatelessWidget {
  final String title;
  const _Header({required this.title});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: 'Zalando Sans',
          fontSize: 18,
          fontWeight: FontWeight.w500,
          height: 1.2,
          letterSpacing: -0.36,
          color: AppColors.sokoInk,
        ),
      ),
    ),
  );
}

class _SubmitFooter extends StatelessWidget {
  final String label;
  final VoidCallback onSubmit;
  final bool enabled;
  final bool loading;

  const _SubmitFooter({
    required this.label,
    required this.onSubmit,
    required this.enabled,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        color: AppColors.sokoPaper,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: SokoCtaButton(
          label: label,
          variant: SokoCtaVariant.red,
          loading: loading,
          onPressed: enabled ? onSubmit : null,
        ),
      ),
    );
  }
}

class _ReasonTile extends StatelessWidget {
  final ReportReason reason;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _ReasonTile({
    required this.reason,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected ? LucideIcons.circle_check_big : LucideIcons.circle,
              size: 20,
              color: selected ? AppColors.sokoInk : AppColors.sokoInkSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: AppTheme.body(fontSize: 14, color: AppColors.sokoInk),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
