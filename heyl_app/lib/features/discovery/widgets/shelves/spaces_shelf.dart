import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../data/models/models.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/entity_image_cache_provider.dart';
import '../../../../shared/widgets/soko_card_image.dart';
import '../../providers/spaces_shelf_provider.dart';
import '../../screens/shelf_see_more_screen.dart';
import 'canonical_shelf_card.dart';
import 'discovery_shelf.dart';
import 'shelf_see_more_tile.dart';

/// "Spaces" shelf (PT-PT: "Espaços") — venues with ≥ 2 active scheduled
/// events in the next 15 days, city-scoped (PROD-1553).
///
/// Visual variant: same canonical 160 × 213 chrome as Editor Picks /
/// Recommended. Subtitle line shows the venue's `primary_tag`; optional
/// 3rd line surfaces an event-count badge ("3 events in 15 days") when
/// `event_count_15d > 0`. Pagination uses the see-more tile (10 + 10).
class SpacesShelf extends ConsumerWidget {
  const SpacesShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final state = ref.watch(spacesShelfProvider);

    if (!state.hasCity && !state.isInitialLoading) {
      return const SizedBox.shrink();
    }

    final notifier = ref.read(spacesShelfProvider.notifier);
    final analytics = ref.read(unifiedAnalyticsProvider);

    // The shelf renders at most 10 cards; deeper content lives on the
    // vertical see-more page behind the trailing tile.
    final visibleCount = state.items.length > kDiscoveryShelfMaxVisibleItems
        ? kDiscoveryShelfMaxVisibleItems
        : state.items.length;
    final showSeeMore =
        state.hasMore || state.items.length > kDiscoveryShelfMaxVisibleItems;

    return DiscoveryShelf(
      shelfId: 'spaces',
      title: l10n.discoveryShelfSpacesTitle,
      isLoading: state.isInitialLoading,
      error: state.error,
      itemCount: visibleCount,
      cardWidth: CanonicalShelfCard.imageWidth,
      cardHeight: CanonicalShelfCard.totalHeight,
      visibleCardsHint: 2.5,
      cardHeightForWidth: CanonicalShelfCard.heightForWidth,
      // PROD-2606 — placeholder cover sizes from width, not row height.
      cardImageHeightForWidth: CanonicalShelfCard.imageHeightForWidth,
      onRetry: notifier.refresh,
      // Title + chevron open the same see-more page as the trailing tile.
      onSeeMore: showSeeMore
          ? () {
              analytics.trackDiscoveryShelfSeeMoreClicked(shelfId: 'spaces');
              context.push(SeeMoreShelf.spaces.routePath);
            }
          : null,
      trailingTileBuilder: showSeeMore
          ? (context, cellWidth, rowHeight, imageHeight) => ShelfSeeMoreTile(
              cellWidth: cellWidth,
              rowHeight: rowHeight,
              imageHeight: imageHeight,
              onTap: () {
                analytics.trackDiscoveryShelfSeeMoreClicked(shelfId: 'spaces');
                context.push(SeeMoreShelf.spaces.routePath);
              },
            )
          : null,
      itemBuilder: (context, index) {
        final item = state.items[index];
        // Fallback for cold-cache venues — see Near you shelf for the
        // propagation pattern (`entity_image_cache_provider.dart`).
        final cachedImage = ref.watch(
          entityImageCacheProvider,
        )[EntityKind.venue]?[item.id];
        return CanonicalShelfCard(
          imageUrl: item.imageUrl ?? cachedImage,
          seed: item.id,
          kind: SokoEntityKind.venue,
          name: item.title,
          subtitle: item.primaryTag,
          attribution: item.eventCount15d > 0
              ? l10n.discoveryShelfSpacesEventCount(item.eventCount15d)
              : '',
          onTap: () {
            analytics.trackDiscoveryShelfCardClicked(
              shelfId: 'spaces',
              cardIndex: index,
              itemId: item.id,
              itemType: 'venue',
            );
            _openVenueDetail(context, item);
          },
        );
      },
    );
  }

  void _openVenueDetail(BuildContext context, VenueWithEventsItem item) {
    // Routed full-screen venue detail page (PROD-1670). Available to
    // all viewers post-PROD-1736 (Discovery is the canonical home).
    context.push('/venues/${item.id}');
  }
}
