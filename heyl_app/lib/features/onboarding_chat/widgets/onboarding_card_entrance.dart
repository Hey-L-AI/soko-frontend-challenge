import 'dart:async';

import 'package:flutter/material.dart';

import '../providers/onboarding_chat_controller.dart';

/// Staggered entrance for a single carousel card/cover: a fade + horizontal
/// slide + subtle scale, delayed by the card's position so a row cascades in
/// one card at a time instead of the whole batch appearing at once.
///
/// Reuses the transcript's bubble-entrance motion vocabulary
/// ([OnboardingChatController.bubbleEntranceDuration] + [Curves.easeOutCubic]).
/// Only the first [_staggerCap] cards stagger; cards past the cap — including
/// ones built lazily as the user scrolls the horizontal list — animate
/// immediately (delay 0), so a late card never sits invisible waiting its turn.
/// Honors reduce-motion by starting fully settled.
class OnboardingCardEntrance extends StatefulWidget {
  const OnboardingCardEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  static const _staggerCap = 6;
  static const _staggerStep = Duration(milliseconds: 70);

  @override
  State<OnboardingCardEntrance> createState() => _OnboardingCardEntranceState();
}

class _OnboardingCardEntranceState extends State<OnboardingCardEntrance>
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
      duration: OnboardingChatController.bubbleEntranceDuration,
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _opacity = curve;
    _scale = Tween<double>(begin: 0.98, end: 1).animate(curve);
    _slide = Tween<Offset>(
      begin: const Offset(0.06, 0),
      end: Offset.zero,
    ).animate(curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read reduce-motion here (needs an inherited MediaQuery). Guard against
    // re-runs so a dependency change can't restart a finished entrance.
    if (_controller.status != AnimationStatus.dismissed) return;
    if (MediaQuery.of(context).disableAnimations) {
      _controller.value = 1;
      return;
    }
    final steps = widget.index < OnboardingCardEntrance._staggerCap
        ? widget.index
        : 0;
    final delay = OnboardingCardEntrance._staggerStep * steps;
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      _startTimer = Timer(delay, () {
        if (mounted) _controller.forward();
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
    child: SlideTransition(
      position: _slide,
      child: ScaleTransition(scale: _scale, child: widget.child),
    ),
  );
}
