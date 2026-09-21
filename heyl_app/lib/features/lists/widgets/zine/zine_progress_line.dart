import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/soko_tooltip.dart';

/// Above this segment count the indicator switches from per-segment
/// tappable dots to a continuous scrubber-style bar. Two reasons
/// (PROD-1955):
///   1. With `Expanded` segments + a 4 px gap, ~40 dots is the
///      width budget on a phone — beyond that, segments collapse to
///      sub-pixel width and the row overflows.
///   2. Discrete dots stop being readable as individual pages once
///      there are too many of them — users perceive the bar as a
///      progress meter anyway.
const int _kContinuousBarThreshold = 30;

/// Vertical extent of the tap target (transparent padding around the
/// visible bar). Bar is vertically centred inside this height.
/// PROD-1955 sizing.
const double _kTapAreaHeight = 16;

/// Visible bar height when active OR hovered (interactive cue). All
/// other segments / the continuous bar at rest use [_kInactiveBarHeight].
const double _kEmphasisBarHeight = 8;

/// Visible bar height at rest (inactive segment / unhovered continuous
/// bar).
const double _kInactiveBarHeight = 2;

/// Corner radius of the progress bars. Same value regardless of bar
/// height — the bars read as slightly-rounded rectangles, not pills.
const double _kBarCornerRadius = 2;

/// Page-progress indicator that sits above each zine card and on the
/// in-list item detail screen.
///
/// **Discrete mode** ([totalSections] ≤ [_kContinuousBarThreshold]):
/// divided into [totalSections] segments (1 cover + N item pages); the
/// first [activeUpTo] segments render in the active color so the user
/// sees their cumulative progress through the list. The currently-active
/// segment (`activeUpTo - 1`) renders at 8 px visible height; the
/// others at 2 px. On mouse hover the segment under the cursor also
/// expands to 8 px and a "Page X" tooltip appears above it. Each
/// segment exposes a 16 px tall tap target (transparent vertical
/// padding around the bar) and a click pointer cursor when
/// interactive. Tapping a segment emits [onSegmentTap] with that
/// segment's 0-based index.
///
/// **Continuous mode** ([totalSections] > [_kContinuousBarThreshold]):
/// a single 2 px scrubber bar fills from left to right in proportion to
/// `activeUpTo / totalSections`. An 8 px round marker pip sits at the
/// fill edge so the active position remains visible. On mouse hover
/// the bar grows to 8 px and a "Page X" tooltip floats above the
/// cursor, previewing the destination page if the user clicks at that
/// x. On touch devices, **press-and-drag** along the bar shows the
/// same floating tooltip following the finger — release commits the
/// seek to wherever the finger landed (PROD-1968). A quick tap is
/// equivalent to press-and-release at the same x. Same 16 px tap target.
///
/// When [onSegmentTap] is null the indicator is purely visual (no
/// hover affordances, default cursor) — its prior behaviour.
class ZineProgressLine extends StatelessWidget {
  /// Total number of segments to draw — typically `items.length + 1`
  /// (cover + items).
  final int totalSections;

  /// 1-based, possibly-fractional count of pages "reached". Cover
  /// settled = 1.0, item index K settled = K + 2.0, halfway through
  /// the flip from K to K+1 = K + 1.5. The integer part drives which
  /// segment is active in discrete mode (`floor(activeUpTo) - 1`);
  /// the fractional part drives the continuous-mode fill width
  /// directly (`activeUpTo / totalSections`).
  final double activeUpTo;

  /// Called with the tapped segment index (0-based) when the user taps
  /// the indicator. In continuous mode this is a tap-to-seek (target
  /// derived from tap-x ratio). The caller is responsible for "tap on
  /// active = noop" and for blocking taps during in-flight transitions.
  final ValueChanged<int>? onSegmentTap;

  const ZineProgressLine({
    super.key,
    required this.totalSections,
    required this.activeUpTo,
    this.onSegmentTap,
  });

