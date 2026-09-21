import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../data/models/chat_message.dart';
import '../../../data/models/user_list.dart';
import '../../../providers/detail_seed_provider.dart';
import '../../discovery/widgets/shelves/highlighted_shelf_card.dart';
import '../../item_detail/widgets/item_detail_sheet.dart';
import '../providers/map_grid_provider.dart';
import '../providers/map_highlight_provider.dart';
import '../providers/map_query_provider.dart';
import '../providers/map_ui_state_provider.dart';
import 'map_drawer_metrics.dart';

/// PROD-2671 / PROD-3043 — the Map page results grid.
///
/// Renders the individually-plotted pins (hydrated via [mapGridProvider]) as
/// preview cards ([HighlightedShelfCard]) in a **width-responsive** grid: the
/// column count is derived from the available width (≈one card width per
/// column) with a floor of 2, so every phone shows 2 columns and a wide desktop
/// window shows more — no hardcoded breakpoints, one card widget everywhere.
/// See [columnsFor]. The exact cell height comes from the card's own
/// [HighlightedShelfCard.heightForWidth], so cards never over/underflow their
/// cell at any width. Tapping a card opens the item's full detail sheet.
///
/// Cards are capped at their design width ([maxCardWidth]) and the grid centres
/// the width they surrender ([centringInsetFor]) — PROD-3090. That cap is what
/// keeps the drawer's `half` snap honest, since the snap is composed from
/// [cardRowHeightFor].
///
/// **This builds a SLIVER, not a box** — it is a child of the results drawer's
/// [CustomScrollView] and is driven by the drawer's shared `scrollController`
/// (PROD-3043). That sharing is the whole point: it's what lets an over-scroll
/// at the top of the list hand off to collapsing the drawer, for free, instead
/// of dead-bouncing.
///
/// Consequently this widget owns **no** scroll controller, does **no** pagination
/// and does **no** hydration — [MapResultsSheet] owns all three, because they
/// depend on the drawer's extent (which this widget can't see). In particular,
/// hydration is deliberately gated on the drawer leaving `peek`: this grid is now
/// permanently mounted, so hydrating on mount would fire a `/map/hydrate` on
/// every camera settle for every user, including one who never opens the drawer.
class MapResultsGrid extends ConsumerStatefulWidget {
  const MapResultsGrid({super.key});

  static const double _crossGap = 12;
  static const double _mainGap = 16;

  /// The vertical gap between two rows of cards.
  ///
  /// Public because PROD-2993 has to reconstruct each row's position from the
  /// scroll offset to work out which cards the user can actually see, and it
  /// must use the SAME gap the grid lays out with — a private copy of `16` at
  /// the call site would drift silently the day this changes.
  static const double rowGap = _mainGap;

  /// Applied *inside* the [GridView], so it eats into the width available to
  /// the cells — [columnsFor] subtracts it. Kept as one constant so the column
  /// math and the grid can't drift apart (PROD-3071: they had). The top pad is
  /// shared with the drawer's `half` snap, which is composed from it — see
  /// [kMapDrawerGridTopPadPx].
  static const EdgeInsets _padding = EdgeInsets.fromLTRB(
    16,
    kMapDrawerGridTopPadPx,
    16,
    16,
  );

  /// PROD-3090 — cards never render **above** their design width.
  ///
  /// [columnsFor] only steps at breakpoints, so just below one the column
  /// stretches: at a 640 px drawer it's still 2 columns, giving a 298 px column
  /// and — because [HighlightedShelfCard.heightForWidth] scales the image with
  /// width while the text block stays fixed — a **471 px** card. That would drag
  /// the drawer's `half` snap (derived from exactly this height) down with it.
  ///
  /// Capping here bounds the card at `heightForWidth(195) = 343` on every
  /// viewport, so `half` is bounded for free and the card is never cut off at the
  /// snap. The width the cards give up is handed to [centringInsetFor], which
  /// centres the grid rather than letting the gaps sprawl.
  ///
  /// No phone is affected: at 375–430 px the column is 165–193 px, already under
  /// the cap (cards there are scaled *down*, which is the card's own design
  /// intent).
  static const double maxCardWidth = HighlightedShelfCard.imageWidth;

