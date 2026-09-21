import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'detail_siblings.dart';

/// Wraps a detail body in a horizontal-swipe gesture detector that
/// navigates to the prev/next [DetailSibling] via `context.replace()`.
///
/// Conflict-free with the shell's vertical scroll because
/// [GestureDetector.onHorizontalDragEnd] only competes for horizontal
/// gestures in the arena. Edge-swipe-from-left (iOS pop) wins at the
/// screen edge, which is what we want.
///
/// Disabled (renders [child] only) when [siblings] is null or has fewer
/// than two items.
class SiblingSwipeNav extends StatelessWidget {
  final DetailSiblings? siblings;
  final Widget child;

  /// Minimum horizontal velocity (logical px / second) to count as a
  /// deliberate prev/next swipe.
  static const double _velocityThreshold = 250;

  const SiblingSwipeNav({
    super.key,
    required this.siblings,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final s = siblings;
    if (s == null || s.items.length <= 1) return child;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v.abs() < _velocityThreshold) return;
        // Swipe left (negative velocity) → next sibling.
        // Swipe right (positive velocity) → previous sibling.
        if (v < 0 && s.hasNext) {
          _go(context, s, s.currentIndex + 1);
        } else if (v > 0 && s.hasPrev) {
          _go(context, s, s.currentIndex - 1);
        }
      },
      child: child,
    );
  }

  void _go(BuildContext context, DetailSiblings siblings, int newIndex) {
    final next = siblings.withIndex(newIndex);
    context.replace(next.routeFor(next.current), extra: next);
  }
}
