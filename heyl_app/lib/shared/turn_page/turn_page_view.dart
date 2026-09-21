// Vendored from `turn_page_transition` v0.5.0 (`lib/src/turn_page_view.dart`)
// so we can extend [TurnPageController] with [animateToPageWithSchedule], a
// per-flip-duration cascade that the upstream API doesn't expose — the
// inner `AnimationController` list, the schedule, and the cascade gap are
// all library-private in the package, so the only path is to vendor.
//
// Used by the zine view (`list_zine_view.dart`) to power the
// progress-line tap → forward/backward page-turn cascade described in
// PROD-1955. Other call sites (weekly bundle overlay) continue to use the
// pub package's `TurnPageView` / `TurnPageController` — they pick up the
// original via `package:turn_page_transition/turn_page_transition.dart`,
// while this library re-implements the same names in a separate scope so
// the two coexist.
//
// Kept as close to upstream as possible — only additions are
// [animateToPageWithSchedule] on [TurnPageController], a `_disposed`
// guard for cascade cancellation on dispose, and inlined constants
// (the upstream `src/const.dart` isn't re-exported on the public surface).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:turn_page_transition/turn_page_transition.dart'
    show TurnDirection, TurnPageAnimation;

// Inlined from `turn_page_transition/src/const.dart` (not re-exported on
// the package's public surface).
const Color _defaultOverleafColor = Colors.grey;
const Color _defaultOverleafBorderColor = Colors.black;
const double _defaultOverleafBorderWidth = 2.0;
const double _defaultAnimationTransitionPoint = 0.1;
const Duration _defaultTransitionDuration = Duration(milliseconds: 300);

final _defaultPageController = TurnPageController(initialPage: 0);
const _defaultThresholdValue = 0.3;

// PROD-1968: lazy controller + widget window. Only the active page ±
// [_defaultWindowRadius] is alive at any time. On a 357-page zine that
// drops controllers + cards from 357 → at most 5.
const int _defaultWindowRadius = 2;

/// The [TurnPageView] class is a widget likes [PageView] with a custom page transition animation.
class TurnPageView extends StatefulWidget {
  /// Creates a new pageable view with a turning page effect using the provided itemBuilder.
  /// The [itemCount] and [itemBuilder] parameters must not be null.
  TurnPageView.builder({
    super.key,
    TurnPageController? controller,
    required this.itemCount,
    required this.itemBuilder,
    this.overleafColorBuilder,
    this.overleafBorderColorBuilder,
    this.overleafBorderWidthBuilder,
    this.animationTransitionPoint = _defaultAnimationTransitionPoint,
    this.useOnTap = true,
    this.useOnSwipe = true,
    this.onSwipe,
    this.onTap,
    this.windowRadius = _defaultWindowRadius,
  }) : assert(itemCount > 0),
       assert(0 <= animationTransitionPoint && animationTransitionPoint < 1),
       assert(windowRadius >= 0),
       controller = controller ?? _defaultPageController;

  /// The controller used to interact with the TurnPageView.
  final TurnPageController controller;

  /// The total number of pages in the TurnPageView.
  final int itemCount;

  /// A builder function that returns the widget for each page.
  final IndexedWidgetBuilder itemBuilder;

  /// A builder function that returns the overleaf color for each page.
  final Color Function(int index)? overleafColorBuilder;

  /// A builder function that returns the overleaf border color for each page.
  /// If null, uses the default overleaf border color.
  final Color Function(int index)? overleafBorderColorBuilder;

  /// A builder function that returns the overleaf border width for each page.
  /// If null, uses the default overleaf border width.
  final double Function(int index)? overleafBorderWidthBuilder;

  /// The point that behavior of the turn-page-animation changes.
  /// This value must be 0 <= animationTransitionPoint < 1.
  final double animationTransitionPoint;

  /// Determines whether the TurnPageView should respond to tap events to change pages.
  final bool useOnTap;

  /// Determines whether the TurnPageView should respond to swipe events to change pages.
  final bool useOnSwipe;

  /// A callback functions than runs when swipe event ends.
  final Function(bool isTurnForward)? onSwipe;

  /// A callback functions than runs when tap event ends.
  final Function(bool isTurnForward)? onTap;

