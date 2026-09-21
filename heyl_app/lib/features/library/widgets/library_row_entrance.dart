import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/widgets/soko_chat_timings.dart';

/// Staggered row entrance. Restarts when [generation] changes; [SokoTurnEntrance] only plays once.
class LibraryRowEntrance extends StatefulWidget {
  const LibraryRowEntrance({
    super.key,
    required this.index,
    required this.generation,
    required this.child,
  });

  final int index;

  /// Change this to replay the entrance.
  final Object generation;

  final Widget child;

  static const int _staggerCap = 8;
  static const Duration _staggerStep = Duration(milliseconds: 45);

  static const Offset _beginOffset = Offset(0, 0.18);

  @override
  State<LibraryRowEntrance> createState() => _LibraryRowEntranceState();
}

class _LibraryRowEntranceState extends State<LibraryRowEntrance>
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
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _opacity = curve;
    _scale = Tween<double>(begin: 0.98, end: 1).animate(curve);
    _slide = Tween<Offset>(
      begin: LibraryRowEntrance._beginOffset,
      end: Offset.zero,
    ).animate(curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce-motion needs an inherited MediaQuery, so the first play is armed
    // here rather than in initState. Guarded so an unrelated dependency change
    // cannot restart a finished entrance.
    if (_controller.status == AnimationStatus.dismissed) _play();
  }

  @override
  void didUpdateWidget(LibraryRowEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generation != widget.generation) _play();
  }

  void _play() {
    _startTimer?.cancel();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.value = 1;
      return;
    }
    _controller.value = 0;
    final steps = widget.index < LibraryRowEntrance._staggerCap
        ? widget.index
        : 0;
    final delay = LibraryRowEntrance._staggerStep * steps;
    if (delay == Duration.zero) {
      unawaited(_controller.forward());
      return;
    }
    _startTimer = Timer(delay, () {
      if (mounted) unawaited(_controller.forward());
    });
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
