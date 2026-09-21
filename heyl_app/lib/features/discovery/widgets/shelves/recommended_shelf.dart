import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/utils/auth_gating.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../lists/utils/zine_cover_recipe.dart';
import '../../../lists/widgets/guest_blur_cta_card.dart';
import '../../providers/recommended_shelf_provider.dart';
import '../../screens/shelf_see_more_screen.dart';
import '../../utils/attribution_prefix.dart';
import 'canonical_shelf_card.dart';
import 'discovery_shelf.dart';
import 'shelf_see_more_tile.dart';

/// "Recommended" shelf (PT-PT: "Recomendado") — Soko's public lists by
/// handle (PROD-1516). Hides when the configured handle is missing or
/// returns no items.
///
/// PROD-1979 — for guests, the cards row renders behind a **super-
/// soft σ≈1.5 blur** with a centered [GuestBlurCtaCard]. Recommended
/// is public curation, so the cover art is part of the discovery
/// value — the blur signals "not fully unlocked" without obscuring
/// the lists. Authenticated users see the row without any overlay.
class RecommendedShelf extends ConsumerWidget {
  final bool guestMode;

  const RecommendedShelf({super.key, this.guestMode = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final asyncLists = ref.watch(recommendedShelfProvider);
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
      shelfId: 'recommended',
      title: l10n.discoveryShelfRecommendedTitle,
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
      onRetry: () => ref.invalidate(recommendedShelfProvider),
      // Title + chevron open the same see-more page as the trailing tile.
      onSeeMore: showSeeMore
          ? () {
              analytics.trackDiscoveryShelfSeeMoreClicked(
                shelfId: 'recommended',
              );
              context.push(SeeMoreShelf.recommended.routePath);
            }
          : null,
      trailingTileBuilder: showSeeMore
          ? (context, cellWidth, rowHeight, imageHeight) => ShelfSeeMoreTile(
              cellWidth: cellWidth,
              rowHeight: rowHeight,
              imageHeight: imageHeight,
              onTap: () {
                analytics.trackDiscoveryShelfSeeMoreClicked(
                  shelfId: 'recommended',
                );
                context.push(SeeMoreShelf.recommended.routePath);
              },
            )
          : null,
      guestOverlay: guestMode
          ? GuestBlurCtaCard(
              onSignIn: () => navigateToLoginPreservingReturn(
                context,
                ref,
                referrer: AuthReferrer.guestGateHome,
              ),
            )
          : null,
      overlayBlurSigma: 1.5,
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
              shelfId: 'recommended',
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
