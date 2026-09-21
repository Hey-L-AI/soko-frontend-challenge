import 'package:flutter/material.dart';

import '../../../../shared/notifications/heyl_notification.dart';
import '../../../../shared/notifications/notification_state.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../data/models/models.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/providers.dart';
import '../../../../shared/navigation/detail_siblings.dart';
import '../../../../shared/widgets/dotted_section_divider.dart';
import '../../../moderation/content_blocked_handler.dart';
import '../../providers/unified_list_provider.dart';
import '../../utils/list_calendar_map_helpers.dart';
import '../../utils/unsave_cascade.dart';
import '../add_to_list_sheet.dart';
import '../cascade_unsave_confirm_dialog.dart';
import '../list_description.dart';
import '../list_edit_cover_row.dart';
import '../list_page_calendar_block.dart';
import '../list_page_map_block.dart';
import 'list_view_item_row.dart';
import 'list_view_section.dart';
import 'zine_item_sort_menu.dart';

/// Edit-mode body for the redesigned list page — owner-only, list-view-locked.
/// Renders the cover row, inline-editable description, then a flat
/// [ReorderableListView] of every item with drag handles + delete buttons +
/// auto-expanded note editors. Section grouping is dropped in this view —
/// mirrors the legacy "Editar elementos" experience, which also reorders the
/// full ordered set rather than per-section.
///
/// PROD-1977 split: read-mode rendering moved to the top-level
/// [buildListViewModeBodySlivers] helper so the list page can opt in to
/// the shell's viewport-culling sliver host. Edit mode stays a regular
/// `Column`-shaped widget — `ReorderableListView` doesn't have a sliver
/// counterpart we want to take on right now, and edit mode is a
/// short-lived, owner-only branch where the eager-build cost is fine.
class ListViewModeBody extends ConsumerWidget {
  final String listId;
  final UnifiedListState state;

