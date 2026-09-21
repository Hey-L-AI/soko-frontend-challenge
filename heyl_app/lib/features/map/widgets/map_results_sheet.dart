import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/recurrence_phase.dart';
import '../../../l10n/generated/l10n.dart';
import '../../discovery/widgets/shelves/highlighted_shelf_card.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/measure_size.dart';
import '../providers/map_grid_provider.dart';
import '../providers/map_highlight_provider.dart';
import '../providers/map_seed_provider.dart';
import '../providers/map_selection_provider.dart';
import '../providers/map_ui_state_provider.dart';
import 'map_drawer_metrics.dart';
import 'map_filter_bar.dart';
import 'map_results_carousel.dart';
import 'map_results_grid.dart';

/// How close two extents must be to count as "already there". `goBallistic`
/// settles on the exact snap fraction, so this only has to absorb float noise.
const double _kEps = 0.002;

/// Velocity (in box-fractions per second) past which a flick is a *fling* — it
/// skips to the next stop in the flick's direction instead of settling on the
/// nearest one.
const double _kFlingVelocity = 0.7;

/// PROD-2993 (D36/D37) — one card's `half↔full` morph, in sheet-relative coords.
///
/// Carries just the card's display fields (not the whole item) plus the `from`
/// and `to` rects. Rendered by a single [AnimatedPositioned] overlay; only
/// `left`/`top`/`width` animate — the card self-sizes its height from the width.
class _MorphAnchor {
  final String? imageUrl;
  final String name;
  final String attribution;
  final String? itemType;
  final RecurrencePhase? recurrencePhase;

  const _MorphAnchor({
    required this.imageUrl,
    required this.name,
    required this.attribution,
    required this.itemType,
    required this.recurrencePhase,
  });
}

const Duration _kSnapDuration = Duration(milliseconds: 240);

/// PROD-2671 / PROD-3043 — the Map page's bottom results drawer.
///
/// A **gesture-driven, 3-snap** [DraggableScrollableSheet] (peek / half / full;
/// see [MapDrawerMetrics]). Drag the handle, swipe it, or scroll the results —
/// and when the grid is at its top and you keep pulling down, the drawer
/// collapses a stop instead of dead-bouncing. That last behaviour is the whole
/// reason this is a `DraggableScrollableSheet` and not hand-rolled gestures: the
/// grid shares the sheet's `scrollController`, so the scroll→resize handoff is
/// the framework's, not ours.
///
/// Structure (a [Stack], deliberately — see below):
/// * a **pinned** header ([_DrawerHeader]: drag handle + "Ver N resultados"),
///   inside the scroll view so a drag on it drives the resize natively, and
///   `pinned:` so it never scrolls away at `full`. It sheds the count row as the
///   drawer opens (PROD-3090), giving 48 px back to the map;
/// * the results grid ([MapResultsGrid]), a sliver on the shared controller;
/// * a **pinned footer** (the filter option row + question buttons), which sits
///   OUTSIDE the scroll view so it's always reachable (PROD-3043 decision #2)
///   and so a filter can be open while the results are dragged/scrolled
///   (decision #3). Being outside the scrollable, it can't resize the sheet
///   natively — hence its own vertical-drag [GestureDetector].
///
/// **Why a `Stack` and not a `Column`.** With `Column[Expanded(scroll), footer]`
/// the footer's intrinsic height briefly exceeds the sheet's own height for one
/// frame after a filter opens (the option row appears before peek has grown),
/// which hands `Expanded` negative space and throws a `RenderFlex` overflow. The
/// `Stack` (under a `ClipRRect`) just clips for that frame.
class MapResultsSheet extends ConsumerStatefulWidget {
  const MapResultsSheet({super.key});

  @override
  ConsumerState<MapResultsSheet> createState() => _MapResultsSheetState();
}

