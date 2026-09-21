import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import 'feed_scroll_controller_scope.dart';

/// PROD-3122 — the floating "Mapa" entry point on Discovery, scroll-reactive.
///
/// At the top of the feed it renders as an **expanded pill** (map glyph +
/// label, Figma `7134-20567`, 141×60); once the user scrolls past
/// [_collapseThreshold] it contracts to an **icon-only circle** (glyph
/// centred, Figma `7134-20420`, 60×60). The transition is animation **A**:
/// the label cross-fades out while the pill contracts horizontally, so the
/// glyph settles to the centre. The button stays pinned bottom-centre by its
/// parent [Center]; only its own width + label opacity animate here.
///
/// It reads the shell's shared [ScrollController] from [ShellSliverScope] and
/// listens for offset changes. A hysteresis band (collapse above
/// [_collapseThreshold], re-expand only at/near the very top —
/// [_expandThreshold]) stops it flickering when the user hovers a single
/// threshold. Admin-gating + placement live at the call site
/// (`discovery_screen.dart`); this widget is presentation only.
class DiscoveryMapButton extends StatefulWidget {
  const DiscoveryMapButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  /// Localised label shown in the expanded state (`discoveryNavMapa`).
  final String label;

  /// Invoked on tap in either state (pushes `/map` at the call site).
  final VoidCallback onTap;

  @override
  State<DiscoveryMapButton> createState() => _DiscoveryMapButtonState();
}

