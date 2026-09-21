import 'dart:async';

import 'package:flutter/material.dart';

/// A one-shot "pop" entrance: a fade in + a springy scale that overshoots
/// slightly past its final size before settling (`easeOutBack`), played once
/// when the child first mounts. Used for detail-page tags that only appear
/// *after* the network detail hydrates (saves, rating) — they pop in over the
/// already-painted seed shell, drawing the eye to the freshly-arrived metadata.
///
/// Only wrap tags that are genuinely absent from the seed. The seed's own
/// kind/type/venue-type chips are present from the first frame, so wrapping
/// them would make them re-pop when the seed→detail swap remounts the body.
///
/// Honours reduce-motion (`MediaQuery.disableAnimations`): the child is shown
/// already settled, no animation.
class SokoPopIn extends StatefulWidget {
  const SokoPopIn({
    super.key,
    required this.child,
    this.startDelay = Duration.zero,
    this.duration = const Duration(milliseconds: 260),
    this.beginScale = 0.7,
  });

  final Widget child;

  /// Delay before the pop plays. Drives a staggered reveal when several pops
  /// share a row (e.g. rating then saves): pass an increasing delay per index.
  /// The child stays hidden (opacity 0) until the delay elapses.
  final Duration startDelay;

  final Duration duration;

  /// Scale the child starts at before overshooting past 1.0 and settling.
  final double beginScale;

  @override
  State<SokoPopIn> createState() => _SokoPopInState();
}

class _SokoPopInState extends State<SokoPopIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  Timer? _startTimer;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    // Opacity uses a plain easeOut (never overshoots); scale uses easeOutBack
    // for the springy overshoot past the final size.
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(
      begin: widget.beginScale,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve reduce-motion here (needs MediaQuery). Runs before first build.
    // Play exactly once across this State's lifetime.
    if (_started) return;
    _started = true;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _controller.value = 1;
      return;
    }
    if (widget.startDelay == Duration.zero) {
      unawaited(_controller.forward());
    } else {
      _startTimer = Timer(widget.startDelay, () {
        if (mounted) unawaited(_controller.forward());
      });
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: ScaleTransition(scale: _scale, child: widget.child),
  );
}
