import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/utils/event_when_formatter.dart';
import '../../../../data/models/models.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/entity_image_cache_provider.dart';
import '../../../../shared/widgets/soko_card_image.dart';
import '../../../../shared/widgets/impression_detector.dart';
import '../../providers/happening_shelf_provider.dart';
import '../../providers/near_you_context_provider.dart';
import '../../screens/shelf_see_more_screen.dart';
import 'discovery_shelf.dart';
import 'near_you_card.dart';
import 'near_you_places_shelf.dart' show nearYouDistanceLabel;
import 'shelf_see_more_tile.dart';
import 'show_hidden_button.dart';

/// "Happening" shelf (PT-PT: "A acontecer", PT-BR: "Rolando agora") —
/// proximity-ranked event cards from `/feed/near-you/events` (PROD-1963).
/// Hides itself when the user hasn't shared location. Pagination is
/// append-only via the trailing see-more tile.
///
/// Card layout (4 lines): image · title · day+time · distance · category.
/// The day+time line surfaces the next upcoming occurrence ([`item.startsAt`])
/// in a locale-aware short form — "Today, 8 PM" / "Hoje, 21h" / "Sex, 21h" /
/// "25 mai, 21h".
class HappeningShelf extends ConsumerWidget {
  const HappeningShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final state = ref.watch(happeningShelfProvider);
    final shelfContext = ref.watch(nearYouContextProvider).valueOrNull;

    // Hide entirely without location — proximity feed has nothing to
    // show. Other shelves still render above and below.
    if (!state.hasLocation && !state.isInitialLoading) {
      return const SizedBox.shrink();
    }

    final notifier = ref.read(happeningShelfProvider.notifier);
    final analytics = ref.read(unifiedAnalyticsProvider);
    final title = l10n.discoveryShelfHappeningTitle;

    // Show the toggle whenever this load hid ANY event (dropped.total). The
    // count line ("N today") shows only when the salient same-day count is
    // non-zero. Both are preserved across the toggle so the button stays put
    // while showing the raw feed.
    final showHiddenButton = state.hiddenTotal > 0;

    // The shelf renders at most 10 cards; deeper content lives on the
    // vertical see-more page behind the trailing tile.
    final visibleCount = state.items.length > kDiscoveryShelfMaxVisibleItems
        ? kDiscoveryShelfMaxVisibleItems
        : state.items.length;
    final showSeeMore =
        state.hasMore || state.items.length > kDiscoveryShelfMaxVisibleItems;

    return DiscoveryShelf(
      shelfId: 'happening',
      title: title,
      titleTrailing: showHiddenButton
          ? ShowHiddenButton(
              countLabel: state.hiddenCount > 0
                  ? l10n.discoveryHiddenTodayLabel(state.hiddenCount)
                  : null,
              active: !state.personalized,
              isLoading: state.isInitialLoading || state.isToggling,
              onTap: notifier.togglePersonalized,
            )
          : null,
      isLoading: state.isInitialLoading,
      error: state.error,
      itemCount: visibleCount,
      cardWidth: NearYouCard.imageWidth,
      cardHeight: NearYouCard.totalHeightWithWhen,
      visibleCardsHint: 3.5,
      cardHeightForWidth: NearYouCard.heightForWidthWithWhen,
      // PROD-2606 — placeholder cover sizes from width, not row height.
      cardImageHeightForWidth: NearYouCard.imageHeightForWidth,
      onRetry: notifier.refresh,
      // `onLoadMore` stays wired ONLY so the paged row keeps the
      // show-hidden scroll anchoring ([itemIdAt]); with `hasMore` left at
      // its false default the auto-pagination never fires. Deeper content
      // is reached via the trailing "Ver mais" tile instead.
      onLoadMore: notifier.loadMore,
      itemIdAt: (index) => state.items[index].id,
      personalized: state.personalized,
      // Title + chevron open the same see-more page as the trailing tile.
      onSeeMore: showSeeMore
          ? () {
              analytics.trackDiscoveryShelfSeeMoreClicked(shelfId: 'happening');
              context.push(SeeMoreShelf.happening.routePath);
            }
          : null,
      trailingTileBuilder: showSeeMore
          ? (context, cellWidth, rowHeight, imageHeight) => ShelfSeeMoreTile(
              cellWidth: cellWidth,
              rowHeight: rowHeight,
              imageHeight: imageHeight,
              onTap: () {
                analytics.trackDiscoveryShelfSeeMoreClicked(
                  shelfId: 'happening',
                );
                context.push(SeeMoreShelf.happening.routePath);
              },
            )
          : null,
      itemBuilder: (context, index) {
        final item = state.items[index];
        // Cold-cache fallback: if the feed didn't carry an image for this
        // event, use whatever the detail sheet learned for it.
        final cachedImage = ref.watch(
          entityImageCacheProvider,
        )[EntityKind.event]?[item.id];
        return ImpressionDetector(
          // From the tracker, not a literal: the detector key and the
          // tracker's dedup gate must not be able to drift apart.
          scopeId: notifier.impressionScopeId,
          itemId: item.id,
          onImpression: () =>
              notifier.recordImpression(item.id, cardIndex: index),
          child: NearYouCard(
            imageUrl: item.imageUrl ?? cachedImage,
            seed: item.id,
            kind: SokoEntityKind.event,
            name: item.title,
            when: formatEventWhen(
              context: context,
              startsAt: item.startsAt,
              timeKnown: item.timeKnown,
            ),
            area: nearYouDistanceLabel(shelfContext, item.distanceKm),
            category: item.primaryCategory,
            onTap: () {
              analytics.trackDiscoveryShelfCardClicked(
                shelfId: 'happening',
                cardIndex: index,
                itemId: item.id,
                itemType: 'event',
              );
              context.push('/events/${item.id}');
            },
          ),
        );
      },
    );
  }
}
