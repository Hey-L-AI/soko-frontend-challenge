import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:showcaseview/showcaseview.dart';

/// The Soko hand pointer that appears adjacent to a spotlight target
/// (PROD-2808). Rendered via `OverlayEntry` from `SpotlightTrigger` so it
/// tracks the target's actual position independently of where the
/// tooltip card lands.
///
/// Uses the same `assets/images/tour_hand.png` glyph the product tour
/// uses (`_CursorPointer` at `product_tour_host.dart:2126`). Natural
/// size 46×52, fingertip at asset-local `(15, 4)`. Bounces up-and-down
/// on a ~900 ms loop to draw the eye.
///
/// **Placement rule**: the hand sits on the OPPOSITE side of the target
/// from the tooltip card, so the two flank the target instead of
/// colliding. The side is derived from the card's ACTUAL on-screen rect
/// (resolved via [tooltipCardKey] each frame): if the card lands ABOVE the
/// target the hand goes BELOW (points up), and vice-versa.
///
/// Tracking the card's real rect — rather than the requested
/// [tooltipPosition] — is what keeps the two from colliding when
/// `showcaseview` AUTO-FLIPS the card past a screen edge. The trigger asks
/// for `TooltipPosition.bottom`, but for a target near the screen bottom
/// (e.g. the Profile tab in the bottom nav) there's no room below, so the
/// package flips the card ABOVE the target. A static side assumption then
/// puts the hand ABOVE too, landing it on the card's dismiss button
/// (PROD-3294). Reading the card's rect makes the flip a non-event.
///
/// [tooltipPosition] survives only as the FIRST-FRAME FALLBACK, used for
/// the frame or two before the card lays out and its rect is resolvable.
///   * `TooltipPosition.top` → fallback hand BELOW (un-rotated, pointing up)
///   * anything else → fallback hand ABOVE (rotated 180°, pointing down)
/// It must still match the value the trigger passes to `Showcase.withWidget`.
///
/// **Position tracking**: the target's rect is re-resolved via
/// [targetKey] on every animation frame (~60 Hz), so the hand tracks
/// the anchor when the surrounding content scrolls or the device
/// rotates. `findRenderObject` is cheap and the rebuild scope is just
/// the `Positioned` inside `AnimatedBuilder`. If the target unmounts
/// mid-flight, the overlay renders nothing until the parent removes
/// the `OverlayEntry` from the dismissal path.
class SpotlightHandOverlay extends StatefulWidget {
  const SpotlightHandOverlay({
    super.key,
    required this.targetKey,
    required this.tooltipCardKey,
    required this.tooltipPosition,
  });

  /// Attached to the target widget by `SpotlightTrigger` via a
  /// `KeyedSubtree`. Resolves to the target's `RenderBox` each frame so
  /// the hand can track scrolls and rotations.
  final GlobalKey targetKey;

  /// Attached to the tooltip card's visible `Container` by `SpotlightTrigger`.
  /// Resolves to the card's `RenderBox` each frame so the hand can take the
  /// side opposite wherever the card actually landed (robust to
  /// `showcaseview` auto-flip).
  final GlobalKey tooltipCardKey;

  /// First-frame fallback for the hand's side, used until [tooltipCardKey]
  /// resolves. As passed by `SpotlightTrigger` to `Showcase.withWidget`;
  /// must match that value so the transient frame matches the common
  /// (non-flipped) final placement.
  final TooltipPosition tooltipPosition;

  static const Size _handSize = Size(46, 52);

  /// Fingertip position in asset-local coordinates for the un-rotated
  /// asset (thumb up + fingertip near top-left third).
  static const Offset _fingertip = Offset(15, 4);

  /// Gap between the fingertip and the target's edge, in logical px.
  static const double _gap = 4;

  @override
  State<SpotlightHandOverlay> createState() => _SpotlightHandOverlayState();
}

class _SpotlightHandOverlayState extends State<SpotlightHandOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce;

  @override
  void initState() {
    super.initState();
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  Rect? _resolveTargetRect() => _resolveRect(widget.targetKey);

  /// The tooltip card's global rect, or null before it lays out. The card's
  /// entrance animation is a paint-time-only transform, so `localToGlobal`
  /// returns its final resting offset from the first attached frame — the
  /// flip side is knowable immediately.
  Rect? _resolveTooltipCardRect() => _resolveRect(widget.tooltipCardKey);

  Rect? _resolveRect(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return null;
    return ro.localToGlobal(Offset.zero) & ro.size;
  }

  @override
  Widget build(BuildContext context) {
    final handSize = SpotlightHandOverlay._handSize;

    // Build the raw asset once and reuse it inside the AnimatedBuilder
    // so `Image.asset` doesn't re-inflate on every animation tick.
    final handImage = Image.asset(
      'assets/images/tour_hand.png',
      width: handSize.width,
      height: handSize.height,
      fit: BoxFit.contain,
    );

    return AnimatedBuilder(
      animation: _bounce,
      builder: (context, _) {
        final rect = _resolveTargetRect();
        if (rect == null) {
          // Target unmounted or not yet attached — render nothing this
          // frame; next tick tries again. The trigger removes the whole
          // overlay on real dispose.
          return const SizedBox.shrink();
        }
        final fingertip = SpotlightHandOverlay._fingertip;
        final gap = SpotlightHandOverlay._gap;

        // pointsDown = hand renders ABOVE the target with fingertip
        // pointing DOWN at it. Take the side OPPOSITE the tooltip card:
        // when the card sits below the target the hand goes above, and
        // vice-versa. Reading the card's real rect keeps the two flanking
        // the target even when showcaseview auto-flips the card past a
        // screen edge (PROD-3294). Before the card lays out, fall back to
        // the requested `tooltipPosition` (`.left`/`.right` → above too).
        final cardRect = _resolveTooltipCardRect();
        final pointsDown = cardRect != null
            ? cardRect.center.dy > rect.center.dy
            : widget.tooltipPosition != TooltipPosition.top;

        late final double top;
        late final double left;
        if (pointsDown) {
          // Hand above target, rotated 180°. Rotated fingertip anchor:
          //   x' = handSize.width  - fingertip.dx  = 46 - 15 = 31
          //   y' = handSize.height - fingertip.dy  = 52 -  4 = 48
          top = rect.top - gap - (handSize.height - fingertip.dy);
          left = rect.center.dx - (handSize.width - fingertip.dx);
        } else {
          top = rect.bottom + gap - fingertip.dy;
          left = rect.center.dx - fingertip.dx;
        }

        // Bounce TOWARD the target: positive dy when hand is above,
        // negative when below.
        final curved = Curves.easeInOut.transform(_bounce.value);
        final delta = 4.0 * curved;
        final dy = pointsDown ? delta : -delta;

        return Positioned(
          left: left,
          top: top + dy,
          width: handSize.width,
          height: handSize.height,
          child: IgnorePointer(
            child: Transform.rotate(
              angle: pointsDown ? math.pi : 0,
              child: handImage,
            ),
          ),
        );
      },
    );
  }
}
