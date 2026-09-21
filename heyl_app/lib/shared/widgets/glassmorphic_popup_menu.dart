import 'dart:ui';

import 'package:flutter/material.dart';

/// A menu item for [GlassmorphicPopupMenu].
class GlassmorphicMenuItem<T> {
  final T value;
  final Widget child;
  final double height;
  final EdgeInsets padding;

  const GlassmorphicMenuItem({
    required this.value,
    required this.child,
    this.height = 40,
    this.padding = const EdgeInsets.symmetric(horizontal: 6),
  });
}

/// A popup menu with glassmorphic (frosted glass + blur) background.
///
/// Unlike [PopupMenuButton], this widget renders the popup in the nearest
/// [Overlay] with a [BackdropFilter], so the blur effect works correctly.
///
/// Usage:
/// ```dart
/// GlassmorphicPopupMenu<String>(
///   backgroundColor: Colors.white.withValues(alpha: 0.88),
///   border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
///   items: [
///     GlassmorphicMenuItem(value: 'a', child: Text('Option A')),
///     GlassmorphicMenuItem(value: 'b', child: Text('Option B')),
///   ],
///   onSelected: (value) => print(value),
///   child: Text('Open menu'),
/// )
/// ```
class GlassmorphicPopupMenu<T> extends StatefulWidget {
  final Widget child;
  final List<GlassmorphicMenuItem<T>> items;
  final ValueChanged<T>? onSelected;
  final Offset offset;
  final double blurSigma;
  final Color? backgroundColor;
  final BorderRadius borderRadius;
  final Border? border;
  final EdgeInsets menuPadding;
  final String? tooltip;

  /// Background painted on each menu row while the pointer hovers over it.
  /// Null falls back to [ThemeData.hoverColor]. Pass [Colors.transparent] to
  /// disable hover. The row's tap/onSelected callback is unaffected.
  final Color? hoverColor;

  /// Custom panel instead of a list of [items]. The panel stays open
  /// until `dismiss` is called (or the scrim is tapped). When non-null,
  /// [items] are ignored.
  final Widget Function(VoidCallback dismiss)? panelBuilder;

  const GlassmorphicPopupMenu({
    super.key,
    required this.child,
    this.items = const [],
    this.onSelected,
    this.offset = const Offset(0, 40),
    this.blurSigma = 20,
    this.backgroundColor,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.border,
    this.menuPadding = const EdgeInsets.symmetric(vertical: 4),
    this.tooltip,
    this.hoverColor,
    this.panelBuilder,
  });

  @override
  State<GlassmorphicPopupMenu<T>> createState() =>
      _GlassmorphicPopupMenuState<T>();
}

class _GlassmorphicPopupMenuState<T> extends State<GlassmorphicPopupMenu<T>>
    with WidgetsBindingObserver {
  OverlayEntry? _overlayEntry;
  final _triggerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _removeOverlay();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // Dismiss on window resize / rotation
    _removeOverlay();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _showMenu() {
    if (_overlayEntry != null) {
      _removeOverlay();
      return;
    }

    final renderBox =
        _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    // Resolve the trigger's position in the *overlay's* coordinate system.
    // `localToGlobal()` walks all the way to the root view, but the
    // `OverlayEntry`'s `Positioned(top: …)` paints relative to the nearest
    // [Overlay]'s render box — those origins disagree whenever the overlay
    // we're inserting into is nested below a Padding/Offset (e.g.
    // DiscoveryShell mounts a nested Navigator + Overlay *inside* a
    // `Padding(top: chromeReserved)` in the SCV; passing screen-global
    // coords leaves the menu floating `chromeReserved` px below the
    // trigger). Anchoring `localToGlobal` to the overlay's RenderBox keeps
    // both reference frames aligned.
    final overlayState = Overlay.of(context);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    final triggerPosition = renderBox.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final triggerSize = renderBox.size;
    // Use the overlay's logical size for left/right clamps so right-aligned
    // menus pin to the overlay's edge even when it doesn't span the full
    // screen.
    final overlaySize = overlayBox?.size ?? MediaQuery.of(context).size;

    final topBelow = triggerPosition.dy + triggerSize.height + widget.offset.dy;

    // Decide alignment based on trigger position:
    // Left-side triggers → left-align menu; right-side → right-align.
    final triggerCenter = triggerPosition.dx + triggerSize.width / 2;
    final isLeftSide = triggerCenter < overlaySize.width / 2;

    double? menuLeft;
    double? menuRight;
    if (isLeftSide) {
      menuLeft = (triggerPosition.dx + widget.offset.dx).clamp(
        8.0,
        overlaySize.width - 100,
      );
    } else {
      menuRight =
          (overlaySize.width -
                  (triggerPosition.dx + triggerSize.width) +
                  widget.offset.dx)
              .clamp(8.0, overlaySize.width - 100);
    }

    _overlayEntry = OverlayEntry(
      builder: (context) => _GlassmorphicMenuOverlay<T>(
        items: widget.items,
        panel: widget.panelBuilder?.call(_removeOverlay),
        onSelected: (value) {
          _removeOverlay();
          widget.onSelected?.call(value);
        },
        onDismiss: _removeOverlay,
        left: menuLeft,
        right: menuRight,
        top: topBelow,
        screenSize: overlaySize,
        blurSigma: widget.blurSigma,
        backgroundColor: widget.backgroundColor,
        borderRadius: widget.borderRadius,
        border: widget.border,
        menuPadding: widget.menuPadding,
        hoverColor: widget.hoverColor,
      ),
    );

    overlayState.insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    Widget trigger = GestureDetector(
      onTap: _showMenu,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(key: _triggerKey, child: widget.child),
      ),
    );

    if (widget.tooltip != null) {
      trigger = Tooltip(message: widget.tooltip!, child: trigger);
    }

    return trigger;
  }
}

