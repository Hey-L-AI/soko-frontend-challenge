import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/clickable.dart';
import '../../../../shared/widgets/thin_chevron.dart';
import 'shelf_divider.dart';

/// Section scaffold for a Discovery Page shelf: stacked H1 title + a
/// horizontally-scrolling row of cards with shared loading / empty / error
/// slots.
///
/// The scaffold is generic over an item count + builder so each shelf forks
/// its own card widget while reusing the snap, padding, and async-state
/// plumbing. Card width must be uniform within a shelf — pass it via
/// [cardWidth] so the gap math (10px between cards per Figma) can be applied
/// consistently. The widget knows nothing about specific shelves.
///
/// Spec source: `docs/ui/figma-cache/screens/discovery/shelves.md`.
///   - Title: 42px, Season Mix TRIAL Light (weight 300), color
///     `AppColors.sokoInk` (`#3B0F18`).
///   - Title-to-row gap: 16px (Figma `6144:5092`) — overridable.
///   - Inter-card gap: 10px.
///   - Edge-bleed: cards start flush at `left: 0` of the section so the row
///     overflows past the right edge.
///   - Inter-shelf rhythm is owned by [ShelfDivider] sandwiched between
///     consecutive shelves on the screen, so the scaffold no longer adds
///     bottom padding of its own.
/// Maximum cards a Discovery shelf renders horizontally. Shelves with more
/// content than this show the trailing "Ver mais" tile
/// ([DiscoveryShelf.trailingTileBuilder]) which opens the shelf's vertical
/// see-more page instead of paginating in place.
const int kDiscoveryShelfMaxVisibleItems = 10;

class DiscoveryShelf extends ConsumerWidget {
  /// Stable analytics id (e.g. `'tuas'`, `'perto_de_ti'`). Used to fire
  /// `discovery_shelf_viewed` once per session via the unified analytics
  /// service's built-in dedup.
  final String shelfId;

  final String title;

  /// Total number of cards to render. Null while loading.
  final int? itemCount;

  /// Whether the shelf is in its initial-loading state. When true, the
  /// scaffold renders skeleton placeholders instead of cards.
  final bool isLoading;

  /// Error from the last refresh, if any. When set, the scaffold renders an
  /// inline retry surface and ignores [itemCount].
  final Object? error;

  /// Builder for individual cards. Called for indices `0..itemCount-1`.
  final IndexedWidgetBuilder itemBuilder;

  /// Builder for skeleton cards. Called for indices `0..3` by default.
  final IndexedWidgetBuilder skeletonBuilder;

  /// Optional builder for a trailing tile rendered after the last item —
  /// the "Ver mais" arrow card that opens the shelf's vertical see-more
  /// page. A builder (not a plain widget) because the tile mirrors the
  /// neighbouring cards' proportions, and the effective cell dimensions
  /// are only known once the shelf resolves its viewport scaling. The
  /// tile is only rendered on the data path — never during loading or
  /// error states.
  final Widget Function(
    BuildContext context,
    double cellWidth,
    double rowHeight,
    double? imageHeight,
  )?
  trailingTileBuilder;

  /// Builder for the empty state. Returning a non-null widget renders it in
  /// place of the card row (e.g. "Cria a tua primeira lista" CTA on Tuas).
  /// Returning null hides the entire shelf when empty.
  final Widget? Function(BuildContext context)? emptyBuilder;

  /// Builder for the error state. The shelf invokes [onRetry] when the user
  /// taps the retry surface; pass null to hide the shelf entirely on error.
  final VoidCallback? onRetry;

  /// Card height at the **design** width (i.e. when the viewport is wide
  /// enough that no scaling kicks in). Drives the row height when
  /// [visibleCardsHint] is null. Skeleton + error retry surfaces also key
  /// off this when the shelf is rendering at design dimensions.
  final double cardHeight;

  /// Card width at the design width. Acts as the cap when the shelf is
  /// scaling to fit a fractional card count.
  final double cardWidth;

  /// Horizontal gap between cards.
  final double cardGap;

  /// Gap between the section title and the row of cards.
  // TODO(figma-pixel-perfect): per-shelf titleGap audit — Em destaque
  // (`6144:5092`) confirms 16, but Guias da cidade (`6144:5193`) specs 20.
  // Other shelf frames not audited; pass `titleGap:` per shelf if Figma
  // diverges from the 16 default.
  final double titleGap;

