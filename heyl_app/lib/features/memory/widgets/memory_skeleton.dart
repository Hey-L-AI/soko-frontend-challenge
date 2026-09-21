import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Three placeholder family blocks. Matches the populated layout's metrics
/// so the screen doesn't reflow when real data lands.
class MemorySkeleton extends StatelessWidget {
  const MemorySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
      itemCount: 3,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bar(width: 100, height: 12),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppColors.sokoInk.withValues(alpha: 0.08),
                ),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < 3; i++)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                      child: Row(
                        children: [
                          _bar(width: 28, height: 28, radius: 14),
                          const SizedBox(width: 12),
                          Expanded(child: _bar(width: 200, height: 14)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar({
    required double width,
    required double height,
    double radius = 6,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