/// The overlay content: scrim + positioned glassmorphic menu.
class _GlassmorphicMenuOverlay<T> extends StatelessWidget {
  final List<GlassmorphicMenuItem<T>> items;
  final Widget? panel;
  final ValueChanged<T> onSelected;
  final VoidCallback onDismiss;
  final double? left;
  final double? right;
  final double top;
  final Size screenSize;
  final double blurSigma;
  final Color? backgroundColor;
  final BorderRadius borderRadius;
  final Border? border;
  final EdgeInsets menuPadding;
  final Color? hoverColor;

  const _GlassmorphicMenuOverlay({
    required this.items,
    this.panel,
    required this.onSelected,
    required this.onDismiss,
    this.left,
    this.right,
    required this.top,
    required this.screenSize,
    required this.blurSigma,
    required this.borderRadius,
    required this.menuPadding,
    this.backgroundColor,
    this.border,
    this.hoverColor,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = backgroundColor ?? Colors.white.withValues(alpha: 0.88);

    return Stack(
      children: [
        // Tap-outside-to-dismiss scrim (transparent)
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        // Positioned menu
        Positioned(
          left: left,
          right: right,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: IntrinsicWidth(
              child: ClipRRect(
                borderRadius: borderRadius,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: blurSigma,
                    sigmaY: blurSigma,
                  ),
                  child: Container(
                    padding: menuPadding,
                    // Clip children to the rounded decoration so the
                    // first/last rows' hover background follows the
                    // menu's corner radius. Container defaults to
                    // `Clip.none`, which let the row paint a square
                    // rectangle inside the decoration's rounded edges,
                    // leaving a visible square "overhang" at the corners
                    // when those rows were hovered.
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: borderRadius,
                      border: border,
                    ),
                    child:
                        panel ??
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: items
                              .map(
                                (item) => _GlassmorphicMenuRow<T>(
                                  item: item,
                                  hoverColor: hoverColor,
                                  onTap: () => onSelected(item.value),
                                ),
                              )
                              .toList(),
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Single menu row with pointer-hover tracking. Wraps [item.child] in a
/// [MouseRegion] so we can paint [hoverColor] (or the theme's hover color
/// when not overridden) while the cursor is over the row. The row's
/// gesture detector still handles tap → [onTap].
///
/// Stretches horizontally (relies on the parent [Column] using
/// `CrossAxisAlignment.stretch`) so the hover background spans the menu's
/// full width regardless of the row's natural content width — keeps the
/// hover affordance visually crisp for shorter labels.
class _GlassmorphicMenuRow<T> extends StatefulWidget {
  final GlassmorphicMenuItem<T> item;
  final Color? hoverColor;
  final VoidCallback onTap;

  const _GlassmorphicMenuRow({
    required this.item,
    required this.hoverColor,
    required this.onTap,
  });

  @override
  State<_GlassmorphicMenuRow<T>> createState() =>
      _GlassmorphicMenuRowState<T>();
}

class _GlassmorphicMenuRowState<T> extends State<_GlassmorphicMenuRow<T>> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hoverColor = widget.hoverColor ?? Theme.of(context).hoverColor;
    // Animate alpha only: lerp from the hover color at α=0 → α=hoverColor.a
    // instead of from `Colors.transparent`. `Colors.transparent` is
    // `#00000000` (black with α=0), so a Color.lerp between it and a warm
    // tint passes through dark-RGB intermediate values, producing a visible
    // dark flash before the paper tint catches up. Sharing RGB between the
    // start and end colors makes only α move.
    final restingColor = hoverColor.withValues(alpha: 0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _hovering ? hoverColor : restingColor,
          padding: widget.item.padding,
          child: SizedBox(height: widget.item.height, child: widget.item.child),
        ),
      ),
    );
  }
}
