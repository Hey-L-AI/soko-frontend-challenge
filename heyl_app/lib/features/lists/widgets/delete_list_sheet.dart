import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// PROD-1884 — confirmation bottom sheet for deleting a list. Replaces
/// the legacy `DeleteListDialog` (`AlertDialog`) with the modern
/// `DSSheetShell` pattern shared with every other recent confirmation
/// sheet (`login_prompt_sheet`, `location_scope_picker_sheet`, etc.).
///
/// Visual follows the canonical DS sheet pair: paper shell, Mobile/B1
/// Bold title, quoted list name, Mobile/B2 Reg warning, and a paired
/// [BtSqIco] action row — `normal` Cancel + `selected` Delete tinted
/// `sokoRed` (the destructive surface also used by
/// `SokoCtaButton.red`). Drop-in compatible with the old dialog —
/// `Future<bool?>` return shape matches `DeleteListDialog.show`.
class DeleteListSheet extends StatefulWidget {
  /// Name of the list being deleted — rendered in the sheet body so
  /// the user can confirm the target before tapping Delete.
  final String listName;

  /// Async callback that performs the actual delete. Should return
  /// `true` on success, `false` on failure (caller surfaces errors).
  /// The sheet pops with this value.
  final Future<bool> Function() onDelete;

  const DeleteListSheet({
    super.key,
    required this.listName,
    required this.onDelete,
  });

  @override
  State<DeleteListSheet> createState() => _DeleteListSheetState();
}

class _DeleteListSheetState extends State<DeleteListSheet> {
  bool _isLoading = false;

  Future<void> _handleDelete() async {
    setState(() => _isLoading = true);
    try {
      final success = await widget.onDelete();
      if (mounted) {
        Navigator.of(context).pop(success);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return DSSheetShell(
      bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Title — Mobile/B1 Bold on sokoInk. Matches login_prompt_sheet.
          Text(
            l10n.listsDeleteDialogTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              height: 1.0,
              letterSpacing: -0.36,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 12),

          // List name — quoted, medium weight, so the user visually
          // confirms the target before tapping Delete.
          Text(
            '"${widget.listName}"',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 12),

          // Warning copy — Mobile/B2 Reg on sokoInk.
          Text(
            l10n.listsDeleteConfirm,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 20),

          // Paired full-width action row — Cancel (×) + Delete (trash,
          // sokoRed), each Expanded with a 12 px gap. Same sticky-
          // footer convention as every other DS confirmation sheet.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.x,
                  label: l10n.listsButtonCancel,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  // No-op while a delete is in flight; visual stays
                  // identical so the row doesn't reflow.
                  onTap: _isLoading ? () {} : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _isLoading
                    ? const _DeleteSpinnerSlot()
                    : BtSqIco(
                        icon: LucideIcons.trash_2,
                        label: l10n.listsButtonDelete,
                        variant: BtSqIcoVariant.selected,
                        selectedBackgroundOverride: AppColors.sokoRed,
                        expand: true,
                        onTap: _handleDelete,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Same-shape spinner slot that replaces the destructive [BtSqIco]
/// during an in-flight delete. Matches BtSqIco's 40 px height + 6 px
/// radius so the footer row doesn't reflow.
class _DeleteSpinnerSlot extends StatelessWidget {
  const _DeleteSpinnerSlot();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.sokoRed,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.sokoInk,
        ),
      ),
    );
  }
}

/// Show the delete-list confirmation bottom sheet.
///
/// Returns `true` if `onDelete()` succeeded, `false` if it returned
/// false (caller surfaces the error), or `null` if the user dismissed
/// the sheet (Cancel, swipe down, tap outside, back button).
Future<bool?> showDeleteListSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String listName,
  required Future<bool> Function() onDelete,
}) {
  return showBottomSheetWithHiddenNav<bool>(
    context: context,
    ref: ref,
    builder: (context) =>
        DeleteListSheet(listName: listName, onDelete: onDelete),
  );
}
