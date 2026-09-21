import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/user_list.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/lists_provider.dart';
import '../../../shared/widgets/bottom_sheet/dashed_border_painter.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/list_thumbnail_stack.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../lists/utils/zine_cover_recipe.dart';

/// Result returned by [showInstagramShareListPickerSheet].
///
/// - The sheet returns `null` when the user dismisses it (swipe down /
///   scrim tap / back gesture) — the caller should NOT submit.
/// - A non-null result means the user explicitly chose to submit;
///   `listId` is the picked target list, or `null` for "Save without a
///   list" (mirrors today's `submit(url)` with no `list_id`).
class InstagramSharePickerResult {
  const InstagramSharePickerResult({this.listId});

  final String? listId;
}

/// Bottom sheet that lets a user pick which list to save an Instagram
/// share into. PROD-2725 brings Android up to iOS Phase-3 parity — before
/// this, every `ACTION_SEND` from Instagram on Android landed in the
/// auto-managed "From Instagram" list with no choice for the user.
///
/// Filter rule: only `!UserList.isSystemManaged` lists appear (matches
/// the iOS extension's filter). Backend-managed lists — IG auto-list,
/// onboarding seed, saved items, weekly bundle, user contributions — are
/// hidden because users never write to them directly.
///
/// Callers must short-circuit BEFORE showing this sheet when the user
/// has zero user-created lists (skip the sheet, submit with no list_id).
/// The picker assumes [lists] is non-empty.
Future<InstagramSharePickerResult?> showInstagramShareListPickerSheet({
  required BuildContext context,
}) {
  return showModalBottomSheet<InstagramSharePickerResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _InstagramShareListPickerSheet(),
  );
}

class _InstagramShareListPickerSheet extends ConsumerStatefulWidget {
  const _InstagramShareListPickerSheet();

  @override
  ConsumerState<_InstagramShareListPickerSheet> createState() =>
      _InstagramShareListPickerSheetState();
}

class _InstagramShareListPickerSheetState
    extends ConsumerState<_InstagramShareListPickerSheet> {
  String? _selectedListId;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final lists = ref
        .watch(listsProvider)
        .lists
        .where((l) => !l.isSystemManaged)
        .toList();

    return DSSheetShell(
      header: _Header(l10n: l10n),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        itemCount: lists.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, index) {
          final list = lists[index];
          return _ListRow(
            list: list,
            isSelected: _selectedListId == list.id,
            onTap: () {
              setState(() {
                _selectedListId = _selectedListId == list.id ? null : list.id;
              });
            },
            l10n: l10n,
          );
        },
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SokoCtaButton(
              label: l10n.instagramShareListPickerSave,
              onPressed: _selectedListId == null
                  ? null
                  : () => Navigator.of(
                      context,
                    ).pop(InstagramSharePickerResult(listId: _selectedListId)),
            ),
            const SizedBox(height: 8),
            SokoCtaButton(
              label: l10n.instagramShareListPickerSaveWithoutList,
              variant: SokoCtaVariant.ink,
              onPressed: () =>
                  Navigator.of(context).pop(const InstagramSharePickerResult()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.l10n});

  final Lt l10n;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.instagramShareListPickerTitle,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 20,
              fontWeight: FontWeight.w500,
              height: 1.1,
              letterSpacing: -0.4,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.instagramShareListPickerSubtitle,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.3,
              letterSpacing: -0.14,
              color: AppColors.sokoShade4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Single list row. Visual language mirrors `add_to_list_sheet._buildListRow`
/// (PROD-1861): dashed `sokoInk @ 30%` border idle, solid `sokoPink` border
/// + `sokoLight3` fill when selected.
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.list,
    required this.isSelected,
    required this.onTap,
    required this.l10n,
  });

  final UserList list;
  final bool isSelected;
  final VoidCallback onTap;
  final Lt l10n;

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
          child: Row(
            children: [
              ListThumbnailStack(
                previewImages: list.previewImages,
                coverImageUrl: list.coverImageUrl,
                coverRecipe: ZineCoverRecipe.fromUserList(list),
                title: list.name,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      list.name,
                      style: const TextStyle(
                        fontFamily: 'Zalando Sans',
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        height: 1.0,
                        letterSpacing: -0.36,
                        color: AppColors.sokoInk,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.listsItemCount(list.itemCount),
                      style: const TextStyle(
                        fontFamily: 'Zalando Sans',
                        fontSize: 14,
                        fontWeight: FontWeight.w300,
                        height: 1.2,
                        letterSpacing: -0.14,
                        color: AppColors.sokoShade4,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 22,
                  color: isSelected ? AppColors.sokoPink : AppColors.sokoShade4,
                ),
              ),
            ],
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
