import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../lists/utils/zine_cover_recipe.dart';
import '../../providers/city_guides_shelf_provider.dart';
import '../../screens/shelf_see_more_screen.dart';
import '../../utils/attribution_prefix.dart';
import 'canonical_shelf_card.dart';
import 'discovery_shelf.dart';
import 'shelf_see_more_tile.dart';

/// "City Guides" shelf — public lists flagged `city_guide=true` (PROD-1513).
/// Mirror of [EditorPicksShelf]; differs only in the BE flag consumed.
class CityGuidesShelf extends ConsumerWidget {
  const CityGuidesShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final asyncLists = ref.watch(cityGuidesShelfProvider);
    final paged = asyncLists.value;

    final analytics = ref.read(unifiedAnalyticsProvider);
    // The shelf renders at most 10 cards; deeper content lives on the
    // vertical see-more page behind the trailing tile.
    final items = paged?.items ?? const [];
    final visibleCount = items.length > kDiscoveryShelfMaxVisibleItems
        ? kDiscoveryShelfMaxVisibleItems
        : items.length;
    final showSeeMore =
        (paged?.hasMore ?? false) ||
        items.length > kDiscoveryShelfMaxVisibleItems;
    // PROD-1961: shrink the row height to match content when no card
    // actually renders a description, so the dotted divider sits tight
    // against the attribution line instead of below empty cell space.
    final hasDescriptions = (paged?.items ?? const []).any(
      (l) => (l.description ?? '').isNotEmpty,
    );
    return DiscoveryShelf(
      shelfId: 'city_guides',
      title: l10n.discoveryShelfCityGuidesTitle,
      isLoading: asyncLists.isLoading,
      error: asyncLists.hasError ? asyncLists.error : null,
      itemCount: paged == null ? null : visibleCount,
      cardWidth: CanonicalShelfCard.imageWidth,
      cardHeight: hasDescriptions
          ? CanonicalShelfCard.totalHeight
          : CanonicalShelfCard.totalHeightNoSubtitle,
      visibleCardsHint: 2.5,
      cardHeightForWidth: hasDescriptions
          ? CanonicalShelfCard.heightForWidth
          : CanonicalShelfCard.heightForWidthNoSubtitle,
      // PROD-2606 — placeholder cover sizes from width, not row height.
      cardImageHeightForWidth: CanonicalShelfCard.imageHeightForWidth,
      onRetry: () => ref.invalidate(cityGuidesShelfProvider),
      // Title + chevron open the same see-more page as the trailing tile.
      onSeeMore: showSeeMore
          ? () {
              analytics.trackDiscoveryShelfSeeMoreClicked(
                shelfId: 'city_guides',
              );
              context.push(SeeMoreShelf.cityGuides.routePath);
            }
          : null,
      trailingTileBuilder: showSeeMore
          ? (context, cellWidth, rowHeight, imageHeight) => ShelfSeeMoreTile(
              cellWidth: cellWidth,
              rowHeight: rowHeight,
              imageHeight: imageHeight,
              onTap: () {
                analytics.trackDiscoveryShelfSeeMoreClicked(
                  shelfId: 'city_guides',
                );
                context.push(SeeMoreShelf.cityGuides.routePath);
              },
            )
          : null,
      itemBuilder: (context, index) {
        final list = paged!.items[index];
        final ownerName = list.ownerName;
        return CanonicalShelfCard(
          coverRecipe: ZineCoverRecipe.fromUserList(list),
          name: list.name,
          subtitle: list.description,
          attribution: ownerName != null && ownerName.isNotEmpty
              ? '${attributionPrefixFor(l10n, list.ownerHandle)}$ownerName'
              : l10n.discoveryShelfYoursAttribution,
          attributionAvatarUrl: list.ownerAvatarUrl,
          attributionAvatarName: ownerName ?? list.ownerHandle,
          attributionAvatarSeed: list.ownerId,
          indexInShelf: index,
          onTap: () {
            analytics.trackDiscoveryShelfCardClicked(
              shelfId: 'city_guides',
              cardIndex: index,
              itemId: list.id,
              itemType: 'list',
            );
            context.push(
              '/lists/${list.urlIdentifier}',
              extra: const {'referrer': '/'},
            );
          },
        );
      },
    );
  }
}