  /// When non-null, the shelf scales each card so this fractional count
  /// fits within the viewport (e.g. `2.5` for the canonical shelves,
  /// `3.5` for "Perto de ti") — a half card peeks at the right to signal
  /// scrollability. Cards never grow beyond their design [cardWidth];
  /// when the viewport is wide enough that the formula would yield a
  /// width ≥ [cardWidth], cards stay at design dimensions and the row
  /// simply has free space on the right.
  ///
  /// Pair with [cardHeightForWidth] so the row reserves the right
  /// vertical space for the scaled image plus the (fixed) text block.
  /// When null, [cardWidth] / [cardHeight] are used as-is (used by
  /// `HighlightedShelf` and other shelves that want fixed dimensions).
  final double? visibleCardsHint;

  /// Maps a card's effective width + the OS text-scale factor to its total
  /// height. Required when [visibleCardsHint] is set. Pass the card class's
  /// `heightForWidth(double, [double])` static (e.g.
  /// `CanonicalShelfCard.heightForWidth`). The second arg lets the card grow
  /// its reserved text block with the OS font size so scaled labels don't
  /// overflow the fixed row height (PROD-2875).
  final double Function(double cardWidth, double textScale)? cardHeightForWidth;

  /// Maps a card's effective width to the height of just its **image /
  /// cover** placeholder. When set, the loading skeleton and the load-more
  /// loader tiles size their image block from this (mirroring the real
  /// card's width-driven cover) instead of guessing a fixed fraction of the
  /// row height — which over-/under-shoots whenever the row height is
  /// inflated for an absent subtitle, the image scales with width, or the
  /// card's aspect differs from the canonical card (PROD-2606). Pass the
  /// card class's `imageHeightForWidth(double)` static (e.g.
  /// `CanonicalShelfCard.imageHeightForWidth`). Falls back to the legacy
  /// fraction when null.
  final double Function(double cardWidth)? cardImageHeightForWidth;

  /// PROD-1979 — when set, this widget renders centered on top of the
  /// cards row. The title + leading divider stay sharp so the user can
  /// still scan the shelf they're missing. Pass a [GuestBlurCtaCard]
  /// (or any compact CTA) sized to fit roughly half-shelf width. Taps
  /// on the underlying cards are blocked by [IgnorePointer]; only
  /// widgets inside [guestOverlay] are interactive.
  ///
  /// Pair with [overlayBlurSigma] to tune how heavily the underlying
  /// cards are blurred behind this overlay.
  final Widget? guestOverlay;

  /// PROD-1979 — Gaussian blur sigma applied to the cards row when
  /// [guestOverlay] is set. Default σ=4 matches the Yours / Daily Drop
  /// guest pattern (cards readable as silhouettes). Pass a smaller
  /// value (e.g. σ≈1.5) for surfaces where the cover art itself is
  /// part of the discovery value — Recommended shelf uses 1.5 so
  /// guests can still recognise the curated lists. Ignored when
  /// [guestOverlay] is null.
  final double overlayBlurSigma;

  /// PROD-2026 — optional replacement for the default `Text(title, ...)`
  /// rendered at the top of the shelf. When non-null, the scaffold renders
  /// this widget in place of the title slot, leaving every other shelf
  /// (rhythm, divider, card row) unchanged. Used by the Yours page to
  /// substitute an animated `Yours / Following` toggle for the static H1.
  /// [title] is still required for analytics + accessibility fallbacks.
  final Widget? titleOverride;

  /// Optional compact action rendered on the trailing (right) edge of the
  /// title line, opposite the title. When set, the title + this widget
  /// share a Row (title left in an [Expanded], action right); when null the
  /// bare title renders exactly as before. Used by the near-you shelves for
  /// the "show hidden items" toggle.
  final Widget? titleTrailing;

  /// When set (a shelf with a see-more page), the default text title becomes
  /// a tap target and grows a trailing chevron — tapping either the title or
  /// the arrow opens the shelf's see-more page. Same navigation the trailing
  /// "Ver mais" tile fires; pass the identical closure so both entry points
  /// stay in sync. Ignored when [titleOverride] is set (the Yours/Following
  /// toggle is its own interactive widget and has no see-more page).
  final VoidCallback? onSeeMore;

  /// PROD-2026 — whether the leading [ShelfDivider] (the row of dots
  /// that separates consecutive shelves on the Discovery page) renders
  /// above the title. Defaults to `true` so multi-shelf surfaces keep
  /// the inter-shelf rhythm. The Yours hub flips this to `false`
  /// because the page-level scallop divider already sits right above
  /// the shelf and a second dotted line in between reads as noise.
  final bool showLeadingDivider;

