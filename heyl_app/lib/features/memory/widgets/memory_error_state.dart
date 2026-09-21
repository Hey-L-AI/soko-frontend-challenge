import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

class MemoryErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const MemoryErrorState({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onRetry,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.sokoInk.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  LucideIcons.rotate_ccw,
                  size: 18,
                  color: AppColors.sokoShade3,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    l10n.memoryErrorRetry,
                    style: const TextStyle(
                      color: AppColors.sokoInk,
                      fontSize: 14,
                      fontWeight: FontWeight.w300,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
