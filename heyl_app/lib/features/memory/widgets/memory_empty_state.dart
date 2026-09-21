import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

class MemoryEmptyState extends StatelessWidget {
  const MemoryEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(
              color: AppColors.sokoPink,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              LucideIcons.sparkles,
              size: 34,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            l10n.memoryEmptyTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.sokoInk,
              fontSize: 28,
              fontWeight: FontWeight.w300,
              height: 0.96,
              letterSpacing: -1,
              fontFamily: 'UnJamoBatang',
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.memoryEmptyBody,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.sokoShade3,
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.35,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.sokoInk,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
              shape: const StadiumBorder(),
            ),
            onPressed: () => context.go(AppRoutes.home),
            child: Text(
              l10n.memoryEmptyCta,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