  /// PROD-1968: number of pages on each side of the active page to keep
  /// alive (controllers + widgets). Default 2 — at most 5 controllers /
  /// 5 [ListZineItemCard]s are mounted regardless of `itemCount`.
  final int windowRadius;

  @override
  State<TurnPageView> createState() => _TurnPageViewState();
}

class _TurnPageViewState extends State<TurnPageView>
    with TickerProviderStateMixin {
  // PROD-1968: pages alive in the current window. Keyed by page index,
  // mirrors `_animation._controllers`. Rebuilt by [_rebuildWindowPages]
  // whenever the controller window slides (via `onWindowChanged`).
  final Map<int, Widget> _pages = {};

  @override
  void initState() {
    super.initState();
    widget.controller
      .._animation = TurnAnimationController(
        vsync: this,
        initialPage: widget.controller.initialPage,
        itemCount: widget.itemCount,
        thresholdValue: widget.controller.thresholdValue,
        duration: widget.controller.duration,
        windowRadius: widget.windowRadius,
      )
      ..onTap = widget.onTap
      ..onSwipe = widget.onSwipe;
    // Propagate every animation tick (drag, single flip, cascade)
    // through the controller's ChangeNotifier so consumers using
    // `AnimatedBuilder(animation: controller, …)` rebuild at 60 FPS
    // and can read `controller.fractionalProgress` for sub-page
    // smoothness. PROD-1955.
    //
    // PROD-1968: tick listener now lives on `TurnAnimationController` as
    // a callback that's wired into every controller as it's allocated
    // by `_ensureWindow` — controllers come and go, but `onTick` stays
    // attached for the State's lifetime.
    widget.controller._animation.onTick = _onTick;
    widget.controller._animation.onWindowChanged = _handleWindowChanged;
    _rebuildWindowPages();
  }

  void _onTick() {
    widget.controller._notifyTickFromState();
  }

  /// PROD-1968: called by `_ensureWindow` after the window slides
  /// (new controllers allocated, stale ones marked for disposal).
  /// Rebuilds `_pages` to mirror the current controller set so the
  /// Stack only contains widgets backed by live AnimationControllers.
  void _handleWindowChanged() {
    if (!mounted) return;
    setState(_rebuildWindowPages);
  }

  /// PROD-1968: build a widget for each page index currently held in
  /// `_animation._controllers`; drop entries for indices that are no
  /// longer in the window. The widget tree is rebuilt in `build` from
  /// `_pages`, sorted descending so page 0 renders on top of the Stack
  /// (matches upstream z-order — newer/later pages are below).
  void _rebuildWindowPages() {
    final controllers = widget.controller._animation._controllers;
    // Build missing entries
    for (final pageIndex in controllers.keys) {
      _pages.putIfAbsent(pageIndex, () => _buildPage(pageIndex));
    }
    // Drop entries no longer in window
    _pages.removeWhere((index, _) => !controllers.containsKey(index));
  }

  Widget _buildPage(int pageIndex) {
    final animation = widget.controller._animation._controllers[pageIndex]!;
    final page = widget.itemBuilder(context, pageIndex);
    return AnimatedBuilder(
      key: ValueKey('turn-page-$pageIndex'),
      animation: animation,
      child: page,
      builder: (context, child) => TurnPageAnimation(
        animation: animation,
        overleafColor:
            widget.overleafColorBuilder?.call(pageIndex) ??
            _defaultOverleafColor,
        overleafBorderColor:
            widget.overleafBorderColorBuilder?.call(pageIndex) ??
            _defaultOverleafBorderColor,
        overleafBorderWidth:
            widget.overleafBorderWidthBuilder?.call(pageIndex) ??
            _defaultOverleafBorderWidth,
        animationTransitionPoint: widget.animationTransitionPoint,
        direction: widget.controller.direction,
        child: child ?? page,
      ),
    );
  }

  @override
  void didUpdateWidget(TurnPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // PROD-1968: propagate itemCount changes through to the animation
    // controller so `_ensureWindow` can clamp against the new bound.
    // The host currently swaps the whole TurnPageView via a changing
    // `ValueKey` on `pageCount`, so this branch is dead today — but it
    // lets the follow-up drop the host-side remount in favour of pure
    // in-place growth.
    if (oldWidget.itemCount != widget.itemCount) {
      widget.controller._animation.itemCount = widget.itemCount;
    }
    if (oldWidget.itemBuilder != widget.itemBuilder) {
      // Drop all cached widgets so they rebuild against the new builder.
      _pages.clear();
      _rebuildWindowPages();
    }
  }

  @override
  void dispose() {
    super.dispose();
    widget.controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    // Descending z-order: page 0 ends up on top of the Stack, matching
    // upstream `List.generate(itemCount, (i) => pageIndex = (itemCount - 1) - i)`.
    final indices = _pages.keys.toList()..sort((a, b) => b.compareTo(a));

    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onTapUp: (details) async {
          if (!widget.useOnTap) {
            return;
          }
          controller._onTapUp(details: details, constraints: constraints);
        },
        onHorizontalDragUpdate: (details) {
          if (!widget.useOnSwipe) {
            return;
          }
          controller._onHorizontalDragUpdate(
            details: details,
            constraints: constraints,
          );
        },
        onHorizontalDragEnd: (_) {
          if (!widget.useOnSwipe) {
            return;
          }
          controller._onHorizontalDragEnd();
        },
        child: Stack(children: [for (final i in indices) _pages[i]!]),
      ),
    );
  }
}

