import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Callback delivering a widget's laid-out size.
typedef OnWidgetSizeChange = void Function(Size size);

/// Reports its child's rendered size via [onChange] whenever it changes.
///
/// A tiny proxy render box: it lays the child out exactly as a plain wrapper
/// would (no layout influence) and fires [onChange] — deferred to the next
/// post-frame so it's safe to mutate state / providers from inside — only when
/// the measured size actually changes. Used by the Map page to track the
/// content-sized results drawer's height so overlays can hug its top edge.
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({
    super.key,
    required this.onChange,
    required Widget super.child,
  });

  final OnWidgetSizeChange onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      MeasureSizeRenderObject(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    MeasureSizeRenderObject renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class MeasureSizeRenderObject extends RenderProxyBox {
  MeasureSizeRenderObject(this.onChange);

  OnWidgetSizeChange onChange;
  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();
    final newSize = child?.size ?? Size.zero;
    if (_oldSize == newSize) return;
    _oldSize = newSize;
    // Defer: performLayout runs during the layout phase, where synchronously
    // setting a provider / calling setState would throw.
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(newSize));
  }
}
