import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../providers/unified_list_provider.dart';
import 'change_cover_sheet.dart';
import 'zine/list_zine_cover.dart';
import 'zine/list_zine_cover_page.dart' show resolveZineCoverRecipe;

/// Owner-only cover-editing row rendered above the description in the
/// redesigned list page's List view while page-level edit mode is active
/// (PROD-1783). Renders a 4:5 portrait preview of the current
/// recipe-driven zine cover (PROD-1908) — **title + Soko logo included**
/// (PROD-1918 batch 3) — next to an "Alterar capa" button that opens
/// the existing [showChangeCoverSheet] flow. The 4:5 ratio matches the
/// list-page hero (D110) so the preview composes title + logo the same
/// way the live cover does.
///
/// Does NOT add horizontal padding — wrap at the call site so it lines
/// up with the description / sections (15-px gutter on List view).
class ListEditCoverRow extends ConsumerWidget {
  final String listId;

  const ListEditCoverRow({super.key, required this.listId});

  static const double _thumbWidth = 88;
  static const double _thumbHeight = 110; // 4:5

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    // Watch the same unified state the rest of the page reads from —
    // when the user changes the cover via the sheet, this thumbnail
    // updates as soon as the optimistic update lands.
    final state = ref.watch(unifiedListProvider(listId));
    final recipe = resolveZineCoverRecipe(state);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: _thumbWidth,
            height: _thumbHeight,
            child: ListZineCover(recipe: recipe, title: state.list?.name ?? ''),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _AlterarCapaButton(
              label: l10n.listActionChangeCover,
              onTap: () => showChangeCoverSheet(
                context: context,
                ref: ref,
                listId: listId,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Pill button — Soko/Ink @ 6 % bg, 6-px radius, label-only. Same visual
/// language as the existing "Deixar nota" pill so the edit-mode surface
/// reads as a single design family.
class _AlterarCapaButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _AlterarCapaButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoInk.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            style: AppTheme.mobileB2Reg(color: AppColors.sokoInk),
          ),
        ),
      ),
    );
  }
}
