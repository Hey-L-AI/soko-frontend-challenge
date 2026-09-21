import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Animated typing indicator shown when AI is processing
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Calculate dot offset using sine wave for smooth up/down motion
  /// Each dot is phase-shifted to create a wave effect
  double _getDotOffset(int index, double animationValue) {
    // Phase shift each dot by 0.33 of the cycle (120 degrees)
    final phase = index * 0.33;
    // Use sine wave: goes smoothly from 0 → 1 → 0 → -1 → 0
    // We only want the positive part (0 → 1 → 0), so use sin and clamp
    final sineValue = math.sin((animationValue + phase) * 2 * math.pi);
    // Convert to 0-1 range (only upward motion)
    return sineValue > 0 ? sineValue : 0;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bubble-free animated dots — plain on the paper surface, matching the
          // typewriter Soko messages. Left-aligned with the Soko text (no
          // horizontal inset); small vertical headroom for the dots' bounce.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (index) {
                    final offset = _getDotOffset(index, _controller.value);
                    return Padding(
                      padding: EdgeInsets.only(right: index < 2 ? 4 : 0),
                      child: Transform.translate(
                        offset: Offset(0, -6 * offset),
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.sokoInk,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
