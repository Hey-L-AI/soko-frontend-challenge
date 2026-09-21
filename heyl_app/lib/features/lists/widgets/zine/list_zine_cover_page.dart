import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/models/models.dart' show slimMapPinToHeavy;
import '../../../../shared/widgets/dotted_section_divider.dart';
import '../../providers/unified_list_provider.dart';
import '../../utils/list_calendar_map_helpers.dart';
import '../../utils/open_in_list_item_detail.dart';
import '../../utils/zine_cover_recipe.dart';
import '../change_cover_sheet.dart';
import '../list_page_calendar_block.dart';
import '../list_page_map_block.dart';
import 'list_zine_cover.dart';
import 'list_zine_tease_peel.dart';
// NOTE: list_zine_hero_slot.dart is no longer imported here — covers now
// render via [ListZineCover] (PROD-1908). The hero slot is still used by
// item pages via list_zine_item_page.dart.

/// Cover card (page 0 of the zine `TurnPageView`) — pure visual, sized by
/// the parent. As of PROD-1908 the cover is a [ListZineCover] driven by
/// the BE-stored recipe (colour + texture + title + logo); the map /
/// calendar / suggestions content for the cover lives in
/// [ListZineCoverAux] which the zine view places below the pager.
class ListZineCoverCard extends StatelessWidget {
  /// Recipe resolved by [resolveZineCoverRecipe]. Drives every cover
  /// pixel — solid colour vs photo, title-stripe presence, logo and
  /// title tint.
  final ZineCoverRecipe recipe;

  /// List title rendered into the cover (uppercased, auto-fitted to
  /// max 2 lines).
  final String title;

  final int pageNumber;

  /// Tap on the cover — wired to [showChangeCoverSheet] for owners only
  /// (see [onCoverAddPhotoTap] and [coverTapEnabled]).
  /// `null` disables tap handling entirely, which is what non-owners get.
  final VoidCallback? onAddPhotoTap;

  /// Optional next-page label rendered inside the looping corner-peel
  /// "tease" overlay. Pass null to disable the tease (e.g., on a
  /// cover for an empty list with no next page).
  final String? teaseNextLabel;

  /// Optional widget rendered BEHIND the peel and revealed through the
  /// lifted-away triangle — meant to be a stand-in for "the page you
  /// would see if you flipped" (e.g. the first item's hero photo).
  /// Null = the peel falls back to a solid neutral fill.
  final Widget? teaseUnderlay;

  const ListZineCoverCard({
    super.key,
    required this.recipe,
    required this.title,
    required this.pageNumber,
    this.onAddPhotoTap,
    this.teaseNextLabel,
    this.teaseUnderlay,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Recipe-driven zine cover. No prev/next tap zones — cover
          // is non-navigating (matches PROD-1738 behaviour); users
          // advance via drag-to-flip or desktop side arrows. When the
          // recipe is `plain` (e.g. `from_profiling`), [ListZineCover]
          // internally suppresses title + logo + texture.
          ListZineCover(recipe: recipe, title: title),
          // Tap-to-change-cover affordance, owners only. PROD-4415: for a
          // non-owner the caller passes null, so NO detector is mounted — an
          // opaque full-bleed detector would otherwise swallow every tap on
          // the cover to no effect. The IgnorePointer-free area lets the
          // underlying widget render without absorbing taps (texture overlay
          // inside ListZineCover is IgnorePointer'd).
          if (onAddPhotoTap != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onAddPhotoTap,
              ),
            ),
          if (teaseNextLabel != null)
            Positioned.fill(
              child: ListZineTeasePeel(
                nextLabel: teaseNextLabel!,
                // First cycle on entry lifts more dramatically (0.25 vs
                // 0.15) — the user sees the cover peeling open enough
                // to reveal the next page underneath. After ~6 s the
                // peel settles into the subtle steady-state hint so the
                // loop doesn't keep grabbing attention.
                firstCyclePeakRealFlipProgress: 0.25,
                // Show the actual next page (first item's hero photo)
                // through the lifted-away triangle instead of a solid
                // neutral fill. Falls back to neutral when null.
                underlay: teaseUnderlay,
              ),
            ),
        ],
      ),
    );
  }
}

/// Auxiliary content rendered beneath the cover card: multi-pin map of all
/// list items, auto-month calendar, and (for owners) the suggestions
/// section. See `docs/designs/list-page-redesign.md` § 6.
class ListZineCoverAux extends ConsumerWidget {
  final UnifiedListState state;