  /// PROD-2091 — pagination support. All optional and default-off so
  /// non-paged shelves are unaffected. When [onLoadMore] is non-null the
  /// shelf swaps its stateless row for a [_PagedHorizontalRow] that
  /// watches scroll position and fires [onLoadMore] near the right edge.
  /// A half-card trailing loader / retry tile renders between the last
  /// data card and [trailingTile] based on these flags.
  final bool hasMore;
  final bool isLoadingMore;
  final Object? loadMoreError;

  /// Latch key for the paged row's auto-fire. Pass the provider's
  /// `nextOffset` — the row releases its "already fired" latch whenever
  /// this value changes, so one `onLoadMore` call lands per page
  /// boundary, not per scroll event.
  final int nextOffset;
  final Future<void> Function()? onLoadMore;
  final Future<void> Function()? onRetryLoadMore;

  /// Opt-in scroll anchoring for the "show hidden" toggle. [itemIdAt] returns
  /// a stable id for the card at an index; [personalized] mirrors the shelf's
  /// current mode. When [personalized] flips (a toggle) and [itemIdAt] is
  /// non-null, the paged row captures the card at the left edge and restores
  /// the scroll so that same card stays put after the list swaps. Shelves
  /// that leave [itemIdAt] null keep the old byte-identical behaviour.
  final String Function(int index)? itemIdAt;
  final bool personalized;

  /// Outer horizontal padding applied by the parent. The shelf assumes the
  /// caller wraps it in the page-level padding — the row scrolls flush to
  /// `left: 0` of its container, and the parent handles edge insets.
  const DiscoveryShelf({
    super.key,
    required this.shelfId,
    required this.title,
    required this.itemCount,
    required this.isLoading,
    required this.error,
    required this.itemBuilder,
    required this.cardHeight,
    required this.cardWidth,
    this.skeletonBuilder = _defaultSkeletonBuilder,
    this.trailingTileBuilder,
    this.emptyBuilder,
    this.onRetry,
    this.cardGap = 10,
    this.titleGap = 16,
    this.visibleCardsHint,
    this.cardHeightForWidth,
    this.cardImageHeightForWidth,
    this.guestOverlay,
    this.overlayBlurSigma = 4.0,
    this.titleOverride,
    this.titleTrailing,
    this.onSeeMore,
    this.showLeadingDivider = true,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.loadMoreError,
    this.nextOffset = 0,
    this.onLoadMore,
    this.onRetryLoadMore,
    this.itemIdAt,
    this.personalized = true,
  }) : assert(
         visibleCardsHint == null || cardHeightForWidth != null,
         'cardHeightForWidth is required when visibleCardsHint is set',
       );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;

    // Pre-check: when the shelf has nothing to render (error with no retry,
    // or empty + null emptyBuilder) we collapse so an upstream `Column`
    // doesn't show a stale title above empty space.
    if (error != null && onRetry == null) return const SizedBox.shrink();
    if (!isLoading && itemCount == 0 && emptyBuilder == null) {
      return const SizedBox.shrink();
    }

