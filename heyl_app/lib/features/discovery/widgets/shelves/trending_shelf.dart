import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../lists/utils/zine_cover_recipe.dart';
import '../../providers/most_followed_shelf_provider.dart';
import '../../screens/shelf_see_more_screen.dart';
import '../../utils/attribution_prefix.dart';
import '../discovery_shell.dart';
import 'canonical_shelf_card.dart';
import 'discovery_shelf.dart';
import 'shelf_see_more_tile.dart';

/// "Most followed" shelf (PT-PT: "Mais seguidas") — the homepage row of
/// the top 50 public lists ranked by **all-time save count**
/// (`sort=popular`, PROD-2416). The shelf is a fixed top-50 window with
/// no infinite scroll. The fetch result is cached for a few hours
/// (PROD-3242 — `/lists/public` is the backend's most expensive query)
/// and each return to the homepage reshuffles the cached lists locally
/// so the row doesn't look static between visits.
///
/// Visual variant: same 160×213 chrome as the canonical card, but DROPS the
/// subtitle line. Attribution shows the real curator name (not the
/// "Edt. por ti" placeholder used on Yours). Per the figma spec, that's the
/// only divergence from the canonical layout.
class TrendingShelf extends ConsumerStatefulWidget {
  const TrendingShelf({super.key});

  @override
  ConsumerState<TrendingShelf> createState() => _TrendingShelfState();
}

class _TrendingShelfState extends ConsumerState<TrendingShelf> {
  /// Tracks whether the homepage was the topmost route last time the nav
  /// observer fired, so we only react to the false→true transition (a
  /// genuine "returned to the homepage" event) and not to every notify.
  late bool _wasOnDiscovery;

  @override
  void initState() {
    super.initState();
    _wasOnDiscovery = discoveryNavObserver.isOnDiscovery;
    discoveryNavObserver.addListener(_onNavChange);
  }

  @override
  void dispose() {
    discoveryNavObserver.removeListener(_onNavChange);
    super.dispose();
  }

  /// PROD-2416 — reorder the shelf when the user navigates back to the
  /// homepage from a pushed detail page. [discoveryNavObserver] notifies
  /// on any top-route change; we fire only on the transition INTO
  /// Discovery (`isOnDiscovery` flips false→true). The notifier reshuffles
  /// its cached top-50 locally and only refetches once the cache TTL
  /// expires (PROD-3242 — the per-return refetch was a major driver of
  /// backend `/lists/public` load).
  void _onNavChange() {
    final onDiscovery = discoveryNavObserver.isOnDiscovery;
    if (onDiscovery && !_wasOnDiscovery && mounted) {
      ref.read(mostFollowedShelfProvider.notifier).onReturnToHomepage();
    }
    _wasOnDiscovery = onDiscovery;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final state = ref.watch(mostFollowedShelfProvider);
    final notifier = ref.read(mostFollowedShelfProvider.notifier);

    final analytics = ref.read(unifiedAnalyticsProvider);
    // The shelf renders at most 10 of the top-50 window; the rest lives
    // on the vertical see-more page behind the trailing tile.
    final visibleCount = state.items.length > kDiscoveryShelfMaxVisibleItems
        ? kDiscoveryShelfMaxVisibleItems
        : state.items.length;
    final showSeeMore = state.items.length > kDiscoveryShelfMaxVisibleItems;
    return DiscoveryShelf(
      shelfId: 'trending',
      title: l10n.discoveryShelfTrendingTitle,
      isLoading: state.isInitialLoading,
      error: state.error,
      itemCount: visibleCount,
      cardWidth: CanonicalShelfCard.imageWidth,
      // PROD-1961: Trending cards never render a subtitle — shrink the
      // row height to content so the dotted divider sits tight against
      // the attribution line instead of below empty cell space.
      cardHeight: CanonicalShelfCard.totalHeightNoSubtitle,
      visibleCardsHint: 2.5,
      cardHeightForWidth: CanonicalShelfCard.heightForWidthNoSubtitle,
      // PROD-2606 — placeholder cover sizes from width, not row height.
      cardImageHeightForWidth: CanonicalShelfCard.imageHeightForWidth,
      onRetry: notifier.refresh,
      // PROD-2416: fixed top-50 window — no infinite scroll (paging
      // params left at their non-paged defaults). The see-more page
      // shows the full window.
      // Title + chevron open the same see-more page as the trailing tile.
      onSeeMore: showSeeMore
          ? () {
              analytics.trackDiscoveryShelfSeeMoreClicked(shelfId: 'trending');
              context.push(SeeMoreShelf.trending.routePath);
            }
          : null,
      trailingTileBuilder: showSeeMore
          ? (context, cellWidth, rowHeight, imageHeight) => ShelfSeeMoreTile(
              cellWidth: cellWidth,
              rowHeight: rowHeight,
              imageHeight: imageHeight,
              onTap: () {
                analytics.trackDiscoveryShelfSeeMoreClicked(
                  shelfId: 'trending',
                );
                context.push(SeeMoreShelf.trending.routePath);
              },
            )
          : null,
      itemBuilder: (context, index) {
        final list = state.items[index];
        final ownerName = list.ownerName ?? list.ownerHandle ?? 'Soko';
        return CanonicalShelfCard(
          coverRecipe: ZineCoverRecipe.fromUserList(list),
          name: list.name,
          // Subtitle intentionally dropped — Trending variant is 2-line.
          subtitle: null,
          attribution:
              '${attributionPrefixFor(l10n, list.ownerHandle)}$ownerName',
          ownerIsExpert: list.ownerIsExpert,
          attributionAvatarUrl: list.ownerAvatarUrl,
          // No-photo curators fall back to an initial dot in their seeded
          // colour (same tint as their avatar everywhere else).
          attributionAvatarName: ownerName,
          attributionAvatarSeed: list.ownerId,
          indexInShelf: index,
          onTap: () {
            analytics.trackDiscoveryShelfCardClicked(
              shelfId: 'trending',
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
