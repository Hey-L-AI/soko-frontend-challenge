import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/lists_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/cached_image.dart';
import '../providers/cover_share_render_provider.dart';
import '../providers/unified_list_provider.dart';
import '../utils/cover_signature.dart';
import '../utils/zine_cover_recipe.dart';
import 'zine/list_zine_cover.dart';
import 'zine/list_zine_cover_page.dart' show resolveZineCoverRecipe;
import 'zine/list_zine_item_page.dart' show showAddPhotoComingSoonSnackBar;

/// Top-level entry point — shows the cover-selection sheet for [listId].
///
/// The sheet watches [unifiedListProvider] internally (PROD-1918) so all
/// swatch rows + the in-sheet live preview reflect the latest recipe as
/// soon as `setCoverRecipe` lands the optimistic update. The callbacks
/// here own the post-mutation propagation: every edit calls
/// [mirrorLocalList] which writes the new [UserList] into [listsProvider]
/// — discovery shelves that listen to it (e.g. `yoursShelfProvider`)
/// patch their cached entries in-place, so the user sees the updated
/// cover the instant they pop back to Discovery, no BE refetch required.
///
/// PROD-1918 batch 5: removed the redundant `invalidateDiscoveryShelves`
/// helper. It used to force every shelf provider to re-run `build()` →
/// `await api.listMyLists()` after every cover edit — but the listen
/// pattern was added to `yoursShelfProvider` afterwards, and the two
/// mechanisms fought each other: any BE replication lag would cause the
/// refetched response to overwrite the locally-patched state with stale
/// data, silently reverting the just-changed list's cover on the shelf.
/// Trust the listen pattern; non-listening shelves refetch naturally on
/// the next discovery visit (autoDispose).
Future<void> showChangeCoverSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String listId,
}) {
  Future<void> mirrorLocalList() async {
    final updatedList = ref.read(unifiedListProvider(listId)).list;
    if (updatedList != null) {
      ref
          .read(listsProvider.notifier)
          .updateListLocally(updatedList.id, updatedList);
    }
  }

  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    // DS chrome (PROD-1913) — `DSSheetShell` paints its own sokoPaper
    // background and 20 px top radius; passing transparent here keeps
    // Material from rendering a colour beneath the rounded corners.
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return ChangeCoverSheet(
        listId: listId,
        onPickColor: (color) async {
          await ref
              .read(unifiedListProvider(listId).notifier)
              .setCoverRecipe(color: color.wire);
          await mirrorLocalList();
        },
        onPickTexture: (textureId) async {
          await ref
              .read(unifiedListProvider(listId).notifier)
              .setCoverRecipe(texture: textureId);
          await mirrorLocalList();
        },
        onPickTextColor: (textColor) async {
          await ref
              .read(unifiedListProvider(listId).notifier)
              .setCoverRecipe(textColor: textColor.wire);
          await mirrorLocalList();
        },
        onPickItemId: (itemId) async {
          await ref
              .read(unifiedListProvider(listId).notifier)
              .setCoverRecipe(
                type: ZineCoverType.itemImage.wire,
                itemId: itemId,
              );
          await mirrorLocalList();
        },
        onClearItemImage: () async {
          // PROD-1918 batch 4 — revert to background_color mode while
          // preserving colour/texture/text-colour. Only clears the
          // item ref; everything else stays as the user set it.
          //
          // PROD-2425 — also write the current effective color
          // explicitly. The resolver gates its PROD-2040 fallback
          // (most-recent item photo) on `coverColor == null`; without an
          // explicit color here, "Sem imagem" would land in a recipe
          // that still resolves to a photo (the fallback), making the
          // tap a no-op for the user. Resolving the current color and
          // writing it back keeps the visible color stable across the
          // transition.
          final list = ref.read(unifiedListProvider(listId)).list;
          final effectiveColorWire =
              list?.coverColor ??
              kZineColors[stableHash(list?.id ?? listId) % kZineColors.length]
                  .wire;
          await ref
              .read(unifiedListProvider(listId).notifier)
              .setCoverRecipe(
                type: ZineCoverType.backgroundColor.wire,
                color: effectiveColorWire,
                clearItemId: true,
              );
          await mirrorLocalList();
        },
        onResetToDefault: () async {
          // PROD-1908 — wipe the recipe back to "BE picks defaults
          // again on next nav, FE renders deterministic fallback in
          // the meantime". Sends explicit nulls per BE PATCH semantics
          // (see PROD-1907 thread). cover_type returns to the default
          // background_color implicitly.
          await ref
              .read(unifiedListProvider(listId).notifier)
              .setCoverRecipe(
                type: ZineCoverType.backgroundColor.wire,
                clearColor: true,
                clearTexture: true,
                clearTextColor: true,
                clearItemId: true,
              );
          await mirrorLocalList();
        },
        onUploadOwnPhoto: () {
          // Real upload lands under PROD-1729; for now share the same
          // coming-soon SnackBar that item-page placeholders use.
          Navigator.pop(sheetContext);
          showAddPhotoComingSoonSnackBar(context);
        },
      );
    },
  ).whenComplete(() {
    // PROD-3217 — render + upload the share-cover PNG ONCE, when the user is
    // done editing (sheet dismissed), instead of on every settled swatch/
    // texture tap — a multi-edit session would otherwise fire several ~2 MB
    // uploads. Gate on a signature drift so a no-op close (cover unchanged)
    // does nothing (no wasteful upload, no share-button "Preparing cover…"
    // flicker); keyed on the canonical UUID so the render-in-progress flag
    // matches the share button's `entityId`.
    final finalList = ref.read(unifiedListProvider(listId)).list;
    if (finalList != null &&
        computeCoverRenderSignature(finalList) !=
            finalList.coverShareRenderSignature) {
      ref.read(coverShareRenderServiceProvider).scheduleRender(finalList.id);
    }
  });
}