    // Fire `discovery_shelf_viewed` once per session per shelf. The
    // analytics service dedupes via `_shelvesViewedThisSession`, so this is
    // safe to call on every successful render. Skipped when the shelf is
    // still loading or in an error state — those don't count as "viewed".
    if (!isLoading && error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(unifiedAnalyticsProvider)
            .trackDiscoveryShelfViewed(shelfId: shelfId);
      });
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Resolve the effective card dimensions for this viewport. When
        // [visibleCardsHint] is null we keep the design width/height; when
        // set we shrink-to-fit so the requested fractional count is visible.
        final effectiveCardWidth = _effectiveCardWidth(constraints.maxWidth);
        final effectiveCardHeight = _effectiveCardHeight(
          context,
          effectiveCardWidth,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Leading dotted divider — owned by the shelf so it
            // disappears with the shelf when the body collapses. The
            // Yours hub (PROD-2026) suppresses it via
            // [showLeadingDivider] because the page-level scallop
            // divider already sits right above the cards.
            if (showLeadingDivider) const ShelfDivider(),
            // Section title (Figma: 42px / Season Mix Light / lh 0.94 /
            // tracking -2%). Matches the "Tuas" canonical sample. The
            // caller may supply [titleOverride] (PROD-2026) to render a
            // custom widget (e.g. animated Yours/Following toggle) in
            // this slot; the analytics [title] string is still used by
            // the shelf-viewed event regardless. [titleTrailing], when
            // set, sits opposite the title on the right edge.
            _buildTitleLine(inkColor),
            SizedBox(height: titleGap),
            _buildBodyWithOverlay(
                  context,
                  inkColor,
                  effectiveCardWidth: effectiveCardWidth,
                  effectiveCardHeight: effectiveCardHeight,
                ) ??
                const SizedBox.shrink(),
          ],
        );
      },
    );
  }

  /// Builds the title slot. Without [titleTrailing] it returns the bare
  /// title (or [titleOverride]); with it, the title and the trailing action
  /// share a Row — title left in an [Expanded], action pinned right.
  Widget _buildTitleLine(Color inkColor) {
    final titleText = Text(
      title,
      style: AppTheme.displayPrimary(
        fontSize: 42,
        fontWeight: FontWeight.w300,
        color: inkColor,
        height: 0.94,
      ),
    );
    // With a see-more destination and the default text title, the title
    // itself opens the see-more page and grows a trailing chevron (the same
    // glyph the profile bio-memories header uses). `titleOverride` (the
    // Yours/Following toggle) keeps its own behaviour untouched.
    final Widget titleWidget;
    if (onSeeMore != null && titleOverride == null) {
      // Embed the chevron in the title's own text run as a WidgetSpan aligned
      // to the middle of the text — so it sits on the same line as the last
      // letter instead of floating against the (taller) line box.
      titleWidget = Clickable(
        onTap: onSeeMore,
        child: Text.rich(
          // Shared with the server-driven feed's bundle block (PROD-4068) —
          // the alignment and sizing rationale lives on `ThinChevron`.
          TextSpan(
            children: ThinChevron.inTitleRun(
              title: title,
              inkColor: inkColor,
            ),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.displayPrimary(
            fontSize: 42,
            fontWeight: FontWeight.w300,
            color: inkColor,
            height: 0.94,
          ),
        ),
      );
    } else {
      titleWidget = titleOverride ?? titleText;
    }
    if (titleTrailing == null) {
      // Wrap the chevron title in an Expanded (inside a Row) even without a
      // trailing action, so the `Text.rich` gets the same tight width
      // constraint as the shelves that DO have a trailing button (happening /
      // near-you). Bare, its baseline-aligned WidgetSpan chevron laid out at
      // a slightly different height — so the arrow sat right on happening but
      // off on the others. One layout path → identical alignment everywhere.
      // `titleOverride` (the Yours/Following toggle) keeps its bare layout.
      final chevronTitle = onSeeMore != null && titleOverride == null;
      return chevronTitle
          ? Row(children: [Expanded(child: titleWidget)])
          : titleWidget;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: titleWidget),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: titleTrailing!,
        ),
      ],
    );
  }

  /// PROD-1979 — wraps [_buildBody] in the guest blur + CTA overlay when
  /// [guestOverlay] is set. Localised here (rather than at the caller) so
  /// the title + divider stay sharp and only the cards row blurs.
  Widget? _buildBodyWithOverlay(
    BuildContext context,
    Color inkColor, {
    required double effectiveCardWidth,
    required double effectiveCardHeight,
  }) {
    final body = _buildBody(
      context,
      inkColor,
      effectiveCardWidth: effectiveCardWidth,
      effectiveCardHeight: effectiveCardHeight,
    );
    if (body == null) return null;
    if (guestOverlay == null) return body;
    // Underlay — body wrapped in a Gaussian blur at the caller-
    // configured sigma + pointer-blocked. Default σ=4 (Yours / Daily
    // Drop pattern). Recommended passes ~1.5 for a super-soft blur
    // that keeps the cover art recognisable.
    return Stack(
      children: [
        ClipRect(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: overlayBlurSigma,
              sigmaY: overlayBlurSigma,
            ),
            child: IgnorePointer(child: body),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: guestOverlay,
            ),
          ),
        ),
      ],
    );
  }

  /// Card width given the available row width. With a
  /// [visibleCardsHint] cards always size to fit the requested
  /// fractional count — they grow above the design [cardWidth] on
  /// wider viewports (tablet, sub-1024 desktop) and shrink below it
  /// on narrow phones. The shell-level desktop cap (`DiscoveryShell`
  /// constrains content to 480 px above 1024 px) provides the actual
  /// upper bound; capping here would leave the row partially-empty on
  /// 600–1023 px viewports and break the half-card peek the design
  /// relies on.
  double _effectiveCardWidth(double maxWidth) {
    final hint = visibleCardsHint;
    if (hint == null || !maxWidth.isFinite) return cardWidth;
    // For an `n.5` hint (2.5, 3.5) there are `n` inter-card gaps inside
    // the visible window. The half-card on the right has no trailing
    // gap of its own — it scrolls past.
    final gapsCount = hint.floor();
    // Clamp to >= 0 — a transient layout pass with `maxWidth` below the
    // total inter-card gap span underflows otherwise, and the downstream
    // `SizedBox(width: cellWidth)` trips `BoxConstraints has a negative
    // minimum width` on every card cell.
    return ((maxWidth - gapsCount * cardGap) / hint).clamp(
      0.0,
      double.infinity,
    );
  }

  double _effectiveCardHeight(BuildContext context, double effectiveCardWidth) {
    final fn = cardHeightForWidth;
    if (fn == null) return cardHeight;
    // PROD-2875: grow the card's reserved text-block height with the OS font
    // scale (already clamped app-wide to 1.3× in app.dart) so scaled card
    // labels don't overflow the fixed row height. Measured at 14px (the
    // dominant metadata line) and never below 1.0 — smaller-text users keep
    // the design height rather than getting a tighter card.
    final raw = MediaQuery.textScalerOf(context).scale(14) / 14;
    final textScale = raw < 1.0 ? 1.0 : raw;
    return fn(effectiveCardWidth, textScale);
  }

  Widget? _buildBody(
    BuildContext context,
    Color inkColor, {
    required double effectiveCardWidth,
    required double effectiveCardHeight,
  }) {
    if (error != null) {
      if (onRetry == null) return null;
      return _ErrorRetry(
        height: effectiveCardHeight,
        color: inkColor,
        onTap: onRetry!,
      );
    }
    // Image-placeholder height for the loading skeleton / load-more loader,
    // derived from the real card's width-driven cover so the placeholder
    // matches a loaded card instead of guessing a row-height fraction
    // (PROD-2606). Null when the caller didn't wire it → tiles fall back to
    // the legacy fraction.
    final skeletonImageHeight = cardImageHeightForWidth?.call(
      effectiveCardWidth,
    );
    if (isLoading || itemCount == null) {
      return _row(
        context,
        count: 3,
        // Use the height-aware default skeleton unless the caller supplied a
        // custom `skeletonBuilder` (none do today, but keep the override
        // path intact).
        builder: identical(skeletonBuilder, _defaultSkeletonBuilder)
            ? (context, _) => _SkeletonCard(imageHeight: skeletonImageHeight)
            : skeletonBuilder,
        cellWidth: effectiveCardWidth,
        rowHeight: effectiveCardHeight,
      );
    }
    if (itemCount == 0) {
      final empty = emptyBuilder?.call(context);
      return empty;
    }
    // PROD-2091 — when the caller wired `onLoadMore`, use the paged row
    // (it watches scroll position and renders a trailing loader / retry
    // tile). Otherwise keep the existing stateless row code path so
    // non-paged shelves are byte-identical to v1.
    // Materialize the trailing "Ver mais" tile here — the builder needs
    // the effective (viewport-scaled) cell dimensions, which are only
    // resolved at this point. Data path only: loading/empty/error states
    // never show it.
    final trailingTile = trailingTileBuilder?.call(
      context,
      effectiveCardWidth,
      effectiveCardHeight,
      skeletonImageHeight,
    );
    if (onLoadMore != null) {
      return _PagedHorizontalRow(
        itemCount: itemCount!,
        itemBuilder: itemBuilder,
        cellWidth: effectiveCardWidth,
        rowHeight: effectiveCardHeight,
        skeletonImageHeight: skeletonImageHeight,
        cardGap: cardGap,
        trailingTile: trailingTile,
        hasMore: hasMore,
        isLoadingMore: isLoadingMore,
        loadMoreError: loadMoreError,
        nextOffset: nextOffset,
        onLoadMore: onLoadMore!,
        onRetryLoadMore: onRetryLoadMore,
        itemIdAt: itemIdAt,
        personalized: personalized,
      );
    }
    return _row(
      context,
      count: itemCount!,
      builder: itemBuilder,
      cellWidth: effectiveCardWidth,
      rowHeight: effectiveCardHeight,
      trailingTile: trailingTile,
    );
  }

  Widget _row(
    BuildContext context, {
    required int count,
    required IndexedWidgetBuilder builder,
    required double cellWidth,
    required double rowHeight,
    Widget? trailingTile,
  }) {
    final hasTrailing = trailingTile != null;
    final totalSlots = count + (hasTrailing ? 1 : 0);
    return SizedBox(
      height: rowHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // Edge-to-edge inside the parent's horizontal padding. PROD-1522
        // figma cache: cards anchor flush at left:0 with off-screen
        // overflow on the right.
        padding: EdgeInsets.zero,
        physics: const ClampingScrollPhysics(),
        itemCount: totalSlots,
        separatorBuilder: (_, __) => SizedBox(width: cardGap),
        itemBuilder: (context, index) {
          if (trailingTile != null && index == totalSlots - 1) {
            // Trailing tiles (the "Ver mais" card) have their own
            // intrinsic dimensions — let them lay out without our cap.
            return trailingTile;
          }
          // Bound each card cell so the card's internal `LayoutBuilder`
          // picks up the scaled width and reduces the image height
          // proportionally.
          return SizedBox(width: cellWidth, child: builder(context, index));
        },
      ),
    );
  }
}

