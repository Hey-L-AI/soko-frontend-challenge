import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import 'add_items_to_list_sheet.dart';

/// Empty-state hero shown above the suggestions section when an
/// owner-visible list has no items yet. PROD-1852 Figma frame
/// 6353:28267.
///
/// Layout (top → bottom):
///   1. `soko-walking-and-reading.webp` illustration — renamed/relocated
///      from the legacy `discovery/done-looking.webp` in the
///      illustration-folder consolidation (commit 07c603a). Asset is
///      opaque RGB (no alpha) so we multiply-blend it against the page
///      bg (`AppColors.background`, NOT `sokoPaper` — #F9F0F0 is pinker
///      and leaves a faint pink rectangle) so the white surround drops
///      into the page while the dark strokes survive.
///   2. "Esta edição está\nem branco" headline (SeasonMix display) —
///      the `\n` lives in the ARB strings so each translation owns its
///      line break.
///   3. `BtSqIco(selected)` — "Adicionar algo" + plus icon. Uses the
///      design-system component (`docs/ui/design-decisions.md` D50),
///      not a hand-rolled pill.
///
/// Tap on the CTA opens [AddItemsToListSheet] as a modal bottom sheet
/// over the list page (`investigate/PROD-zine-add-item-freeze`,
/// replacing the previous `/lists/<listId>/add-items` route push that
/// triggered a list-page remount cycle). The Instagram-share handoff
/// lives on the header's [_handleAdd] entry point in [ListPageScreen];
/// this CTA is a primary affordance and intentionally skips that
/// side-channel — users who want to share can use the action menu sheet.
class EmptyZineState extends ConsumerWidget {
  final String listId;
  final String listName;

  /// Whether to render the "Adicionar algo" CTA.
  ///
  /// Owners get it; visitors get the illustration + headline alone. Required
  /// rather than defaulted, so a new call site has to decide — this state used
  /// to be owner-gated by the CALLER, which meant a visitor looking at an empty
  /// zine fell through to the zine view's "still loading" static cover and sat
  /// on a frozen page with no explanation (reported 2026-09-15). The gate
  /// belongs here, on the one affordance that is actually owner-only.
  final bool canAdd;

  const EmptyZineState({
    super.key,
    required this.listId,
    required this.listName,
    required this.canAdd,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Match the colour the surrounding shell paints on the Scaffold —
    // multiplying the webp by the page bg drops the asset's opaque
    // white surround into the page (white × pageBg = pageBg) while
    // preserving the darker pink/ink strokes (low × pageBg ≈ low).
    // Same technique as `DiscoveryFooter`.
    final pageBg = isDark ? AppColors.backgroundDark : AppColors.background;

    // Source asset is 252 × 230; render with the longest edge at 140 px
    // (≈ 22 % taller than the discovery footer tile because this hero
    // is the page's primary illustration, not a closing flourish).
    const targetMax = 140.0;
    const aspect = 252.0 / 230.0;
    final renderWidth = aspect >= 1 ? targetMax : targetMax * aspect;
    final renderHeight = aspect >= 1 ? targetMax / aspect : targetMax;

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 32, 15, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Image.asset(
              'assets/images/illustrations/soko-walking-and-reading.webp',
              width: renderWidth,
              height: renderHeight,
              fit: BoxFit.contain,
              color: pageBg,
              colorBlendMode: BlendMode.multiply,
            ),
          ),
          const SizedBox(height: 24),

          // Mobile/H1 — Season Mix TRIAL, w300, 42 px, line-height 94 %,
          // letter-spacing −2 % (= −0.84 px). Centred. Hard line break
          // is embedded in each ARB translation (`\n`) so the two-line
          // layout works across PT / PT_BR / EN without per-language
          // width tuning. Uses `AppTheme.displayPrimary`, which already
          // encodes the SeasonMix family + −2 % letter-spacing default.
          Text(
            l10n.listEmptyZineTitle,
            textAlign: TextAlign.center,
            style: AppTheme.displayPrimary(
              fontSize: 42,
              fontWeight: FontWeight.w300,
              height: 0.94,
              color: AppColors.sokoInk,
            ),
          ),
          // Design-system CTA (Figma `Bt_Sq_Ico` / 4108:2975). Selected
          // variant = Soko/Pink fill, radius 6, 14-px plus + 8-px gap +
          // 14-px label. Replaces the hand-rolled rounded pink pill.
          //
          // Owner-only: a visitor cannot add to someone else's zine, so for
          // them the state ends at the headline.
          if (canAdd) ...[
            const SizedBox(height: 20),
            Center(
              child: BtSqIco(
                icon: LucideIcons.circle_plus,
                label: l10n.listEmptyZineAddCta,
                variant: BtSqIcoVariant.selected,
                onTap: () => showAddItemsToListSheet(
                  context,
                  ref: ref,
                  listId: listId,
                  listName: listName,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