/// Bottom sheet body. Watches [unifiedListProvider] for the live recipe
/// state so the swatch rings + the 4:5 preview repaint as soon as the
/// optimistic update lands (PROD-1918). All controls are tap-to-apply —
/// PROD-1918 batch 4 dropped the pending "Confirm" pattern for the
/// items grid; selection state now lives entirely in the provider.
class ChangeCoverSheet extends ConsumerStatefulWidget {
  /// The list whose cover we're editing. Used to scope the
  /// [unifiedListProvider] watch and to seed the initial pending-pick
  /// item id from the live recipe.
  final String listId;

  /// Fired when a Soko colour swatch is tapped. Applies immediately
  /// (no separate confirm).
  final ValueChanged<ZineCoverColor> onPickColor;

  /// Fired when a texture thumbnail is tapped. Applies immediately.
  final ValueChanged<String> onPickTexture;

  /// Fired when a title-colour swatch is tapped. Applies immediately.
  final ValueChanged<ZineCoverTextColor> onPickTextColor;

  /// Fired when the user taps an item image — applies immediately
  /// (PROD-1918 batch 4 — no more pending Confirm).
  final ValueChanged<String> onPickItemId;

  /// Fired when the user taps the "Sem imagem" / "No image" tile in
  /// the items grid. Reverts the cover to `background_color` mode and
  /// clears the `cover_item_id` reference, preserving the
  /// colour / texture / text-colour choices (PROD-1918 batch 4 —
  /// dedicated "no image" affordance so users can undo an item-image
  /// pick without the broader "Reset to default" sweep).
  final VoidCallback onClearItemImage;

  /// Resets the recipe back to FE-determined defaults (clears
  /// cover_color / cover_texture / cover_text_color / cover_item_id,
  /// returns cover_type to background_color).
  final VoidCallback onResetToDefault;

  final VoidCallback onUploadOwnPhoto;

  const ChangeCoverSheet({
    super.key,
    required this.listId,
    required this.onPickColor,
    required this.onPickTexture,
    required this.onPickTextColor,
    required this.onPickItemId,
    required this.onClearItemImage,
    required this.onResetToDefault,
    required this.onUploadOwnPhoto,
  });

  @override
  ConsumerState<ChangeCoverSheet> createState() => _ChangeCoverSheetState();
}