  const ListViewModeBody({
    super.key,
    required this.listId,
    required this.state,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    assert(
      state.editMode && state.isOwner,
      'ListViewModeBody is the edit-mode body. Call buildListViewModeBodySlivers '
      'for read-mode rendering.',
    );
    return _buildEditMode(context, ref);
  }

  /// PROD-3873 — an owner removal cascades: the item leaves every list they
  /// hold it in, not just this one. Disclose the blast radius before deleting.
  /// Looks up the affected lists via `contains_*`, and only prompts when the
  /// cascade reaches beyond this single list. On confirm (or when there's
  /// nothing extra to disclose), performs the removal.
  Future<void> _confirmAndRemove(
    BuildContext context,
    WidgetRef ref,
    UnifiedListNotifier notifier,
    UserListItem item,
  ) async {
    // #2521 — a removal cascades ONLY when this list is an auto-filed save list
    // (Saved Items / My Places / My Events). Deleting from a zine removes just
    // this row and leaves the save standing, so never prompt. When it does
    // cascade, disclose the curated zines it will also clear.
    final list = state.list;
    final cascades = list != null && listRemovalCascades(list);
    if (cascades) {
      final curatedNames = await _affectedCuratedListNames(ref, item);
      if (!context.mounted) return;
      if (curatedNames.isNotEmpty) {
        final confirmed = await showCascadeUnsaveConfirmDialog(
          context,
          listNames: curatedNames,
        );
        if (!confirmed) return;
      }
    }
    await notifier.removeItem(item.id);
  }

  /// Names of the caller's own CURATED lists (zines) holding this item — the
  /// cascade blast radius we disclose. Auto-managed lists are excluded (implied,
  /// never hand-filed). Empty on lookup failure (degrade to a plain removal).
  Future<List<String>> _affectedCuratedListNames(
    WidgetRef ref,
    UserListItem item,
  ) async {
    try {
      final response = await ref
          .read(listsApiProvider)
          .listMyLists(
            containsEventId: item.eventId,
            containsVenueId: item.eventId != null ? null : item.venueId,
            containsGooglePlaceId:
                (item.eventId != null || item.venueId != null)
                ? null
                : item.googlePlaceId,
            limit: 100,
          );
      return response.items
          .where((l) => l.isOwner && !l.isSystemManaged)
          .map((l) => l.name)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Widget _buildEditMode(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(unifiedListProvider(listId).notifier);
    final list = state.list;
    final items = state.items;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: ListEditCoverRow(listId: listId),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: ListDescription(
              description: list?.description,
              editable: true,
              onCommit: (text) async {
                try {
                  final ok = await notifier.commitListUpdate(description: text);
                  if (!ok && context.mounted) {
                    showSoko(
                      ref,
                      message: Lt.of(context).errorUnknown,
                      variant: SokoVariant.error,
                    );
                  }
                } catch (e) {
                  if (!context.mounted) return;
                  // PROD-2264 — wordlist filter rejection. The
                  // optimistic update has already been rolled back by
                  // [commitListUpdate]; surface the backend message.
                  if (!handleContentBlocked(
                    ref,
                    context,
                    e,
                    field: ContentBlockedField.listDescription,
                  )) {
                    showSoko(
                      ref,
                      message: Lt.of(context).errorUnknown,
                      variant: SokoVariant.error,
                    );
                  }
                }
              },
            ),
          ),
          const SizedBox(height: 20),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 15),
              child: SizedBox(height: 0),
            )
          else
            ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: items.length,
              onReorder: (oldIndex, newIndex) =>
                  notifier.reorderItems(oldIndex, newIndex),
              proxyDecorator: (child, index, animation) {
                return Material(
                  color: Colors.transparent,
                  elevation: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.sokoInk.withValues(alpha: 0.06),
                      border: Border.all(color: AppColors.sokoInk, width: 1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: child,
                    ),
                  ),
                );
              },
              itemBuilder: (context, index) {
                final item = items[index];
                return Padding(
                  key: ValueKey('list-view-row-edit-${item.id}'),
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ListViewItemRow(
                    item: item,
                    editMode: true,
                    isOwner: state.isOwner,
                    listId: listId,
                    leadingDragHandle: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(
                        LucideIcons.grip_vertical,
                        size: 18,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    onRemove: () {
                      _confirmAndRemove(context, ref, notifier, item);
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// PROD-1977: read-mode sliver builder for the list-page List view.
/// Emits the section + map + calendar + suggestions blocks as slivers so
/// off-screen rows are not built — the actual viewport-culling unlock
/// for long lists (the PROD-1967 trigger 355-item list).
///
/// Composition (top → bottom): description? → Sítios → Eventos → Map
/// (500 px) → Calendar → (owner-only) Sugerido para ti, separated by
/// [DottedSectionDivider] slivers. Each block is conditionally rendered
/// based on item content; trailing dividers are suppressed when nothing
/// follows.
///
/// Returns the empty list when the list has no content AND no
/// description so the caller can decide what to fall back to (the page
/// shows an empty-state hero for owners, or nothing for non-owners — §
/// 9.2 #19 of the design doc).
/// Which type section leads the read-mode list body.
///
/// Places lead by default (the Figma owner frame's order). An event-ordered
/// sort flips them — see [ZineItemSort.ordersByEventDate] for why.
List<SavedItemType> listSectionOrder(ZineItemSort? sort) =>
    (sort?.ordersByEventDate ?? false)
    ? const [SavedItemType.event, SavedItemType.place]
    : const [SavedItemType.place, SavedItemType.event];

List<Widget> buildListViewModeBodySlivers(
  BuildContext context,
  WidgetRef ref, {
  required String listId,
  required UnifiedListState state,
}) {
  final l10n = Lt.of(context);
  final items = state.items;
  final places = items.where((i) => i.itemType == SavedItemType.place).toList();
  final events = items.where((i) => i.itemType == SavedItemType.event).toList();
  // PROD-1967 — cover map reads from the server-deduped `state.mapPins`
  // (one pin per unique venue across the whole list) instead of
  // FE-deduping over `state.items`. Pins arrive before the background
  // tail finishes so the map is complete immediately.
  final mapPinItems = state.mapPins
      .map((p) => slimMapPinToHeavy(p, listId))
      .toList();
  final hasMap = mapPinItems.isNotEmpty;
  final calendarMonth = autoPickMonthFromItems(events);
  final hasCalendar = calendarMonth != null;

  // PROD-1979: guests get a blurred-rows treatment + sign-in CTA via
  // [ListViewSection]'s widget shape (which owns `GuestListGateOverlay`).
  // That shape isn't a sliver — wrap it in a single `SliverToBoxAdapter`.
  // Loses per-row culling for guests, but guests see ≤ ⌈N/3⌉ unblurred
  // rows by design so the eager-build cost is bounded. Authenticated
  // users still go through `buildListViewSectionSlivers` for real
  // `SliverList.builder` culling on long lists (PROD-1977's win).
  final isGuest = !ref.watch(isAuthenticatedProvider);

  // Build the ordered list of block-sliver lists. Each entry is a
  // `List<Widget>` of slivers contributing one block. Interleaved with
  // 20-px gap slivers + section dividers to match the Figma owner frame
  // (`6197:5954`)'s `gap-[20px]` column rhythm.
  final blocks = <List<Widget>>[];

  // The sort chip rides the FIRST rendered section's header rather than owning
  // a row above it — see [ListViewSection.trailing]. Guests never get it: the
  // gated body shows a fixed unblurred prefix, so resorting would only shuffle
  // which rows they are teased with.
  var sortChipPlaced = isGuest;

  void addSection(String title, List<UserListItem> sectionItems) {
    if (sectionItems.isEmpty) return;
    final trailing = sortChipPlaced ? null : ZineItemSortMenu(listId: listId);
    sortChipPlaced = true;
    if (isGuest) {
      blocks.add([
        SliverToBoxAdapter(
          child: ListViewSection(
            title: title,
            items: sectionItems,
            listId: listId,
            onItemTap: (item) =>
                _openItemDetail(context, ref, listId, state, item),
            onItemBookmarkTap: (item) => _openAddToList(context, ref, item),
          ),
        ),
      ]);
    } else {
      blocks.add(
        buildListViewSectionSlivers(
          title: title,
          items: sectionItems,
          listId: listId,
          onItemTap: (item) =>
              _openItemDetail(context, ref, listId, state, item),
          onItemBookmarkTap: (item) => _openAddToList(context, ref, item),
          trailing: trailing,
        ),
      );
    }
  }

  for (final type in listSectionOrder(state.sort)) {
    switch (type) {
      case SavedItemType.place:
        addSection(l10n.listSectionPlaces, places);
      case SavedItemType.event:
        addSection(l10n.listSectionEvents, events);
    }
  }

  if (hasMap) {
    blocks.add([
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: ListPageMapBlock(items: mapPinItems),
        ),
      ),
    ]);
  }

  if (hasCalendar) {
    blocks.add([
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: ListPageCalendarBlock(
            items: items,
            // Auto-pick the month with the closest events to today (§ 6
            // calendar logic — also used by the Zine view).
            currentMonth: calendarMonth,
            // Match the zine cover's tinted container so the calendar
            // looks identical across both view modes.
            tinted: true,
          ),
        ),
      ),
    ]);
  }

  // ListSuggestionsSection removed (PROD-2004 final) — the owner-only
  // "Suggestions" block sat here. Feature disabled while the search
  // pipeline's Google-fallback parsing is sorted out.

  final description = state.list?.description;
  final hasDescription = description != null && description.trim().isNotEmpty;

  if (blocks.isEmpty && !hasDescription) {
    return const <Widget>[];
  }

  final slivers = <Widget>[];

  // Outer top padding so the first block breathes below the header
  // (matches the `EdgeInsets.symmetric(vertical: 20)` outer padding that
  // wrapped the legacy Column).
  slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 20)));

  if (hasDescription) {
    slivers.add(
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          child: ListDescription(description: description),
        ),
      ),
    );
    if (blocks.isNotEmpty) {
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 20)));
    }
  }

  for (var i = 0; i < blocks.length; i++) {
    if (i > 0) {
      // Section divider + 20-px rhythm between blocks.
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 15),
            child: DottedSectionDivider(),
          ),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 20)));
    }
    slivers.addAll(blocks[i]);
  }

  // Outer bottom padding so the last block doesn't hug the bottom edge.
  slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 20)));

  return slivers;
}