  /// Columns that fit in [maxWidth] — the grid's OUTER width, i.e. what
  /// `LayoutBuilder` reports before [_padding] is applied.
  ///
  /// Floors at **2**: the card is designed for a 2-up layout and is never
  /// rendered full-bleed. Every other card surface in the app is 2-up
  /// (`search_results_view`, `public_profile_screen`, `smart_lists_screen`),
  /// but they can hardcode it because they sit inside the 480 px `PageContent`
  /// cap. The map drawer is uncapped (`map_results_sheet` mounts it
  /// `Positioned(left: 0, right: 0)`), so above the floor the count still grows
  /// with width — that's why the math exists at all.
  /// No longer test-only: PROD-2993 reconstructs the grid's layout from the
  /// scroll offset to work out which cards are on screen, and it has to use the
  /// same column count the grid actually laid out with.
  static int columnsFor(double maxWidth) {
    final content = maxWidth - _padding.horizontal;
    return ((content + _crossGap) /
            (HighlightedShelfCard.imageWidth + _crossGap))
        .floor()
        .clamp(2, 8);
  }

  /// Width of one cell once [maxWidth] is split into [cols] gapped columns.
  @visibleForTesting
  static double columnWidthFor(double maxWidth, int cols) =>
      (maxWidth - _padding.horizontal - _crossGap * (cols - 1)) / cols;

  /// The width a card actually **renders** at — the column width, capped at
  /// [maxCardWidth]. This is the width the cells are sized to, so the card fills
  /// its cell exactly and needs no `Align`/`SizedBox` wrapper of its own.
  static double cardWidthFor(double outerWidth) => math.min(
    columnWidthFor(outerWidth, columnsFor(outerWidth)),
    maxCardWidth,
  );

  /// The height of **one row** of cards at [outerWidth].
  ///
  /// The drawer's `half` snap is composed from this (PROD-3090), which is why it
  /// lives here rather than at the call site: the snap and the grid must agree on
  /// the card's height to the pixel, or `half` reveals a clipped card.
  ///
  /// `hasSubtitle: false` because this grid never passes one (see [build] — it's
  /// the only [HighlightedShelfCard] caller that doesn't). Reserving the
  /// subtitle's slot anyway left ~36 px of dead space under every card, which at
  /// the `half` snap reads as a gap between the cards and the filter buttons.
  /// The card still reserves **two lines for the name**, which is real — names do
  /// wrap, and a fixed-extent grid has to fit the tallest card in the row.
  static double cardRowHeightFor(double outerWidth) =>
      HighlightedShelfCard.heightForWidth(
        cardWidthFor(outerWidth),
        hasSubtitle: false,
      );

  /// The symmetric extra padding that absorbs the width the capped cards gave up.
  ///
  /// Without it, [maxCardWidth] would simply widen the *gaps* — cards pinned to
  /// the edges with a chasm between them. Handing the leftover to the outer
  /// padding instead centres the grid as a block, matching every other card
  /// surface in the app (they all sit inside the 480 px `PageContent` cap; the
  /// drawer is uncapped, which is why it has to do this itself). Zero whenever
  /// the cap doesn't bind — i.e. on every phone.
  static double centringInsetFor(double outerWidth) {
    final cols = columnsFor(outerWidth);
    final surrendered =
        (columnWidthFor(outerWidth, cols) - maxCardWidth) * cols;
    return surrendered <= 0 ? 0 : surrendered / 2;
  }

  /// The rect of card [index]'s cell in the grid's **scroll-content** space —
  /// origin at the sliver's top-left, i.e. before the pinned header and before
  /// any scroll offset. PROD-2993's `half↔full` anchor-morph tweens the focused
  /// card between its carousel-centre rect and this cell; reusing the exact
  /// column/row/inset math the grid lays out with is what keeps the morph target
  /// from drifting off the real cell.
  static Rect cellRect(double outerWidth, int index) {
    final cols = columnsFor(outerWidth);
    final w = cardWidthFor(outerWidth);
    final h = cardRowHeightFor(outerWidth);
    final inset = centringInsetFor(outerWidth);
    final col = index % cols;
    final row = index ~/ cols;
    final x = _padding.left + inset + col * (w + _crossGap);
    final y = _padding.top + row * (h + _mainGap);
    return Rect.fromLTWH(x, y, w, h);
  }

