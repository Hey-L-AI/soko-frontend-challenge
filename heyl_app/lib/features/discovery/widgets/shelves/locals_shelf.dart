import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/services/unified_analytics_service.dart';
import '../../../../data/models/social/user_search_item.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/auth_provider.dart';
import '../../../profile/providers/people_providers.dart';
import '../../../profile/widgets/follow_suggestion_card.dart';
import '../discovery_shell.dart';
import 'discovery_shelf.dart';
import 'shelf_see_more_tile.dart';

/// "Locals" shelf — suggested people to follow (same
/// [orderedSuggestedUsersProvider] source as the find-people page), rendered as
/// a horizontal row of person cards on the Discovery home, right after the
/// "Mais seguidas" shelf. The trailing see-more tile opens the find-people
/// page, which carries the full suggestions list (the shelf's continuation).
///
/// The row shows ten of a fifty-strong window and re-draws that ten on every
/// return to the homepage, the same way "Mais seguidas" does — see
/// [_LocalsShelfState._onNavChange]. Without it the shelf was frozen: the
/// backend ranking is deterministic and its top is a wide band of ties, so
/// twelve equally-ranked people were competing for eight slots and the same
/// eight won every time.
class LocalsShelf extends ConsumerStatefulWidget {
  const LocalsShelf({super.key});

  @override
  ConsumerState<LocalsShelf> createState() => _LocalsShelfState();
}

class _LocalsShelfState extends ConsumerState<LocalsShelf> {
  /// Whether the homepage was the topmost route last time the nav observer
  /// fired, so we react only to the false→true transition and not to every
  /// notify.
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

  /// Re-draw the order when the user comes back to the homepage, mirroring
  /// `TrendingShelf._onNavChange`. Bumping the seed re-runs the weighted
  /// shuffle over the response already in memory — the fetch underneath is
  /// cached, so this costs no request. Refetching instead would cost 450–600 ms
  /// and hand back the identical ranking.
  void _onNavChange() {
    final onDiscovery = discoveryNavObserver.isOnDiscovery;
    if (onDiscovery && !_wasOnDiscovery && mounted) {
      ref.read(localsOrderSeedProvider.notifier).state++;
    }
    _wasOnDiscovery = onDiscovery;
  }

  /// The cards are [FollowSuggestionCard] — the same card the onboarding
  /// follow carousel shows — so the geometry comes from that Figma frame (118
  /// wide around an 80 avatar) rather than from the Near you / Happening
  /// portrait image the other shelves mirror. A person's card carries a follow
  /// badge over the avatar's right edge; the cell has to be wider than the
  /// avatar to leave that badge somewhere to sit.
  static final double _cardWidth = FollowSuggestionCard.widthForAvatar(
    FollowSuggestionCard.designAvatarSize,
  );

  /// 3.3 rather than the 3.5 the other shelves use: at 3.5 a phone-width
  /// viewport scales the cell to ~93 px, which drags the avatar down to ~63 and
  /// the follow badge with it, to ~31 — under the tap target it needs. 3.3
  /// keeps the card near its design size and still peeks a third of the next
  /// card, so the row still reads as scrollable.
  static const double _visibleCardsHint = 3.3;

  /// Avatar height for a cell of [width] — square, and narrower than the cell
  /// by the badge's overhang. The same derivation has to hold here and in the
  /// `cardImageHeightForWidth` handed to [DiscoveryShelf]; if the two disagree,
  /// the trailing see-more tile stops lining up with the cards.
  static double _avatarHeightForWidth(double width) =>
      FollowSuggestionCard.avatarForWidth(width);

  static double _heightForWidth(double width, [double textScale = 1.0]) =>
      _avatarHeightForWidth(width) +
      FollowSuggestionCard.textBlockHeight(textScale);

  @override
  Widget build(BuildContext context) {
    // Suggestions are viewer-relative — nothing to show a guest.
    if (!ref.watch(isAuthenticatedProvider)) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    final async = ref.watch(orderedSuggestedUsersProvider);
    final dismissed = ref.watch(dismissedSuggestionsProvider);
    final analytics = ref.read(unifiedAnalyticsProvider);

    final all = (async.valueOrNull?.items ?? const <UserSearchItem>[])
        .where((u) => !dismissed.contains(u.userId))
        .toList();
    final isLoading = async.isLoading && !async.hasValue;
    if (!isLoading && async.error == null && all.isEmpty) {
      return const SizedBox.shrink();
    }

    final visibleCount = all.length > kDiscoveryShelfMaxVisibleItems
        ? kDiscoveryShelfMaxVisibleItems
        : all.length;
    final showSeeMore = all.length > kDiscoveryShelfMaxVisibleItems;

    return DiscoveryShelf(
      shelfId: 'locals',
      title: l10n.discoveryShelfLocalsTitle,
      isLoading: isLoading,
      error: async.error,
      itemCount: visibleCount,
      cardWidth: _cardWidth,
      cardHeight: _heightForWidth(_cardWidth),
      visibleCardsHint: _visibleCardsHint,
      cardHeightForWidth: _heightForWidth,
      cardImageHeightForWidth: _avatarHeightForWidth,
      onRetry: () => ref.invalidate(suggestedUsersProvider),
      // Title + chevron open the same find-people page as the trailing tile.
      onSeeMore: showSeeMore
          ? () {
              analytics.trackDiscoveryShelfSeeMoreClicked(shelfId: 'locals');
              context.push(AppRoutes.findPeople);
            }
          : null,
      trailingTileBuilder: showSeeMore
          ? (context, cellWidth, rowHeight, imageHeight) => ShelfSeeMoreTile(
              cellWidth: cellWidth,
              rowHeight: rowHeight,
              imageHeight: imageHeight,
              onTap: () {
                analytics.trackDiscoveryShelfSeeMoreClicked(shelfId: 'locals');
                context.push(AppRoutes.findPeople);
              },
            )
          : null,
      itemBuilder: (context, index) {
        final item = all[index];
        return _LocalCard(
          item: item,
          onTap: () {
            analytics.trackDiscoveryShelfCardClicked(
              shelfId: 'locals',
              cardIndex: index,
              itemId: item.userId,
              itemType: 'user',
            );
            final handle = item.handle;
            if (handle != null && handle.isNotEmpty) {
              context.push(AppRoutes.publicProfilePath(handle));
            }
          },
        );
      },
    );
  }
}

/// One suggested person, rendered as the app's shared follow-suggestion card.
class _LocalCard extends StatelessWidget {
  final UserSearchItem item;
  final VoidCallback onTap;
  const _LocalCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => FollowSuggestionCard(
        item: item,
        analyticsSource: 'discovery_locals_shelf',
        avatarSize: _LocalsShelfState._avatarHeightForWidth(
          constraints.maxWidth,
        ),
        onTap: onTap,
      ),
    );
  }
}