/// [TurnPageController] is responsible for managing the page state
/// and controlling the page-turning animation for [TurnPageView].
class TurnPageController extends ChangeNotifier {
  final int initialPage;

  /// The direction in which the pages are turned.
  final TurnDirection direction;

  /// The threshold value is used to determine whether a page turn should be
  /// completed or reverted based on the percentage of the swipe gesture.
  final double thresholdValue;

  /// The duration during which the page is turned.
  final Duration duration;

  TurnPageController({
    this.initialPage = 0,
    this.direction = TurnDirection.rightToLeft,
    this.thresholdValue = _defaultThresholdValue,
    this.duration = _defaultTransitionDuration,
  }) : assert(0 <= thresholdValue && thresholdValue <= 1);

  // The `windowRadius` from the [TurnPageView] is plumbed into the
  // animation controller at construction time inside `_TurnPageViewState.initState`.
  // Kept off the public surface of [TurnPageController] for now since
  // the host configures it via the widget, not the controller.

  void Function(bool isTurnForward)? onTap;

  void Function(bool isTurnForward)? onSwipe;

  late TurnAnimationController _animation;

  bool? _isTurnForward;

  /// Set to `true` inside [dispose] so an in-flight
  /// [animateToPageWithSchedule] cascade can bail out cleanly between
  /// flips instead of calling `animateTo` on a disposed
  /// `AnimationController` (which would throw).
  bool _disposed = false;

  int get currentIndex => _animation.currentIndex;

  /// PROD-1968: test-only window inspection. Returns the page indices
  /// of currently-allocated `AnimationController`s.
  @visibleForTesting
  Iterable<int> get debugAliveIndices => _animation._controllers.keys;

  /// PROD-1968: test-only window size. Same as `debugAliveIndices.length`
  /// but avoids materialising the iterable.
  @visibleForTesting
  int get debugAliveControllerCount => _animation._controllers.length;

