import 'package:flutter/material.dart';

/// The shared overshoot curve: grow past 1.0 fast, then ease back to rest.
/// Used by the tap-driven [PressPop], the confirm-driven [PopOnActivate], and
/// any control that keeps its own gesture but wants the identical release pop
/// (e.g. `CircleIconButton`) — so every "pop" in the app feels the same.
Animation<double> popScale(AnimationController controller) {
  return TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.18,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 40,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.18,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 60,
    ),
  ]).animate(controller);
}

/// Tactile tap feedback for the detail action row. Shrinks slightly while held,
/// then — on release — pops (grows past 1.0, then settles) so a tap feels
/// physical instead of waiting on the network to fill a colour.
///
/// [pop] gates the release overshoot: `false` keeps only the press-shrink (the
/// Save cell, unchanged; and the reminder bell, which pops on *confirmation*
/// instead — see [PopOnActivate]). [onTap] fires on release, before the pop
/// finishes, so an optimistic state flip and the animation run together.
class PressPop extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool pop;

  const PressPop({
    super.key,
    required this.child,
    required this.onTap,
    this.pop = true,
  });

  @override
  State<PressPop> createState() => _PressPopState();
}

class _PressPopState extends State<PressPop>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _scale = popScale(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // MouseRegion → pointer cursor on web, so PressPop is a full drop-in for
    // `Clickable` (which callers used only for the cursor) plus the pop.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          if (widget.pop) _controller.forward(from: 0);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 120),
          // When pop is off the controller never runs, so this stays at 1.0.
          child: ScaleTransition(scale: _scale, child: widget.child),
        ),
      ),
    );
  }
}

/// Pops its child when [active] transitions false → true — the "confirmed"
/// beat. Used by the reminder bell: tapping only opens the picker, so the pop
/// (and the fill) should fire together once the reminder actually lands, not on
/// the tap. No pop on the initial build, or when [active] flips back to false.
class PopOnActivate extends StatefulWidget {
  final bool active;
  final Widget child;

  const PopOnActivate({super.key, required this.active, required this.child});

  @override
  State<PopOnActivate> createState() => _PopOnActivateState();
}

class _PopOnActivateState extends State<PopOnActivate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _scale = popScale(_controller);

  @override
  void didUpdateWidget(PopOnActivate old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scale, child: widget.child);
  }
}
