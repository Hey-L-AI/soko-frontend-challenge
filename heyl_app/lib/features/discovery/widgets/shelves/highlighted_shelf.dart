import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../data/models/models.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../lists/utils/zine_cover_recipe.dart';
import '../../providers/highlighted_shelf_provider.dart';
import '../../utils/attribution_prefix.dart';
import 'highlighted_shelf_card.dart';
import 'shelf_divider.dart';

/// "Highlighted" shelf (PT-PT: "Em destaque") at the top of the Discovery
/// Page (PROD-1554 → PROD-1986).
///
/// Differs from every other shelf:
///   - 2 cards in a fixed Row (not horizontal scroll).
///   - No "Ver mais" — intentional deviation from Figma per ticket.
///   - 0/1/2 cards depending on backend availability; hidden when empty.
///
/// Cards are a marketing-curated, ordered selection (BE returns up to 10;
/// the provider slices to 2). All cards render with owner attribution —
/// no per-card badge.
///
/// Visual chrome uses the forked [HighlightedShelfCard] (195 × 242 image
/// per Figma `d4BCnyUHe2705J7ecQtaIH` node `6144:5096`) — taller and wider
/// than the canonical 160.418 × 213 used by the other shelves.
class HighlightedShelf extends ConsumerWidget {
  const HighlightedShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final asyncCards = ref.watch(highlightedShelfProvider);
    final analytics = ref.read(unifiedAnalyticsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;

    // valueOrNull (not .value) — .value rethrows on AsyncError, which would
    // bypass the explicit `hasError` branch below and surface as an
    // ErrorWidget when the BE call fails.
    final cards = asyncCards.valueOrNull ?? const <HighlightedCard>[];

    // Hide entirely when loaded-and-empty: the BE returns `cards: []` when
    // no qualifying list exists in the city. Skip rendering rather than
    // showing a 0-card frame.
    if (!asyncCards.isLoading && cards.isEmpty) {
      return const SizedBox.shrink();
    }

    if (asyncCards.hasError) {
      // Errors hide the shelf — see-more / retry on a 2-card fixed shelf
      // would surface awkwardly. Other shelves render below either way.
      return const SizedBox.shrink();
    }

    // Fire shelf-viewed once per session via the shared analytics dedup.
    if (!asyncCards.isLoading && cards.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        analytics.trackDiscoveryShelfViewed(shelfId: 'highlighted');
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Leading dotted divider — owned by the shelf so it collapses with
        // the shelf on empty/error states.
        const ShelfDivider(),
        Text(
          l10n.discoveryShelfHighlightedTitle,
          style: AppTheme.displayPrimary(
            fontSize: 42,
            fontWeight: FontWeight.w300,
            color: inkColor,
            height: 0.94,
          ),
        ),
        const SizedBox(height: 16),
        if (asyncCards.isLoading)
          const _HighlightedSkeleton()
        else
          _HighlightedRow(
            cards: cards,
            onCardTap: (index, card) {
              analytics.trackDiscoveryShelfCardClicked(
                shelfId: 'highlighted',
                cardIndex: index,
                itemId: card.list.id,
                itemType: 'list',
              );
              context.push(
                '/lists/${card.list.urlIdentifier}',
                extra: const {'referrer': '/'},
              );
            },
          ),
      ],
    );
  }
}

class _HighlightedRow extends StatelessWidget {
  final List<HighlightedCard> cards;
  final void Function(int index, HighlightedCard card) onCardTap;

  const _HighlightedRow({required this.cards, required this.onCardTap});

  /// Inter-card horizontal gap.
  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two cards always fill the row, regardless of viewport. On
        // narrow phones cards shrink proportionally; on wider viewports
        // they grow above the design width. The shell-level cap
        // (`DiscoveryShell` constrains content to 480 px above 1024
        // px) provides the actual upper bound — capping here would
        // leave 30–60 px of right-side slack on 600–1023 px viewports.
        // Clamp to >= 0 — when the parent gives this LayoutBuilder a
        // maxWidth below `_gap` (transient layout passes during
        // DiscoveryShell rebuilds, narrow viewports, off-screen
        // measurements), `(maxWidth - _gap) / 2` underflows and the
        // downstream `SizedBox(width: cardWidth)` trips
        // `BoxConstraints has a negative minimum width`.
        final cardWidth = constraints.hasBoundedWidth
            ? ((constraints.maxWidth - _gap) / 2).clamp(0.0, double.infinity)
            : HighlightedShelfCard.imageWidth;

        final children = <Widget>[];
        for (var i = 0; i < cards.length; i++) {
          if (i > 0) children.add(const SizedBox(width: _gap));
          children.add(
            SizedBox(
              width: cardWidth,
              child: _HighlightedCardCell(
                card: cards[i],
                onTap: () => onCardTap(i, cards[i]),
              ),
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }
}

class _HighlightedCardCell extends StatelessWidget {
  final HighlightedCard card;
  final VoidCallback onTap;
  const _HighlightedCardCell({required this.card, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final list = card.list;
    final ownerName = list.ownerName ?? list.ownerHandle;
    final attribution = ownerName != null && ownerName.isNotEmpty
        ? '${attributionPrefixFor(l10n, list.ownerHandle)}$ownerName'
        : l10n.discoveryShelfYoursAttribution;
    return HighlightedShelfCard(
      coverRecipe: ZineCoverRecipe.fromUserList(list),
      name: list.name,
      subtitle: list.description,
      attribution: attribution,
      attributionAvatarUrl: list.ownerAvatarUrl,
      attributionAvatarName: ownerName ?? list.ownerHandle,
      attributionAvatarSeed: list.ownerId,
      onTap: onTap,
    );
  }
}

class _HighlightedSkeleton extends StatelessWidget {
  const _HighlightedSkeleton();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.surfaceDark : AppColors.sokoShade5;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth - 10) / 2
            : HighlightedShelfCard.imageWidth;
        final cardHeight =
            cardWidth *
            HighlightedShelfCard.totalHeight /
            HighlightedShelfCard.imageWidth;
        Widget cell() => Container(
          width: cardWidth,
          height: cardHeight,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(5),
          ),
        );
        return Row(children: [cell(), const SizedBox(width: 10), cell()]);
      },
    );
  }
}