class _MapResultsSheetState extends ConsumerState<MapResultsSheet>
    with TickerProviderStateMixin {
  final DraggableScrollableController _sheet = DraggableScrollableController();

  /// The scroll controller the sheet hands to its builder. The SDK deliberately
  /// keeps the SAME instance across extent replacements, so we attach our
  /// pagination listener once and **never dispose it** — it isn't ours.
  ScrollController? _scroll;
  bool _scrollListenerAttached = false;

  /// The sheet's box height, from our own `LayoutBuilder`. NOT the screen
  /// height — `/map` renders with the bottom nav visible. See [MapDrawerMetrics].
  double _boxHeight = 0;

  /// The sheet's box width. Needed to reconstruct the grid's row layout when
  /// scrolling it to the carousel's focused card on a `half → full` switch.
  double _boxWidth = 0;

  /// PROD-2993 — which body is CURRENTLY mounted: the carousel or the grid.
  ///
  /// This lags the drawer's snap deliberately. The snap flips the instant a drag
  /// settles, but the body cross-fades (`_bodyFade`): old content fades out, the
  /// body swaps at opacity 0, new content fades in. So the *snap* says where we
  /// want to be and this says what's on screen right now. Starts on the carousel
  /// (the drawer opens at `peek`, whose content is the carousel — a `peek`/`half`
  /// open must show carousel content, never the full grid).
  bool _bodyIsCarousel = true;
  bool _bodyTransitioning = false;

  /// PROD-2993 (D36/D37) — the narrow `half↔full` **anchor-morph**.
  ///
  /// The focused card is a persistent shared element: while everything else
  /// cross-fades (`_bodyFade`), this one card tweens between [_morphFrom] and
  /// [_morphTo] (sheet-relative rects) so the card you're looking at never
  /// blinks. Null when no morph is running. Driven by [_morphCtrl] (a lerp, not
  /// an [AnimatedPositioned]) so half→full can correct [_morphTo] to the card's
  /// real grid landing mid-flight — see [_scrollGridToFocused].
  _MorphAnchor? _morph;
  Rect _morphFrom = Rect.zero;
  Rect _morphTo = Rect.zero;
  Timer? _morphSafety;
  late final AnimationController _morphCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  /// The carousel's last focused card, tracked **durably** so a `half → full`
  /// switch can land the grid on it.
  ///
  /// It can't just be read off [mapVisibleCardIndicesProvider] at switch time:
  /// that provider is `autoDispose`, and the moment the drawer hits `full`
  /// nothing watches it any more (`mapHighlightProvider` short-circuits before it
  /// on the `snap != half` guard, and the carousel has unmounted), so it disposes
  /// and resets to `[]` — which is exactly why the grid used to always open at
  /// the top. The `ref.listen` in `build` both keeps the provider alive while the
  /// sheet is up AND parks the last non-empty index here, surviving the reset.
  int _lastFocusedIndex = 0;
  late final AnimationController _bodyFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    value: 1,
  );

  /// Measured footer height. Seeded with the exact no-filter value so frame 1 is
  /// already correct and the drawer never flashes collapsed.
  double _footerHeight = kMapDrawerBaseFooterPx;

  /// The snap list handed to [DraggableScrollableSheet], memoized **by value**.
  ///
  /// `_replaceExtent` re-snaps (`position.goBallistic(0)`) whenever
  /// `snapSizes != oldWidget.snapSizes` — and Dart `List` compares by
  /// *identity*. A freshly-built list each rebuild would therefore fire a
  /// re-snap on every rebuild; at rest that's a harmless no-op, but mid-drag it
  /// cancels the drag and rips the sheet out of the user's finger. And rebuilds
  /// DO happen mid-drag here (the count row updates as the map re-selects).
  List<double> _snaps = const <double>[];

  /// Latest resolved geometry — kept on the State because listeners (extent,
  /// pointer-signal, footer drag) run outside `build`.
  MapDrawerMetrics _metrics = MapDrawerMetrics.resolve(
    boxHeight: 0,
    chromeHeight: kMapDrawerBasePeekPx,
    cardRowHeight: 0,
    topChromeInset: 0,
    hasResults: false,
  );

  /// Seeded (chat) map: opens the drawer to `half` (cards visible) once, as soon
  /// as the metrics resolve a real `half` stop and the sheet is attached. The
  /// standalone `/map` opens at `peek`; this one-shot is the chat-map's
  /// "already-open" affordance (and it arms the resultsHighlight session so
  /// carousel scroll lights the matching pin).
  bool _seededDidOpen = false;

  /// True once the footer has laid out and reported its height at least once
  /// (via [_onFooterMeasured]). The seeded auto-open waits for this: the footer's
  /// first measure moves `_footerHeight` off its 72 px default (to 0 in seeded
  /// mode, where the footer is empty), which shifts every snap fraction and makes
  /// the SDK re-snap. If that landed mid-open it snapped the sheet straight back
  /// to `peek` — the "opens then closes" bug. Gating the open on this means the
  /// snap list is already stable before the open animation runs.
  bool _footerSettled = false;

  /// Debounces the extent stream down to a single "it settled" event.
  Timer? _settleDebounce;

  /// True while the user's finger/pointer is driving the sheet — either through
  /// the scroll view (handle / results drag) or the footer's own drag detector.
  ///
  /// [_onSettled] MUST NOT run while this is true. The settle detector is a
  /// debounce, and a debounce cannot tell "the drag finished" from "the user
  /// paused mid-drag for 80 ms" — which people do constantly. Writing the snap
  /// provider during that pause would make the `ref.listen` below `animateTo`
  /// the sheet out from under a pointer that is still down.
  bool _dragging = false;

  /// True while a drag on the **top grab strip** is in flight. Keeps that strip
  /// mounted even once the drag pulls the sheet down to `peek` — otherwise the
  /// strip un-mounts under the finger and its drag-end never fires, leaving
  /// [_dragging] stuck true. See the strip in [_buildSheet].
  bool _edgeDragActive = false;

  /// Single choke point for [_dragging], so the local flag and the published
  /// [mapDrawerDraggingProvider] can never drift apart. The map page reads the
  /// provider to keep the camera still while a finger is on the drawer — see
  /// the provider's doc for why a debounce alone is not enough.
  set _isDragging(bool v) {
    if (_dragging == v) return;
    _dragging = v;
    final n = ref.read(mapDrawerDraggingProvider.notifier);
    if (n.state != v) n.state = v;
  }

  /// Whether we've hydrated the grid for the CURRENT selection.
  ///
  /// The grid is now permanently mounted (it's a sliver in the always-present
  /// scroll view), so it must NOT hydrate on mount the way it used to — that
  /// would fire a `/map/hydrate` on every camera settle for every user, even one
  /// who never opens the drawer. Hydration is gated on the drawer actually
  /// leaving `peek`, and reset whenever the selection changes.
  bool _hydrated = false;

  @override
  void initState() {
    super.initState();
    _sheet.addListener(_onExtentChanged);
  }

  @override
  void dispose() {
    _settleDebounce?.cancel();
    _morphSafety?.cancel();
    _morphCtrl.dispose();
    _bodyFade.dispose();
    _sheet.removeListener(_onExtentChanged);
    _sheet.dispose();
    // _scroll belongs to the DraggableScrollableSheet — detach, never dispose.
    if (_scrollListenerAttached) _scroll?.removeListener(_onScroll);
    super.dispose();
  }

  // -------------------------------------------------------- body cross-fade

  /// PROD-2993 (D21) — drive the carousel↔grid swap as a **cross-fade**.
  ///
  /// [wantCarousel] is `true` for every snap except `full` (so `peek` and `half`
  /// both show the carousel, and opening from `peek` never flashes the grid).
  /// A change vs [_bodyIsCarousel] means we're crossing the `full` boundary:
  /// fade the current body out, swap it at opacity 0, then fade the new one in.
  /// When the new body is the **grid**, we also jump it to the row holding the
  /// card the carousel was focused on, so `half → full` lands on what you were
  /// looking at (first card → top, last → bottom, middle → that card in view).
  ///
  /// Re-checks at the end: a fast `half→full→half` that arrives mid-fade is
  /// honoured once the in-flight transition finishes, so the body can't end up
  /// stuck out of sync with the snap.
  Future<void> _syncBody(bool wantCarousel) async {
    // Wide: the body is always the grid, so a snap change is a pure resize with
    // nothing to cross-fade. (Narrow-only feature — the morph lives here.)
    if (_boxWidth >= kMapWideDrawerMinWidth) return;
    if (_bodyTransitioning || wantCarousel == _bodyIsCarousel) return;
    // PROD-2993 (D37): fire the anchor-morph at snap-commit, concurrent with the
    // sheet's open ease — NOT after the fade-out. The overlay bridges the body's
    // dip-to-blank so the focused card never disappears.
    _startMorph(toFull: !wantCarousel);
    _bodyTransitioning = true;
    await _bodyFade.animateTo(0, curve: Curves.easeOut);
    if (!mounted) {
      _bodyTransitioning = false;
      return;
    }
    setState(() => _bodyIsCarousel = wantCarousel);
    if (!wantCarousel) {
      // Switched to the grid — land it on the focused card once it's laid out.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollGridToFocused(),
      );
    } else {
      // Back to the carousel — it re-reads the focused index on mount itself.
      _rewindScroll();
    }
    await _bodyFade.animateTo(1, curve: Curves.easeIn);
    _bodyTransitioning = false;
    // The overlay held the focused card across the WHOLE cross-fade; the base
    // body is fully opaque again at the destination cell now, so remove the
    // overlay here (not on its shorter position-tween's onEnd, which would drop
    // it while the base was still mid-fade and blink the card).
    _clearMorph();
    // A snap change that landed during the fade — reconcile now.
    if (mounted) {
      final want = ref.read(mapDrawerSnapProvider) != MapDrawerSnap.full;
      if (want != _bodyIsCarousel) _syncBody(want);
    }
  }

  /// PROD-2993 (D36/D37) — build the anchor-morph overlay for a narrow
  /// `half↔full` swap. The focused card ([_lastFocusedIndex]) tweens between its
  /// carousel-centre rect and its grid-cell rect, both in sheet-relative coords
  /// (origin = the sheet's top-left, where the open header sits at
  /// [kMapDrawerOpenHeaderPx]). `to`/`from` are computed analytically from the
  /// same geometry the two bodies lay out with, so nothing has to be measured.
  void _startMorph({required bool toFull}) {
    final items = ref.read(mapGridProvider).items;
    if (items.isEmpty || _boxWidth <= 0) return;
    final idx = _lastFocusedIndex.clamp(0, items.length - 1);
    final box = _boxWidth;

    // Carousel-centre rect: the carousel's own card size, centred under the open
    // header. The card is `Center`-ed in a body of height (cardHeight + top pad),
    // so it sits `gridTopPad / 2` below the header.
    final cw = MapResultsCarousel.cardWidthFor(box);
    final ch = MapResultsCarousel.cardHeightFor(box);
    final carouselRect = Rect.fromLTWH(
      (box - cw) / 2,
      kMapDrawerOpenHeaderPx + kMapDrawerGridTopPadPx / 2,
      cw,
      ch,
    );

    final cell = MapResultsGrid.cellRect(box, idx);
    final Rect from;
    final Rect to;
    if (toFull) {
      from = carouselRect;
      // The grid scrolls the focused card toward the top but CLAMPS at the
      // bottom, so a last-row card lands low, not at the top row. Seed the
      // target with an estimated clamped scroll so the card heads the right way
      // from the start; [_scrollGridToFocused] corrects it to the measured
      // landing one frame later (the lerp reads [_morphTo] live, no restart).
      final rowPitch =
          MapResultsGrid.cardRowHeightFor(box) + MapResultsGrid.rowGap;
      final focusedRowTop = (idx ~/ MapResultsGrid.columnsFor(box)) * rowPitch;
      final estScroll = focusedRowTop.clamp(
        0.0,
        _estimatedGridMaxScroll(items.length),
      );
      to = _gridCellSheetRect(cell, estScroll);
    } else {
      final scrollPixels = (_scroll?.hasClients ?? false)
          ? _scroll!.position.pixels
          : 0.0;
      from = _gridCellSheetRect(cell, scrollPixels);
      to = carouselRect;
      // full→half: if the focused card is scrolled well off-screen, a fly-in from
      // nowhere reads worse than the plain cross-fade — skip the morph then.
      final sheetH = _sheet.isAttached ? _sheet.size * _boxHeight : _boxHeight;
      if (from.bottom < kMapDrawerOpenHeaderPx || from.top > sheetH) return;
    }

    final item = items[idx];
    _morphSafety?.cancel();
    _morphFrom = from;
    _morphTo = to;
    setState(() {
      _morph = _MorphAnchor(
        imageUrl: item.imageUrl,
        name: item.name,
        attribution: item.category ?? item.city ?? '',
        itemType: item.type == 'event' ? 'event' : 'venue',
        recurrencePhase: item.recurrencePhase,
      );
    });
    _morphCtrl.forward(from: 0);
    // Belt-and-braces: `_syncBody` clears the overlay after its cross-fade, but
    // if that path ever bails (e.g. an interrupted fade) this guarantees the
    // overlay never sticks. Comfortably past the 320 ms cross-fade so it never
    // pre-empts the seamless clear.
    _morphSafety = Timer(const Duration(milliseconds: 800), _clearMorph);
  }

  /// A grid cell's rect lifted into sheet-relative coords: below the open header
  /// and shifted by the current scroll offset.
  Rect _gridCellSheetRect(Rect cell, double scrollPixels) => Rect.fromLTWH(
    cell.left,
    kMapDrawerOpenHeaderPx + cell.top - scrollPixels,
    cell.width,
    cell.height,
  );

  /// A rough max-scroll of the full grid, used only to seed the half→full morph
  /// target (the exact landing is corrected from the real scroll extent in
  /// [_scrollGridToFocused]). Mirrors the grid's content box — top pad + rows +
  /// inter-row gaps + bottom pad + footer clearance — minus the scroll viewport
  /// (the full sheet minus the pinned open header).
  double _estimatedGridMaxScroll(int itemCount) {
    final box = _boxWidth;
    final cols = MapResultsGrid.columnsFor(box);
    if (cols <= 0) return 0;
    final rows = (itemCount + cols - 1) ~/ cols;
    final cellH = MapResultsGrid.cardRowHeightFor(box);
    final contentH =
        kMapDrawerGridTopPadPx +
        rows * cellH +
        (rows - 1).clamp(0, rows) * MapResultsGrid.rowGap +
        16 + // grid bottom padding
        _footerHeight;
    final viewportH = _metrics.full * _boxHeight - kMapDrawerOpenHeaderPx;
    final maxScroll = contentH - viewportH;
    return maxScroll < 0 ? 0 : maxScroll;
  }

  void _clearMorph() {
    _morphSafety?.cancel();
    _morphSafety = null;
    if (_morph == null) return;
    _morphCtrl.stop();
    if (mounted) {
      setState(() => _morph = null);
    } else {
      _morph = null;
    }
  }

  /// Jump the full grid so the carousel's focused card is in view. Row-aligned:
  /// the focused item's row is brought to the top of the grid's scroll area, and
  /// the clamp makes the first card land at the top and the last at the bottom.
  void _scrollGridToFocused() {
    final sc = _scroll;
    if (sc == null || !sc.hasClients || _boxWidth <= 0) return;
    final idx = _lastFocusedIndex;
    final cols = MapResultsGrid.columnsFor(_boxWidth);
    if (cols <= 0) return;
    final row = idx ~/ cols;
    final rowPitch =
        MapResultsGrid.cardRowHeightFor(_boxWidth) + MapResultsGrid.rowGap;
    final target = (row * rowPitch).clamp(0.0, sc.position.maxScrollExtent);
    sc.jumpTo(target);
    // Correct the anchor-morph target to where the focused card ACTUALLY landed
    // now that the real (clamped) scroll extent is known — a last-row card lands
    // low, not at the top. The controller-driven lerp reads [_morphTo] live, so
    // this just curves the in-flight card to the corrected endpoint; no restart.
    if (_morph != null) {
      _morphTo = _gridCellSheetRect(
        MapResultsGrid.cellRect(_boxWidth, idx),
        target,
      );
      // While the controller is animating the AnimatedBuilder repaints every
      // frame and picks this up for free; if it already finished (jank), force a
      // rebuild so the corrected target still lands.
      if (!_morphCtrl.isAnimating && mounted) setState(() {});
    }
  }

  // ---------------------------------------------------------------- commands

  /// Drive the drawer to [snap] and keep [mapDrawerSnapProvider] in step.
  ///
  /// When the provider value actually changes, our `ref.listen` does the
  /// animating; when it doesn't (e.g. a footer drag released back onto the stop
  /// it started from), the listener never fires — so we animate here instead.
  /// Exactly one `animateTo` either way.
  void _command(MapDrawerSnap snap) {
    final notifier = ref.read(mapDrawerSnapProvider.notifier);
    final changed = notifier.state != snap;
    notifier.state = snap;
    if (!changed) _animateTo(snap);
  }

  /// Seeded (chat) map: drive the drawer open to `half` on mount, retrying
  /// across frames until the sheet's controller is actually attached.
  ///
  /// The one-shot is BURNED at build time the moment the geometry resolves (see
  /// the seeded guard in [build]), but the sheet below only attaches its
  /// controller after its first layout — which is one or more frames later, and
  /// in seeded mode no provider change rebuilds this widget to re-check. So the
  /// open can't be a plain single post-frame (it would fire before attach and
  /// no-op); it polls post-frame until `_sheet.isAttached`, then commands once.
  void _openSeededDrawer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Wait for BOTH the controller to attach AND the footer to have reported
      // its height once — the latter is what makes the snap list stable, so the
      // open animation below can't be re-snapped shut mid-flight. See
      // [_footerSettled].
      if (!_sheet.isAttached || !_footerSettled) {
        _openSeededDrawer(); // not ready yet — try the next frame
        return;
      }
      _command(MapDrawerSnap.half);
    });
  }

  void _animateTo(MapDrawerSnap snap) {
    if (!_sheet.isAttached) return;
    final target = _metrics.fractionFor(snap);
    if ((_sheet.size - target).abs() < _kEps) return;
    // Collapsing to peek with the list scrolled would leave `pixels > 0`, which
    // keeps the scrollable claiming the next downward drag instead of handing it
    // to the sheet. Rewind first.
    if (snap == MapDrawerSnap.peek) _rewindScroll();
    _sheet
        .animateTo(target, duration: _kSnapDuration, curve: Curves.easeOutCubic)
        .whenComplete(() {
          // A PROGRAMMATIC snap (the "Ver N resultados" button, a cluster tap,
          // etc.) drives the sheet's extent through the shared scroll controller,
          // which raises a `ScrollStart` — setting `_isDragging` — with no finger
          // ever lifting to clear it. Left stuck true it blocks the map's
          // camera-follow (`map_screen._recenterOnFocused` guards on
          // `mapDrawerDraggingProvider`), so a button-open HIGHLIGHTS but never
          // recenters, while a real drag (which does lift a finger) works. Clear
          // it on arrival: the `_isDragging` provider write then fires the same
          // finger-lifted recenter, so a programmatic open recenters like a drag.
          // Skip if a user grab interrupted the animation (sheet not at target) —
          // that finger owns the flag now.
          if (mounted &&
              _sheet.isAttached &&
              (_sheet.size - target).abs() < _kEps) {
            _isDragging = false;
          }
        });
  }

  void _rewindScroll() {
    final sc = _scroll;
    if (sc != null && sc.hasClients && sc.position.pixels != 0) sc.jumpTo(0);
  }

  // ---------------------------------------------------------------- extent

  void _onExtentChanged() {
    // Hydrate the moment the drawer leaves peek — deliberately NOT gated on
    // settle, so the request is already in flight while the user is still
    // dragging and the cards are there on arrival instead of popping in after.
    // Idempotent per selection, and it never touches the sheet, so it's safe to
    // run mid-drag.
    if (_sheet.isAttached && _sheet.size > _metrics.peek + _kEps) {
      _ensureHydrated();
    }
    // The controller notifies on every pixel of travel. Collapse the stream into
    // one settled event; a running drag/animation keeps resetting the timer.
    _settleDebounce?.cancel();
    _settleDebounce = Timer(const Duration(milliseconds: 80), _onSettled);
  }

  void _onSettled() {
    if (!mounted || !_sheet.isAttached) return;
    // Still under the finger — a mid-drag pause is not a settle. See [_dragging].
    if (_dragging) return;
    final size = _sheet.size;

    // Write the user's drag back as intent, so the chevron (and anything else
    // reading the provider) reflects reality. This cannot loop: the value we
    // write is the snap the sheet is ALREADY at, so the `ref.listen` below
    // computes that same extent, sees `|size - target| < eps`, and returns.
    final snap = _metrics.nearestSnap(size);
    final notifier = ref.read(mapDrawerSnapProvider.notifier);
    if (notifier.state != snap) {
      notifier.state = snap;
      _haptic();
    }

    // (Hydration is kicked off in [_onExtentChanged], not here — it starts while
    // the drag is still in flight so the cards land with the drawer.)

    // PROD-2993: publish how much map the drawer is now covering. On SETTLE only
    // — the map page reads this to decide whether a highlighted pin is hidden
    // behind us, and re-deriving that on every pixel of a drag would rebuild the
    // map page for the whole gesture.
    final occluded = size * _boxHeight;
    final occludedNotifier = ref.read(mapDrawerOccludedHeightProvider.notifier);
    if ((occludedNotifier.state - occluded).abs() > 0.5) {
      occludedNotifier.state = occluded;
    }

    // A sheet RESIZE doesn't move `pixels`, so growing peek→full can satisfy the
    // near-the-end condition without ever emitting a scroll notification. Top up
    // here as well as on scroll, or we under-fetch until the user scrolls.
    _maybeLoadMore();
  }

  void _haptic() {
    if (kIsWeb) return;
    HapticFeedback.selectionClick();
  }

  // ------------------------------------------------------- grid data plumbing

  void _ensureHydrated() {
    if (_hydrated) return;
    _hydrated = true;
    final st = ref.read(mapGridProvider);
    if (st.items.isEmpty && st.hasMore && !st.isLoading) {
      _loadMore();
    }
  }

  /// The selection genuinely changed — [mapGridProvider] is keyed off
  /// [mapFocusedClusterProvider] / [mapSettledSelectionProvider], so it has just
  /// been rebuilt with a fresh, empty state. Re-arm the hydration gate.
  ///
  /// Keyed off those providers deliberately, NOT off the grid's *state shape*.
  /// `items.isEmpty && hasMore && !isLoading` looks like "a fresh selection", but
  /// `MapGridNotifier` produces exactly that shape after a **cancellation**
  /// (`map_grid_provider.dart` — `cancelInFlight()` on map movement) and after a
  /// **request error** (its `catch`). Treating those as a selection change would
  /// re-fire `/map/hydrate` on every pan while the drawer is open, and would
  /// retry a failing request forever.
  void _onSelectionChanged() {
    _hydrated = false;
    _rewindScroll();
    // Post-frame so the autoDispose grid provider has actually been rebuilt.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheet.isAttached) return;
      // Only if the drawer is open — the user is looking at the results.
      if (_sheet.size > _metrics.peek + _kEps) _ensureHydrated();
    });
  }

  void _onScroll() => _maybeLoadMore();

  void _maybeLoadMore() {
    final sc = _scroll;
    if (sc == null || !sc.hasClients) return;
    if (sc.position.pixels < sc.position.maxScrollExtent - 240) return;
    final st = ref.read(mapGridProvider);
    if (st.hasMore && !st.isLoading) _loadMore();
  }

  /// Kick a pagination fetch — but never synchronously from inside a layout
  /// pass. [_maybeLoadMore] (via the [_onScroll] position listener) and
  /// [_ensureHydrated] (via the [_onExtentChanged] extent listener) can both be
  /// invoked while the DraggableScrollableSheet is re-dimensioning inside
  /// `performLayout`, where `loadMore`'s synchronous `isLoading: true` state
  /// write would throw "modify a provider while building". `loadMore` is
  /// idempotent (its own `_busy` guard), so a one-frame defer is invisible.
  void _loadMore() =>
      _outsideLayout(() => ref.read(mapGridProvider.notifier).loadMore());

  /// Run [fn] now, unless we're mid-frame (build/layout/paint) — then defer it
  /// to the next post-frame. Scroll position/extent listeners can fire from
  /// inside `performLayout` (the sheet re-goes-ballistic when its content
  /// dimensions change), and a provider write there is illegal.
  void _outsideLayout(VoidCallback fn) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fn();
      });
    } else {
      fn();
    }
  }

  // --------------------------------------------------------- footer dragging

  void _onFooterDragUpdate(DragUpdateDetails d) {
    if (_metrics.locked || !_sheet.isAttached || _boxHeight <= 0) return;
    final next = (_sheet.size - d.primaryDelta! / _boxHeight).clamp(
      _metrics.peek,
      _metrics.full,
    );
    // `jumpTo` sets hasDragged=false, so the sheet will NOT auto-snap for us —
    // which is exactly what we want: we snap explicitly on drag end.
    _sheet.jumpTo(next);
  }

  void _onFooterDragEnd(DragEndDetails d) {
    // Clear BEFORE commanding: _command -> _animateTo must not be suppressed, and
    // the settle that follows the animation is a real settle.
    _isDragging = false;
    if (_metrics.locked || !_sheet.isAttached || _boxHeight <= 0) return;
    // Box-fractions per second, positive = upward (the drawer growing).
    final velocity = -d.velocity.pixelsPerSecond.dy / _boxHeight;
    final size = _sheet.size;
    final double target;
    if (velocity > _kFlingVelocity) {
      target = _metrics.snaps.firstWhere(
        (s) => s > size + _kEps,
        orElse: () => _metrics.full,
      );
    } else if (velocity < -_kFlingVelocity) {
      target = _metrics.snaps.lastWhere(
        (s) => s < size - _kEps,
        orElse: () => _metrics.peek,
      );
    } else {
      target = _metrics.fractionFor(_metrics.nearestSnap(size));
    }
    _command(_metrics.nearestSnap(target));
  }

  // ---------------------------------------------------------- desktop wheel

  /// A mouse wheel can NEVER resize a `DraggableScrollableSheet` on its own:
  /// wheel deltas go `pointerScroll()` → `jumpTo`, which never reaches
  /// `applyUserOffset` — the only door into the sheet's extent. (Trackpad *pan*
  /// does use the drag path, so that collapses for free.) So we do it by hand:
  /// wheeling "up" while the list is already at its top collapses a stop, which
  /// is the pointer equivalent of the touch over-scroll handoff.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_metrics.locked || !_sheet.isAttached) return;
    // Wheeling down = scroll the list, not collapse the drawer.
    if (event.scrollDelta.dy >= 0) return;
    final sc = _scroll;
    if (sc != null && sc.hasClients && sc.position.pixels > 0.5) return;
    final below = _metrics.snapBelow(_sheet.size);
    if (below != null) _command(below);
  }

  // ---------------------------------------------------------------- measuring

  void _onFooterMeasured(Size size) {
    if (!mounted) return;
    // Release the seeded auto-open, but only AFTER this measure's layout change
    // has actually landed. Marking it now (synchronously) would let the open run
    // in the same post-frame batch, before the `setState` below rebuilds and the
    // SDK re-snaps to the new snap list — which is exactly the mid-open re-snap
    // that closed the drawer. A post-frame flag is true only once the new snaps
    // are in force and no further change is pending.
    if (!_footerSettled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _footerSettled = true;
      });
    }
    final height = size.height;
    if ((height - _footerHeight).abs() < 0.5) return;
    setState(() => _footerHeight = height);

    // The my-location button hugs the drawer's full PEEK chrome (so it clears an
    // open filter's option rows) — never the live drag extent.
    final chrome = kMapDrawerHeaderPx + height;
    final notifier = ref.read(mapDrawerChromeHeightProvider.notifier);
    if (notifier.state != chrome) notifier.state = chrome;

    // Every snap fraction just moved (peek grew/shrank, and `half` is derived
    // from peek). `_replaceExtent`'s clamp only pushes the current extent UP when
    // peek grows — it never pulls it back DOWN when a filter closes, and it never
    // re-settles a sheet resting at `half`/`full`. So re-command whichever snap
    // we're supposed to be at, or the sheet is left stranded between stops while
    // the provider still claims a snap.
    //
    // Post-frame: `_metrics` is recomputed by the rebuild this setState triggers.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheet.isAttached) return;
      if (_dragging) return; // never re-command under an active finger
      final target = _metrics.fractionFor(ref.read(mapDrawerSnapProvider));
      if ((_sheet.size - target).abs() < _kEps) return;
      _sheet.animateTo(
        target,
        duration: _kSnapDuration,
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// The question-buttons row on its own (no filter option row). This — not the
  /// whole footer — is what the map camera reserves, so a transient filter panel
  /// never re-frames the map. Measured rather than hard-coded so it can't go
  /// stale if the resting drawer UI changes.
  void _onButtonsMeasured(Size size) {
    if (!mounted) return;
    // The footer's top gap sits above the buttons but is still part of the
    // resting chrome, so the camera has to reserve it too.
    final basePeek =
        kMapDrawerHeaderPx + kMapDrawerFooterTopGapPx + size.height;
    final notifier = ref.read(mapDrawerBasePeekHeightProvider.notifier);
    if ((notifier.state - basePeek).abs() < 0.5) return;
    notifier.state = basePeek;
  }

  /// See [_snaps] — memoize by VALUE so the sheet doesn't re-snap on rebuild.
  List<double> _memoSnaps(List<double> next) =>
      listEquals(_snaps, next) ? _snaps : (_snaps = next);

  // ------------------------------------------------------------ header collapse

  /// How far the header has shed its count row — see
  /// [MapDrawerMetrics.headerCollapseT], which owns the maths (it's pure, so it's
  /// unit-tested there rather than only through a rendered sheet).
  ///
  /// Before the sheet attaches there is no extent to read, and the drawer starts
  /// at `peek`, so the row is fully shown.
  double _headerCollapseT() =>
      _sheet.isAttached ? _metrics.headerCollapseT(_sheet.size) : 0;

  @override
  Widget build(BuildContext context) {
    // When a cluster is focused the drawer is scoped to its members; otherwise
    // the count = ALL results in view (including those hidden inside clusters).
    final focused = ref.watch(mapFocusedClusterProvider);
    final count =
        focused?.members.length ??
        ref.watch(mapSettledSelectionProvider).visibleCount;
    final hasResults = count > 0;

    // Re-arm the hydration gate when the selection genuinely changes. These are
    // the two providers `mapGridProvider` is keyed off, so they are the true
    // "the grid just reset" signal — see [_onSelectionChanged] for why the grid's
    // own state shape is NOT safe to use here.
    ref.listen(mapSettledSelectionProvider, (_, _) => _onSelectionChanged());
    ref.listen(mapFocusedClusterProvider, (_, _) => _onSelectionChanged());

    // Intent → reality. The eps guard is what terminates the loop with the
    // settle-write in [_onSettled].
    ref.listen<MapDrawerSnap>(mapDrawerSnapProvider, (_, next) {
      _animateTo(next);
      // PROD-2993 (D21): the body is the carousel at every snap except `full`
      // (so opening from `peek` shows carousel content, not the full grid). A
      // change crossing the `full` boundary cross-fades — see [_syncBody].
      _syncBody(next != MapDrawerSnap.full);
    });

    // PROD-2993 (D30/D31): keep the focus provider ALIVE while the sheet is up
    // (this `ref.listen` counts as a listener, so it doesn't autoDispose at
    // `full`), and park the last real index so `half → full` can land the grid on
    // it and `full → half` can resume the carousel there. A reset to `[]` (on
    // close) is ignored so the last card survives it.
    ref.listen<List<int>>(mapVisibleCardIndicesProvider, (_, next) {
      if (next.isNotEmpty) _lastFocusedIndex = next.first;
    });

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _boxHeight = constraints.maxHeight;
          _boxWidth = constraints.maxWidth;
          // PROD-2993: narrow `half` is one carousel card tall (D26); wide `half`
          // is a scrolling grid parked at a fraction of the box — a grid card is
          // ~343 px, too tall to fit a row-derived `half` below `full` on a short
          // desktop window (see [kMapWideHalfFraction]).
          final isWide = constraints.maxWidth >= kMapWideDrawerMinWidth;
          final metrics = MapDrawerMetrics.resolve(
            boxHeight: _boxHeight,
            chromeHeight: kMapDrawerHeaderPx + _footerHeight,
            cardRowHeight: isWide
                ? MapResultsGrid.cardRowHeightFor(constraints.maxWidth)
                : MapResultsCarousel.cardHeightFor(constraints.maxWidth),
            // PROD-2993: the full drawer parks below the back/search row and
            // covers the shortcut-chips row (reclaiming that height for the
            // grid) — hence the shorter drawer-specific inset, not the full
            // top-chrome inset the camera uses.
            topChromeInset: mapDrawerFullTopInset(context),
            hasResults: hasResults,
            halfFractionOverride: isWide ? kMapWideHalfFraction : null,
          );
          _metrics = metrics;

          // Seeded (chat) map: the drawer is BORN open at `half` — it loads
          // already showing the carousel, rather than animating open after
          // paint. Animating lost a race: the footer's first measure shifts
          // every snap fraction (empty seeded footer: 72 px default → 0), which
          // makes the SDK re-snap to the NEAREST stop — and mid-open, near the
          // bottom, that stop is `peek`, so the drawer snapped shut ("opens then
          // closes"). Born at `half`, the same re-snap is harmless: the nearest
          // stop to `half` IS `half`, so it stays open. Requires a real box +
          // resolved `half` stop (hasResults); in seeded mode both hold on frame
          // 1 (the seed selection is constant, the LayoutBuilder box is real).
          final seededOpen =
              ref.read(mapSeededModeProvider) &&
              hasResults &&
              metrics.fractionFor(MapDrawerSnap.half) > metrics.peek + _kEps;

          // Sync the snap PROVIDER to `half` once, so the map side-effects arm as
          // for a manual open: `map_screen._onDrawerSnapChanged` enters the
          // resultsHighlight session (carousel scroll lights the matching pin),
          // fires the entry analytics, and runs the one-shot fit-all camera move.
          // With the sheet already at `half`, `_command`'s animation is a no-op —
          // this is purely the provider write. It also serves as the fallback
          // open on the rare frame where `seededOpen` is false at birth (an
          // unlaid-out box), where the animation is what opens the drawer.
          if (seededOpen && !_seededDidOpen) {
            _seededDidOpen = true;
            _openSeededDrawer();
          }

          return DraggableScrollableSheet(
            controller: _sheet,
            initialChildSize: seededOpen ? metrics.half : metrics.peek,
            minChildSize: metrics.peek,
            maxChildSize: metrics.full,
            snap: true,
            snapSizes: _memoSnaps(metrics.snaps),
            // Our floor IS peek — there is no route to pop and nothing to close.
            shouldCloseOnMinExtent: false,
            builder: (context, scrollController) {
              if (!identical(_scroll, scrollController)) {
                if (_scrollListenerAttached) {
                  _scroll?.removeListener(_onScroll);
                }
                _scroll = scrollController;
                scrollController.addListener(_onScroll);
                _scrollListenerAttached = true;
              }
              return _buildSheet(
                metrics,
                scrollController,
                constraints.maxWidth,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSheet(
    MapDrawerMetrics metrics,
    ScrollController scrollController,
    double boxWidth,
  ) {
    // PROD-2993: wide viewports never show the carousel — the body is the grid at
    // every snap (`half` is just a shorter grid). Narrow keeps the carousel at
    // every snap except `full` (tracked by [_bodyIsCarousel]).
    final showCarousel = boxWidth < kMapWideDrawerMinWidth && _bodyIsCarousel;
    // PointerInterceptor shields the Mapbox HTML canvas on web so the sheet gets
    // its own drag/scroll pointers. It wraps the sheet CONTENT only — wrapping
    // the DraggableScrollableSheet would shield the whole map.
    return PointerInterceptor(
      child: DecoratedBox(
        // Shadow lives outside the clip so it isn't cut off.
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Color(0x1F44131D), // sokoInk @ 12%
              blurRadius: 20,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: ColoredBox(
            color: AppColors.sokoPaper,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ScrollConfiguration(
                    // Flutter's default dragDevices is touch-only, so without
                    // this the drawer drags on mobile but is dead to a desktop
                    // mouse. (Same fix as `ds_draggable_sheet.dart`.)
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: const {
                        PointerDeviceKind.touch,
                        PointerDeviceKind.mouse,
                        PointerDeviceKind.trackpad,
                        PointerDeviceKind.stylus,
                      },
                    ),
                    child: Listener(
                      onPointerSignal: _onPointerSignal,
                      // Track whether a finger is currently driving the sheet, so
                      // the settle debounce can't mistake a mid-drag pause for a
                      // settle and yank the sheet away. ScrollEnd fires once the
                      // ballistic (snap) simulation completes — that IS the settle.
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          // PROD-2993: the carousel at `half` scrolls
                          // HORIZONTALLY inside this same scroll view; its
                          // notifications bubble up here. Acting on them would
                          // read a sideways browse as a sheet drag. Only the
                          // sheet's own VERTICAL scroll drives the resize.
                          // (The carousel also consumes its own notifications,
                          // so this is belt-and-braces.)
                          if (n.metrics.axis != Axis.vertical) return false;
                          if (n is ScrollStartNotification) {
                            // Only a real FINGER drag flips `_isDragging`
                            // (dragDetails != null). A ballistic/programmatic
                            // scroll-start carries no dragDetails and — crucially
                            // — the sheet dispatches one from INSIDE
                            // `performLayout` when its content dimensions change
                            // (e.g. the grid resizing on a half<->full swap):
                            // `applyContentDimensions -> goBallistic ->
                            // didStartScroll`. Writing the drag provider there
                            // throws "modify a provider while building". A genuine
                            // finger drag can never originate mid-layout, so this
                            // gate is both the crash fix and the correct meaning
                            // of "a finger is on the drawer".
                            if (n.dragDetails != null) _isDragging = true;
                          } else if (n is ScrollEndNotification) {
                            _isDragging = false;
                            _onSettled();
                          }
                          return false;
                        },
                        child: CustomScrollView(
                          controller: scrollController,
                          physics: metrics.locked
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          slivers: [
                            // Rebuilt on every pixel of extent so the header can
                            // shed its count row continuously (PROD-3090).
                            //
                            // The listener sits INSIDE the sheet's builder on
                            // purpose: rebuilding here never re-runs
                            // `DraggableScrollableSheet.build`, so `_replaceExtent`
                            // is never re-entered and the identity-compared
                            // `snapSizes` can't fire a mid-drag re-snap (the trap
                            // [_snaps] exists to dodge). A proxy widget is
                            // transparent to the sliver protocol, so returning a
                            // sliver from here is legal.
                            ListenableBuilder(
                              listenable: _sheet,
                              builder: (context, _) => SliverPersistentHeader(
                                pinned: true,
                                delegate: _DrawerHeaderDelegate(
                                  collapseT: _headerCollapseT(),
                                  // Force-open via `_command` (not a bare provider
                                  // write): if the snap provider already reads
                                  // `half` while the sheet is actually at `peek`
                                  // (a desync), a plain write is a no-op and the
                                  // button does nothing — `_command` animates
                                  // regardless.
                                  onOpen: () => _command(MapDrawerSnap.half),
                                ),
                              ),
                            ),
                            // PROD-2993 (D21): the body is the horizontal
                            // carousel (every snap except `full`) or the vertical
                            // grid (`full`), cross-faded via [_bodyFade]. The
                            // AnimatedBuilder rebuilds only this sliver on each
                            // fade tick, never the DSS above it (same rule as the
                            // header — a proxy widget is transparent to the sliver
                            // protocol, so returning a sliver from here is legal).
                            AnimatedBuilder(
                              animation: _bodyFade,
                              builder: (context, _) => SliverOpacity(
                                opacity: _bodyFade.value,
                                sliver: showCarousel
                                    // A FIXED-height `SliverToBoxAdapter`,
                                    // deliberately NOT `SliverFillRemaining`: the
                                    // latter asserts in `performLayout` when its
                                    // child is a horizontal `ListView` (it can't
                                    // size to one), which showed as a blank drawer
                                    // on both platforms. Sized to exactly the hero
                                    // card + grid top pad; the footer overlay
                                    // covers the strip below. Shorter than the
                                    // sheet, so a vertical drag still over-scrolls
                                    // it and grows to `full`; horizontal drags are
                                    // the carousel's own.
                                    ? SliverToBoxAdapter(
                                        child: SizedBox(
                                          height:
                                              MapResultsCarousel.cardHeightFor(
                                                boxWidth,
                                              ) +
                                              kMapDrawerGridTopPadPx,
                                          child: const MapResultsCarousel(),
                                        ),
                                      )
                                    : SliverPadding(
                                        // Clear the pinned footer so the last row
                                        // of cards isn't stranded under it.
                                        padding: EdgeInsets.only(
                                          bottom: _footerHeight,
                                        ),
                                        sliver: const MapResultsGrid(),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // PROD-2993 (D36/D37) — the anchor-morph overlay: one card, ON
                // TOP of the cross-fading body, bridging the dip so the focused
                // card never blinks across half↔full. IgnorePointer — it's a
                // transient visual; taps fall through to the body/chrome below.
                // Only `left`/`top`/`width` animate; the card self-sizes height.
                if (_morph != null)
                  AnimatedBuilder(
                    animation: _morphCtrl,
                    // Rebuilds ONLY this one overlay card per frame (never the
                    // scrolling list), so it stays clear of the list-rebuild
                    // web-crash pattern. A controller (not AnimatedPositioned) so
                    // half→full can correct the target mid-flight — see
                    // [_scrollGridToFocused] — without restarting the tween.
                    builder: (context, child) {
                      final t = Curves.easeInOutCubic.transform(
                        _morphCtrl.value,
                      );
                      final r = Rect.lerp(_morphFrom, _morphTo, t)!;
                      return Positioned(
                        left: r.left,
                        top: r.top,
                        width: r.width,
                        child: child!,
                      );
                    },
                    child: IgnorePointer(
                      child: HighlightedShelfCard(
                        imageUrl: _morph!.imageUrl,
                        name: _morph!.name,
                        attribution: _morph!.attribution,
                        // No indexInShelf: keep the transient overlay neutral so
                        // it never fires the first-card peel hint that the real
                        // base card already owns.
                        itemType: _morph!.itemType,
                        recurrencePhase: _morph!.recurrencePhase,
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  // The footer is outside the scroll view, so the Scrollable's
                  // drag recognizer never sees these pointers — we forward them
                  // to the sheet ourselves. Safe: the only other recognizers here
                  // are MapFilterButtons' HORIZONTAL scroll (resolved by dominant
                  // axis) and button taps (a stationary tap beats a drag).
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: (_) => _isDragging = true,
                    onVerticalDragUpdate: _onFooterDragUpdate,
                    onVerticalDragEnd: _onFooterDragEnd,
                    onVerticalDragCancel: () => _isDragging = false,
                    child: MeasureSize(
                      onChange: _onFooterMeasured,
                      // Opaque: the grid scrolls UNDER the footer.
                      child: ColoredBox(
                        color: AppColors.sokoPaper,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Seeded (chat) map: no live filters — the footer
                            // collapses to nothing (the results are a fixed
                            // list). `mapSeededModeProvider` is a constant
                            // override, so `read` never rebuilds.
                            if (!ref.read(mapSeededModeProvider)) ...[
                              // Breathing room so the grid doesn't get cut flush
                              // against the footer's content — the grid scrolls
                              // UNDER this opaque band. Sits above the option row
                              // too, so an OPEN filter is separated from the grid
                              // just as the buttons are.
                              const SizedBox(height: kMapDrawerFooterTopGapPx),
                              // The open filter's option row — nothing when closed.
                              const MapFilterOptions(),
                              // Measured separately from the option row above: the
                              // map camera reserves only THIS (the resting chrome),
                              // so an open filter never re-frames the map.
                              //
                              // MapFilterButtons scrolls edge-to-edge (it owns its
                              // horizontal padding); only the bottom gap lives here.
                              MeasureSize(
                                onChange: _onButtonsMeasured,
                                child: const Padding(
                                  padding: EdgeInsets.only(bottom: 12),
                                  child: MapFilterButtons(),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // PROD-2993 — a grab strip over the drawer's TOP edge (the drag
                // handle). Like the footer detector it lives OUTSIDE the scroll
                // view, so a drag on it resizes the sheet DIRECTLY — regardless of
                // how far the grid is scrolled. Without it, collapsing from `full`
                // meant scrolling the grid all the way up first. Shown while the
                // drawer is OPEN (above `peek`) so it doesn't cover the `peek`
                // count-row button — BUT it stays mounted for the whole duration
                // of its OWN drag ([_edgeDragActive]) even once that drag reaches
                // `peek`. Otherwise dragging it to `peek` un-mounts the
                // `GestureDetector` mid-gesture, its `onVerticalDragEnd` never
                // fires, `_isDragging` sticks true, and the settle at `peek` is
                // skipped — so the drawer collapses but the snap provider never
                // reaches `peek` and the camera never restores.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: ListenableBuilder(
                    listenable: _sheet,
                    builder: (context, _) {
                      final open =
                          _edgeDragActive ||
                          (_sheet.isAttached &&
                              !_metrics.locked &&
                              _sheet.size > _metrics.peek + _kEps);
                      if (!open) return const SizedBox.shrink();
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragStart: (_) {
                          _edgeDragActive = true;
                          _isDragging = true;
                        },
                        // Reuses the footer's resize handlers — same physics:
                        // drag DOWN shrinks, UP grows, a flick snaps to the next
                        // stop.
                        onVerticalDragUpdate: _onFooterDragUpdate,
                        onVerticalDragEnd: (d) {
                          _edgeDragActive = false;
                          _onFooterDragEnd(d);
                        },
                        onVerticalDragCancel: () {
                          _edgeDragActive = false;
                          _isDragging = false;
                        },
                        // Transparent — the handle drawn by the pinned header
                        // shows through; this only adds the drag zone.
                        child: const SizedBox(
                          height: kMapDrawerTopGrabPx,
                          width: double.infinity,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pinned header: the drag handle, plus the "Ver N resultados" row *while
/// the drawer is closed*.
///
/// Pinned (not a plain adapter) so the handle survives at `full` — otherwise the
/// drawer's permanent grab surface would scroll out of reach exactly when it's
/// needed. Living inside the scroll view is what makes a drag on it resize the
/// sheet natively, with no gesture code of our own.
///
/// PROD-3090 — the height is now a function of [collapseT]: `24` (handle only)
/// once open, `72` at `peek`, and continuously in between. The count row is the
/// affordance to *open* the drawer; once open it says nothing the results below
/// it don't, so it hands its 48 px back to the map.
class _DrawerHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DrawerHeaderDelegate({required this.collapseT, required this.onOpen});

  /// 0 at `peek` (row fully shown) → 1 from `half` up (row fully shed).
  final double collapseT;

  /// Opens the drawer to `half` — routed through the sheet's `_command` so it
  /// works even when the snap provider is desynced from the sheet position.
  final VoidCallback onOpen;

  double get _height => mapDrawerHeaderHeight(collapseT);

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox(
    height: _height,
    child: _DrawerHeader(collapseT: collapseT, onOpen: onOpen),
  );

  // `onOpen` is intentionally NOT compared: it's a fresh closure each build but
  // always calls the sheet's current `_command`, so a stale one is still correct
  // — and comparing it (closures differ by identity) would rebuild every frame.
  @override
  bool shouldRebuild(covariant _DrawerHeaderDelegate oldDelegate) =>
      oldDelegate.collapseT != collapseT;
}

/// Kept a separate [ConsumerWidget] so that watching the count providers rebuilds
/// only this strip — not the whole sheet (which would churn the snap list and the
/// metrics on every settle).
class _DrawerHeader extends ConsumerWidget {
  const _DrawerHeader({required this.collapseT, required this.onOpen});

  final double collapseT;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused = ref.watch(mapFocusedClusterProvider);
    final count =
        focused?.members.length ??
        ref.watch(mapSettledSelectionProvider).visibleCount;
    final shown = (1 - collapseT).clamp(0.0, 1.0);

    return ColoredBox(
      color: AppColors.sokoPaper,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetDragHandle(),
          // Shrinks AND fades as the drawer opens, rather than being clipped —
          // `heightFactor` drives the height the delegate above already reserved,
          // so the two stay in lockstep and the grid glides up instead of jumping.
          // At `heightFactor: 0` the row has no box left to hit-test, so it also
          // stops being tappable once it's gone.
          ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: shown,
              child: Opacity(
                opacity: shown,
                // Held in the layout even at count == 0 (`maintainSize`) so the
                // peek height is stable from the first frame — the map camera
                // reserves this row from the very first fetch, and pins never land
                // behind it. Only painted + tappable once there are results.
                child: Visibility(
                  visible: count > 0,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: BtSqIco(
                      // Only ever seen at peek now, so it only ever points one
                      // way. Closing an open drawer is the handle / a swipe / an
                      // over-scroll / the desktop wheel.
                      icon: Icons.keyboard_arrow_up,
                      label: Lt.of(context).mapViewResultsCount(count),
                      variant: BtSqIcoVariant.idle,
                      expand: true,
                      onTap: onOpen,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
