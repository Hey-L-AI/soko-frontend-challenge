import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/page_layout.dart';

/// Wraps a zine card with desktop-only side-arrow chevrons rendered in
/// the page's outer gutter — the empty space outside `PageContent`'s
/// 480-px content column. Implemented with [OverlayPortal] so the
/// arrows can paint and receive pointer events outside the constrained
/// column without restructuring the parent layout.
///
/// Visibility:
/// - Mouse enters the card → fade in.
/// - Mouse moves card → gutter → arrow: a 220 ms hide-debounce keeps
///   the arrows visible during the transit, then either the arrow's
///   own [MouseRegion] cancels the hide (we land on the arrow) or it
///   fires (we left for good).
/// - Touch never fires `MouseRegion`, so the arrows never appear on
///   mobile-touch viewports — page navigation there happens via
///   card-only horizontal swipe.
class ZineSideArrows extends StatefulWidget {
  /// The card whose hover triggers the arrows. Rendered in place; the
  /// arrows live in the global [Overlay] and follow the card via a
  /// [LayerLink].
  final Widget child;

  /// Whether the LEFT arrow should mount.
  final bool showLeft;

  /// Whether the RIGHT arrow should mount.
  final bool showRight;

  /// Tap callback for the LEFT arrow.
  final VoidCallback? onPrev;

  /// Tap callback for the RIGHT arrow.
  final VoidCallback? onNext;

  const ZineSideArrows({
    super.key,
    required this.child,
    this.showLeft = false,
    this.showRight = false,
    this.onPrev,
    this.onNext,
  });

  @override
  State<ZineSideArrows> createState() => _ZineSideArrowsState();
}

class _ZineSideArrowsState extends State<ZineSideArrows> {
  /// Linked to the card; arrows in the overlay follow it.
  final LayerLink _link = LayerLink();

  /// Drives the overlay child mount/unmount. We keep the portal mounted
  /// the entire time the widget is alive (any side enabled) so the
  /// fade-in/out animation runs cleanly.
  final OverlayPortalController _portal = OverlayPortalController();

  bool _cardHovered = false;
  bool _arrowsHovered = false;

  /// Brief delay between losing card hover and hiding the arrows so the
  /// pointer can transit the gutter without the arrows blinking out.
  Timer? _hideTimer;

  bool get _visible => _cardHovered || _arrowsHovered;

  @override
  void initState() {
    super.initState();
    // Eagerly request the overlay. `OverlayPortalController.show()` is
    // safe to call before the controller attaches — it queues the
    // request, and the OverlayPortal picks it up on its first build.
    // Earlier we deferred this to a post-frame callback, but that
    // races with `AnimatedSwitcher`'s page transitions in
    // `ListZineView`: the new item page is mounted while the old cover
    // is still tearing down, and the post-frame call could land on a
    // widget that was already disposed mid-transition. Calling
    // synchronously avoids that window entirely.
    _portal.show();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    // Explicitly hide the overlay before tearing down so the
    // outgoing page (e.g. the cover during an `AnimatedSwitcher`
    // swap to an item) doesn't leak its arrows into the next page's
    // gutter while the new ZineSideArrows is mounting.
    if (_portal.isShowing) _portal.hide();
    super.dispose();
  }

  void _onCardEnter(_) {
    _hideTimer?.cancel();
    if (!_cardHovered) setState(() => _cardHovered = true);
  }

  void _onCardExit(_) => _scheduleHideCard();

  void _onArrowsEnter() {
    _hideTimer?.cancel();
    if (!_arrowsHovered) setState(() => _arrowsHovered = true);
  }

  void _onArrowsExit() => _scheduleHideArrows();