class _DiscoveryMapButtonState extends State<DiscoveryMapButton>
    with SingleTickerProviderStateMixin {
  // Scroll offsets (logical px): expanded at/below [_expandThreshold],
  // collapsed above [_collapseThreshold]. The gap between them is the
  // hysteresis band that prevents state chatter around a single trigger point.
  static const double _expandThreshold = 4;
  static const double _collapseThreshold = 28;

  // Figma geometry (7134-20567 / 7134-20420). The glyph slot is a fixed box so
  // the pill (141) and circle (60) outer widths stay exact regardless of the
  // artwork. `_inset*` is the design distance from the OUTER edge to the
  // content; the 1-px border eats into it, so the Container's own padding is
  // `inset − border` (Container adds `border.dimensions` back on top):
  //   collapsed: 2×14.5 + 31            = 60
  //   expanded : 2×24   + 31 + (17+45)  = 141
  static const double _height = 60;
  static const double _glyphWidth = 31;
  static const double _glyphHeight = 24.47;
  static const double _labelGap = 17; // glyph → label
  static const double _labelFadeEdge = 18; // soft trailing-edge fade width
  static const double _borderWidth = 1;
  static const double _insetExpanded = 24;
  static const double _insetCollapsed = 14.5;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1, // assume top-of-feed (expanded) until the first scroll sync
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  ScrollController? _scroll;
  bool _expanded = true;
  bool _pressed = false;
  bool _hovered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // DiscoveryScreen provides the feed controller via FeedScrollControllerScope
    // (the button is a Positioned sibling of the feed scrollable, not a
    // descendant). Null off the Discovery feed / mid-transition — handled
    // defensively everywhere.
    final next = FeedScrollControllerScope.maybeOf(context);
    if (!identical(next, _scroll)) {
      _scroll?.removeListener(_onScroll);
      _scroll = next;
      _scroll?.addListener(_onScroll);
      // scroll_memory_observer restores a saved offset a frame after mount, so
      // sync the initial state post-frame — without animating — to avoid an
      // expand→collapse flash when returning to an already-scrolled feed.
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncInitial());
    }
  }

  void _syncInitial() {
    if (!mounted) return;
    final offset = _currentOffset();
    if (offset == null) return;
    final shouldExpand = offset <= _collapseThreshold;
    _expanded = shouldExpand;
    _controller.value = shouldExpand ? 1 : 0; // jump, no animation
  }

  /// Current scroll offset, or null if the controller has no live position.
  ///
  /// Never reads `ScrollController.offset`: during Navigator transitions the
  /// leaving + arriving pages both attach a [ScrollPosition], and `.offset`
  /// asserts when `positions.length != 1` (see `scroll_memory_observer.dart`).
  double? _currentOffset() {
    final c = _scroll;
    if (c == null || !c.hasClients) return null;
    final positions = c.positions;
    if (positions.isEmpty) return null;
    return positions.last.pixels;
  }

  void _onScroll() {
    final offset = _currentOffset();
    if (offset == null) return;
    if (_expanded && offset > _collapseThreshold) {
      _expanded = false;
      _controller.reverse();
    } else if (!_expanded && offset <= _expandThreshold) {
      _expanded = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _scroll?.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const ink = AppColors.sokoInk;

    // Hover / press lighten ONLY the background — a white overlay over the pink
    // (press a touch stronger than hover). Deliberately lighter, not darker:
    // an ink overlay would muddy the pink. Border / label / glyph are untouched.
    Color bg = AppColors.sokoPink;
    if (_pressed) {
      bg = Color.alphaBlend(Colors.white.withValues(alpha: 0.28), bg);
    } else if (_hovered) {
      bg = Color.alphaBlend(Colors.white.withValues(alpha: 0.16), bg);
    }

    return RepaintBoundary(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            widget.onTap();
          },
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? 0.96 : 1,
            duration: const Duration(milliseconds: 150),
            child: AnimatedBuilder(
              animation: _t,
              builder: (context, _) {
                final t = _t.value.clamp(0.0, 1.0);
                final inset =
                    _insetCollapsed + (_insetExpanded - _insetCollapsed) * t;
                // Label opacity is steep near fully-expanded and flat near
                // collapsed (ease-in cubic on t). That single shape gives the
                // asymmetric *feel* asked for: fading fast at the START of the
                // collapse (disappearing) and snapping back in only at the END
                // of the expand (reappearing). It's also ~0 well before the
                // width finishes contracting, so the text never hard-clips.
                final labelOpacity = Curves.easeInCubic.transform(t);
                // Trailing-edge fade exists ONLY while contracting: 0 at rest
                // (t=1) so the fully-expanded label is crisp to its natural
                // edge, ramping to the full soft edge over the first slice of
                // the collapse (by t≈0.85) to smother the clip boundary.
                final fadeEdge = (_labelFadeEdge * (1 - t) / 0.15).clamp(
                  0.0,
                  _labelFadeEdge,
                );
                return Container(
                  height: _height,
                  padding: EdgeInsets.symmetric(
                    horizontal: inset - _borderWidth,
                  ),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: ink.withValues(alpha: 0.10),
                      width: _borderWidth,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x1A291519),
                        offset: Offset(0, 4),
                        blurRadius: 3,
                        spreadRadius: -1,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _glyph(ink),
                      // The label region (gap + text) contracts horizontally
                      // (widthFactor) and cross-fades (opacity) in lock-step
                      // with the pill. The ShaderMask ramps the trailing edge to
                      // transparent over the last [_labelFadeEdge] px so the text
                      // dissolves into the pill instead of being sliced by a hard
                      // clip line; ClipRect still bounds any sub-pixel overflow.
                      ClipRect(
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (rect) =>
                              _labelEdgeFade(rect, fadeEdge),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: t,
                            child: Opacity(
                              opacity: labelOpacity,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(width: _labelGap),
                                  Text(
                                    widget.label,
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.clip,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w300,
                                      height: 1,
                                      letterSpacing: -0.36,
                                      color: ink,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // Right-edge fade for the collapsing label (applied via BlendMode.dstIn):
  // fully opaque across the region, ramping to transparent over its last
  // [_labelFadeEdge] px so the trailing glyph dissolves rather than meeting a
  // hard clip line. When the region is narrower than the fade zone (near the
  // collapsed circle, where the label is already ~invisible), the whole thing
  // fades — which also sidesteps a degenerate zero-width gradient.
  Shader _labelEdgeFade(Rect rect, double fadeEdge) {
    // No fade at rest (fully expanded) → label stays crisp to its natural edge.
    if (fadeEdge <= 0 || rect.width <= 0) {
      return const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [Colors.white, Colors.white],
      ).createShader(rect);
    }
    if (rect.width <= fadeEdge) {
      return const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [Colors.white, Colors.transparent],
      ).createShader(rect);
    }
    final start = (rect.width - fadeEdge) / rect.width;
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      stops: [0, start, 1],
      colors: const [Colors.white, Colors.white, Colors.transparent],
    ).createShader(rect);
  }

  // The Soko folded-map glyph (Figma 7134-20422). Shipped as a 3.4 KB
  // transparent PNG (128×105), NOT SVG: the source is a ~600-stamp scatter-brush
  // illustration that stays heavy and slow as vector (598 `<use>` nodes even
  // after SVGO). Rendered as an alpha silhouette and tinted to [ink] via srcIn
  // so it shares the label's colour token; the fixed 31×24.47 slot keeps the
  // pill/circle geometry exact regardless of the artwork's own aspect.
  Widget _glyph(Color ink) {
    return SizedBox(
      width: _glyphWidth,
      height: _glyphHeight,
      child: Image.asset(
        'assets/images/icons/discovery/map_button_glyph.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        color: ink,
        colorBlendMode: BlendMode.srcIn,
      ),
    );
  }
}