  /// Bridges `_TurnPageViewState`'s per-tick animation listener into
  /// the public `ChangeNotifier` surface. `notifyListeners` is
  /// `@protected` so it can't be called from outside the subclass —
  /// this thin wrapper lives on the subclass itself and is accessed
  /// library-privately from the State.
  void _notifyTickFromState() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Sub-page-accurate progress, computed as the sum of every page
  /// controller's value (0.0–1.0). Returns the integer settled page
  /// when no animation is in flight, and a fractional value during
  /// drag / single flip / multi-page cascade. Use with
  /// `AnimatedBuilder(animation: controller, …)` for 60 FPS progress
  /// indicators. PROD-1955.
  ///
  /// Returns `currentIndex.toDouble()` if the underlying animation
  /// hasn't been mounted yet (controller created but TurnPageView not
  /// in the tree yet) or has been disposed — gracefully matches the
  /// integer index in those edge windows.
  double get fractionalProgress {
    if (_disposed) return currentIndex.toDouble();
    try {
      // PROD-1968: pages below the window are conceptually at value
      // 1.0 (already flipped); pages above the window are at 0.0 (not
      // yet visited). Only window-resident controllers contribute a
      // live value. windowStart counts the implicit-1.0 pages below.
      final radius = _animation.windowRadius;
      final windowStart = math.max(0, _animation.currentIndex - radius);
      var sum = windowStart.toDouble();
      for (final c in _animation._controllers.values) {
        sum += c.value;
      }
      return sum;
    } catch (_) {
      // `_animation` is `late` and only set once TurnPageView mounts.
      // Before that, fall back to the initial page.
      return initialPage.toDouble();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
    _animation.dispose();
  }

  /// Moves to the next page in the view.
  void nextPage() => _animation.turnNextPage();

  /// Moves to the previous page in the view.
  void previousPage() => _animation.turnPreviousPage();

  /// Animate to a specific page in the view.
  Future<void> animateToPage(int index) async {
    final diff = index - _animation.currentIndex;
    for (var i = 0; i < diff.abs(); i++) {
      diff >= 0 ? _animation.turnNextPage() : _animation.turnPreviousPage();
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Animate to [targetIndex] by chaining per-page flips with the supplied
  /// per-flip durations. Each flip is awaited, so flip N+1 starts the
  /// moment flip N finishes — a continuous riffle with no inter-flip gap.
  ///
  /// [schedule] must have exactly `|targetIndex - currentIndex|` entries.
  /// Direction (forward / backward) is inferred from the sign of the
  /// difference. A zero-length transition is a noop.
  ///
  /// Bails out cleanly if the controller is disposed mid-cascade (the
  /// in-flight `animateTo` completes via the ticker being canceled).
  Future<void> animateToPageWithSchedule(
    int targetIndex,
    List<Duration> schedule,
  ) async {
    if (_disposed) return;
    final start = _animation.currentIndex;
    final diff = targetIndex - start;
    if (diff == 0) return;
    final steps = diff.abs();
    if (schedule.length != steps) {
      throw ArgumentError(
        'animateToPageWithSchedule: schedule length (${schedule.length}) '
        'must match step count ($steps).',
      );
    }
    final forward = diff > 0;

    for (var i = 0; i < steps; i++) {
      if (_disposed) return;
      // Re-read the page controllers each iteration — `currentPage` /
      // `previousPage` resolve against the live `currentIndex` we mutate
      // at the end of the loop body.
      final pageCtrl = forward
          ? _animation.currentPage
          : _animation.previousPage;
      if (pageCtrl == null) break;

      try {
        if (forward) {
          await pageCtrl.animateTo(1.0, duration: schedule[i]);
        } else {
          await pageCtrl.animateTo(0.0, duration: schedule[i]);
        }
      } catch (_) {
        // Ticker disposed mid-animation (state unmounted) — exit
        // cleanly. The page-controllers we've already animated are
        // either fully on (1.0) or fully off (0.0); no half-state to
        // clean up.
        return;
      }
      if (_disposed) return;

      if (forward) {
        _animation.currentIndex++;
      } else {
        _animation.currentIndex--;
      }
      // PROD-1968: slide the controller window so the NEXT iteration's
      // `currentPage` / `previousPage` resolve to live controllers.
      // Without this the cascade would null-out at iteration windowRadius+1.
      _animation._ensureWindow(_animation.currentIndex);
      notifyListeners();
    }
  }

  /// Moves to a specific page in the view.
  void jumpToPage(int index) => _animation.jump(index);

  void _onTapUp({
    required TapUpDetails details,
    required BoxConstraints constraints,
  }) {
    final isLeftSideTapped =
        details.localPosition.dx <= constraints.maxWidth / 2;

    switch (direction) {
      case TurnDirection.rightToLeft:
        isLeftSideTapped ? previousPage() : nextPage();
        onTap?.call(!isLeftSideTapped);
        break;

      case TurnDirection.leftToRight:
        isLeftSideTapped ? nextPage() : previousPage();
        onTap?.call(isLeftSideTapped);
        break;
    }
  }

  void _onHorizontalDragUpdate({
    required DragUpdateDetails details,
    required BoxConstraints constraints,
  }) {
    final width = constraints.maxWidth;
    late final double delta;
    switch (direction) {
      case TurnDirection.rightToLeft:
        delta = -(details.primaryDelta ?? 0) / width;
        break;
      case TurnDirection.leftToRight:
        delta = (details.primaryDelta ?? 0) / width;
        break;
    }

    _isTurnForward ??= delta >= 0;
    final isTurnForward = _isTurnForward ?? delta >= 0;

    if (isTurnForward) {
      final currentPageController = _animation.currentPage;
      if (currentPageController == null) {
        return;
      }
      var updated = currentPageController.value + delta;
      if (updated <= 0.0) {
        updated = 0.0;
      } else if (updated >= 1.0) {
        updated = 1.0;
      }
      _animation.updateCurrentPage(updated);
      notifyListeners();
    } else {
      final previousPageController = _animation.previousPage;
      if (previousPageController == null) {
        return;
      }
      var updated = previousPageController.value + delta;
      if (updated <= 0.0) {
        updated = 0.0;
      } else if (updated >= 1.0) {
        updated = 1.0;
      }
      _animation.updatePreviousPage(updated);
      notifyListeners();
    }
  }

  void _onHorizontalDragEnd() {
    if (!_animation.thresholdExceeded) {
      _animation.reverse();
    } else {
      final isTurnForward = _isTurnForward;
      if (isTurnForward != null) {
        isTurnForward ? nextPage() : previousPage();
        onSwipe?.call(isTurnForward);
      }
    }

    _isTurnForward = null;
  }
}

const _animationMinValue = 0.0;
const _animationMaxValue = 1.0;

/// [TurnAnimationController] is responsible for managing the animation
/// of the [TurnPageView] widget.
///
/// PROD-1968: controllers are allocated lazily for a small window
/// around the active page (`current ± [windowRadius]`) instead of an
/// eager list sized to `itemCount`. On a 357-page zine this drops the
/// live `AnimationController` count from 357 → at most 5.
class TurnAnimationController {
  /// The index of the first page to display
  final int initialPage;

  /// The total number of pages in the TurnPageView.
  ///
  /// PROD-1968: mutable so the host can grow the pager in place when
  /// items append (PROD-1967's progressive tail fetch). Currently the
  /// host swaps the whole TurnPageView via a `ValueKey(pageCount)`
  /// remount as a safety net, but the setter is in place so the
  /// follow-up can drop the remount. Assumes monotonic growth — does
  /// not defend against shrinking below `currentIndex`.
  int _itemCount;
  int get itemCount => _itemCount;
  set itemCount(int v) {
    if (v == _itemCount) return;
    _itemCount = v;
    // Re-clamp the window against the new bound (and allocate any
    // newly in-range pages if itemCount grew above currentIndex + radius).
    _ensureWindow(currentIndex);
  }

  /// The threshold value is used to determine whether a page turn should be
  /// completed or reverted based on the percentage of the swipe gesture.
  final double thresholdValue;

  /// The duration during which the page is turned.
  final Duration duration;

  /// PROD-1968: number of pages on each side of `currentIndex` kept
  /// alive in `_controllers`. Total live count is at most
  /// `2 * windowRadius + 1` (5 by default).
  final int windowRadius;

  /// PROD-1968: keyed by page index. Only entries inside the current
  /// window exist — pages below the window are conceptually at 1.0
  /// (already flipped), pages above are at 0.0 (not yet visited).
  final Map<int, AnimationController> _controllers = {};

  final TickerProvider _vsync;

  /// PROD-1968: invoked after every animation tick on any live
  /// controller. Wired by `_TurnPageViewState` so the controller's
  /// `ChangeNotifier` (`TurnPageController`) fires at 60 FPS.
  /// Attached to each controller as `addListener(onTick)` in
  /// [_ensureWindow] as new entries are allocated.
  VoidCallback? onTick;

  /// PROD-1968: invoked after [_ensureWindow] mutates `_controllers`
  /// (allocations + evictions). The State uses this to rebuild its
  /// widget map so the Stack contains exactly the windowed pages.
  VoidCallback? onWindowChanged;

  int currentIndex;

  TurnAnimationController({
    required TickerProvider vsync,
    required this.initialPage,
    required int itemCount,
    required this.thresholdValue,
    required this.duration,
    this.windowRadius = _defaultWindowRadius,
  }) : _vsync = vsync,
       _itemCount = itemCount,
       currentIndex = initialPage {
    _ensureWindow(initialPage);
  }

  /// PROD-1968: slide the controller window to cover
  /// `[activeIndex - windowRadius, activeIndex + windowRadius]`
  /// clamped to `[0, itemCount - 1]`. Allocates missing entries,
  /// disposes ones that fell out. Disposal is deferred to the next
  /// post-frame so the in-tree `AnimatedBuilder`s have a chance to
  /// unmount before their animation handle goes away.
  void _ensureWindow(int activeIndex) {
    if (_itemCount == 0) return;
    final start = math.max(0, activeIndex - windowRadius);
    final end = math.min(_itemCount - 1, activeIndex + windowRadius);
    var changed = false;

    // Allocate missing controllers in window.
    for (var i = start; i <= end; i++) {
      if (_controllers.containsKey(i)) continue;
      final c = AnimationController(
        vsync: _vsync,
        duration: duration,
        // Initial value matches the conceptual "outside window" state
        // we just escaped: anything below currentIndex is fully flipped,
        // anything at or above is unflipped.
        value: i < currentIndex ? _animationMaxValue : _animationMinValue,
      );
      final tick = onTick;
      if (tick != null) c.addListener(tick);
      _controllers[i] = c;
      changed = true;
    }

    // Evict controllers that fell out of the window. Remove from the
    // map immediately so the State's rebuild won't include them, then
    // dispose after the next frame so any AnimatedBuilders pointing at
    // them have time to unmount.
    final stale = [
      for (final i in _controllers.keys)
        if (i < start || i > end) i,
    ];
    if (stale.isNotEmpty) {
      final toDispose = <AnimationController>[];
      for (final i in stale) {
        toDispose.add(_controllers.remove(i)!);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final c in toDispose) {
          c.dispose();
        }
      });
      changed = true;
    }

    if (changed) onWindowChanged?.call();
  }

  AnimationController? get previousPage =>
      currentIndex > 0 ? _controllers[currentIndex - 1] : null;

  AnimationController? get currentPage =>
      currentIndex < _itemCount - 1 ? _controllers[currentIndex] : null;

  bool get thresholdExceeded {
    final currentPage = this.currentPage;
    final previousPage = this.previousPage;
    return currentPage != null && currentPage.value >= thresholdValue ||
        previousPage != null && previousPage.value < (1 - thresholdValue);
  }

  bool get isNextPageNone => currentIndex + 1 >= _itemCount;

  bool get isPreviousPageNone => currentIndex - 1 < 0;

  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
  }

