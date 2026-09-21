import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../discovery/widgets/shelves/highlighted_shelf_card.dart';
import '../providers/map_grid_provider.dart';
import '../providers/map_highlight_provider.dart';
import '../providers/map_ui_state_provider.dart';
import 'map_results_grid.dart' show openMapResultDetail;
import '../../../shared/widgets/carousel_snap_physics.dart';

/// PROD-2993 (D21–D25) — the Map page results as a **horizontal one-card
/// carousel**, shown at the drawer's `half` snap.
///
/// ## Why a carousel at all
///
/// The results drawer is a `DraggableScrollableSheet`, and in a DSS scrolling
/// the content and resizing the sheet are the **same gesture** — an up-drag
/// grows the sheet until it hits the top, and the list only scrolls once it's at
/// `full`. So a *vertical* list at `half` can't be browsed without the drawer
/// swallowing the map. Moving browsing to the **horizontal** axis dissolves the
/// conflict outright: a sideways swipe browses and never resizes; a vertical
/// drag resizes and never browses. Same reason every map app does this.
///
/// ## The layout (D22)
///
/// One card centered; the previous/next card peeks ~20 % at the drawer edges,
/// faded to 50 %. First card → only the next peeks; last → only the previous.
/// The peek is geometric, not hand-placed: with card width `W` in a box of width
/// `B`, the per-card pitch is `D = B/2 + (0.5 − peek)·W`, which lands the
/// neighbour's inner `peek·W` exactly at the drawer edge for any `W`.
///
/// ## Snapping (D23)
///
/// A small swipe advances exactly one card; a fast fling carries through several
/// and settles on one. A plain `PageView` can't do the second (its fling only
/// ever advances one page), so this is a horizontal `ListView` driven by
/// [CarouselSnapPhysics]: momentum runs, then rounds to the nearest card.
///
/// ## What it drives (D24/D25)
///
/// Two things, deliberately decoupled:
///  * **The card opacity** — the centred card is solid, the neighbours recede —
///    updates as you scroll, off local state, via a per-card `AnimatedOpacity`.
///    Cheap and never touches the map.
///  * **The map** — the highlighted pin tracks the centred card **as you
///    scroll**, one card at a time (see [_MapResultsCarouselState._onScrollTick]):
///    the moment a new card takes centre its pin lights up, rather than waiting
///    for the scroll to settle. The publish is deferred out of the scroll
///    dispatch, because running it synchronously mid-scroll cascaded into a
///    `map_screen` rebuild of the very list being scrolled and tore the tree on
///    desktop web — deferring is what makes a live publish safe. The camera
///    **recenter** is coalesced separately (map_screen debounces a fast
///    multi-card fling into a single move), so the pin leads and the camera
///    follows once the browse stops.
class MapResultsCarousel extends ConsumerStatefulWidget {
  const MapResultsCarousel({super.key});

  /// The card's width as a fraction of the drawer width, then clamped.
  ///
  /// Kept deliberately small: the `half` snap is sized to this card's height, so
  /// a smaller card means a shorter drawer and more map above it — which is the
  /// whole point of `half`. The peek formula ties the inter-card spacing to the
  /// card size, so a smaller card automatically gets more air around it. Tunable
  /// — a device-QA judgement.
  static const double _kCardWidthFraction = 0.36;
  static const double _kCardMinWidth = 110;
  static const double _kCardMaxWidth = 165;

  /// How much of the neighbour card shows at the drawer edge (D22).
  static const double _kPeekFraction = 0.20;

  /// Neighbour cards fade to this while the centred card stays at 1.0 (D22).
  static const double _kNeighbourOpacity = 0.5;

  /// The hero card width for a given drawer width.
  static double cardWidthFor(double boxWidth) =>
      (boxWidth * _kCardWidthFraction).clamp(_kCardMinWidth, _kCardMaxWidth);

  /// The `half` snap is sized to fit this (D26) — fed to `MapDrawerMetrics` in
  /// place of the grid's row height. `hasSubtitle: false` mirrors the card the
  /// carousel actually builds (name + attribution only).
  static double cardHeightFor(double boxWidth) =>
      HighlightedShelfCard.heightForWidth(
        cardWidthFor(boxWidth),
        hasSubtitle: false,
      );

  /// Per-card pitch (the [ListView] item extent) that yields the [_kPeekFraction]
  /// peek at the edges. See the class doc for the derivation.
  @visibleForTesting
  static double pitchFor(double boxWidth) {
    final w = cardWidthFor(boxWidth);
    return boxWidth / 2 + (0.5 - _kPeekFraction) * w;
  }

  /// The neighbour's visible width at the drawer edge, for a given box width —
  /// exposed so a test can pin the "~20 % peek" invariant that the pitch maths
  /// exists to guarantee.
  @visibleForTesting
  static double peekWidthFor(double boxWidth) {
    // Neighbour card centre sits one pitch from the centred card's centre; its
    // near edge is `pitch − cardW/2` from viewport centre, and the drawer edge
    // is `boxWidth/2` out. What shows is the difference.
    final w = cardWidthFor(boxWidth);
    return boxWidth / 2 - (pitchFor(boxWidth) - w / 2);
  }

