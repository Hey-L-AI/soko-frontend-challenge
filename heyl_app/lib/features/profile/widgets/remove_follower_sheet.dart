import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// Confirmation sheet for removing one of my followers (Instagram "Remove"
/// semantics: the removed user simply stops following me and is NOT notified).
/// Mirrors [DeleteListSheet] — the canonical DS destructive-confirm pattern
/// (paper shell, quoted target name, paired [BtSqIco] Cancel + sokoRed Remove).
class RemoveFollowerSheet extends StatefulWidget {
  /// Follower's display name, quoted in the body so the user confirms who.
  final String name;

  /// Performs the removal. Returns true on success (sheet pops with it).
  final Future<bool> Function() onRemove;

  const RemoveFollowerSheet({
    super.key,
    required this.name,
    required this.onRemove,
  });

  @override
  State<RemoveFollowerSheet> createState() => _RemoveFollowerSheetState();
}

class _RemoveFollowerSheetState extends State<RemoveFollowerSheet> {
  bool _isLoading = false;

  Future<void> _handleRemove() async {
    setState(() => _isLoading = true);
    try {
      final ok = await widget.onRemove();
      if (mounted) Navigator.of(context).pop(ok);
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
          Text(
            l10n.removeFollowerTitle,
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
            '"${widget.name}"',
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
          Text(
            l10n.removeFollowerConfirm,
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
                  label: l10n.commonCancel,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  onTap: _isLoading ? () {} : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _isLoading
                    ? const _RemoveSpinnerSlot()
                    : BtSqIco(
                        icon: LucideIcons.user_x,
                        label: l10n.removeFollowerButton,
                        variant: BtSqIcoVariant.selected,
                        selectedBackgroundOverride: AppColors.sokoRed,
                        expand: true,
                        onTap: _handleRemove,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Same-shape spinner slot that replaces the destructive [BtSqIco] during an
/// in-flight remove, so the footer row doesn't reflow.
class _RemoveSpinnerSlot extends StatelessWidget {
  const _RemoveSpinnerSlot();

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

/// Show the remove-follower confirmation sheet. Returns true if the removal
/// succeeded, false on failure, null if dismissed.
Future<bool?> showRemoveFollowerSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String name,
  required Future<bool> Function() onRemove,
}) {
  return showBottomSheetWithHiddenNav<bool>(
    context: context,
    ref: ref,
    builder: (context) => RemoveFollowerSheet(name: name, onRemove: onRemove),
  );
}
