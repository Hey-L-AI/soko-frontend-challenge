import 'package:flutter/material.dart';

/// Defers building [child] until the enclosing route's **push transition has
/// finished** — i.e. until the shared-element Hero flight that carries the
/// detail poster has landed — then reveals it once with a fade + a short
/// upward slide.
///
/// **Why not just [SokoPopIn]?** `SokoPopIn` plays on *mount* and only *hides*
/// its child (opacity/scale) — the subtree is still built and laid out during
/// the flight. On the detail pages the below-hero content is a ~10-section
/// synchronous column that includes a live Mapbox instance; building it on the
/// first frames of the push is exactly what drops frames and makes the Hero
/// "snap" out of the card (PROD-4160-followup). This widget instead renders
/// [placeholder] (a cheap `SizedBox.shrink()` by default) for the whole flight,
/// so none of that cost lands on the flight frames, then builds + reveals the
/// content once the poster has settled — turning the old abrupt content pop
/// into an intentional staged reveal.
///
/// **How "settled" is detected:** it listens to `ModalRoute.of(context)!
/// .animation` and reveals when it reaches [AnimationStatus.completed]. That is
/// the route's own push animation — the same clock the Hero flight runs on
/// (`_detailPage` drives both), so it lands cross-platform (iOS Cupertino
/// slide, Android/web fade). When there is no push animation to wait on — a
/// bottom sheet, a cold deep-link with the transition already finished, an
/// onboarding preview, or a widget test — it reveals immediately (still
/// animating the entrance). Honours reduce-motion
/// (`MediaQuery.disableAnimations`): revealed already-settled, no animation and
/// no defer.
///
/// The reveal latches: once shown it stays shown, so the seed→hydrated-detail
/// rebuild (which reuses this State) never re-defers or re-plays.
class SokoRevealOnSettle extends StatefulWidget {
  const SokoRevealOnSettle({
    super.key,
    required this.child,
    this.placeholder = const SizedBox.shrink(),
    this.duration = const Duration(milliseconds: 280),
    this.slideUp = 12,
    this.curve = Curves.easeOutCubic,
  });

  /// The (potentially heavy) content revealed after the flight settles. NOT
  /// built until then — keep the flight target (the Hero poster) OUTSIDE this.
  final Widget child;

  /// Shown while waiting for the flight to land. Cheap by default; pass a
  /// sized box if the slot must reserve space during the flight.
  final Widget placeholder;

  /// Entrance duration (fade + slide).
  final Duration duration;

  /// Pixels the content rises through as it fades in.
  final double slideUp;

  final Curve curve;

  @override
  State<SokoRevealOnSettle> createState() => _SokoRevealOnSettleState();
}

class _SokoRevealOnSettleState extends State<SokoRevealOnSettle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curved;
  Animation<double>? _routeAnimation;
  bool _settled = false;
  bool _wired = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _curved = CurvedAnimation(parent: _controller, curve: widget.curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve the route/reduce-motion context once (needs an inherited
    // lookup). Runs before the first build. Play exactly once across this
    // State's lifetime.
    if (_wired) return;
    _wired = true;

    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      // Reveal already-settled, no animation. Set the flag directly (not via
      // setState) — build() runs immediately after this and reads it.
      _settled = true;
      _controller.value = 1;
      return;
    }

    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      // No push transition to wait on (sheet / deep-link / preview / test, or
      // it already finished before we mounted) — reveal now, still animating.
      _settled = true;
      _controller.forward();
      return;
    }

    // Wait for the push transition (== the Hero flight) to land.
    _routeAnimation = animation;
    animation.addStatusListener(_onRouteStatus);
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _detachRouteListener();
    if (!mounted || _settled) return;
    // Fires from an animation callback (not during build), so setState is safe.
    setState(() => _settled = true);
    _controller.forward();
  }

  void _detachRouteListener() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _routeAnimation = null;
  }

  @override
  void dispose() {
    _detachRouteListener();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_settled) return widget.placeholder;
    // At rest (t == 1) `Opacity` paints its child with no save-layer and the
    // translate is identity, so the wrapper is free once the entrance settles.
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        final t = _curved.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * widget.slideUp),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
