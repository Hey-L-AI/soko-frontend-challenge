import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// What the user chose when told they have unsaved edits (PROD-3806).
enum UnsavedChangesChoice {
  /// Leave, keeping nothing.
  discard,

  /// Save, then leave — the save owns the leaving, so a failed save keeps the
  /// user on the form with its error visible.
  save,
}

/// "You have unsaved changes" confirmation, shown when leaving the edit-profile
/// form with edits pending.
///
/// Follows the canonical DS confirm pattern ([RemoveFollowerSheet],
/// `DeleteListSheet`): paper shell, centred title + body, paired [BtSqIco] with
/// the secondary action `normal` and the primary `selected`.
///
/// Dismissing the sheet — tapping outside, or a back gesture on the sheet
/// itself — returns null and means **stay on the form**. That is deliberate: a
/// dismissal is the one input that carries no intent, and the safe reading of
/// "no intent" is "don't lose anything and don't navigate anywhere".
class UnsavedChangesSheet extends StatelessWidget {
  const UnsavedChangesSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return DSSheetShell(
      bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            l10n.profileEditUnsavedTitle,
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
          Text(
            l10n.profileEditUnsavedBody,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.x,
                  label: l10n.profileEditUnsavedDiscard,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  onTap: () =>
                      Navigator.of(context).pop(UnsavedChangesChoice.discard),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.check,
                  label: l10n.profileEditUnsavedSave,
                  variant: BtSqIcoVariant.selected,
                  expand: true,
                  onTap: () =>
                      Navigator.of(context).pop(UnsavedChangesChoice.save),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Ask what to do about pending edits. Null means the sheet was dismissed —
/// treat it as "stay".
Future<UnsavedChangesChoice?> showUnsavedChangesSheet(
  BuildContext context, {
  required WidgetRef ref,
}) {
  return showBottomSheetWithHiddenNav<UnsavedChangesChoice>(
    context: context,
    ref: ref,
    builder: (_) => const UnsavedChangesSheet(),
  );
}
