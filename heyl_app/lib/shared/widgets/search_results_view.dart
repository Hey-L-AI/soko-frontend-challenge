import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../features/lists/widgets/guest_blur_cta_card.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../features/discovery/widgets/sections/discovery_footer.dart';
import '../../features/discovery/widgets/shelves/highlighted_shelf_card.dart';
import '../../features/lists/utils/zine_cover_recipe.dart';
import '../../l10n/generated/l10n.dart';

/// Presentation-only shape for a single search-result card. Each surface
/// (Discovery / Lists hub) adapts its domain shapes into this so the
/// shared [SearchResultsView] doesn't have to know about any specific
/// entity types — only how to paint them.
///
/// `onTap` carries the per-surface routing (e.g. Discovery pushes
/// `/lists/<slug>` with `referrer='/'`, Lists hub pushes the same path
/// with `referrer='/lists'`). The shared view never knows about routes.
///
/// Exactly one of [imageUrl] / [coverRecipe] should be set per card.
/// Lists (zines) use the recipe so background-colour covers paint
/// correctly; event / venue cards use a raw URL. Both are nullable so
/// missing-image cards still render the placeholder chrome.
class SearchResultCard {
  /// Stable identifier for [Key] equality. Use the surface's row key
  /// (`'list_<id>'`, `'event_<id>'`, `'venue_<id>'`, …) so card-swap
  /// animations work across re-fetches.
  final String rowKey;

  /// Raw image URL for event / venue cards.
  final String? imageUrl;

  /// Zine-cover recipe — paints colour + texture + text fallbacks for
  /// list-type cards. Wins over [imageUrl] when both are set.
  final ZineCoverRecipe? coverRecipe;

  final String name;
  final String? subtitle;
  final String attribution;

  /// Curator "bolinha" for list cards — photo, or initial dot in the
  /// person's seeded colour. Event/venue cards leave these null.
  final String? attributionAvatarUrl;
  final String? attributionAvatarName;
  final String? attributionAvatarSeed;
  final VoidCallback? onTap;

  const SearchResultCard({
    required this.rowKey,
    required this.name,
    required this.attribution,
    this.attributionAvatarUrl,
    this.attributionAvatarName,
    this.attributionAvatarSeed,
    this.imageUrl,
    this.coverRecipe,
    this.subtitle,
    this.onTap,
  });
}

/// Shared search-results view — powers both `/discovery` and `/lists`
/// search surfaces. Each surface keeps its own data adapter + routing
/// next to its provider; this widget owns the presentation. Owns:
///   - loading skeleton (2-up tinted blocks)
///   - error / empty copy (centred Soko-Ink text)
///   - the 2-up paired grid of cards with orphan-row left-alignment
///     per D48
///   - the [DiscoveryFooter.doneLooking] tile + caption to close the
///     page
///
/// Each surface owns its own fetch + mapping to [SearchResultCard]s,
/// and passes the resulting [AsyncValue] to this widget. Surface-
/// specific banners (e.g. Lists hub's "not filtered" notice) plug in
/// via the optional [topBanner] slot — rendered above the grid only
/// when there's data to show.
class SearchResultsView extends ConsumerWidget {
  /// The full results pipeline status. The view branches on
  /// loading / error / data.
  final AsyncValue<List<SearchResultCard>> resultsAsync;

  /// Current trimmed query — used by the empty state for the
  /// "No results for `<query>`" copy.
  final String query;

  /// Optional banner widget rendered above the grid when there's at
  /// least one card to show. The Lists hub uses this for its
  /// "not filtered by location or date" notice; Discovery passes
  /// `null`.
  final Widget? topBanner;

  // ---- Pagination (PROD-2466 / PROD-2368) ----------------------------------
  // Optional. When [onLoadMore] is null the view is non-paginated (the Lists
  // hub) and renders exactly as before. When set, an auto-infinite-scroll
  // sentinel + loading/retry footer appear below the grid.

  /// Whether more pages exist beyond what's currently shown.
  final bool hasMore;

  /// Whether a load-more fetch is currently in flight.
  final bool isLoadingMore;

  /// Last load-more failure, if any — swaps the spinner for a retry affordance.
  final Object? loadMoreError;

  /// Fired when the bottom sentinel scrolls into view (auto-infinite-scroll).
  /// Null disables pagination entirely.
  final VoidCallback? onLoadMore;

  /// Fired when the user taps the retry affordance after a load-more failure.
  final VoidCallback? onRetryLoadMore;

  // ---- Guest gating (PROD-2221 / PROD-2369) --------------------------------
  // Optional, opt-in. When [isGuest] is true AND [onGuestSignIn] is provided,
  // the view renders the guest clamp: the first [_kGuestVisibleCount] cards
  // crisp, the remainder blurred + pointer-blocked behind a centered
  // [GuestBlurCtaCard], and NO pagination footer (guests can't page past the
  // wall). Callers that don't pass these (e.g. the Lists hub) are unaffected.