Widget _defaultSkeletonBuilder(BuildContext context, int index) {
  return const _SkeletonCard();
}

/// Generic shelf-card skeleton. Sized by the parent cell — the
/// `DiscoveryShelf._row` wrap supplies tight `cellWidth` and `rowHeight`
/// constraints derived from the (possibly scaled) effective card dims.
class _SkeletonCard extends StatelessWidget {
  /// Explicit image-placeholder height, derived by [DiscoveryShelf] from the
  /// real card's width-driven cover (PROD-2606). When null, falls back to
  /// the legacy [_imageHeightFraction] of the row height.
  final double? imageHeight;

  const _SkeletonCard({this.imageHeight});

  /// Legacy fallback: fraction of total height occupied by the image
  /// placeholder when no explicit [imageHeight] is supplied. Only an
  /// approximation — the real image scales with width while the text block
  /// is fixed-height, so this drifts whenever the row height changes
  /// (subtitle slot, scaled width). Prefer wiring
  /// `DiscoveryShelf.cardImageHeightForWidth`.
  static const double _imageHeightFraction = 0.78;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.surfaceDark : AppColors.sokoShade5;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 160.418;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 275.0;
        final resolvedImageHeight =
            imageHeight ?? (height * _imageHeightFraction);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: width,
              height: resolvedImageHeight,
              decoration: BoxDecoration(
                color: base,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            const SizedBox(height: 10),
            Container(width: width * 0.7, height: 14, color: base),
            const SizedBox(height: 6),
            Container(width: width * 0.5, height: 12, color: base),
          ],
        );
      },
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final double height;
  final Color color;
  final VoidCallback onTap;
  const _ErrorRetry({
    required this.height,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Center(
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(Icons.refresh, color: color, size: 18),
          label: Text(
            Lt.of(context).discoveryShelfErrorRetry,
            style: TextStyle(color: color, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

// PROD-2091 — image-area share of total card height. Mirrors
// `_SkeletonCard._imageHeightFraction` so the trailing loader's ghost
// proportions match the surrounding skeleton row.
const double _kLoaderImageHeightFraction = 0.78;

// PROD-2091 — half-card visual width as a fraction of the cell width.
// Matches the "half-card peek" pattern users already see when the
// canonical shelves render with `visibleCardsHint: 2.5`.
const double _kLoaderInnerWidthFraction = 0.55;

/// PROD-2091 — horizontal row used by paged shelves. Owns a
/// [ScrollController] so it can fire [onLoadMore] near the right edge,
/// renders a trailing loader / retry tile based on the flags, and uses
/// a `nextOffset` latch so the auto-fire lands once per page boundary
/// instead of once per scroll notification.
///
/// All `onLoadMore` invocations are scheduled via
/// [WidgetsBinding.addPostFrameCallback]. Calling synchronously from a
/// scroll listener would invite re-entrancy: the await on `onLoadMore`
/// can rebuild + dispose this widget mid-notification.
class _PagedHorizontalRow extends StatefulWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double cellWidth;
  final double rowHeight;

  /// Image-placeholder height for the trailing loader / retry tiles,
  /// derived from the real card cover (PROD-2606). Null → tiles fall back
  /// to the legacy [_kLoaderImageHeightFraction] of [rowHeight].
  final double? skeletonImageHeight;
  final double cardGap;
  final Widget? trailingTile;
  final bool hasMore;
  final bool isLoadingMore;
  final Object? loadMoreError;
  final int nextOffset;
  final Future<void> Function() onLoadMore;
  final Future<void> Function()? onRetryLoadMore;

  /// Opt-in scroll anchoring (see [DiscoveryShelf.itemIdAt]). Null → disabled.
  final String Function(int index)? itemIdAt;
  final bool personalized;

  const _PagedHorizontalRow({
    required this.itemCount,
    required this.itemBuilder,
    required this.cellWidth,
    required this.rowHeight,
    required this.skeletonImageHeight,
    required this.cardGap,
    required this.trailingTile,
    required this.hasMore,
    required this.isLoadingMore,
    required this.loadMoreError,
    required this.nextOffset,
    required this.onLoadMore,
    required this.onRetryLoadMore,
    this.itemIdAt,
    this.personalized = true,
  });

  @override
  State<_PagedHorizontalRow> createState() => _PagedHorizontalRowState();
}

class _PagedHorizontalRowState extends State<_PagedHorizontalRow> {
  late final ScrollController _controller;

  // Last `nextOffset` value we fired `onLoadMore` for. The auto-fire is
  // released the moment this falls behind `widget.nextOffset`, i.e. the
  // provider successfully appended a new page.
  int? _lastFiredOffset;

  // Sticky latch for the in-flight window. Prevents the scroll listener
  // and the underfilled-row post-frame check from both firing for the
  // same edge approach.
  bool _autoFireScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller.addListener(_onScroll);
    // Cover the underfilled-row case: the row may render with content
    // narrower than the viewport, so no scroll events ever fire.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeFireAutoLoad();
    });
  }

  @override
  void didUpdateWidget(covariant _PagedHorizontalRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Show-hidden toggle: the mode flipped, so the list swapped for its
    // overlapping counterpart. Anchor the scroll so the card at the left
    // edge stays put across the swap (read the OLD offset here, before the
    // new content lays out; the jump is scheduled post-frame).
    if (oldWidget.personalized != widget.personalized) {
      _anchorAcrossToggle(oldWidget);
    }
    // Re-run the edge check whenever items or pagination flags shift —
    // this is what catches the underfilled-row regime after a `loadMore`
    // appends but still falls short of the viewport width.
    if (oldWidget.itemCount != widget.itemCount ||
        oldWidget.hasMore != widget.hasMore ||
        oldWidget.isLoadingMore != widget.isLoadingMore ||
        oldWidget.loadMoreError != widget.loadMoreError ||
        oldWidget.nextOffset != widget.nextOffset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maybeFireAutoLoad();
      });
    }
  }

  /// Keep the same card under the viewport's left edge across a show-hidden
  /// toggle. Captures the anchor from the pre-swap offset + old item ids,
  /// then jumps to that card's new index once the new content is laid out.
  /// Falls back to the nearest surviving card to the anchor's left, or to
  /// offset 0 when nothing survives. No-op unless [DiscoveryShelf.itemIdAt]
  /// was supplied.
  void _anchorAcrossToggle(_PagedHorizontalRow oldWidget) {
    final oldIdAt = oldWidget.itemIdAt;
    final newIdAt = widget.itemIdAt;
    if (oldIdAt == null || newIdAt == null) return;
    if (!_controller.hasClients) return;
    final pitch = widget.cellWidth + widget.cardGap;
    if (pitch <= 0) return;
    final oldOffset = _controller.offset;
    if (oldOffset <= 0 || oldWidget.itemCount == 0) return; // at start

    final anchorIndex = (oldOffset / pitch).floor().clamp(
      0,
      oldWidget.itemCount - 1,
    );
    final within = oldOffset - anchorIndex * pitch;

    // Nearest surviving card at or before the anchor.
    String? anchorId;
    var carryWithin = within;
    for (var i = anchorIndex; i >= 0; i--) {
      if (_indexOfId(oldIdAt(i), newIdAt, widget.itemCount) >= 0) {
        anchorId = oldIdAt(i);
        if (i != anchorIndex) carryWithin = 0; // pinned a neighbour
        break;
      }
    }
    if (anchorId == null) {
      _scheduleJump(0);
      return;
    }
    final newIndex = _indexOfId(anchorId, newIdAt, widget.itemCount);
    _scheduleJump(newIndex * pitch + carryWithin);
  }

  int _indexOfId(String id, String Function(int) idAt, int count) {
    for (var i = 0; i < count; i++) {
      if (idAt(i) == id) return i;
    }
    return -1;
  }

  void _scheduleJump(double target) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      _controller.jumpTo(target.clamp(0.0, max));
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final threshold = widget.cellWidth; // ~one card ahead of the edge
    if (position.pixels >= position.maxScrollExtent - threshold) {
      _maybeFireAutoLoad();
    }
  }

  void _maybeFireAutoLoad() {
    if (!widget.hasMore) return;
    if (widget.isLoadingMore) return;
    // Don't hammer a failing endpoint — retry is explicit via the tile.
    if (widget.loadMoreError != null) return;
    // Latch: already fired for this page boundary.
    if (_lastFiredOffset == widget.nextOffset) return;
    if (_autoFireScheduled) return;
    _autoFireScheduled = true;
    final firedFor = widget.nextOffset;
    // Schedule outside the current rebuild/notification stack.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;
        // Re-check the gates — state may have moved between schedule and fire.
        if (!widget.hasMore ||
            widget.isLoadingMore ||
            widget.loadMoreError != null) {
          return;
        }
        if (_lastFiredOffset == widget.nextOffset) return;
        _lastFiredOffset = firedFor;
        await widget.onLoadMore();
      } finally {
        if (mounted) _autoFireScheduled = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasTrailingTile = widget.trailingTile != null;
    final hasTrailingPagingTile =
        widget.hasMore || widget.isLoadingMore || widget.loadMoreError != null;
    final totalSlots =
        widget.itemCount +
        (hasTrailingPagingTile ? 1 : 0) +
        (hasTrailingTile ? 1 : 0);
    return SizedBox(
      height: widget.rowHeight,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        physics: const ClampingScrollPhysics(),
        itemCount: totalSlots,
        separatorBuilder: (_, __) => SizedBox(width: widget.cardGap),
        itemBuilder: (context, index) {
          // Order: [...data, pagingTile?, trailingTile?].
          if (index < widget.itemCount) {
            return SizedBox(
              width: widget.cellWidth,
              child: widget.itemBuilder(context, index),
            );
          }
          if (hasTrailingPagingTile && index == widget.itemCount) {
            if (widget.loadMoreError != null) {
              return _TrailingLoadMoreErrorTile(
                cellWidth: widget.cellWidth,
                rowHeight: widget.rowHeight,
                imageHeight: widget.skeletonImageHeight,
                onRetry: widget.onRetryLoadMore,
              );
            }
            return _TrailingLoaderTile(
              cellWidth: widget.cellWidth,
              rowHeight: widget.rowHeight,
              imageHeight: widget.skeletonImageHeight,
            );
          }
          // Trailing tile slot.
          return widget.trailingTile!;
        },
      ),
    );
  }
}

