import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/event_time.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/circle_icon_button.dart';
import '../../../shared/widgets/soko_toggle_glyph.dart';
import '../../discovery/feed_v2/widgets/blocks/feed_bundle_row.dart';
import '../../library/widgets/library_item_row.dart';
import 'add_to_list_sheet.dart';

/// Row widget used by the calendar agenda to surface a saved event /
/// venue under the selected day.
///
/// **Presentation is [LibraryItemRow] — the same bundle row the Discovery
/// feed and the Library list are built from — not a layout of its own.** It
/// used to hand-roll a 54-px square thumb, two text lines and a bookmark
/// inside a bordered white card, which meant the agenda under the calendar
/// was the only place in the app where a saved event looked like that: wrong
/// thumbnail shape (no ticket perforation), wrong type scale, and a card
/// border nothing else has. This widget now owns only the behaviour — the
/// add-to-list sheet, the guest gate, the owner's edit-mode delete — and
/// hands the drawing to the shared row.
///
/// Tapping anywhere on the row opens the detail page via the caller's
/// [onTap]; the trailing bookmark wins its own hit test and saves instead.
class ListItemRow extends ConsumerWidget {
  final UserListItem item;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  /// Whether the current user owns this list (controls edit-mode delete).
  final bool isOwner;

  /// Whether in edit mode (owner only — shows Delete button).
  final bool isEditMode;

  /// Whether this item is saved in any of the user's owned lists.
  final bool isSaved;

  /// The ID of the current list being viewed (if any). Used to detect
  /// when the item is removed from the current list via bookmark sheet.
  final String? currentListId;

  /// Callback when item is removed from the current list via the
  /// add-to-list sheet.
  final void Function(UserListItem item)? onRemovedFromCurrentList;

  /// Whether the user is authenticated (if false, bookmark shows the
  /// login prompt).
  final bool isAuthenticated;

  /// Callback when a non-authenticated user taps bookmark.
  final VoidCallback? onLoginRequired;

  /// The calendar day this row is rendered under. When set, the
  /// subtitle picks the matching occurrence's time-of-day. Null on
  /// the "events without dates" projection.
  final DateTime? selectedDay;

  const ListItemRow({
    super.key,
    required this.item,
    this.onTap,
    this.onRemove,
    this.isOwner = true,
    this.isEditMode = false,
    this.isSaved = false,
    this.currentListId,
    this.onRemovedFromCurrentList,
    this.isAuthenticated = true,
    this.onLoginRequired,
    this.selectedDay,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isEvent = item.itemType == SavedItemType.event;

    return LibraryItemRow(
      title: item.title ?? l10n.listDetailItemTitleFallback,
      // Events get the tear-off-ticket well, places the plain rectangle —
      // the same two thumbs the Library rows use, so an event reads as an
      // event before the text is parsed.
      thumbnail: isEvent
          ? FeedBundleRow.eventPhotoThumb(item.imageUrl, paperGrain: false)
          : FeedBundleRow.placePhotoThumb(item.imageUrl, paperGrain: false),
      metaLines: _metaLines(l10n),
      // The agenda hangs off a day the user picked, so it is a list by
      // nature — it must not flip to grid tiles because the Library was last
      // left in grid mode.
      forceListLayout: true,
      onTap: onTap,
      trailing: _trailing(context, ref, l10n),
    );
  }

  /// Two meta lines, matching the Library's own event / place rows: when and
  /// what on the first, where on the second.
  List<List<MetaChip>> _metaLines(Lt l10n) {
    final lines = <List<MetaChip>>[];
    final first = <MetaChip>[];

    if (selectedDay != null && item.itemType == SavedItemType.event) {
      final occ = item.firstOccurrenceOnDay(selectedDay!);
      if (occ != null) {
        final t = formatOccurrenceTimeRange(occ, l10n);
        if (t != null) first.add(MetaChip(t, icon: LucideIcons.calendar));
      }
    }
    if (item.category != null && item.category!.isNotEmpty) {
      first.add(MetaChip(item.category!, icon: LucideIcons.arrow_up_right));
    }
    if (first.isNotEmpty) lines.add(first);

    final where = [
      item.address,
      item.city,
    ].firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
    if (where != null) {
      lines.add([MetaChip(where, icon: LucideIcons.map_pin)]);
    }
    return lines;
  }

  /// The owner's edit-mode delete (when shown) alongside the save bookmark.
  Widget _trailing(BuildContext context, WidgetRef ref, Lt l10n) {
    final showOwnerEditButtons = isOwner && isEditMode;
    final save = CircleIconButton(
      glyphBuilder: (hovered) =>
          SokoToggleGlyph.bookmarkChip(active: isSaved || hovered),
      background: AppColors.sokoInk8,
      iconColor: AppColors.sokoInk,
      selected: isSaved,
      semanticLabel: isSaved
          ? l10n.listActionSaveItemSaved
          : l10n.listActionSaveItem,
      onTap: () => _handleBookmarkTap(context, ref),
      popOnTap: true,
    );
    if (!showOwnerEditButtons || onRemove == null) return save;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 32,
          height: 32,
          child: IconButton(
            icon: const Icon(
              Icons.delete_outline,
              size: 16,
              color: AppColors.error,
            ),
            onPressed: onRemove,
            padding: EdgeInsets.zero,
            tooltip: l10n.listActionRemoveItem,
          ),
        ),
        save,
      ],
    );
  }

  void _handleBookmarkTap(BuildContext context, WidgetRef ref) {
    if (!isAuthenticated) {
      onLoginRequired?.call();
      return;
    }
    _showAddToListSheet(context, ref);
  }

  Future<void> _showAddToListSheet(BuildContext context, WidgetRef ref) async {
    final place = ItemSuggestion(
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
    final result = await showAddToListSheet(
      context,
      place,
      ref: ref,
      source: ListSource.listUi,
      // PROD-3873 — quicksave on tap, half-open peek on a fresh save.
      quickSaveIfUnsaved: true,
      skipDrawerWhenSaving: true,
    );

    if (result != null &&
        currentListId != null &&
        result.wasRemovedFrom(currentListId!)) {
      onRemovedFromCurrentList?.call(item);
    }
  }
}
