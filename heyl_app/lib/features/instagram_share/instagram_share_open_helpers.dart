import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/instagram_share.dart';
import '../../data/models/saved_item.dart';
import '../../data/models/user_list.dart';
import '../../providers/lists_provider.dart';
import '../lists/providers/unified_list_provider.dart';
import 'providers/instagram_share_polling_provider.dart';

/// Open the just-ingested item in its target list's context.
///
/// Resolution order:
///   1. Use [InstagramSharePollingState.targetListId] when set (the user
///      shared from inside a list / via the share sheet).
///   2. Fall back to finding the user's "From Instagram" list by name —
///      covers the chat dialog and native share-extension flows where the
///      backend auto-created the list.
///
/// On success, routes to the in-list detail page (`/lists/<listId>/{venues|events}/<id>`)
/// and dismisses the banner. We don't fall back to routing to the list, since
/// the whole point of this CTA is to put the user directly on the ingested item.
///
/// Used both by the in-app share notification "Ver" CTA (wired in
/// `NotificationHost`) and by the iOS Share Extension's deep-link handoff
/// after polling completes.
Future<void> openIngestedItem(
  BuildContext context, {
  required WidgetRef ref,
}) async {
  final state = ref.read(instagramSharePollingProvider);
  final share = state.activeShare;

  void dismiss() => ref.read(instagramSharePollingProvider.notifier).dismiss();

  if (share == null) {
    dismiss();
    return;
  }

  // Fast path: the share already carries the resolved entity id (it's the same
  // id `findMatchingItem` would re-derive), so when we already know the target
  // list we can navigate straight to the detail page — no `loadLists()`, no
  // `loadItemsQuietly()`. Removes the ~2s of on-tap network work for the common
  // share-from-list / share-sheet flow (the detail itself is pre-warmed on
  // share completion, see `NotificationHost._prewarmDetail`).
  final directListId = state.targetListId;
  if (directListId != null) {
    final directEventId =
        share.eventId ??
        (share.eventIds.isNotEmpty ? share.eventIds.first : null);
    if (directEventId != null && directEventId.isNotEmpty) {
      dismiss();
      context.push('/lists/$directListId/events/$directEventId');
      return;
    }
    final directVenueId = share.venueId;
    if (directVenueId != null && directVenueId.isNotEmpty) {
      dismiss();
      context.push('/lists/$directListId/venues/$directVenueId');
      return;
    }
  }

  // Fallback: no known target list (chat / native-share flows), or a share that
  // only carries a `listItemId` — resolve the "From Instagram" list and match
  // the ingested item inside it.
  String? listId = state.targetListId;
  if (listId == null) {
    await ref.read(listsProvider.notifier).loadLists();
    if (!context.mounted) return;
    final fallback = findInstagramList(ref.read(listsProvider).lists);
    listId = fallback?.id;
  }
  if (listId == null) {
    dismiss();
    return;
  }

  await ref.read(unifiedListProvider(listId).notifier).loadItemsQuietly();
  if (!context.mounted) return;

  final items = ref.read(unifiedListProvider(listId)).items;
  final match = findMatchingItem(items, share);
  if (match == null) {
    dismiss();
    return;
  }

  final entityId = match.itemType == SavedItemType.event
      ? match.eventId
      : match.venueId;
  if (entityId == null || entityId.isEmpty) {
    dismiss();
    return;
  }

  dismiss();
  final path = match.itemType == SavedItemType.event
      ? '/lists/$listId/events/$entityId'
      : '/lists/$listId/venues/$entityId';
  context.push(path);
}

/// Match a list item against the share's identifiers (listItemId → eventId →
/// venueId, in order of specificity).
UserListItem? findMatchingItem(List<UserListItem> items, SharedPostOut share) {
  for (final item in items) {
    if ((share.listItemId != null && item.id == share.listItemId) ||
        (share.eventId != null && item.eventId == share.eventId) ||
        (share.venueId != null && item.venueId == share.venueId)) {
      return item;
    }
  }
  return null;
}

/// Find the user's auto-managed "From Instagram" list via the backend's
/// `system_kind` field (PROD-1741). The display name is locale-dependent
/// and is *not* a reliable identifier — substring matching used to fall
/// over on translated lists, on lists the user renamed themselves, and
/// on collisions with user-created lists that happened to mention
/// "Instagram" in the title.
UserList? findInstagramList(List<UserList> lists) {
  for (final list in lists) {
    if (list.isFromInstagramShare) return list;
  }
  return null;
}