  @override
  ConsumerState<MapResultsGrid> createState() => _MapResultsGridState();
}

/// Open a result card's full detail sheet, then mark its pin "viewed".
///
/// Shared by the results grid ([MapResultsGrid], at `full`) and the results
/// carousel ([MapResultsCarousel], at `half`) so the two can't drift on how a
/// result is opened. PROD-2989: the "viewed" fade lands on sheet CLOSE (the
/// `await` returns on dismiss), matching the pin-tap timing. An empty [markerId]
/// means the hydrate walk couldn't pair this item back to a pin (a rare stale-id
/// drop) — skip the fade then.
///
/// PROD-2981: shields the (web) Mapbox canvas via [mapModalOpenProvider] while
/// the sheet is up — same as the pin-tap path in `map_screen` — so a tap outside
/// the sheet reaches the modal barrier that closes it, not the live map platform
/// view (which would pan the map / open another pin).
Future<void> openMapResultDetail(
  BuildContext context,
  WidgetRef ref,
  ItemSuggestion item,
  String markerId, {
  required String surface,
}) async {
  // PROD-3219: opened an item detail from a Map-page result card
  // (`surface`='grid' or 'carousel'). Same event as the pin path, so every
  // "opened detail from map" lands under one funnel, separable by `surface`.
  ref
      .read(unifiedAnalyticsProvider)
      .trackMapPinViewDetailsClick(
        itemId: item.id,
        itemType: item.type == 'event' ? 'event' : 'venue',
        mapContext: MapContext.mapPage,
        surface: surface,
      );
  ref.read(mapModalOpenProvider.notifier).state = true;

  // PROD-4160-followup — seed the detail shell from the tapped card so the
  // map's detail SHEET paints hero + title + chips instantly (skeleton) and
  // then hydrates, instead of showing a spinner while the full detail loads.
  ref.cacheDetailSeed(DetailSeed.fromItemSuggestion(item));

  // Build siblings from the full results list so the sheet can swipe through
  // them (PROD "swipe to next result"); fall back to a single-item sheet when
  // the tapped item isn't in the grid. `markerIds` stays index-aligned with the
  // siblings, so `onIndexChanged` can mark each swiped-to result "viewed".
  final grid = ref.read(mapGridProvider);
  final items = grid.items;
  final markerIds = grid.markerIds;
  final idx = markerId.isNotEmpty ? markerIds.indexOf(markerId) : -1;
  final siblings = (idx >= 0 && items.isNotEmpty)
      ? detailSiblingsFromSuggestions(items, idx)
      : detailSiblingsFromSuggestions([item], 0);

  try {
    await showItemDetailSheet(
      context,
      ref,
      siblings: siblings,
      listAddSource: ListSource.map,
      onIndexChanged: (i) {
        if (i >= 0 && i < markerIds.length && markerIds[i].isNotEmpty) {
          ref
              .read(mapViewedItemIdsProvider.notifier)
              .update((s) => <String>{...s, markerIds[i]});
        }
        // Carousel (half snap, map visible): drive the carousel to this result
        // so its existing focus machinery recenters the camera + lights the pin
        // as you swipe. Grid (full snap) has the map fully occluded by the
        // drawer, so a camera move would be invisible — skip it there.
        if (surface == 'carousel') {
          ref.read(mapCarouselFocusRequestProvider.notifier).state = i;
        }
      },
    );
  } finally {
    // Hand the map back once the sheet is gone.
    if (context.mounted) {
      ref.read(mapModalOpenProvider.notifier).state = false;
    }
  }
  if (!context.mounted || markerId.isEmpty) return;
  ref
      .read(mapViewedItemIdsProvider.notifier)
      .update((s) => <String>{...s, markerId});
}

