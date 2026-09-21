// PROD-2018 follow-up — single source of truth for the "open this
// list-item's detail page" navigation rule.
//
// Three callers previously each had their own near-duplicate inline
// implementation: the calendar agenda row, the hub calendar's
// per-day agenda, and the map pin tooltip's "View details" button.
// They all share the same shape (`/lists/<listId>/<entity>/<id>` when
// the item belongs to a real list, standalone otherwise) so we
// collapse the duplication here and have everyone call this helper.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/models.dart';
import '../services/unified_analytics_service.dart';

/// Push the event/venue detail screen for [item], scoped to its parent
/// list when one is available. Routes match `app_router.dart`:
///
///   * in-list event → `/lists/<listId>/events/<id>`
///   * in-list venue → `/lists/<listId>/venues/<id>`
///   * standalone    → `/events/<id>` or `/venues/<id>`
///
/// [scopedListIdOverride] lets a calling surface force the list-scoped
/// route even when [UserListItem.listId] is empty — e.g. a synthesised
/// item rendered inside a known list. Passes through unchanged when
/// null.
///
/// Fires `trackListItemClick` best-effort; analytics failures never
/// block navigation. Returns silently when the item lacks an entity id
/// (defensive — shouldn't happen for real list items).
void openItemDetail(
  BuildContext context,
  WidgetRef ref,
  UserListItem item, {
  String? scopedListIdOverride,
}) {
  final isEvent = item.itemType == SavedItemType.event;
  final id = isEvent ? item.eventId : item.venueId;
  if (id == null || id.isEmpty) return;

  final listId = scopedListIdOverride ?? item.listId;
  final path = listId.isEmpty
      ? (isEvent ? '/events/$id' : '/venues/$id')
      : (isEvent ? '/lists/$listId/events/$id' : '/lists/$listId/venues/$id');

  _trackBestEffort(ref, item);
  context.push(path);
}

void _trackBestEffort(WidgetRef ref, UserListItem item) {
  try {
    ref
        .read(unifiedAnalyticsProvider)
        .trackListItemClick(
          listId: item.listId,
          itemType: item.itemType == SavedItemType.event ? 'event' : 'place',
          eventId: item.eventId,
          venueId: item.venueId,
          itemName: item.title,
        );
  } catch (_) {
    // Analytics is best-effort — never block navigation on failure.
  }
}