  @override
  ConsumerState<MapResultsCarousel> createState() => _MapResultsCarouselState();
}

class _MapResultsCarouselState extends ConsumerState<MapResultsCarousel> {
  final ScrollController _controller = ScrollController();

  /// The pitch the list is currently laid out with. Recomputed per layout so a
  /// width change (rotation, desktop resize) re-derives the geometry.
  double _pitch = 0;

  /// The card to open on. Seeded from the last-published focus so the carousel
  /// **resumes** where it was rather than snapping back to the first card — e.g.
  /// returning to `half` from `full`, where the carousel remounts. 0 on a fresh
  /// open (the focus provider was cleared when the drawer last closed).
  int _initialIndex = 0;
  bool _didInitialJump = false;

  /// The card currently at (or nearest) centre. Drives the card opacity AND
  /// (as it changes) the live pin publish, and lives in local state on purpose:
  /// it updates continuously as you scroll, but a per-card `AnimatedOpacity`
  /// does the visible fade, so the cards are never rebuilt from the scroll
  /// controller frame-by-frame. That matters — listening to the scroll
  /// controller to rebuild items each frame is what a carousel usually does, and
  /// it's exactly the pattern that tripped an inherited-widget assertion on
  /// desktop web when it cascaded into a map rebuild. The map-driving publish is
  /// keyed off a *change* in this index (once per card, not per frame) and is
  /// deferred out of the scroll dispatch (see [_onScrollTick]); the opacity is
  /// cheap and local.
  int _centeredIndex = 0;