  void _scheduleHideCard() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _cardHovered = false);
    });
  }

  void _scheduleHideArrows() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _arrowsHovered = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.showLeft && !widget.showRight) return widget.child;

    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: _onCardEnter,
        onExit: _onCardExit,
        // Target the ROOT overlay (above all navigators) rather than
        // the nearest one. The cover worked with the nearest-overlay
        // variant, but item pages — mounted mid-`AnimatedSwitcher`
        // transition — failed to attach to whichever overlay
        // `OverlayPortal` resolved to from inside the transition's
        // FadeTransition + SlideTransition wrappers. Routing to the
        // root MaterialApp overlay sidesteps that lookup entirely.
        child: OverlayPortal(
          controller: _portal,
          overlayLocation: OverlayChildLocation.rootOverlay,
          overlayChildBuilder: (overlayContext) => _ArrowsOverlay(
            link: _link,
            showLeft: widget.showLeft,
            showRight: widget.showRight,
            visible: _visible,
            onPrev: widget.onPrev,
            onNext: widget.onNext,
            onArrowsEnter: _onArrowsEnter,
            onArrowsExit: _onArrowsExit,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Overlay child that renders the two arrow buttons positioned via
/// [CompositedTransformFollower] anchored to the card's outer edges,
/// pushed further out into the gutter by [_arrowGap].
///
/// Hidden on viewports below [PageLayout.desktopBreakpoint] — page
/// navigation there is touch-only (card-body swipe).
class _ArrowsOverlay extends StatelessWidget {
  final LayerLink link;
  final bool showLeft;
  final bool showRight;
  final bool visible;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback onArrowsEnter;
  final VoidCallback onArrowsExit;

  const _ArrowsOverlay({
    required this.link,
    required this.showLeft,
    required this.showRight,
    required this.visible,
    required this.onPrev,
    required this.onNext,
    required this.onArrowsEnter,
    required this.onArrowsExit,
  });

  @override
  Widget build(BuildContext context) {
    final viewportWidth = MediaQuery.of(context).size.width;
    if (viewportWidth < PageLayout.desktopBreakpoint) {
      return const SizedBox.shrink();
    }

    // Distance from the card's outer edge to the nearest edge of the
    // arrow — the followers are anchored to the card's centerLeft /
    // centerRight, so this is also the gap between card and arrow.
    const arrowGap = 28.0;

    return Stack(
      children: [
        if (showLeft)
          CompositedTransformFollower(
            link: link,
            // Without this, an unlinked follower paints at its offset
            // from (0,0), which puts the LEFT arrow off-screen at
            // viewport x = -arrowGap on the first frame after mount —
            // the cause of "no arrows on item pages" in the previous
            // build.
            showWhenUnlinked: false,
            targetAnchor: Alignment.centerLeft,
            followerAnchor: Alignment.centerRight,
            offset: Offset(-arrowGap, 0),
            child: _ArrowButton(
              visible: visible,
              rotated: false,
              onTap: onPrev,
              onEnter: onArrowsEnter,
              onExit: onArrowsExit,
            ),
          ),
        if (showRight)
          CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.centerRight,
            followerAnchor: Alignment.centerLeft,
            offset: Offset(arrowGap, 0),
            child: _ArrowButton(
              visible: visible,
              rotated: true,
              onTap: onNext,
              onEnter: onArrowsEnter,
              onExit: onArrowsExit,
            ),
          ),
      ],
    );
  }
}

class _ArrowButton extends StatelessWidget {
  static const String _arrowAsset =
      'assets/images/icons/detail/back-arrow.svg';

  /// Whether the parent says the arrow should be visible. Drives the
  /// fade-in/out and gates the click handler so an invisible arrow
  /// doesn't accept taps.
  final bool visible;

  /// Mirrors the chevron horizontally (the source asset points LEFT).
  final bool rotated;

  final VoidCallback? onTap;

  /// Fired when the pointer enters the arrow. Used by the parent to
  /// cancel the hide-debounce so the arrow stays visible while hovered.
  final VoidCallback onEnter;

  /// Fired when the pointer leaves the arrow.
  final VoidCallback onExit;

  const _ArrowButton({
    required this.visible,
    required this.rotated,
    required this.onTap,
    required this.onEnter,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    final chevron = SvgPicture.asset(
      _arrowAsset,
      width: 14,
      height: 14,
      colorFilter: ColorFilter.mode(
        AppColors.sokoInk.withValues(alpha: 0.85),
        BlendMode.srcIn,
      ),
    );
    // When invisible, ignore pointer events so the arrow's MouseRegion
    // can't keep itself "hovered" indefinitely just because the cursor
    // happens to drift through the gutter where the arrow lives. This
    // is the difference between "arrows visible only while card is
    // hovered" and "arrows latch on once shown" — the latter was the
    // bug behind the always-visible report.
    return IgnorePointer(
      ignoring: !visible,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onEnter(),
        onExit: (_) => onExit(),
        child: AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: visible ? onTap : null,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sokoShade5,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.sokoInk.withValues(alpha: 0.14),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: rotated
                    ? Transform.rotate(angle: math.pi, child: chevron)
                    : chevron,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