  /// Whether the viewer is an unauthenticated guest.
  final bool isGuest;

  /// Sign-in handler wired to the guest blur CTA. Null leaves the view ungated
  /// even for guests (the clamp only engages when this is non-null).
  final VoidCallback? onGuestSignIn;

  /// Replaces the default "No results for X" empty state. The discovery
  /// browse feed passes `SizedBox.shrink()` so an empty filter renders nothing
  /// rather than the misleading typed-search copy.
  final Widget? emptyState;

  const SearchResultsView({
    super.key,
    required this.resultsAsync,
    required this.query,
    this.topBanner,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.loadMoreError,
    this.onLoadMore,
    this.onRetryLoadMore,
    this.isGuest = false,
    this.onGuestSignIn,
    this.emptyState,
  });

  /// Vertical gap between paired rows. Matches Discovery's original
  /// `_rowGap` for cross-surface consistency.
  static const double _rowGap = 24;

  /// Horizontal gap between the two cards in a row.
  static const double _columnGap = 12;

  /// Guest clamp — cards shown crisp before the blur curtain falls. 6 = three
  /// paired rows in the 2-up grid; avoids a half-filled trailing row.
  static const int _kGuestVisibleCount = 6;

  /// Gaussian sigma for the blurred guest tail — unreadable cards, but the
  /// grid silhouette survives.
  static const double _kGuestBlurSigma = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return resultsAsync.when(
      loading: () => const _SearchResultsSkeleton(),
      error: (_, __) => const _SearchResultsErrorState(),
      data: (cards) {
        if (cards.isEmpty) {
          return emptyState ?? _SearchResultsEmptyState(query: query);
        }
        // Guest clamp wins over pagination: a guest gets the first N crisp +
        // a blurred, walled tail and never paginates (no sentinel/footer).
        if (isGuest && onGuestSignIn != null) {
          return _GuestClampedColumn(
            cards: cards,
            topBanner: topBanner,
            onSignIn: onGuestSignIn!,
          );
        }
        final showLoadMore =
            onLoadMore != null &&
            (hasMore || isLoadingMore || loadMoreError != null);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (topBanner != null) ...[topBanner!, const SizedBox(height: 16)],
            _SearchResultsGrid(cards: cards),
            if (showLoadMore)
              _LoadMoreFooter(
                hasMore: hasMore,
                isLoadingMore: isLoadingMore,
                hasError: loadMoreError != null,
                onVisible: onLoadMore!,
                onRetry: onRetryLoadMore,
              ),
            const DiscoveryFooter.doneLooking(),
          ],
        );
      },
    );
  }
}