  const ListZineCoverAux({super.key, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = state.list;
    if (list == null) return const SizedBox.shrink();

    // § 9.2 #13: cover map shows one pin per unique venue. PROD-1967 —
    // pins now come pre-deduped from the BE in `state.mapPins`
    // (whole-list set on every slim response), so we no longer FE-dedupe
    // over `state.items`. The pins arrive on first paint and stay
    // complete even before the background-tail items finish appending.
    final mapPinItems = state.mapPins
        .map((p) => slimMapPinToHeavy(p, list.id))
        .toList();
    final autoMonth = autoPickMonthFromItems(state.items);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Map ───────────────────────────────────────────────────
        if (mapPinItems.isNotEmpty) ...[
          const DottedSectionDivider(),
          ListPageMapBlock(
            items: mapPinItems,
            onItemTap: (item) {
              // PROD-2033 — cover tooltip "Ver detalhes" jumps directly
              // to the in-list venue/event detail page (same destination
              // as the zine item card's "Ver mais" button), skipping the
              // zine pager middle step.
              //
              // The slim map-pin item passed in has only `venueId` (and
              // no `eventId`), so we look up the full heavy item from
              // `state.items` first. Pin's representative `item_id` may
              // not be in `state.items` yet if the background tail
              // hasn't appended it (large lists, slow networks).
              // Silently no-op in that case — user can re-tap once
              // items finish loading. Forwarded only on the
              // authenticated branch by [ListPageMapBlock].
              final full = state.items.firstWhere(
                (it) => it.id == item.id,
                orElse: () => item,
              );
              openInListItemDetail(
                context,
                ref: ref,
                listId: list.id,
                tapped: full,
                allItems: state.items,
              );
            },
          ),
        ],

        // ── Calendar (auto-pick month, hidden if no events) ──────
        if (autoMonth != null) ...[
          const DottedSectionDivider(),
          ListPageCalendarBlock(
            items: state.items,
            currentMonth: autoMonth,
            tinted: true,
          ),
        ],

        // ListSuggestionsSection removed (PROD-2004 final) — the
        // owner-only "Suggestions" block sat here. Feature disabled
        // while the search pipeline's Google-fallback parsing is sorted
        // out.
      ],
    );
  }
}

/// Whether the cover exposes a tap target at all.
///
/// Non-owners get NO hit region (PROD-4415): the cover belongs to the list's
/// owner, so there is nothing for a viewer or collaborator to tap, and a
/// mounted detector would silently swallow every tap on the cover. The
/// sandbox preview is read-only for everyone.
bool coverTapEnabled({
  required bool sandbox,
  required UnifiedListState state,
}) => !sandbox && state.isOwner;

/// Helper for the cover's "Change cover" tap. Defined here so the zine view
/// (which owns the cover-card lifecycle) can wire it via [coverTapEnabled].
void onCoverAddPhotoTap({
  required BuildContext context,
  required WidgetRef ref,
  required UnifiedListState state,
}) {
  final list = state.list;
  if (list == null) return;
  // Belt and braces: call sites gate on [coverTapEnabled], but
  // showChangeCoverSheet carries no ownership guard of its own.
  if (!state.isOwner) return;
  // ignore: discarded_futures
  showChangeCoverSheet(context: context, ref: ref, listId: list.id);
}

/// Resolves the [ZineCoverRecipe] for a list. Handles three modes via
/// `cover_type` plus a legacy compat path for pre-PROD-1907 rows that
/// stored an item-image URL directly in `cover_image_url`. Falls back
/// deterministically when fields are missing/unsupported so every list
/// renders a coherent cover.
ZineCoverRecipe resolveZineCoverRecipe(UnifiedListState state) {
  final list = state.list;
  // No list yet (still loading) — produce a recipe from a stable
  // sentinel so the placeholder cover doesn't flicker between renders.
  if (list == null) {
    return ZineCoverRecipe.fromFields(
      listId: 'zine-cover-empty',
      coverType: null,
      coverColor: null,
      coverTexture: null,
      coverTextColor: null,
      coverItemId: null,
    );
  }
  return ZineCoverRecipe.fromUserList(
    list,
    itemLookup: (id) {
      for (final item in state.items) {
        if (item.id == id) return item.imageUrl;
      }
      return null;
    },
  );
}
