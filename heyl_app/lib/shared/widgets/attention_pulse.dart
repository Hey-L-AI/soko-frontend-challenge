import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Wraps [child] in a repeating "breathe" — a gentle scale (1.0 ↔ [_maxScale])
/// plus a soft coloured glow halo behind it — to draw the eye to an action the
/// user hasn't taken yet (the onboarding "like at least one" nudge). Same
/// intent as the product-tour "tap here" pulse, packaged as a reusable wrapper.
///
/// Opt-in and default-inert: [enabled] false renders [child] verbatim with no
/// controller running, so shared callers that don't ask for it are unchanged.
/// When [enabled] flips true the pulse starts after [startDelay] (so it reads
/// as a *later* nudge, not part of the element's entrance). Honors
/// reduce-motion — under `MediaQuery.disableAnimations` the child renders static
/// with no halo, matching [OnboardingCardEntrance].
class AttentionPulse extends StatefulWidget {
  const AttentionPulse({
    super.key,
    required this.child,
    required this.enabled,
    this.glowColor = AppColors.sokoPink,
    this.startDelay = const Duration(seconds: 1),
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  final Widget child;

  /// When false the child renders unchanged and no animation runs. When true
  /// the breathe begins after [startDelay].
  final bool enabled;

  /// Tint of the soft halo behind the child.
  final Color glowColor;

  /// Delay from [enabled] becoming true (or from first build if already true)
  /// before the pulse starts.
  final Duration startDelay;

  /// Radius of the halo — match the wrapped element's own corner radius so the
  /// glow hugs its shape.
  final BorderRadius borderRadius;

  @override
  State<AttentionPulse> createState() => _AttentionPulseState();
}

class _AttentionPulseState extends State<AttentionPulse>
    with SingleTickerProviderStateMixin {
  // A restrained overshoot — enough to catch the eye on a 30×28 button without
  // reading as a bounce.
  static const _maxScale = 1.12;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _breathe = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  Timer? _startTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AttentionPulse old) {
    super.didUpdateWidget(old);
    if (widget.enabled != old.enabled) _sync();
  }

  /// Start or stop the breathe to match [widget.enabled] + reduce-motion.
  void _sync() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final shouldRun = widget.enabled && !reduceMotion;
    if (shouldRun) {
      if (_startTimer == null && !_controller.isAnimating) {
        _startTimer = Timer(widget.startDelay, () {
          _startTimer = null;
          if (mounted) _controller.repeat(reverse: true);
        });
      }
    } else {
      _startTimer?.cancel();
      _startTimer = null;
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Inert path: no wrapping widgets at all, so a non-highlighted card is
    // byte-for-byte the plain child.
    if (!widget.enabled) return widget.child;

    return AnimatedBuilder(
      animation: _breathe,
      child: widget.child,
      builder: (context, child) {
        final t = _breathe.value;
        final scale = 1.0 + (_maxScale - 1.0) * t;
        return Container(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            boxShadow: [
              BoxShadow(
                color: widget.glowColor.withValues(alpha: 0.55 * t),
                blurRadius: 4 + 8 * t,
                spreadRadius: 1 + 2 * t,
              ),
            ],
          ),
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}
