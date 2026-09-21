import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../discovery/widgets/shelves/canonical_shelf_card.dart';
import '../../lists/utils/zine_cover_recipe.dart';
import '../providers/venue_detail_provider.dart';

/// "Aparece em" — public lists containing this venue. Manual horizontal
/// scroll row of [CanonicalShelfCard] (subtitle: null, Trending-style
/// 2-line variant) sized to fit 4.5 cards across the content width
/// (intentional Figma divergence per design doc § 4.2).
///
/// We can't reuse [DiscoveryShelf] here because its built-in title style
/// is Mobile/H1 (42 px) and Figma cache `6144:4229` calls for an 18 px
/// Mobile/B1 Bold header. The card-sizing math is identical to the
/// shelf scaffold and stays here as a small inline helper.
///
/// Owner attribution is empty in v1: `ListSummary` from `getVenueDetail`
/// doesn't yet carry an owner block (soft-blocked on Backend #1). When the
/// backend extends the schema, [CanonicalShelfCard] picks up the
/// attribution automatically.
class VenueAppearsInShelf extends ConsumerWidget {
  final VenueDetailSnapshot snapshot;

  /// Visible card count target. Half-card peek on the right signals
  /// scrollability. Matches design doc § 4.2.
  static const double _visibleCardsHint = 4.5;
  static const double _cardGap = 10;

  const VenueAppearsInShelf({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = snapshot.venue.socialProof.lists;
    if (lists.isEmpty) return const SizedBox.shrink();

    final analytics = ref.read(unifiedAnalyticsProvider);
    final l10n = Lt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.venueDetailAppearsInTitle,
          style: const TextStyle(
            fontFamily: 'ZalandoSans',
            fontWeight: FontWeight.w500,
            fontSize: 18,
            height: 1.0,
            letterSpacing: -0.36,
            color: AppColors.sokoInk,
          ),
        ),
        // Title is its own top-level section in Figma `6181:5531`
        // (sibling of the cards row under a `flex-col gap-[30px]`
        // container), so the title→cards gap is a section-level 30 px.
        const SizedBox(height: 30),
        LayoutBuilder(
          builder: (ctx, constraints) {
            final maxWidth = constraints.maxWidth;
            final cardWidth = _effectiveCardWidth(maxWidth);
            final cardHeight = CanonicalShelfCard.heightForWidth(cardWidth);
            return SizedBox(
              height: cardHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: lists.length,
                separatorBuilder: (_, __) => const SizedBox(width: _cardGap),
                itemBuilder: (cellCtx, index) {
                  final list = lists[index];
                  return SizedBox(
                    width: cardWidth,
                    child: CanonicalShelfCard(
                      coverRecipe: ZineCoverRecipe.fromFields(
                        listId: list.id,
                        coverType: list.coverType,
                        coverColor: list.coverColor,
                        coverTexture: list.coverTexture,
                        coverTextColor: list.coverTextColor,
                        coverItemId: list.coverItemId,
                        coverItemImageUrl: list.coverItemImageUrl,
                        legacyCoverImageUrl: list.coverImageUrl,
                        showTitle: list.coverShowTitle,
                        showTexture: list.coverShowTexture,
                        showLogo: list.coverShowLogo,
                      ),
                      name: list.name,
                      subtitle: null,
                      attribution: '',
                      indexInShelf: index,
                      onTap: () {
                        analytics.trackDiscoveryShelfCardClicked(
                          shelfId: 'venue_detail_appears_in',
                          cardIndex: index,
                          itemId: list.id,
                          itemType: 'list',
                        );
                        cellCtx.push('/lists/${list.urlIdentifier}');
                      },
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }

  /// Mirror of [DiscoveryShelf._effectiveCardWidth] for the 4.5-card
  /// hint. Cards never grow past the design [CanonicalShelfCard.imageWidth].
  static double _effectiveCardWidth(double maxWidth) {
    if (!maxWidth.isFinite) return CanonicalShelfCard.imageWidth;
    final gapsCount = _visibleCardsHint.floor();
    final scaled = (maxWidth - gapsCount * _cardGap) / _visibleCardsHint;
    return scaled > CanonicalShelfCard.imageWidth
        ? CanonicalShelfCard.imageWidth
        : scaled;
  }
}
