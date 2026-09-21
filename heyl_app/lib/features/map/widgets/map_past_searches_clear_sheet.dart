import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// PROD-3499 — confirmation sheet for clearing ALL past map searches
/// (Decision #31). Same canonical DS confirm-sheet anatomy as
/// `DeleteListSheet`: paper shell, bold title, warning copy, paired
/// [BtSqIco] row with the destructive side tinted `sokoRed`.
class MapPastSearchesClearSheet extends StatefulWidget {
  /// Performs the clear; returns true on success (the sheet pops with it).
  final Future<bool> Function() onClear;

  const MapPastSearchesClearSheet({super.key, required this.onClear});

  @override
  State<MapPastSearchesClearSheet> createState() =>
      _MapPastSearchesClearSheetState();
}

class _MapPastSearchesClearSheetState extends State<MapPastSearchesClearSheet> {
  bool _isLoading = false;

  Future<void> _handleClear() async {
    setState(() => _isLoading = true);
    try {
      final success = await widget.onClear();
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
          Text(
            l10n.mapPastSearchesClearAllConfirmTitle,
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
            l10n.mapPastSearchesClearAllConfirmBody,
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
                  label: l10n.listsButtonCancel,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  onTap: _isLoading ? () {} : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _isLoading
                    ? const _ClearSpinnerSlot()
                    : BtSqIco(
                        icon: LucideIcons.trash_2,
                        label: l10n.mapPastSearchesClearAllConfirmCta,
                        variant: BtSqIcoVariant.selected,
                        selectedBackgroundOverride: AppColors.sokoRed,
                        expand: true,
                        onTap: _handleClear,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Same-shape spinner replacing the destructive [BtSqIco] while the clear
/// is in flight (40 px height + 6 px radius — no footer reflow).
class _ClearSpinnerSlot extends StatelessWidget {
  const _ClearSpinnerSlot();

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

/// Returns true when the history was cleared, false when the server call
/// failed, null when dismissed without confirming.
Future<bool?> showMapPastSearchesClearSheet(
  BuildContext context, {
  required WidgetRef ref,
  required Future<bool> Function() onClear,
}) {
  return showBottomSheetWithHiddenNav<bool>(
    context: context,
    ref: ref,
    builder: (_) => MapPastSearchesClearSheet(onClear: onClear),
  );
}
