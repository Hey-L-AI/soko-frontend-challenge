import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../data/models/models.dart'
    show DiscoveryForYouItem, EntityKind;
import '../../../../data/models/user_profile.dart' show UserRole;
import '../../../../providers/auth_provider.dart';
import '../../../../providers/entity_image_cache_provider.dart';
import '../../../../shared/widgets/soko_card_image.dart';
import '../../../memory/utils/memory_value_label.dart';
import '../../providers/discovery_feed_shelf_provider.dart';
import 'discovery_shelf.dart';
import 'near_you_card.dart';

/// Admin-only discovery feed shelf — one per `entity_types` (`events` /
/// `venues`). Surfaces the Discovery API's `for_you` ranking (PROD-3912) in
/// the real app with horizontal infinite scroll so admins can evaluate the
/// ranking per entity type at depth. Self-hides for non-admins (mirrors the
/// `role == UserRole.admin` gate used elsewhere on the Discovery screen).
///
/// Replaces the earlier single mixed "Discovery (for you)" shelf (PROD-3927).
class DiscoveryFeedShelf extends ConsumerWidget {
  /// `'events'` or `'venues'` — gates the whole discovery pipeline and keys
  /// the backing [discoveryFeedShelfProvider].
  final String entityTypes;

  /// Analytics shelf id (e.g. `'discovery_events'`).
  final String shelfId;

  /// H1 shown above the row. Hard-coded English — this is an admin-only
  /// evaluation surface (mirrors the retired shelf), not a shipped string.
  final String title;

  const DiscoveryFeedShelf({
    super.key,
    required this.entityTypes,
    required this.shelfId,
    required this.title,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Admin gate — everyone else never sees (nor fetches) this shelf.
    if (ref.watch(currentUserProvider)?.role != UserRole.admin) {
      return const SizedBox.shrink();
    }

    final async = ref.watch(discoveryFeedShelfProvider(entityTypes));
    final notifier = ref.read(discoveryFeedShelfProvider(entityTypes).notifier);
    final paged = async.value;
    final items = paged?.items ?? const <DiscoveryForYouItem>[];

    return DiscoveryShelf(
      shelfId: shelfId,
      title: title,
      isLoading: async.isLoading,
      error: async.hasError ? async.error : null,
      // null itemCount while the first load is in flight → skeletons.
      itemCount: paged == null ? null : items.length,
      cardWidth: NearYouCard.imageWidth,
      cardHeight: NearYouCard.totalHeight,
      visibleCardsHint: 3.5,
      cardHeightForWidth: NearYouCard.heightForWidth,
      cardImageHeightForWidth: NearYouCard.imageHeightForWidth,
      onRetry: () => ref.invalidate(discoveryFeedShelfProvider(entityTypes)),
      // Horizontal infinite-scroll pagination wiring.
      hasMore: paged?.hasMore ?? false,
      isLoadingMore: paged?.isLoadingMore ?? false,
      loadMoreError: paged?.loadMoreError,
      nextOffset: paged?.nextOffset ?? 0,
      onLoadMore: notifier.loadMore,
      onRetryLoadMore: notifier.retryLoadMore,
      itemBuilder: (context, index) {
        final item = items[index];
        final isEvent = item.isEvent;
        // Discovery returns the raw retrieval payload, which often lacks a
        // venue cover — fall back to whatever the detail sheet cached for this
        // entity (mirrors NearYouPlacesShelf).
        final cachedImage = ref.watch(
          entityImageCacheProvider,
        )[isEvent ? EntityKind.event : EntityKind.venue]?[item.id];
        // Category is a canonical taxonomy value (venue `types[0]` / event
        // category) — render the locale-aware label, not the raw slug.
        final category = item.category == null
            ? null
            : humanizeMemoryValue(
                context,
                item.category!,
                family: isEvent ? 'event_categories' : 'venue_types',
              );
        return NearYouCard(
          imageUrl: item.imageUrl ?? cachedImage,
          seed: item.id,
          kind: isEvent ? SokoEntityKind.event : SokoEntityKind.venue,
          name: item.title,
          category: category,
          onTap: () =>
              context.push('/${isEvent ? 'events' : 'venues'}/${item.id}'),
        );
      },
    );
  }
}
