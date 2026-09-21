import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/bottom_sheet/dashed_border_painter.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;

/// `/menu/account/merge` page (PROD-2023). Replaces the legacy
/// `_MergeContent` case inside `ProfileSheet`'s drawer. Mirrors
/// `account_screen.dart`'s shell. Reached only via the Account screen
/// when `AddPhoneInline` / `AddEmailInline` detects an identifier that
/// belongs to another account (see `_handleMergeRequired`).
///
/// Cancel and a successful merge both pop back to `/menu/account`.
class MergeAccountsScreen extends ConsumerWidget {
  const MergeAccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _MergeHeader(
                title: l10n.mergeAccountsTitle,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _MergeBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _MergeHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _MergeHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: const Icon(
                LucideIcons.arrow_left,
                color: AppColors.sokoInk,
              ),
              onPressed: onBack,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            ),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _MergeBody extends ConsumerWidget {
  const _MergeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountState = ref.watch(accountProvider);
    final mergeData = accountState.mergeData;
    final l10n = Lt.of(context);

    // No merge data → bounce back to Account. This screen is only
    // meant to be reached after `_handleMergeRequired` has populated
    // `accountState.mergeData`.
    if (mergeData == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) popOrFallback(context);
      });
      return const Center(
        child: CircularProgressIndicator(color: AppColors.sokoPink),
      );
    }

    final authTypeDisplay = mergeData.pendingAuthType == 'phone'
        ? l10n.mergeAuthTypePhone
        : l10n.mergeAuthTypeEmail;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.sokoPink.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              LucideIcons.merge,
              size: 48,
              color: AppColors.sokoPink,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.mergeDetectedHeading,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'ZalandoSans',
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.2,
            letterSpacing: -0.44,
            color: AppColors.sokoInk,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.mergeDetectedSubtitle(
            authTypeDisplay,
            mergeData.pendingAuthIdentifier,
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            color: AppColors.sokoShade3,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 28),
        if (accountState.hasHandleConflict) ...[
          _ConflictSelector(
            label: l10n.mergeChooseHandle,
            currentValue: mergeData.mergePreview.thisAccount.handle!,
            otherValue: mergeData.mergePreview.otherAccount.handle!,
            currentLabel: l10n.mergeCurrentAccount,
            otherLabel: l10n.mergeOtherAccount,
            selectedSide: accountState.selectedHandleSide,
            onSelected: (side) {
              ref.read(accountProvider.notifier).setSelectedHandleSide(side);
            },
            formatValue: (value) => '@$value',
          ),
          const SizedBox(height: 20),
        ],
        if (accountState.hasFullNameConflict) ...[
          _ConflictSelector(
            label: l10n.mergeChooseDisplayName,
            currentValue: mergeData.mergePreview.thisAccount.fullName!,
            otherValue: mergeData.mergePreview.otherAccount.fullName!,
            currentLabel: l10n.mergeCurrentAccount,
            otherLabel: l10n.mergeOtherAccount,
            selectedSide: accountState.selectedFullNameSide,
            onSelected: (side) {
              ref.read(accountProvider.notifier).setSelectedFullNameSide(side);
            },
          ),
          const SizedBox(height: 20),
        ],
        if (accountState.error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.sokoRed.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(
                  LucideIcons.triangle_alert,
                  size: 18,
                  color: AppColors.sokoRed,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    accountState.error!,
                    style: const TextStyle(
                      color: AppColors.sokoRed,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: BtSqIco(
                icon: LucideIcons.x,
                label: l10n.commonCancel,
                variant: BtSqIcoVariant.normal,
                expand: true,
                onTap: accountState.isLoading
                    ? () {}
                    : () => _cancel(context, ref),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: IgnorePointer(
                ignoring:
                    accountState.isLoading || !accountState.canConfirmMerge,
                child: Opacity(
                  opacity:
                      accountState.isLoading || !accountState.canConfirmMerge
                      ? 0.5
                      : 1.0,
                  child: BtSqIco(
                    icon: LucideIcons.merge,
                    label: l10n.mergeConfirmButton,
                    variant: BtSqIcoVariant.selected,
                    expand: true,
                    onTap: () => _confirmMerge(context, ref),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _cancel(BuildContext context, WidgetRef ref) {
    ref.read(accountProvider.notifier).cancelFlow();
    popOrFallback(context);
  }

  Future<void> _confirmMerge(BuildContext context, WidgetRef ref) async {
    final success = await ref.read(accountProvider.notifier).confirmMerge();
    if (success && context.mounted) {
      showSoko(
        ref,
        message: Lt.of(context).mergeSuccess,
        variant: SokoVariant.success,
      );
      popOrFallback(context);
    }
  }
}

/// Pair of soko-styled picker rows for choosing between two conflicting
/// values during account merge. Replaces the legacy Material
/// `SegmentedButton` — uses the same dashed-vs-solid border treatment
/// as the preferences-screen picker rows so the merge flow feels native
/// to the rebrand.
class _ConflictSelector extends StatelessWidget {
  final String label;
  final String currentValue;
  final String otherValue;
  final String currentLabel;
  final String otherLabel;
  final MergeSide? selectedSide;
  final ValueChanged<MergeSide> onSelected;
  final String Function(String)? formatValue;

  const _ConflictSelector({
    required this.label,
    required this.currentValue,
    required this.otherValue,
    required this.currentLabel,
    required this.otherLabel,
    required this.selectedSide,
    required this.onSelected,
    this.formatValue,
  });

  @override
  Widget build(BuildContext context) {
    final displayCurrent = formatValue?.call(currentValue) ?? currentValue;
    final displayOther = formatValue?.call(otherValue) ?? otherValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.sokoInk,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        _MergeOptionRow(
          value: displayCurrent,
          subLabel: currentLabel,
          isSelected: selectedSide == MergeSide.current,
          onTap: () => onSelected(MergeSide.current),
        ),
        const SizedBox(height: 8),
        _MergeOptionRow(
          value: displayOther,
          subLabel: otherLabel,
          isSelected: selectedSide == MergeSide.other,
          onTap: () => onSelected(MergeSide.other),
        ),
      ],
    );
  }
}

class _MergeOptionRow extends StatelessWidget {
  final String value;
  final String subLabel;
  final bool isSelected;
  final VoidCallback onTap;

  const _MergeOptionRow({
    required this.value,
    required this.subLabel,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rowContent = Material(
      color: isSelected ? AppColors.sokoLight3 : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value,
                        style: const TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.0,
                          letterSpacing: -0.28,
                          color: AppColors.sokoInk,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subLabel,
                        style: const TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 12,
                          fontWeight: FontWeight.w300,
                          height: 1.2,
                          letterSpacing: -0.12,
                          color: AppColors.sokoShade4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.sokoPink
                        : AppColors.sokoInk.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isSelected ? Icons.check_rounded : Icons.add_rounded,
                    size: 16,
                    color: AppColors.sokoInk,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (isSelected) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.sokoPink, width: 1),
        ),
        child: rowContent,
      );
    }
    return CustomPaint(
      painter: DashedBorderPainter(
        color: AppColors.sokoInk.withValues(alpha: 0.30),
      ),
      child: rowContent,
    );
  }
}
