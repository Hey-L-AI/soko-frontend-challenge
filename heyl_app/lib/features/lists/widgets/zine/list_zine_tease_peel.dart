import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/theme/app_colors.dart';

/// Decorative top-right corner peel that animates on a slow loop to
/// suggest the user can swipe to see the next page. Drawn entirely with
/// `CustomPaint` (does NOT drive the underlying `TurnPageView`
/// animation — the turn_page_transition package's controller doesn't
/// expose partial-progress publicly). When the user actually drags, the
/// real page-flip plays on top of this overlay.
///
/// Geometry deliberately mirrors the package's `_PageTurnClipper` at
/// low progress values (rightToLeft direction, animationTransitionPoint
/// 0.5 → vertical velocity 2): the peel triangle has its apex at the
/// top-right corner, one leg along the top edge (length `width * p`)
/// and one leg along the right edge (length `height * 2 * p`). At max
/// tease progress = [_maxRealFlipProgress] (~8% of a real flip) the
/// triangle is small but clearly readable as the start of a page-turn.
///
/// The overleaf (back of the lifted page) is plain Soko paper with no
/// fold outline, matching the live `TurnPageView` overleaf
/// (`list_zine_view.dart`) so the "tease at rest" → "active drag"
/// hand-off is seamless.
class ListZineTeasePeel extends StatefulWidget {
  /// Text rendered inside the peel area when the peel is large enough.
  /// Typically the page number / label of the next page being teased.
  /// Pass null on hosts (e.g. shelf cards) that don't want a label inside
  /// the peel — the geometry still renders, just without text.
  final String? nextLabel;

  /// Peak fraction of a real `TurnPageView` flip the peel reaches at
  /// progress=1.0. Defaults to 0.15 (the zine value — pronounced lift).
  /// Shelf cards pass a smaller value (~0.10) since their artwork tile
  /// is much smaller than a full zine page and a 0.15 peak would eat
  /// into the cover image too aggressively.
  final double peakRealFlipProgress;

  /// Optional peak used for the FIRST cycle on entry only. After one
  /// full ~6 s loop, the peel reverts to [peakRealFlipProgress] for
  /// every subsequent cycle. Null means every cycle uses
  /// [peakRealFlipProgress]. The zine cover page uses this for a more
  /// dramatic "open this" gesture on entry while keeping the looping
  /// hint subtle afterwards.
  final double? firstCyclePeakRealFlipProgress;

  /// Starting phase of the loop (0.0–1.0). Defaults to 0 (peel begins
  /// the moment the widget mounts). Hosts rendering many tease peels
  /// at once (e.g. a shelf of cards) should pass a per-instance value
  /// so the cards don't all peel in lockstep.
  final double initialProgress;

  /// Optional widget rendered BEHIND the peel, clipped to the lifted-
  /// away triangle. Use to actually expose what's "under" the page —
  /// e.g. the next item's hero photo on the zine cover. When null,
  /// the painter falls back to filling the lifted-away triangle with
  /// a solid neutral colour (back-compat for shelves and item pages).
  final Widget? underlay;

  const ListZineTeasePeel({
    super.key,
    this.nextLabel,
    this.peakRealFlipProgress = 0.15,
    this.firstCyclePeakRealFlipProgress,
    this.initialProgress = 0.0,
    this.underlay,
  }) : assert(peakRealFlipProgress > 0 && peakRealFlipProgress < 1),
       assert(
         firstCyclePeakRealFlipProgress == null ||
             (firstCyclePeakRealFlipProgress > 0 &&
                 firstCyclePeakRealFlipProgress < 1),
       ),
       assert(initialProgress >= 0 && initialProgress <= 1);

  @override
  State<ListZineTeasePeel> createState() => _ListZineTeasePeelState();
}

