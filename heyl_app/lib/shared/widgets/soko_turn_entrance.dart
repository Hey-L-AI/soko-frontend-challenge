import 'dart:async';

import 'package:flutter/material.dart';

import 'soko_chat_timings.dart';

/// Per-turn entrance for Soko chat bubbles/lines: a fade + subtle scale
/// (0.98→1) + short slide over [sokoBubbleEntranceDuration], easeOutCubic.
/// When [animate] is false (history / resume / reduce-motion) the child is shown
/// already settled. Shared by the onboarding transcript and the main chat.
///
/// [beginOffset] is the slide's start position, as a fraction of the child's
/// size (the same units as [SlideTransition]). Defaults to a subtle upward
/// slide; pass a horizontal offset (e.g. `Offset(-0.06, 0)`) to have the newest
/// bubble slide in from its aligned side instead.
class SokoTurnEntrance extends StatefulWidget {
  const SokoTurnEntrance({
    super.key,
    required this.animate,
    required this.child,
    this.beginOffset = const Offset(0, 0.08),
    this.startDelay = Duration.zero,
  });

  final bool animate;
  final Widget child;
  final Offset beginOffset;

  /// Delay before the entrance plays. Drives a staggered reveal when several
  /// entrances share a parent (e.g. one-card-at-a-time in a chat carousel):
  /// pass an increasing delay per index. The child stays at its hidden start
  /// state (opacity 0) until the delay elapses.
  final Duration startDelay;

  @override
  State<SokoTurnEntrance> createState() => _SokoTurnEntranceState();
}

class _SokoTurnEntranceState extends State<SokoTurnEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide;
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: sokoBubbleEntranceDuration,
      value: widget.animate ? 0 : 1,
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _opacity = curve;
    _scale = Tween<double>(begin: 0.98, end: 1).animate(curve);
    _slide = Tween<Offset>(
      begin: widget.beginOffset,
      end: Offset.zero,
    ).animate(curve);

    if (widget.animate) {
      if (widget.startDelay == Duration.zero) {
        unawaited(_controller.forward());
      } else {
        _startTimer = Timer(widget.startDelay, () {
          if (mounted) unawaited(_controller.forward());
        });
      }
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
    child: SlideTransition(
      position: _slide,
      child: ScaleTransition(scale: _scale, child: widget.child),
    ),
  );
}