  @override
  void initState() {
    super.initState();
    final focus = ref.read(mapVisibleCardIndicesProvider);
    _initialIndex = focus.isNotEmpty && focus.first >= 0 ? focus.first : 0;
    _centeredIndex = _initialIndex;
    // Publish the initial focus once the first frame is laid out, so entering
    // `half` lights that card and recenters the map on it without waiting for a
    // swipe. Provider writes can't happen during build.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _publishFocus(_initialIndex),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _focusedIndex => (_pitch <= 0 || !_controller.hasClients)
      ? 0
      : (_controller.position.pixels / _pitch).round();

  void _publishFocus(int index) {
    if (!mounted) return;
    final n = ref.read(mapVisibleCardIndicesProvider.notifier);
    if (!listEquals(n.state, <int>[index])) n.state = <int>[index];
  }

  /// Track the centred card as it scrolls, so its opacity leads and the others
  /// recede — and light its pin on the map at the same time. Only fires when the
  /// centred index actually changes (once per card, not per frame).
  void _onScrollTick() {
    if (!mounted) return;
    final items = ref.read(mapGridProvider).items;
    if (items.isEmpty) return;
    final i = _focusedIndex.clamp(0, items.length - 1);
    if (i == _centeredIndex) return;
    setState(() => _centeredIndex = i);
    // Light the map pin for the newly-centred card NOW, rather than waiting for
    // the scroll to settle — that settle wait is what made the highlight lag a
    // swipe. Deferred out of this scroll-notification dispatch: a synchronous
    // publish here cascades into a map_screen rebuild of THIS scrolling list and
    // tears the tree on desktop web (which is the whole reason the publish used
    // to be settle-only). The guard drops a stale publish if a faster card has
    // since taken centre during a fling, so only the current card ever lights.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _centeredIndex == i) _publishFocus(i);
    });
  }

  void _onSettled() {
    final items = ref.read(mapGridProvider).items;
    if (items.isEmpty) return;
    final i = _focusedIndex.clamp(0, items.length - 1);
    // The settle backstop: [_onScrollTick] already publishes the map pin live as
    // each card takes centre, but a fling whose intermediate publishes were
    // dropped by the stale-guard must still land its final card. Publish it here
    // — deferred (a map re-render mid-notification-dispatch can tear the tree)
    // and again synchronously (ScrollEnd is not mid-layout, so it's safe and
    // guarantees the final index even if the post-frame is coalesced away).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishFocus(i);
    });
    _publishFocus(i);
    // Page the hydrate as the user nears the end of what's loaded.
    final st = ref.read(mapGridProvider);
    if (i >= items.length - 3 && st.hasMore && !st.isLoading) {
      ref.read(mapGridProvider.notifier).loadMore();
    }
  }

  /// Tap on a card: open its detail if it's the one centred, otherwise bring it
  /// to centre. Tapping a half-faded peek to *open* it would be a mis-hit; the
  /// natural reading of that tap is "show me this one".
  void _onCardTap(int index) {
    final items = ref.read(mapGridProvider).items;
    if (index < 0 || index >= items.length) return;
    if (index == _focusedIndex) {
      final markerId = index < ref.read(mapGridProvider).markerIds.length
          ? ref.read(mapGridProvider).markerIds[index]
          : '';
      openMapResultDetail(
        context,
        ref,
        items[index],
        markerId,
        surface: 'carousel',
      );
    } else {
      _scrollToIndex(index);
    }
  }

  /// Animate the carousel so [index]'s card becomes the centred one. The scroll
  /// itself republishes the focus ([_onScrollTick]), so the pin lights and the
  /// camera recentres exactly as a manual swipe would — no special-casing here.
  /// Shared by card taps ([_onCardTap]) and external requests (a faded-pin tap
  /// on the map, via [mapCarouselFocusRequestProvider]).
  void _scrollToIndex(int index) {
    final items = ref.read(mapGridProvider).items;
    if (index < 0 || index >= items.length || !_controller.hasClients) return;
    _controller.animateTo(
      index * _pitch,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // PROD-2993 — re-light the pin when the drawer returns to `half` from a
    // non-`half` snap WITHOUT remounting the carousel. `peek↔half` keeps this
    // widget mounted (only `half↔full` swaps carousel↔grid and remounts it), so
    // `initState`'s publish never re-runs on a reopen — and `_endSession` cleared
    // the focus provider to `[]` on the way down to `peek`. Without this, coming
    // back to `half` shows a card whose pin isn't highlighted. Republish the card
    // we're actually on, deferred (a provider write during build is illegal) and
    // clamped in case the selection changed while collapsed. `full→half` is the
    // remount case and is covered by `initState` instead.
    ref.listen<MapDrawerSnap>(mapDrawerSnapProvider, (prev, next) {
      if (next != MapDrawerSnap.half || prev == MapDrawerSnap.half) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final items = ref.read(mapGridProvider).items;
        if (items.isEmpty) return;
        _publishFocus(_centeredIndex.clamp(0, items.length - 1));
      });
    });

    // PROD-2993 — an external request to select a card (a tap on a FADED map pin
    // at narrow `half`). Scroll to it, then clear the one-shot so the same index
    // can be requested again after a manual swipe. Clearing re-fires this with
    // `null`, which the guard drops (no loop).
    ref.listen<int?>(mapCarouselFocusRequestProvider, (prev, next) {
      if (next == null) return;
      ref.read(mapCarouselFocusRequestProvider.notifier).state = null;
      _scrollToIndex(next);
    });

    final st = ref.watch(mapGridProvider);
    final items = st.items;

    if (items.isEmpty) {
      return Center(
        child: st.isLoading
            ? const CircularProgressIndicator(strokeWidth: 2)
            : const SizedBox.shrink(),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.maxWidth;
        _pitch = MapResultsCarousel.pitchFor(boxWidth);
        final cardWidth = MapResultsCarousel.cardWidthFor(boxWidth);
        // Symmetric padding of (box − pitch)/2 centres the first and last card
        // (their slots sit flush against the viewport centre at the scroll
        // extremes), so the very first card opens centred, not left-aligned.
        final endPad = (boxWidth - _pitch) / 2;

        // Resume on the last-focused card (see [_initialIndex]). Once, after the
        // first layout has given the controller clients — jumping needs the pitch.
        if (!_didInitialJump && _initialIndex > 0) {
          _didInitialJump = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _controller.hasClients) {
              _controller.jumpTo(
                (_initialIndex * _pitch).clamp(
                  0.0,
                  _controller.position.maxScrollExtent,
                ),
              );
            }
          });
        }

        return NotificationListener<ScrollNotification>(
          // Return true to CONSUME: the carousel scrolls horizontally inside the
          // drawer's vertical scroll view, and if these notifications bubbled up
          // the sheet would read a sideways browse as a resize drag (PROD-2993).
          onNotification: (n) {
            if (n is ScrollUpdateNotification) _onScrollTick();
            if (n is ScrollEndNotification) _onSettled();
            return true;
          },
          child: ListView.builder(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: CarouselSnapPhysics(itemExtent: _pitch),
            padding: EdgeInsets.symmetric(horizontal: endPad),
            itemExtent: _pitch,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              // The centred card is solid; its neighbours recede to
              // [_kNeighbourOpacity]. `AnimatedOpacity` fades the change smoothly
              // when the centred card changes (once per card — see
              // [_centeredIndex]), so the cards are NOT rebuilt from the scroll
              // controller every frame. That per-frame rebuild is the usual
              // carousel trick, and it's what tripped an inherited-widget
              // assertion on desktop web when the focus publish cascaded into a
              // map rebuild mid-scroll. This is cheap, local, and just as smooth.
              return AnimatedOpacity(
                opacity: i == _centeredIndex
                    ? 1.0
                    : MapResultsCarousel._kNeighbourOpacity,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: Center(
                  child: SizedBox(
                    width: cardWidth,
                    child: HighlightedShelfCard(
                      imageUrl: item.imageUrl,
                      name: item.name,
                      attribution: item.category ?? item.city ?? '',
                      onTap: () => _onCardTap(i),
                      indexInShelf: i,
                      // PROD-3124: the "Evento"/"Sítio" type pill, same as the
                      // full-drawer grid cards (map_results_grid).
                      itemType: item.type == 'event' ? 'event' : 'venue',
                      // PROD-3379: recurrence chip ("Primeiros dias"/"Últimos dias").
                      recurrencePhase: item.recurrencePhase,
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
