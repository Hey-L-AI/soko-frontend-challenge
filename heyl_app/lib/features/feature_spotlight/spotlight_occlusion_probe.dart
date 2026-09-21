import 'package:flutter/rendering.dart';

/// Answers "is this spotlight target overshadowed by anything right now?"
/// generically — without any occluder having to register itself.
///
/// The insight: a feature spotlight teaches an element the user is meant
/// to tap, so "is the target visible and on top" is the same question as
/// "would a tap at the target actually reach it." That's exactly what the
/// framework's hit test answers. We probe the target's own sample points;
/// if the front-most thing hit at a point is NOT the target (nor a
/// descendant of it) — because chrome covers it, it scrolled off screen,
/// or a header clips it — the target is overshadowed and the coach-mark
/// should defer (PROD-2964).
///
/// This replaces an occluder allow-list: any new tab, sheet, nav bar, or
/// banner is caught automatically the moment it's painted over a target.
/// Nothing has to know about the spotlight framework.
///
/// **Boundary — hit-test occlusion, not pixel occlusion.** This catches
/// occluders that participate in hit testing: interactive or opaque
/// widgets. A purely decorative overlay that lets touches pass through it
/// (an `IgnorePointer` film, a translucent gradient with no hit region)
/// visually covers the target while a hit sails through, so it is NOT
/// caught. For a "tap this" coach-mark that's the right trade —
/// reachability is what actually matters. It also assumes the target
/// itself hit-tests (all current spotlight targets are buttons); a
/// non-interactive target would read as overshadowed because a hit passes
/// through it to the background.
class SpotlightOcclusionProbe {
  const SpotlightOcclusionProbe._();

  /// Inset for the corner samples so a 1px border overlap with adjacent
  /// chrome doesn't trip the check.
  static const double _inset = 2.0;

  /// True when [target] is overshadowed at any of its sample points.
  /// [viewId] is the FlutterView the target is rendered into.
  static bool isOccluded(RenderBox target, int viewId) {
    // Can't resolve a rect this frame → don't block (fail-open): let the
    // normal flow decide rather than defer forever.
    if (!target.attached || !target.hasSize) return false;
    final rect = target.localToGlobal(Offset.zero) & target.size;
    for (final point in _samplePoints(rect)) {
      if (!_reaches(target, point, viewId)) return true;
    }
    return false;
  }

  static List<Offset> _samplePoints(Rect r) {
    const i = _inset;
    return <Offset>[
      r.center,
      Offset(r.left + i, r.top + i),
      Offset(r.right - i, r.top + i),
      Offset(r.left + i, r.bottom - i),
      Offset(r.right - i, r.bottom - i),
    ];
  }

  /// True when a hit test at [point] lands on [target] (or a descendant)
  /// as the front-most box — i.e. nothing is painted over the target
  /// there, and the point is on screen.
  static bool _reaches(RenderBox target, Offset point, int viewId) {
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(result, point, viewId);
    for (final entry in result.path) {
      final node = entry.target;
      if (node is! RenderBox) continue;
      // The first box in the path is the front-most painted at this point.
      return _isSelfOrDescendant(node, target);
    }
    return false; // nothing hit (off-screen / detached) → overshadowed
  }

  static bool _isSelfOrDescendant(RenderObject node, RenderObject ancestor) {
    RenderObject? n = node;
    while (n != null) {
      if (identical(n, ancestor)) return true;
      final parent = n.parent;
      n = parent is RenderObject ? parent : null;
    }
    return false;
  }
}
