import 'package:flutter/material.dart';

/// The type of exit animation to play on a suggestion card.
enum SuggestionExitAnimation {
  /// Scale 1.0 → 0.85 + fade out, then collapse height.
  scaleFadeOut,

  /// Slide upward (Offset 0 → -1.5) + fade, then collapse height.
  flyUpward,

  /// Simultaneous height collapse + fade (no separate exit phase).
  collapseHeight,

  /// Slide right (Offset 0 → 1.2) + then collapse height.
  slideRight,
}

/// Animation orchestration wrapper for suggestion cards.
///
/// Wraps a child widget and manages exit animations triggered externally.
/// When [exitAnimation] is set, the animation plays and [onExitComplete]
/// is called when finished, allowing the parent to update provider state.
class AnimatedSuggestionCard extends StatefulWidget {
  final Widget child;
  final SuggestionExitAnimation? exitAnimation;
  final VoidCallback? onExitComplete;

  const AnimatedSuggestionCard({
    super.key,
    required this.child,
    this.exitAnimation,
    this.onExitComplete,
  });

  @override
  State<AnimatedSuggestionCard> createState() => _AnimatedSuggestionCardState();
}

class _AnimatedSuggestionCardState extends State<AnimatedSuggestionCard>
    with TickerProviderStateMixin {
  AnimationController? _exitController;
  AnimationController? _collapseController;
  bool _isAnimating = false;

  @override
  void didUpdateWidget(covariant AnimatedSuggestionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exitAnimation != null &&
        oldWidget.exitAnimation == null &&
        !_isAnimating) {
      _startExitAnimation(widget.exitAnimation!);
    }
  }

  Future<void> _startExitAnimation(SuggestionExitAnimation type) async {
    _isAnimating = true;

    switch (type) {
      case SuggestionExitAnimation.scaleFadeOut:
        await _animateScaleFadeOut();
      case SuggestionExitAnimation.flyUpward:
        await _animateFlyUpward();
      case SuggestionExitAnimation.collapseHeight:
        await _animateCollapseHeight();
      case SuggestionExitAnimation.slideRight:
        await _animateSlideRight();
    }

    widget.onExitComplete?.call();
  }

  Future<void> _animateScaleFadeOut() async {
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _collapseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    await _exitController!.forward();
    if (!mounted) return;
    await _collapseController!.forward();
  }

  Future<void> _animateFlyUpward() async {
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _collapseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    await _exitController!.forward();
    if (!mounted) return;
    await _collapseController!.forward();
  }

  Future<void> _animateCollapseHeight() async {
    // Single phase: simultaneous collapse + fade
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    // No separate collapse — uses exitController for both
    _collapseController = _exitController;

    await _exitController!.forward();
  }

  Future<void> _animateSlideRight() async {
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _collapseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    await _exitController!.forward();
    if (!mounted) return;
    await _collapseController!.forward();
  }

  @override
  void dispose() {
    // Only dispose collapse if it's a separate controller
    if (_collapseController != null &&
        _collapseController != _exitController) {
      _collapseController!.dispose();
    }
    _exitController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.exitAnimation;

    if (type == null || !_isAnimating) {
      // Not animating — render child with bottom padding
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: widget.child,
      );
    }

    // Build animated version based on type
    Widget animatedChild;

    switch (type) {
      case SuggestionExitAnimation.scaleFadeOut:
        animatedChild = _buildScaleFadeOut();
      case SuggestionExitAnimation.flyUpward:
        animatedChild = _buildFlyUpward();
      case SuggestionExitAnimation.collapseHeight:
        animatedChild = _buildCollapseHeight();
      case SuggestionExitAnimation.slideRight:
        animatedChild = _buildSlideRight();
    }

    return ClipRect(child: animatedChild);
  }

  Widget _buildScaleFadeOut() {
    final exitAnim = _exitController!;
    final collapseAnim = _collapseController!;

    final scale = Tween<double>(begin: 1.0, end: 0.85).animate(
      CurvedAnimation(parent: exitAnim, curve: Curves.easeOut),
    );
    final opacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: exitAnim, curve: Curves.easeOut),
    );
    final heightFactor = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: collapseAnim, curve: Curves.easeOut),
    );

    return AnimatedBuilder(
      animation: Listenable.merge([exitAnim, collapseAnim]),
      builder: (context, child) {
        return SizeTransition(
          sizeFactor: collapseAnim == exitAnim
              ? const AlwaysStoppedAnimation(1.0)
              : heightFactor,
          axisAlignment: -1.0,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FadeTransition(
              opacity: opacity,
              child: ScaleTransition(
                scale: scale,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFlyUpward() {
    final exitAnim = _exitController!;
    final collapseAnim = _collapseController!;

    final slideOffset =
        Tween<Offset>(begin: Offset.zero, end: const Offset(0, -1.5)).animate(
      CurvedAnimation(parent: exitAnim, curve: Curves.easeIn),
    );
    final opacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: exitAnim, curve: Curves.easeIn),
    );
    final heightFactor = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: collapseAnim, curve: Curves.easeOut),
    );

    return AnimatedBuilder(
      animation: Listenable.merge([exitAnim, collapseAnim]),
      builder: (context, child) {
        return SizeTransition(
          sizeFactor: collapseAnim == exitAnim
              ? const AlwaysStoppedAnimation(1.0)
              : heightFactor,
          axisAlignment: -1.0,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FadeTransition(
              opacity: opacity,
              child: SlideTransition(
                position: slideOffset,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCollapseHeight() {
    final anim = _exitController!;

    final opacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: anim, curve: Curves.easeOut),
    );
    final heightFactor = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: anim, curve: Curves.easeOut),
    );

    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) {
        return SizeTransition(
          sizeFactor: heightFactor,
          axisAlignment: -1.0,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FadeTransition(
              opacity: opacity,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }

  Widget _buildSlideRight() {
    final exitAnim = _exitController!;
    final collapseAnim = _collapseController!;

    final slideOffset =
        Tween<Offset>(begin: Offset.zero, end: const Offset(1.2, 0)).animate(
      CurvedAnimation(parent: exitAnim, curve: Curves.easeIn),
    );
    final opacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: exitAnim,
        curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
      ),
    );
    final heightFactor = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: collapseAnim, curve: Curves.easeOut),
    );

    return AnimatedBuilder(
      animation: Listenable.merge([exitAnim, collapseAnim]),
      builder: (context, child) {
        return SizeTransition(
          sizeFactor: collapseAnim == exitAnim
              ? const AlwaysStoppedAnimation(1.0)
              : heightFactor,
          axisAlignment: -1.0,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FadeTransition(
              opacity: opacity,
              child: SlideTransition(
                position: slideOffset,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}
