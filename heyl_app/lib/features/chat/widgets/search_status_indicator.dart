import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Animated search status indicator that shows pipeline progress text.
/// Replaces the generic TypingIndicator when search trace events arrive.
class SearchStatusIndicator extends StatefulWidget {
  final String text;

  const SearchStatusIndicator({super.key, required this.text});

  @override
  State<SearchStatusIndicator> createState() => _SearchStatusIndicatorState();
}

class _SearchStatusIndicatorState extends State<SearchStatusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bubble-free status — pulsing dot + label plain on the paper surface,
          // matching the typewriter Soko messages. Left-aligned with the Soko
          // text (no horizontal inset); small vertical padding for rhythm.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Pulsing dot
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, _) {
                    final opacity = 0.3 + 0.7 * _pulseController.value;
                    return Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppColors.sokoInk.withValues(alpha: opacity),
                        shape: BoxShape.circle,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 10),
                // Animated text crossfade
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      widget.text,
                      key: ValueKey(widget.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.sokoInk,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
