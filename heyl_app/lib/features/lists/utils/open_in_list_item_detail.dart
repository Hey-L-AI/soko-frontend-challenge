import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models/models.dart';
import '../../../providers/detail_seed_provider.dart';
import '../../../shared/navigation/detail_siblings.dart';
import '../../../shared/widgets/hero_image_warmup.dart';

/// Pushes the in-list venue/event detail route for [tapped] and attaches
/// a [DetailSiblings] payload built from [allItems] so the detail screen
/// can enable horizontal-swipe prev/next.
///
/// Used by both the zine-item-page "Ver mais" button and the cover-map
/// pin tooltip — both flows must land on the same destination so a pin
/// tap from the cover skips the zine pager middle step.
///
/// No-op when [tapped] resolves to an empty venue/event id (e.g. an
/// ad-hoc place not linked to a backend venue). Caller is responsible
/// for ensuring [tapped] is the full heavy item — slim map-pin items
/// don't carry `eventId` and would silently no-op for events.
void openInListItemDetail(
  BuildContext context, {
  required WidgetRef ref,
  required String listId,
  required UserListItem tapped,
  required List<UserListItem> allItems,
}) {
  final isEvent = tapped.itemType == SavedItemType.event;
  final id = isEvent ? tapped.eventId : tapped.venueId;
  if (id == null || id.isEmpty) return;

  final path = isEvent
      ? '/lists/$listId/events/$id'
      : '/lists/$listId/venues/$id';

  // PROD-4XXX: seed the detail shell from the tapped item so the destination
  // paints hero + title + chips instantly instead of a full-page spinner.
  ref.cacheDetailSeed(DetailSeed.fromUserListItem(tapped));

  // Warm the poster into the image cache so the shared-element Hero flight
  // (zine card poster → detail collage tile) glides the real photo instead of
  // the brand-floor placeholder on a cold cache. Fire-and-forget.
  warmHeroImage(context, tapped.imageUrl);

  context.push(path, extra: _buildSiblings(tapped, allItems, listId));
}

DetailSiblings? _buildSiblings(
  UserListItem tapped,
  List<UserListItem> allItems,
  String listId,
) {
  final filtered = <DetailSibling>[];
  int? mappedIndex;
  for (final i in allItems) {
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