/// PROD-2091 — half-card ghost loader that sits at the right edge of a
/// paged shelf while the next page is in flight.
///
/// The outer cell reserves the same dimensions as a normal card so
/// `ListView.separated` alignment, padding, and inter-cell gaps stay
/// consistent. The visual sits inside that cell at ~55 % of cell width,
/// preserving the existing half-card peek pattern.
class _TrailingLoaderTile extends StatelessWidget {
  final double cellWidth;
  final double rowHeight;

  /// Explicit image-placeholder height from the real card cover (PROD-2606);
  /// null falls back to the legacy fraction of [rowHeight].
  final double? imageHeight;

  const _TrailingLoaderTile({
    required this.cellWidth,
    required this.rowHeight,
    this.imageHeight,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? AppColors.surfaceDark : AppColors.sokoShade5;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final innerWidth = cellWidth * _kLoaderInnerWidthFraction;
    final resolvedImageHeight =
        imageHeight ?? rowHeight * _kLoaderImageHeightFraction;
    return SizedBox(
      width: cellWidth,
      height: rowHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: innerWidth,
                height: resolvedImageHeight,
                decoration: BoxDecoration(
                  color: baseColor,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    inkColor.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(width: innerWidth * 0.7, height: 14, color: baseColor),
          const SizedBox(height: 6),
          Container(width: innerWidth * 0.5, height: 12, color: baseColor),
        ],
      ),
    );
  }
}

