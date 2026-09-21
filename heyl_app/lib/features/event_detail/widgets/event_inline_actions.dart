import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/user_list.dart';
import '../../lists/providers/unified_list_provider.dart';
import '../../lists/widgets/list_item_note.dart';
import '../providers/event_detail_provider.dart';

/// Note surface for event pages. Reads the tip, list-element id and
/// ownership **live** from [unifiedListProvider] (keyed by the in-list
/// `effectiveListId`) rather than from a frozen snapshot, so it survives
/// the cold-deep-load race where the parent list's items arrive after the
/// detail future resolves — and so it can render the owner's note
/// read-only to non-owners. Delegates all four states (no tip + can edit,
/// no tip + read-only, has tip + read-only, has tip + edit) to the shared
/// [ListItemNote] widget; mirrors `VenueInlineActions`.
///
/// The 40 px circular Save button used to live next to "Deixar nota"
/// (Figma `6181:5701`); it moved up next to the event name (intentional
/// divergence) so it stays visible on every entry point — see the
/// `_NameAndTagBlock` doc comment in `event_detail_screen.dart`.
class EventInlineActions extends ConsumerWidget {
  final EventDetailSnapshot snapshot;

  const EventInlineActions({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listId = snapshot.effectiveListId;
    if (listId == null) return const SizedBox.shrink();

    final listState = ref.watch(unifiedListProvider(listId));
    // Match the list element for this event; null while items are still
    // loading (the widget rebuilds when they arrive) or when the event
    // isn't part of the list.
    UserListItem? match;
    for (final it in listState.items) {
      if (it.eventId == snapshot.event.id) {
        match = it;
        break;
      }
    }
    if (match == null) return const SizedBox.shrink();

    // [ListItemNote] renders nothing in the "no tip + read-only" state (a
    // non-owner viewing a curator's list where this item has no note). Bail
    // out entirely so the section's 30 px top gap doesn't leave a phantom band
    // above the details grid.
    final canEdit = listState.isOwner; // owner edits; non-owner sees read-only
    final hasTip = (match.tip ?? '').trim().isNotEmpty;
    if (!canEdit && !hasTip) return const SizedBox.shrink();

    return Padding(
      // The section owns its own top gap (was a sibling SizedBox in the body).
      padding: const EdgeInsets.only(top: 30),
      child: ListItemNote(
        listId: listId,
        listElementId: match.id,
        tip: match.tip,
        canEdit: canEdit,
        itemName: snapshot.event.title,
      ),
    );
  }
}
