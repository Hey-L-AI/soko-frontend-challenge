import 'package:flutter/material.dart';

import 'press_pop.dart';

/// Small circular icon button with press-scale + hover-scale feedback.
///
/// Promoted out of the action-bar's private widgets so other surfaces can
/// reuse the same 40 px chrome (e.g. the new `/lists` hub).
///
/// Renders either a Material/Lucide [icon] or, via [glyphBuilder], any widget —
/// which is how the Discovery feed draws the shared [SokoToggleGlyph] pairs
/// while keeping this circle. The circle is deliberately NOT shared with the
/// chat/onboarding thumb control (that one is a 30 px squared-corner half of a
/// two-up); only the glyph inside it is common to both.
class CircleIconButton extends StatefulWidget {
  /// Material/Lucide glyph. Mutually exclusive with [glyphBuilder].
  final IconData? icon;
  final Color background;
  final Color iconColor;
  final String semanticLabel;
  final VoidCallback onTap;

  /// Outer dimension of the button (width = height). Defaults to 40 px.
  final double size;

  /// Icon glyph size in logical px. Defaults to 14 (matches the action bar).
  final double iconSize;

  /// Builds the glyph instead of rendering [icon], receiving the button's live
  /// hover state.
  ///
  /// Exists so a surface can draw a Soko SVG toggle (see [SokoToggleGlyph])
  /// rather than a Material icon while keeping this chrome. The hover flag is
  /// passed through because the two-state glyphs fill on hover as well as on
  /// selection, and hover is owned privately by this widget — without it the
  /// caller could only ever paint the resting state.
  final Widget Function(bool hovered)? glyphBuilder;

  /// When true, releasing a tap plays the shared [popScale] overshoot — the
  /// same "pop" as the like/dislike/save controls elsewhere. Opt-in so neutral
  /// uses (nav/close) keep the plain press-only scale. Defaults to false.
  final bool popOnTap;

  /// Toggle state announced to assistive tech, when this button *is* a toggle.
  ///
  /// `null` — the default — leaves the semantics node a plain button, which is
  /// right for the nav/close/search uses that have no on-off state. A toggle
  /// must pass it: selection here is carried entirely by the glyph swapping
  /// outline→fill (D310), and a screen reader cannot see a glyph, so without
  /// this a saved card and an unsaved one announce identically.
  final bool? selected;

  const CircleIconButton({
    super.key,
    this.icon,
    required this.background,
    required this.iconColor,
    required this.semanticLabel,
    required this.onTap,
    this.size = 40,
    this.iconSize = 14,
    this.glyphBuilder,
    this.popOnTap = false,
    this.selected,
  }) : assert(
         (icon == null) != (glyphBuilder == null),
         'Provide exactly one of `icon` or `glyphBuilder`.',
       );

  @override
  State<CircleIconButton> createState() => _CircleIconButtonState();
}

class _CircleIconButtonState extends State<CircleIconButton>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  bool _isHovered = false;

  // Release-overshoot "pop" (shared curve), driven only when [popOnTap]. At
  // rest the controller sits at 0 → scale 1.0, so it's inert otherwise.
  late final AnimationController _popController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _popScale = popScale(_popController);

  @override
  void dispose() {
    _popController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // PROD-2145: hover scale dropped (was 1.08). The button's 40 px
    // circle paints inside a 40 px layout box, but the AnimatedSwitcher
    // ancestor in `CityActionBar` wraps children in `SizeTransition`,
    // which uses a `ClipRect` internally with no `clipBehavior` knob.
    // That ClipRect sliced flat edges off the scaled circle's bottom +
    // right. Background-color change on hover (below) already carries
    // the affordance — matches `BtSqIco`'s press-only scale pattern.
    final scale = _isPressed ? 0.95 : 1.0;
    Color effectiveBg = widget.background;
    if (_isPressed) {
      effectiveBg = Color.alphaBlend(
        widget.iconColor.withValues(alpha: 0.16),
        widget.background,
      );
    } else if (_isHovered) {
      effectiveBg = Color.alphaBlend(
        widget.iconColor.withValues(alpha: 0.10),
        widget.background,
      );
    }
    return Semantics(
      label: widget.semanticLabel,
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) {
            setState(() => _isPressed = false);
            if (widget.popOnTap) _popController.forward(from: 0);
            widget.onTap();
          },
          onTapCancel: () => setState(() => _isPressed = false),
          child: ScaleTransition(
            scale: _popScale,
            child: AnimatedScale(
              scale: scale,
              duration: const Duration(milliseconds: 150),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: effectiveBg,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child:
                      widget.glyphBuilder?.call(_isHovered) ??
                      Icon(
                        widget.icon,
                        size: widget.iconSize,
                        color: widget.iconColor,
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
