import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Adds [gap] below [child] — **unless the child laid out to nothing**, in
/// which case this contributes no space at all.
///
/// The problem it solves: a section that self-hides (returns
/// `SizedBox.shrink()` for one of its own states) leaves its neighbours to
/// guess. Padding the section from the outside then double-spaces the page
/// whenever it hides — the gap above it and the gap below it collapse into one
/// oversized gap with nothing between them, and nothing in the code says so.
///
/// A plain `Column` cannot express this: it spaces a zero-height child exactly
/// like any other. Nor can the parent read the child's state without duplicating
/// the child's own visibility rule, which is the thing that drifts.
///
/// So the decision is made where it is knowable — at layout, from the child's
/// measured height. The child stays the single source of truth about whether it
/// is on screen.
///
/// ```dart
/// TrailingGap(gap: 30, child: DailyDropSection(...))
/// ```
class TrailingGap extends SingleChildRenderObjectWidget {
  /// Space added below the child when the child has any height of its own.
  final double gap;

  const TrailingGap({
    super.key,
    required this.gap,
    required Widget super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderTrailingGap(gap);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTrailingGap renderObject,
  ) {
    renderObject.gap = gap;
  }
}

/// The render object behind [TrailingGap]. Public only because a private
/// type may not appear in `updateRenderObject`'s signature.
class RenderTrailingGap extends RenderShiftedBox {
  RenderTrailingGap(this._gap) : super(null);

  double _gap;

  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  /// The one rule, in one place: height zero stays height zero.
  Size _withGap(Size childSize) => childSize.height == 0
      ? childSize
      : Size(childSize.width, childSize.height + _gap);

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    (child.parentData! as BoxParentData).offset = Offset.zero;
    size = constraints.constrain(_withGap(child.size));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return constraints.constrain(_withGap(child.getDryLayout(constraints)));
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    final child = this.child;
    if (child == null) return 0;
    final h = child.getMinIntrinsicHeight(width);
    return h == 0 ? 0 : h + _gap;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    final child = this.child;
    if (child == null) return 0;
    final h = child.getMaxIntrinsicHeight(width);
    return h == 0 ? 0 : h + _gap;
  }
}
