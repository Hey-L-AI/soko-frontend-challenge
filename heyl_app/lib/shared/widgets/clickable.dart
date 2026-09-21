import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A widget that wraps its child with proper cursor behavior for web.
///
/// Shows a pointer cursor on hover when [onTap] is provided,
/// and a default cursor when disabled (onTap is null).
///
/// Use this instead of raw [GestureDetector] for consistent
/// cursor behavior across platforms.
class Clickable extends StatelessWidget {
  const Clickable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onDoubleTap,
    this.behavior = HitTestBehavior.opaque,
  });

  /// The widget to wrap.
  final Widget child;

  /// Called when the user taps this widget.
  final VoidCallback? onTap;

  /// Called when the user long-presses this widget.
  final VoidCallback? onLongPress;

  /// Called when the user double-taps this widget.
  final VoidCallback? onDoubleTap;

  /// How this gesture detector should behave during hit testing.
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) {
    final isEnabled =
        onTap != null || onLongPress != null || onDoubleTap != null;

    return MouseRegion(
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        onDoubleTap: onDoubleTap,
        behavior: behavior,
        child: child,
      ),
    );
  }
}