  @override
  Widget build(BuildContext context) {
    if (totalSections <= 1) return const SizedBox.shrink();
    final clamped = activeUpTo.clamp(0.0, totalSections.toDouble());
    // Figma `7660:27961`: the progress fill is Soko/Pink (#FFB8CB), not ink.
    // Inactive segments keep a faint ink hairline so the track stays visible
    // over paper (Figma's isolated export shows paper-on-paper, which would
    // read as an invisible track in-app).
    final activeColor = AppColors.sokoPink;
    final inactiveColor = AppColors.sokoInk.withValues(alpha: 0.12);
    final l10n = Lt.of(context);
    // Cover (segment 0) is NOT a numbered page — it gets its own
    // "Cover" tooltip. Item pages start at "Page 1" on segment 1.
    // PROD-1955.
    String tooltipFor(int segmentIndex) {
      if (segmentIndex == 0) return l10n.zineProgressLineCoverTooltip;
      return l10n.zineProgressLinePageTooltip(segmentIndex);
    }

    if (totalSections > _kContinuousBarThreshold) {
      return _ContinuousBar(
        totalSections: totalSections,
        activeUpTo: clamped,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        onSeek: onSegmentTap,
        tooltipFor: tooltipFor,
      );
    }
    // Discrete mode advances per-flip-completion: the "active" segment
    // = the floor of the integer part. Half-completed flips keep the
    // SOURCE segment active — the bar bump only moves once the new
    // page is fully revealed, which lines up with the natural feel of
    // a settled card.
    final filledCount = clamped.floor().clamp(0, totalSections);
    final activeIndex = filledCount - 1;
    return SizedBox(
      height: _kTapAreaHeight,
      child: Row(
        children: [
          for (var i = 0; i < totalSections; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: _Segment(
                isFilled: i < filledCount,
                isActive: i == activeIndex,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                tooltip: tooltipFor(i),
                onTap: onSegmentTap == null ? null : () => onSegmentTap!(i),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Segment extends StatefulWidget {
  final bool isFilled;
  final bool isActive;
  final Color activeColor;
  final Color inactiveColor;
  final String tooltip;
  final VoidCallback? onTap;

  const _Segment({
    required this.isFilled,
    required this.isActive,
    required this.activeColor,
    required this.inactiveColor,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    // The visible bar (`_kInactiveBarHeight` or `_kEmphasisBarHeight`)
    // is vertically centred inside a `_kTapAreaHeight` tap area. Hover
    // (web/desktop) bumps an inactive segment up to the emphasis height
    // to signal it's interactive; the active segment is already at the
    // emphasis height and stays put. `HitTestBehavior.opaque` ensures
    // the transparent padding around the bar still receives taps.
    final isInteractive = widget.onTap != null;
    final showLarge = widget.isActive || (isInteractive && _hovering);
    final barHeight = showLarge ? _kEmphasisBarHeight : _kInactiveBarHeight;
    final bar = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      height: barHeight,
      decoration: BoxDecoration(
        color: widget.isFilled ? widget.activeColor : widget.inactiveColor,
        borderRadius: BorderRadius.circular(_kBarCornerRadius),
      ),
    );
    final core = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: SizedBox(
        height: _kTapAreaHeight,
        child: Center(child: bar),
      ),
    );
    // No tooltip + no hover affordance when the indicator is purely
    // visual — keeps the cursor default and avoids ghost tooltips on
    // non-interactive cards.
    if (!isInteractive) return core;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onExit: (_) {
        if (_hovering) setState(() => _hovering = false);
      },
      child: SokoTooltip(message: widget.tooltip, child: core),
    );
  }
}

class _ContinuousBar extends StatefulWidget {
  final int totalSections;
  // Fractional — the fill width tracks this directly for sub-page
  // smoothness during cascades / drags.
  final double activeUpTo;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<int>? onSeek;
  final String Function(int segmentIndex) tooltipFor;

  const _ContinuousBar({
    required this.totalSections,
    required this.activeUpTo,
    required this.activeColor,
    required this.inactiveColor,
    required this.onSeek,
    required this.tooltipFor,
  });

  @override
  State<_ContinuousBar> createState() => _ContinuousBarState();
}

class _ContinuousBarState extends State<_ContinuousBar> {
  // x-coordinate of the mouse pointer inside the bar (null when the
  // pointer is not over the bar). Drives the hover tooltip position
  // and the bar-height expansion. Desktop-only.
  double? _hoverX;

  // x-coordinate of the active touch inside the bar (null when no
  // pointer is down). Mirrors `_hoverX` for touch devices: set on
  // press, updated during drag, cleared on release. PROD-1968 scope
  // creep — gives mobile users the same scrub-preview affordance
  // desktop already had via hover.
  double? _dragX;

  int _pageForX(double x, double width) {
    final ratio = (x / width).clamp(0.0, 1.0);
    return (ratio * (widget.totalSections - 1)).round().clamp(
      0,
      widget.totalSections - 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isInteractive = widget.onSeek != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // activeUpTo == currentIndex + 1, so dividing by totalSections
        // gives "fraction of pages reached" (page 0 → 1/N filled,
        // last page → fully filled). Marker pip sits at the right
        // edge of the fill so it tracks the current page.
        final fillRatio = widget.activeUpTo / widget.totalSections;
        final fillWidth = (width * fillRatio).clamp(0.0, width);
        // Pip matches the emphasis-bar height so the active position
        // remains visible at the same scale as a hovered segment in
        // discrete mode (8 px round dot).
        const pipDiameter = _kEmphasisBarHeight;
        // Pin the pip so it stays fully inside the bar even at the
        // extremes (otherwise half of it would render off-canvas).
        final pipLeft = (fillWidth - pipDiameter / 2).clamp(
          0.0,
          width - pipDiameter,
        );
        // Touch drag takes priority over hover — on a hybrid device
        // (Surface, iPad with mouse), the most recent active pointer
        // wins. Tooltip & bar emphasis both follow this combined value.
        final previewX = _dragX ?? _hoverX;
        final barHeight = (isInteractive && previewX != null)
            ? _kEmphasisBarHeight
            : _kInactiveBarHeight;
        final hoverPage = (isInteractive && previewX != null)
            ? _pageForX(previewX, width)
            : null;

        final core = SizedBox(
          height: _kTapAreaHeight,
          // `Clip.none` so the hover tooltip can paint above the bar
          // without being clipped by the SizedBox.
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerLeft,
            children: [
              // Inactive background bar — full width, vertically
              // centred inside the 8 px tap area.
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                height: barHeight,
                decoration: BoxDecoration(
                  color: widget.inactiveColor,
                  borderRadius: BorderRadius.circular(_kBarCornerRadius),
                ),
              ),
              // Filled portion — same height, anchored left.
              SizedBox(
                width: fillWidth,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: widget.activeColor,
                    borderRadius: BorderRadius.circular(_kBarCornerRadius),
                  ),
                ),
              ),
              // Active marker pip — 4 px circle sitting on top of the
              // bar at the fill edge. Same height as the active
              // segment in discrete mode so the visual language is
              // consistent.
              Positioned(
                left: pipLeft,
                child: Container(
                  height: pipDiameter,
                  width: pipDiameter,
                  decoration: BoxDecoration(
                    color: widget.activeColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              // Preview tooltip — floats above the touch / cursor x,
              // previewing the destination page. The anchored
              // [SokoTooltip] can't do per-x positioning (it hangs off
              // a single child widget), so we render the design-system
              // bubble directly via [SokoTooltipChip] inside this
              // Stack with `Clip.none` and centre it on `previewX`.
              // Same visual, same source of truth for hover (desktop)
              // and touch-drag (mobile).
              if (hoverPage != null && previewX != null)
                Positioned(
                  left: previewX,
                  top: -28,
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, 0),
                    child: SokoTooltipChip(label: widget.tooltipFor(hoverPage)),
                  ),
                ),
            ],
          ),
        );

        if (!isInteractive) return core;

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (event) {
            setState(() => _hoverX = event.localPosition.dx);
          },
          onExit: (_) {
            if (_hoverX != null) setState(() => _hoverX = null);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Show the preview tooltip on press. `onTapDown` fires
            // after `kPressTimeout` (~100 ms), which is acceptable —
            // matches the "press to invoke" feel of every other
            // Flutter button. For an actively-dragging gesture, the
            // tooltip appears at the first `onHorizontalDragStart`
            // instead (typically once the user has moved ~18 px,
            // Flutter's default horizontal pan slop).
            onTapDown: (d) {
              setState(() => _dragX = d.localPosition.dx);
            },
            // Tap (no slop exceeded) → commit and clear.
            onTapUp: (d) {
              final target = _pageForX(d.localPosition.dx, width);
              setState(() => _dragX = null);
              widget.onSeek!(target);
            },
            // The arena resolved tap → horizontal drag. The drag
            // handlers below re-set `_dragX` synchronously in the
            // same gesture frame, so the rebuild sees the new value
            // and there's no visible flicker. Intentionally no-op.
            onTapCancel: null,
            // `onHorizontalDrag*` instead of `onPan*` so VERTICAL
            // drags on the bar fall through to the parent scrollable
            // (the discovery-shell page scroller). Only horizontal
            // motion is claimed by the bar for scrubbing.
            //
            // Drag commits on release, NOT during motion — the host's
            // cascade-vs-jump heuristic in `_animateToPage` should
            // fire once, at the final target. While dragging,
            // `_dragX` only drives the local tooltip + bar emphasis.
            onHorizontalDragStart: (d) {
              setState(() => _dragX = d.localPosition.dx);
            },
            onHorizontalDragUpdate: (d) {
              setState(() => _dragX = d.localPosition.dx);
            },
            onHorizontalDragEnd: (_) {
              final dx = _dragX;
              setState(() => _dragX = null);
              if (dx != null) widget.onSeek!(_pageForX(dx, width));
            },
            // Pointer left the screen / system stole the gesture → no
            // seek, just clear the preview.
            onHorizontalDragCancel: () {
              if (_dragX != null) setState(() => _dragX = null);
            },
            child: core,
          ),
        );
      },
    );
  }
}