class _MapResultsGridState extends ConsumerState<MapResultsGrid> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mapGridProvider);
    final items = state.items;

    // PROD-2993: on WIDE viewports at `half`, hovering a card lights its pin
    // (see below). Whenever we're NOT there, clear any stale hover so a leftover
    // index can't keep a pin lit — e.g. after dragging to `full`, which removes
    // the MouseRegions without firing their onExit.
    final snap = ref.watch(mapDrawerSnapProvider);
    if (snap != MapDrawerSnap.half &&
        ref.read(mapHoveredCardIndexProvider) != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(mapHoveredCardIndexProvider.notifier).state = null;
        }
      });
    }

    if (items.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: state.isLoading
                ? const CircularProgressIndicator(strokeWidth: 2)
                : const SizedBox.shrink(),
          ),
        ),
      );
    }

    // `SliverLayoutBuilder` (not `LayoutBuilder` — we're in sliver-land now, see
    // the class doc). It sits **OUTSIDE** the `SliverPadding` on purpose: that
    // makes `crossAxisExtent` the grid's **outer** width, which is exactly what
    // PROD-3071's [columnsFor] / [columnWidthFor] expect — they subtract
    // [_padding] themselves. Putting the builder inside the padding would
    // double-subtract it and re-introduce the breakpoint drift PROD-3071 fixed.
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final outerWidth = constraints.crossAxisExtent;
        // Wide + `half` → hover a card to light its pin (mouse only). A MouseRegion
        // fires only for a real pointer, so touch devices get no hover-highlight.
        final hoverMode =
            outerWidth >= kMapWideDrawerMinWidth && snap == MapDrawerSnap.half;
        final cols = MapResultsGrid.columnsFor(outerWidth);
        final cellHeight = MapResultsGrid.cardRowHeightFor(outerWidth);
        // PROD-3090 — the cards are capped at their design width, so hand the
        // width they surrendered to the outer padding. The arithmetic lands the
        // cells at exactly `cardWidthFor(outerWidth)`: the padded content box is
        // now `cols * cappedWidth + gaps`, which is precisely what the delegate
        // divides back up.
        final inset = MapResultsGrid.centringInsetFor(outerWidth);
        return SliverPadding(
          padding:
              MapResultsGrid._padding + EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisExtent: cellHeight,
              crossAxisSpacing: MapResultsGrid._crossGap,
              mainAxisSpacing: MapResultsGrid._mainGap,
            ),
            delegate: SliverChildBuilderDelegate((context, i) {
              final item = items[i];
              // PROD-2989: index-aligned marker id (guarded against any transient
              // length skew) so a grid open fades the exact source pin.
              final markerId = i < state.markerIds.length
                  ? state.markerIds[i]
                  : '';
              final card = HighlightedShelfCard(
                imageUrl: item.imageUrl,
                name: item.name,
                attribution: item.category ?? item.city ?? '',
                onTap: () => openMapResultDetail(
                  context,
                  ref,
                  item,
                  markerId,
                  surface: 'grid',
                ),
                indexInShelf: i,
                // PROD-3124: "Evento"/"Sítio" pill inset top-right on the
                // image (same tag as the chat suggestion cards).
                itemType: item.type == 'event' ? 'event' : 'venue',
                // PROD-3379: "Primeiros dias"/"Últimos dias" recurrence chip (event
                // hydrate cards only; null ⇒ no chip).
                recurrencePhase: item.recurrencePhase,
              );
              if (!hoverMode) return card;
              // Publish this card as the hovered one on enter; clear on exit (only
              // if it's still the current one, so a fast enter→enter doesn't get
              // clobbered by the previous card's late exit).
              return MouseRegion(
                onEnter: (_) =>
                    ref.read(mapHoveredCardIndexProvider.notifier).state = i,
                onExit: (_) {
                  final n = ref.read(mapHoveredCardIndexProvider.notifier);
                  if (n.state == i) n.state = null;
                },
                child: card,
              );
            }, childCount: items.length),
          ),
        );
      },
    );
  }
}