/// PROD-2091 — half-card retry affordance shown when a `loadMore` call
/// failed. Auto-fire stays blocked while this is on screen; only an
/// explicit tap fires `onRetry`.
class _TrailingLoadMoreErrorTile extends StatelessWidget {
  final double cellWidth;
  final double rowHeight;

  /// Explicit image-placeholder height from the real card cover (PROD-2606);
  /// null falls back to the legacy fraction of [rowHeight].
  final double? imageHeight;
  final Future<void> Function()? onRetry;

  const _TrailingLoadMoreErrorTile({
    required this.cellWidth,
    required this.rowHeight,
    this.imageHeight,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? AppColors.surfaceDark : AppColors.sokoShade5;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final innerWidth = cellWidth * _kLoaderInnerWidthFraction;
    final resolvedImageHeight =
        imageHeight ?? rowHeight * _kLoaderImageHeightFraction;
    return SizedBox(
      width: cellWidth,
      height: rowHeight,
      child: InkWell(
        onTap: onRetry == null ? null : () => onRetry!(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: innerWidth,
              height: resolvedImageHeight,
              decoration: BoxDecoration(
                color: baseColor,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Center(
                child: Icon(
                  Icons.refresh,
                  size: 24,
                  color: inkColor.withValues(alpha: 0.6),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: innerWidth,
              child: Text(
                Lt.of(context).discoveryShelfErrorRetry,
                style: TextStyle(
                  color: inkColor.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