void _openItemDetail(
  BuildContext context,
  WidgetRef ref,
  String listId,
  UnifiedListState state,
  UserListItem item,
) {
  _trackItemClick(ref, state, listId, item);
  // Match the zine view's "Vê mais" target (PROD-1738) — push the
  // in-list detail card route, which mounts `ListInContextDetailScreen`.
  final id = item.itemType == SavedItemType.event ? item.eventId : item.venueId;
  if (id == null || id.isEmpty) return;
  final path = item.itemType == SavedItemType.event
      ? '/lists/$listId/events/$id'
      : '/lists/$listId/venues/$id';
  context.push(path, extra: _buildListSiblings(state, listId, item));
}

/// Siblings = every item in this list that has a navigable detail id.
/// Mixes places + events so the user can swipe across sections; the
/// section split is a visual grouping, not a navigation boundary.
DetailSiblings _buildListSiblings(
  UnifiedListState state,
  String listId,
  UserListItem tapped,
) {
  final filtered = <DetailSibling>[];
  int? mappedIndex;
  for (final i in state.items) {
    final id = i.itemType == SavedItemType.event ? i.eventId : i.venueId;
    if (id == null || id.isEmpty) continue;
    if (i.id == tapped.id) mappedIndex = filtered.length;
    filtered.add(
      DetailSibling(
        type: i.itemType == SavedItemType.event
            ? DetailSiblingType.event
            : DetailSiblingType.place,
        id: id,
      ),
    );
  }
  return DetailSiblings(
    items: filtered,
    currentIndex: mappedIndex ?? 0,
    listId: listId,
  );
}