class _SearchResultsGrid extends StatelessWidget {
  final List<SearchResultCard> cards;
  const _SearchResultsGrid({required this.cards});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < cards.length; i += 2) {
      final left = cards[i];
      final right = (i + 1 < cards.length) ? cards[i + 1] : null;
      children.add(
        _SearchResultsRow(
          left: left,
          right: right,
          leftIndex: i,
          rightIndex: i + 1,
        ),
      );
      if (i + 2 < cards.length) {
        children.add(const SizedBox(height: SearchResultsView._rowGap));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// Auto-infinite-scroll footer (PROD-2466 / PROD-2368). When [hasMore] and the
/// sentinel scrolls into view, [onVisible] is called to fetch the next page;
/// while loading it shows a spinner. On [hasError] it swaps to a tappable
/// retry row.
class _LoadMoreFooter extends StatelessWidget {
  final bool hasMore;
  final bool isLoadingMore;
  final bool hasError;
  final VoidCallback onVisible;
  final VoidCallback? onRetry;

  const _LoadMoreFooter({
    required this.hasMore,
    required this.isLoadingMore,
    required this.hasError,
    required this.onVisible,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;

    if (hasError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: GestureDetector(
            onTap: onRetry,
            child: Text(
              Lt.of(context).discoveryShelfErrorRetry,
              textAlign: TextAlign.center,
              style: AppTheme.body(
                fontSize: 14,
                fontWeight: FontWeight.w300,
                color: inkColor.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    }

    // Sentinel: fires when scrolled into view. The key is stable across
    // rebuilds so VisibilityDetector tracks the same element. `loadMore`
    // self-guards against re-entrancy (isLoadingMore / !hasMore), so a
    // repeated fire while a page is in flight is a no-op.
    return VisibilityDetector(
      key: const Key('discovery-search-load-more-sentinel'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction > 0 && hasMore && !isLoadingMore) {
          onVisible();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: inkColor.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

/// Guest clamp (extracted from `DefaultContentSection`, PROD-2221, so the
/// browse feed and the typed-search surface share one implementation): the
/// first [SearchResultsView._kGuestVisibleCount] cards crisp via the normal
/// grid, the remainder blurred + pointer-blocked behind a centered
/// [GuestBlurCtaCard]. No pagination footer — the wall is the end of the road.
class _GuestClampedColumn extends StatelessWidget {
  final List<SearchResultCard> cards;
  final Widget? topBanner;
  final VoidCallback onSignIn;

  const _GuestClampedColumn({
    required this.cards,
    required this.topBanner,
    required this.onSignIn,
  });

  @override
  Widget build(BuildContext context) {
    final visible = cards.take(SearchResultsView._kGuestVisibleCount).toList();
    final blurred = cards.skip(SearchResultsView._kGuestVisibleCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (topBanner != null) ...[topBanner!, const SizedBox(height: 16)],
        _SearchResultsGrid(cards: visible),
        if (blurred.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: _BlurredTail(cards: blurred, onSignIn: onSignIn),
          ),
      ],
    );
  }
}

/// The blurred, pointer-blocked tail of a guest-clamped grid, with the
/// sign-in CTA floating over the first blurred row.
class _BlurredTail extends StatelessWidget {
  final List<SearchResultCard> cards;
  final VoidCallback onSignIn;

  const _BlurredTail({required this.cards, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Underlay: the rest of the cards, blurred + pointer-blocked.
        ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: SearchResultsView._kGuestBlurSigma,
              sigmaY: SearchResultsView._kGuestBlurSigma,
            ),
            child: IgnorePointer(child: _SearchResultsGrid(cards: cards)),
          ),
        ),
        // Overlay: centered "sign in to see more" CTA. Top-aligned so it lands
        // within the first blurred row rather than the middle of a long tail.
        Positioned.fill(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 48, left: 24, right: 24),
              child: GuestBlurCtaCard(onSignIn: onSignIn),
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchResultsRow extends StatelessWidget {
  final SearchResultCard left;
  final SearchResultCard? right;
  // Global indices of left/right within the flattened result list.
  // Plumbed to [HighlightedShelfCard.indexInShelf] so the peel-overlay
  // gate guarantees index 0 or 1 (the first result row) peels.
  final int leftIndex;
  final int rightIndex;
  const _SearchResultsRow({
    required this.left,
    required this.right,
    required this.leftIndex,
    required this.rightIndex,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two cards always fill the row regardless of viewport — the
        // shell-level desktop cap bounds the upper end.
        final cardWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth - SearchResultsView._columnGap) / 2
            : HighlightedShelfCard.imageWidth;
        final orphanHeight =
            cardWidth *
            HighlightedShelfCard.totalHeight /
            HighlightedShelfCard.imageWidth;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: cardWidth,
              child: _SearchResultsCell(card: left, indexInShelf: leftIndex),
            ),
            const SizedBox(width: SearchResultsView._columnGap),
            // Orphan-row treatment matches D48: left-align, half empty.
            right == null
                ? SizedBox(width: cardWidth, height: orphanHeight)
                : SizedBox(
                    width: cardWidth,
                    child: _SearchResultsCell(
                      card: right!,
                      indexInShelf: rightIndex,
                    ),
                  ),
          ],
        );
      },
    );
  }
}

class _SearchResultsCell extends StatelessWidget {
  final SearchResultCard card;
  final int indexInShelf;
  const _SearchResultsCell({required this.card, required this.indexInShelf});

  @override
  Widget build(BuildContext context) {
    return HighlightedShelfCard(
      key: ValueKey(card.rowKey),
      coverRecipe: card.coverRecipe,
      imageUrl: card.coverRecipe == null ? card.imageUrl : null,
      name: card.name,
      subtitle: card.subtitle,
      attribution: card.attribution,
      attributionAvatarUrl: card.attributionAvatarUrl,
      attributionAvatarName: card.attributionAvatarName,
      attributionAvatarSeed: card.attributionAvatarSeed,
      onTap: card.onTap,
      indexInShelf: indexInShelf,
    );
  }
}

// ---------------------------------------------------------------------------
// State widgets (loading / error / empty).
// ---------------------------------------------------------------------------

class _SearchResultsSkeleton extends StatelessWidget {
  const _SearchResultsSkeleton();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.surfaceDark : AppColors.sokoShade5;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth - SearchResultsView._columnGap) / 2
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
        Widget row() => Row(
          children: [
            cell(),
            const SizedBox(width: SearchResultsView._columnGap),
            cell(),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(),
            const SizedBox(height: SearchResultsView._rowGap),
            row(),
            const SizedBox(height: SearchResultsView._rowGap),
            row(),
          ],
        );
      },
    );
  }
}

class _SearchResultsEmptyState extends StatelessWidget {
  final String query;
  const _SearchResultsEmptyState({required this.query});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(
          query.isEmpty
              ? l10n.searchNoResults
              : l10n.discoverySearchNoResults(query),
          textAlign: TextAlign.center,
          style: AppTheme.body(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: inkColor.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _SearchResultsErrorState extends StatelessWidget {
  const _SearchResultsErrorState();

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(
          l10n.discoverySearchError,
          textAlign: TextAlign.center,
          style: AppTheme.body(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: inkColor.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}
