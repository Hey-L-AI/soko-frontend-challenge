import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

/// Shared bottom-sheet confirmation used by every destructive memory action.
/// Returns `true` only when the user taps the confirm action.
class _ConfirmSheet extends StatelessWidget {
  final String title;
  final Widget body;
  final String confirmLabel;
  final Color confirmColor;
  final Color confirmForeground;

  const _ConfirmSheet({
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.confirmColor,
    required this.confirmForeground,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: AppColors.sokoShade4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              title,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 26,
                fontWeight: FontWeight.w300,
                height: 1,
                letterSpacing: -0.8,
                fontFamily: 'UnJamoBatang',
              ),
            ),
            const SizedBox(height: 10),
            DefaultTextStyle(
              style: const TextStyle(
                color: AppColors.sokoShade2,
                fontSize: 14,
                fontWeight: FontWeight.w300,
                height: 1.4,
                letterSpacing: -0.3,
              ),
              child: body,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.sokoInk,
                      side: BorderSide(
                        color: AppColors.sokoInk.withValues(alpha: 0.08),
                      ),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      l10n.memoryActionCancel,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: confirmColor,
                      foregroundColor: confirmForeground,
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                      confirmLabel,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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

Future<bool> showMemoryDeleteItemSheet(
  BuildContext context, {
  required String quoted,
}) async {
  final l10n = Lt.of(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.sokoPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _ConfirmSheet(
      title: l10n.memoryDeleteItemTitle,
      body: Text(l10n.memoryDeleteItemBody(quoted)),
      confirmLabel: l10n.memoryActionDelete,
      confirmColor: AppColors.sokoRed,
      confirmForeground: AppColors.sokoInk,
    ),
  );
  return ok == true;
}

/// Confirm removing an AVOIDED value.
///
/// A separate sheet from [showMemoryDeleteItemSheet] because deleting an avoid
/// does the opposite of deleting a like: the item's own copy says Soko will
/// "stop using" the value when suggesting places, which for an avoid reads as
/// "stop suggesting it" — exactly backwards. Removing an avoid makes the value
/// eligible again, so the sheet has to say so.
Future<bool> showMemoryDeleteAvoidSheet(
  BuildContext context, {
  required String quoted,
}) async {
  final l10n = Lt.of(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.sokoPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _ConfirmSheet(
      title: l10n.memoryDeleteAvoidTitle,
      body: Text(l10n.memoryDeleteAvoidBody(quoted)),
      confirmLabel: l10n.memoryActionDelete,
      confirmColor: AppColors.sokoRed,
      confirmForeground: AppColors.sokoInk,
    ),
  );
  return ok == true;
}

Future<bool> showMemoryDeleteCategorySheet(
  BuildContext context, {
  required String family,
}) async {
  final l10n = Lt.of(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.sokoPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _ConfirmSheet(
      title: l10n.memoryDeleteCategoryTitle(family),
      body: Text(l10n.memoryDeleteCategoryBody),
      confirmLabel: l10n.memoryActionDelete,
      confirmColor: AppColors.sokoRed,
      confirmForeground: AppColors.sokoInk,
    ),
  );
  return ok == true;
}

Future<bool> showMemoryClearAllSheet(BuildContext context) async {
  final l10n = Lt.of(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.sokoPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _ConfirmSheet(
      title: l10n.memoryClearAllTitle,
      body: Text(l10n.memoryClearAllBody),
      confirmLabel: l10n.memoryActionClearEverything,
      confirmColor: AppColors.sokoInk,
      confirmForeground: Colors.white,
    ),
  );
  return ok == true;
}