class _ChangeCoverSheetState extends ConsumerState<ChangeCoverSheet> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = Lt.of(context);
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final secondaryTextColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    // Live recipe state — watched so every swatch ring + the preview
    // repaints the instant the optimistic update lands (PROD-1918).
    final listState = ref.watch(unifiedListProvider(widget.listId));
    final currentColor = ZineCoverColor.fromWire(listState.list?.coverColor);
    final currentTexture = listState.list?.coverTexture;
    final currentTextColor =
        ZineCoverTextColor.fromWire(listState.list?.coverTextColor) ??
        kZineDefaultTextColor;
    final currentItemId = listState.list?.coverItemId;
    final itemsWithImages = listState.filteredItems
        .where((item) => item.imageUrl != null && item.imageUrl!.isNotEmpty)
        .toList();
    final previewRecipe = resolveZineCoverRecipe(listState);
    final previewTitle = listState.list?.name ?? '';

    // PROD-1913: DS chrome — replaces the legacy DraggableScrollableSheet
    // + manual drag handle + manual maxHeightFraction math. The sheet
    // caps at 92 % of viewport via DSSheetShell; the items grid below
    // gets its own scroll region inside `Expanded`.
    return DSSheetShell(
      header: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            l10n.zineCoverTitle,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ),
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Live 4:5 cover preview (PROD-1918). Sits right under the
          // title so the user sees their choices apply without
          // dragging the sheet down. Tiny (80 × 100) — meant for
          // glanceable feedback, not as a hero.
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 80,
                  height: 100,
                  child: ListZineCover(
                    recipe: previewRecipe,
                    title: previewTitle,
                  ),
                ),
              ),
            ),
          ),

          // Background-colour swatches (PROD-1908). Tap-to-apply, no
          // separate confirm — the change persists immediately and
          // the sheet stays open so the user can iterate.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.listCoverBackgroundColor,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: secondaryTextColor,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                for (final c in kZineColors)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _ColorSwatch(
                      color: c.flutterColor,
                      selected: currentColor == c,
                      // Same-colour constraint (PROD-1918 batch 4) — block
                      // picking a bg colour that matches the EFFECTIVE
                      // title colour. `previewRecipe.textColor` is the
                      // resolved value (default kZineDefaultTextColor when
                      // unset), so the constraint holds even before the
                      // user has explicitly chosen a title colour.
                      onTap: c.wire == previewRecipe.textColor.wire
                          ? null
                          : () => widget.onPickColor(c),
                    ),
                  ),
              ],
            ),
          ),

          // Title-colour swatches (PROD-1918). 8 swatches — 6 brand
          // colours plus ink + paper — applied immediately. Horizontal
          // ListView (not a fixed Row) so the row stays scrollable at
          // narrow widths and accommodates future palette additions.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.zineCoverTitleColor,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: secondaryTextColor,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final tc in ZineCoverTextColor.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Center(
                      child: _ColorSwatch(
                        color: tc.flutterColor,
                        selected: currentTextColor == tc,
                        // Ring contrast: ink-on-ink would disappear, so
                        // ring the ink swatch in paper instead.
                        selectedRingColor: tc == ZineCoverTextColor.ink
                            ? AppColors.sokoPaper
                            : AppColors.sokoInk,
                        // Same-colour constraint (PROD-1918 batch 4) —
                        // block picking a title colour that matches the
                        // effective bg colour. The 6 brand-colour enum
                        // names overlap (e.g. `blue`) so wire-string
                        // equality is the join; ink/paper never match
                        // any bg (the bg row doesn't include them).
                        onTap: tc.wire == previewRecipe.color.wire
                            ? null
                            : () => widget.onPickTextColor(tc),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Texture picker (PROD-1908). Gated on having more than one
          // texture in the catalog — until then the section is a
          // single-item row, which reads as noise.
          if (kZineTextureCatalog.length > 1) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.listCoverTexture,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: secondaryTextColor,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final entry in kZineTextureCatalog.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _TextureSwatch(
                        textureId: entry.key,
                        assetPath: entry.value,
                        selected: currentTexture == entry.key,
                        backgroundColor:
                            currentColor?.flutterColor ?? AppColors.sokoPaper,
                        onTap: () => widget.onPickTexture(entry.key),
                      ),
                    ),
                ],
              ),
            ),
          ],

          // Upload-your-photo row (always visible — coming-soon for now)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: Icon(LucideIcons.image_plus, color: primaryColor),
              title: Text(
                l10n.listCoverUploadOwnPhoto,
                style: TextStyle(color: textColor),
              ),
              onTap: widget.onUploadOwnPhoto,
            ),
          ),

          // Reset-to-default — clears all recipe overrides so the
          // cover falls back to the deterministic FE picks.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              leading: Icon(Icons.refresh, color: secondaryTextColor),
              title: Text(
                l10n.listCoverResetToDefault,
                style: TextStyle(color: textColor),
              ),
              onTap: () {
                Navigator.pop(context);
                widget.onResetToDefault();
              },
            ),
          ),

          // Items grid OR empty-state
          if (itemsWithImages.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.listCoverEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: secondaryTextColor, fontSize: 14),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.listCoverChooseFromItems,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: secondaryTextColor,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  // 4:5 portrait per D110 — matches the ratio the
                  // chosen item-image paints at when used as a cover,
                  // so the picker preview = the resolved cover crop.
                  childAspectRatio: 4 / 5,
                ),
                // +1 for the leading "Sem imagem" tile (PROD-1918 batch 4).
                itemCount: itemsWithImages.length + 1,
                itemBuilder: (_, index) {
                  // Index 0 = "Sem imagem" tile: revert to background-
                  // colour mode while preserving the rest of the recipe.
                  if (index == 0) {
                    final noImageSelected = !previewRecipe.hasPhoto;
                    return _NoImageTile(
                      label: l10n.zineCoverNoImage,
                      selected: noImageSelected,
                      primaryColor: primaryColor,
                      secondaryTextColor: secondaryTextColor,
                      onTap: noImageSelected ? null : widget.onClearItemImage,
                    );
                  }
                  final item = itemsWithImages[index - 1];
                  // PROD-1918 batch 4 — selection state lives in the
                  // provider; tap immediately applies the cover (no
                  // pending Confirm). The watched `currentItemId`
                  // drives the ring + check-badge.
                  final isSelected =
                      currentItemId == item.id &&
                      listState.list?.coverType == ZineCoverType.itemImage.wire;
                  return GestureDetector(
                    onTap: () => widget.onPickItemId(item.id),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: isSelected
                            ? Border.all(color: primaryColor, width: 3)
                            : null,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(isSelected ? 5 : 8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CachedImage(
                              imageUrl: item.imageUrl!,
                              fit: BoxFit.cover,
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 4,
                                ),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black54,
                                    ],
                                  ),
                                ),
                                child: Text(
                                  item.title ?? '',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: Container(
                                  width: 24,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: primaryColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Leading 1:1 tile in the items grid that toggles the cover into
/// background-colour mode and clears `cover_item_id` (PROD-1918 batch
/// 4). Selected when no cover photo is currently rendered — i.e. the
/// effective recipe is solid-colour. `onTap: null` when already
/// selected (no-op, dimmed by `Opacity` for consistency with other
/// disabled affordances in the sheet).
class _NoImageTile extends StatelessWidget {
  final String label;
  final bool selected;
  final Color primaryColor;
  final Color secondaryTextColor;
  final VoidCallback? onTap;

  const _NoImageTile({
    required this.label,
    required this.selected,
    required this.primaryColor,
    required this.secondaryTextColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.sokoInk.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: selected
              ? Border.all(color: primaryColor, width: 3)
              : Border.all(
                  color: AppColors.sokoInk.withValues(alpha: 0.12),
                  width: 1,
                ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(selected ? 5 : 8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    LucideIcons.image_off,
                    size: 24,
                    color: secondaryTextColor,
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: secondaryTextColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (selected)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: primaryColor,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Texture preview thumbnail — square tile that shows the texture
/// overlaid on the current cover colour so the user previews what the
/// applied texture will look like in context. Selected state is a Soko
/// Ink ring identical to the colour swatch.
class _TextureSwatch extends StatelessWidget {
  final String textureId;
  final String assetPath;
  final bool selected;
  final Color backgroundColor;
  final VoidCallback? onTap;

  const _TextureSwatch({
    required this.textureId,
    required this.assetPath,
    required this.selected,
    required this.backgroundColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: selected
              ? Border.all(color: AppColors.sokoInk, width: 2)
              : Border.all(
                  color: AppColors.sokoInk.withValues(alpha: 0.12),
                  width: 1,
                ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: backgroundColor),
            Image.asset(assetPath, fit: BoxFit.cover),
          ],
        ),
      ),
    );
  }
}

/// Small circular Soko-colour swatch used by both the Background-colour
/// and Title-colour sections. Selected state is conveyed by a 2px ring
/// around the swatch; the ring colour defaults to Soko Ink but can be
/// overridden via [selectedRingColor] when the swatch itself is Soko
/// Ink (PROD-1918 title-colour picker — ink-on-ink would disappear).
class _ColorSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final Color? selectedRingColor;
  final VoidCallback? onTap;

  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.selectedRingColor,
  });

  @override
  Widget build(BuildContext context) {
    final Color ringColor = selectedRingColor ?? AppColors.sokoInk;
    // Disabled state — `onTap: null` means the parent is blocking this
    // swatch (e.g. the same-colour constraint between bg and title rows,
    // PROD-1918 batch 4). Render dimmed so the user reads it as
    // unavailable, not just unresponsive.
    final bool enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.3,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: selected
                ? Border.all(color: ringColor, width: 2)
                : Border.all(
                    color: AppColors.sokoInk.withValues(alpha: 0.12),
                    width: 1,
                  ),
          ),
        ),
      ),
    );
  }
}