Future<void> _openAddToList(
  BuildContext context,
  WidgetRef ref,
  UserListItem item,
) async {
  final suggestion = ItemSuggestion(
    id: item.venueId ?? item.eventId ?? item.id,
    type: item.itemType == SavedItemType.event ? 'event' : 'place',
    eventId: item.eventId,
    venueId: item.venueId,
    googlePlaceId: item.googlePlaceId,
    name: item.title ?? '',
    imageUrl: item.imageUrl,
    category: item.category,
    address: item.address,
    city: item.city,
    latitude: item.latitude,
    longitude: item.longitude,
    // PROD-3829: forward the facet so a re-save from this surface keeps it.
    primaryFacet: item.primaryFacet,
  );
  await showAddToListSheet(
    context,
    suggestion,
    ref: ref,
    source: ListSource.listUi,
    // PROD-3873 — quicksave on tap, half-open peek on a fresh save.
    quickSaveIfUnsaved: true,
    skipDrawerWhenSaving: true,
  );
}

void _trackItemClick(
  WidgetRef ref,
  UnifiedListState state,
  String listId,
  UserListItem item,
) {
  try {
    final itemType = item.itemType == SavedItemType.event ? 'event' : 'place';
    ref
        .read(unifiedAnalyticsProvider)
        .trackListItemClick(
          listId: state.list?.id ?? listId,
          itemType: itemType,
          eventId: item.eventId,
          venueId: item.venueId,
          listName: state.list?.name,
          itemName: item.title,
        );
  } catch (e) {
    debugPrint('Analytics: trackListItemClick failed - $e');
  }
}