  Future<void> reverse() async {
    if (previousPage?.value != _animationMaxValue) {
      await previousPage?.animateTo(_animationMaxValue);
    }
    if (currentPage?.value != _animationMinValue) {
      await currentPage?.animateTo(_animationMinValue);
    }
  }

  void updateCurrentPage(double value) {
    if (isNextPageNone) {
      return;
    }
    currentPage?.value = value;
  }

  void updatePreviousPage(double value) {
    if (isPreviousPageNone) {
      return;
    }
    previousPage?.value = value;
  }

  Future<void> turnNextPage() async {
    if (isNextPageNone) {
      return;
    }
    currentPage?.animateTo(_animationMaxValue);
    currentIndex++;
    // PROD-1968: window slides forward — pre-allocates the new
    // current/next pages so the next flip / drag has live controllers.
    _ensureWindow(currentIndex);
  }

  Future<void> turnPreviousPage() async {
    if (isPreviousPageNone) {
      return;
    }
    previousPage?.animateTo(_animationMinValue);
    currentIndex--;
    _ensureWindow(currentIndex);
  }

  void jump(int index) {
    if (index == currentIndex) return;
    // PROD-1968: discard the current window entirely — every alloc'd
    // controller's value reflects its old position relative to the
    // OLD currentIndex; re-allocating around the new index sets each
    // new entry's initial value correctly (`i < currentIndex → 1.0,
    // else 0.0`). Deferred dispose so any in-tree AnimatedBuilders
    // get one frame to unmount.
    final old = _controllers.values.toList();
    _controllers.clear();
    if (old.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final c in old) {
          c.dispose();
        }
      });
    }
    currentIndex = index;
    _ensureWindow(currentIndex);
  }
}