class _ListZineTeasePeelState extends State<ListZineTeasePeel>
    with SingleTickerProviderStateMixin {
  static const Duration _kPeriod = Duration(seconds: 6);

  late final AnimationController _controller;
  late final Animation<double> _peel;
  Timer? _phaseDelay;

  /// True once the first ~6 s cycle has elapsed. Used to swap from
  /// [ListZineTeasePeel.firstCyclePeakRealFlipProgress] (e.g. 0.25 on
  /// the zine cover) to the steady-state [ListZineTeasePeel.peakRealFlipProgress]
  /// (e.g. 0.15). Stays `false` forever when no first-cycle peak is set.
  bool _firstCycleDone = false;
  Timer? _firstCycleTimer;

  /// Stable key for the wrapping [VisibilityDetector]. Stored on the
  /// State so it survives widget rebuilds (the parent rebuilding the
  /// peel must NOT cause VisibilityDetector to re-register with a new
  /// key, which would cause it to miss visibility events).
  late final Key _visKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _kPeriod);
    // Cycle: peel out → brief hold → retract → long pause at rest.
    // Rest is at the END so the first cycle on mount begins with the
    // peel — the user sees the hint immediately on entering the zine
    // instead of staring at a static card for ~3s.
    // Total weight = 60. Distribution gives ~1.2s peel, ~0.6s hold,
    // ~1.2s retract, ~3s rest before the next cycle.
    _peel = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 12,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 6),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 12,
      ),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 30),
    ]).animate(_controller);
    // Phase offset: delay the FIRST call to `repeat()` by a fraction of
    // the period. Once each card's repeat() fires at its own wall-clock
    // time, the underlying simulation stays out of phase forever — no
    // mid-cycle resync. Can't use `_controller.value = X` after
    // `repeat()` because the value setter internally calls `stop()`,
    // freezing the controller at the offset (silent killer that left
    // shelf peels static).
    final delayMs = (widget.initialProgress * _kPeriod.inMilliseconds).round();
    if (delayMs <= 0) {
      _controller.repeat();
      _scheduleFirstCycleSwap();
    } else {
      _phaseDelay = Timer(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        _controller.repeat();
        _scheduleFirstCycleSwap();
      });
    }
  }

  /// Arm a one-shot timer to flip [_firstCycleDone] true after the
  /// first ~6 s cycle elapses, so the painter swaps from the dramatic
  /// first-cycle peak to the steady-state peak. Noop when the host
  /// didn't ask for a first-cycle peak — most callers (shelf cards,
  /// item pages) sit at one constant peak forever.
  void _scheduleFirstCycleSwap() {
    if (widget.firstCyclePeakRealFlipProgress == null) return;
    if (_firstCycleDone) return;
    _firstCycleTimer?.cancel();
    _firstCycleTimer = Timer(_kPeriod, () {
      if (!mounted) return;
      setState(() => _firstCycleDone = true);
    });
  }

  @override
  void dispose() {
    _phaseDelay?.cancel();
    _firstCycleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Pause the ticker when this peel is fully off-screen and resume
  /// when it returns. Avoids burning frames on rows that a `ListView`
  /// keeps alive within its `cacheExtent` but the user can't see.
  /// On resume we accept a phase reset (cards re-staggering naturally
  /// from their re-entry moment is fine; preserving the original hash
  /// phase isn't important after a visibility gap).
  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    if (info.visibleFraction == 0.0) {
      // `stop()` cancels the ticker but leaves `value` untouched —
      // painter still early-returns at rest, draws statically at peak.
      // Cancel any pending phase-offset Timer too so it doesn't
      // re-arm the ticker while we're off-screen.
      _phaseDelay?.cancel();
      _phaseDelay = null;
      _controller.stop(canceled: false);
    } else if (!_controller.isAnimating) {
      _phaseDelay?.cancel();
      _phaseDelay = null;
      _controller.repeat();
    }
  }

  /// Peak this frame uses — swaps from the first-cycle peak to the
  /// steady-state peak after one full ~6 s loop. Equivalent to a
  /// switch on `_firstCycleDone` plus a null-coalesce on the optional
  /// first-cycle override.
  double get _effectivePeak {
    final first = widget.firstCyclePeakRealFlipProgress;
    if (first == null || _firstCycleDone) return widget.peakRealFlipProgress;
    return first;
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: _visKey,
      onVisibilityChanged: _onVisibilityChanged,
      child: IgnorePointer(
        // RepaintBoundary isolates the per-tick CustomPaint repaints
        // from whatever sits behind us (cover photo, recipe stripe,
        // system badge). Without it, every peel frame would dirty the
        // parent layer and force the cover bitmap to re-rasterise.
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _peel,
            builder: (context, _) {
              final progress = _peel.value;
              final peak = _effectivePeak;
              final underlay = widget.underlay;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (underlay != null)
                    // Reveal the next page through the lifted-away
                    // triangle: clip the underlay widget (e.g. first
                    // item's hero photo on the cover) to the same
                    // triangle the painter would otherwise fill with
                    // a solid neutral.
                    ClipPath(
                      clipper: _PeelClipTriangleClipper(
                        progress: progress,
                        peak: peak,
                      ),
                      child: underlay,
                    ),
                  CustomPaint(
                    painter: _TeasePeelPainter(
                      progress: progress,
                      nextLabel: widget.nextLabel,
                      peakRealFlipProgress: peak,
                      // When an underlay is provided, the lifted-away
                      // triangle is "filled" by the clipped underlay
                      // widget behind us — skip the painter's solid
                      // fill so the underlay shows through.
                      drawClipFill: underlay == null,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Geometry of the peel's two triangles (lifted-away "clip" + folded-
/// into-card "overleaf") at a given [progress] and [peak]. Returns null
/// when the peel is too small to render. Shared between the painter and
/// the underlay clipper so both paint at exactly the same edge.
class _PeelGeometry {
  final Offset corner;
  final Offset foldUpper;
  final Offset foldLower;
  final Offset topCorner;

  const _PeelGeometry({
    required this.corner,
    required this.foldUpper,
    required this.foldLower,
    required this.topCorner,
  });

  static _PeelGeometry? compute(Size size, double progress, double peak) {
    if (progress <= 0) return null;
    final width = size.width;
    final height = size.height;
    // `2.0` = vertical velocity for animationTransitionPoint=0.5
    // (matches the package's `_PageTurnClipper`).
    final p = progress * peak;
    final w = width * p;
    final h = height * 2.0 * p;
    final w2 = w * w;
    final h2 = h * h;
    final denom = w2 + h2;
    if (denom == 0) return null;
    final intersectionX = (w * h2) / denom;
    final intersectionY = (w2 * h) / denom;
    return _PeelGeometry(
      corner: Offset(width, 0),
      foldUpper: Offset(width - w, 0),
      foldLower: Offset(width, h),
      topCorner: Offset(width - 2 * intersectionX, 2 * intersectionY),
    );
  }
}

/// Clips the underlay to the lifted-away triangle so what shows through
/// the peel is the underlay (e.g. next page's photo) instead of a
/// solid neutral fill.
class _PeelClipTriangleClipper extends CustomClipper<Path> {
  final double progress;
  final double peak;
  const _PeelClipTriangleClipper({required this.progress, required this.peak});

  @override
  Path getClip(Size size) {
    final g = _PeelGeometry.compute(size, progress, peak);
    if (g == null) return Path();
    return Path()
      ..moveTo(g.corner.dx, g.corner.dy)
      ..lineTo(g.foldUpper.dx, g.foldUpper.dy)
      ..lineTo(g.foldLower.dx, g.foldLower.dy)
      ..close();
  }

  @override
  bool shouldReclip(covariant _PeelClipTriangleClipper old) =>
      old.progress != progress || old.peak != peak;
}

class _TeasePeelPainter extends CustomPainter {
  final double progress;
  final String? nextLabel;
  final double peakRealFlipProgress;

  /// When true (default) the painter fills the lifted-away triangle
  /// with [_clipFill] (a solid neutral) — back-compat for hosts that
  /// don't provide an underlay widget. When false, the painter skips
  /// that fill so the host's underlay widget (clipped behind us via
  /// [_PeelClipTriangleClipper]) shows through instead.
  final bool drawClipFill;

  _TeasePeelPainter({
    required this.progress,
    required this.nextLabel,
    required this.peakRealFlipProgress,
    required this.drawClipFill,
  });

  /// Inset of the page-number label from the card's top-right corner.
  /// The label is rendered at a fixed position regardless of the peel
  /// progress, so it doesn't move or scale with the triangle.
  static const double _labelInsetRight = 14;
  static const double _labelInsetTop = 11;

  /// Fill for the corner clip-triangle — the part of the current
  /// page that's been "lifted away", revealing the page underneath.
  /// Uses the next card's background colour (`sokoShade5`) so it reads
  /// as the next item card peeking through the lifted corner. Only
  /// drawn when [drawClipFill] is true; when false, the host's
  /// underlay widget fills the same area via [_PeelClipTriangleClipper].
  static Color get _clipFill => AppColors.sokoShade5;

  @override
  void paint(Canvas canvas, Size size) {
    final g = _PeelGeometry.compute(size, progress, peakRealFlipProgress);
    if (g == null) return;

    // Two triangles sharing the fold line as their hypotenuse — together
    // they form a "kite" shape at the top-right corner:
    //   1. CLIP triangle (closer to the corner): the area of the
    //      current page that's been "lifted away", revealing the page
    //      underneath. Vertices: corner, foldUpper (on top edge),
    //      foldLower (on right edge). The page number sits inside this
    //      triangle.
    //   2. OVERLEAF triangle (rotated INTO the card): the back of the
    //      lifted page. Vertices: topFold = foldUpper, topCorner
    //      (inside the card area), bottomFold = foldLower. Filled with
    //      plain Soko paper and no outline.

    // Draw 1 — clip triangle (page-underneath fill). Skipped when the
    // host stacked an underlay widget behind us — that widget is
    // already clipped to this exact triangle.
    if (drawClipFill) {
      final clipPath = Path()
        ..moveTo(g.corner.dx, g.corner.dy)
        ..lineTo(g.foldUpper.dx, g.foldUpper.dy)
        ..lineTo(g.foldLower.dx, g.foldLower.dy)
        ..close();
      canvas.drawPath(clipPath, Paint()..color = _clipFill);
    }

    // Draw 2 — overleaf triangle (back of the lifted page). Plain Soko
    // paper with no border, so the switching page reads as a clean
    // sheet — matches the live `TurnPageView` overleaf
    // (`list_zine_view.dart`: sokoPaper fill, no outline).
    final overleafPath = Path()
      ..moveTo(g.foldUpper.dx, g.foldUpper.dy)
      ..lineTo(g.topCorner.dx, g.topCorner.dy)
      ..lineTo(g.foldLower.dx, g.foldLower.dy)
      ..close();
    canvas.drawPath(overleafPath, Paint()..color = AppColors.sokoPaper);

    final width = size.width;

    // Next-page label — pinned at a fixed offset from the top-right
    // corner. Doesn't move or scale with the peel triangle. Opacity
    // tracks the peel progress so the label fades in with the peel
    // and out as it retracts. Skipped entirely when null (e.g. shelf
    // cards — the peel reads as a visual hint without text).
    final label = nextLabel;
    if (label != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: AppColors.sokoInk.withValues(alpha: 0.45 * progress),
            fontSize: 12,
            fontFamily: 'SeasonMix',
            fontWeight: FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelOffset = Offset(
        width - _labelInsetRight - tp.width,
        _labelInsetTop,
      );
      tp.paint(canvas, labelOffset);
    }
  }

  @override
  bool shouldRepaint(_TeasePeelPainter old) =>
      old.progress != progress ||
      old.nextLabel != nextLabel ||
      old.peakRealFlipProgress != peakRealFlipProgress ||
      old.drawClipFill != drawClipFill;
}
