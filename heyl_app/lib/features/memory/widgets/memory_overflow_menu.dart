import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

enum MemoryMenuAction { export, clearAll }

Future<MemoryMenuAction?> showMemoryOverflowMenu(
  BuildContext context, {
  required Offset anchor,
  required bool isEmpty,
}) async {
  final l10n = Lt.of(context);
  final size = MediaQuery.of(context).size;
  return showMenu<MemoryMenuAction>(
    context: context,
    color: AppColors.sokoPaper,
    elevation: 6,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: AppColors.sokoInk.withValues(alpha: 0.08)),
      borderRadius: BorderRadius.circular(14),
    ),
    position: RelativeRect.fromLTRB(
      size.width - anchor.dx - 200,
      anchor.dy,
      anchor.dx,
      size.height - anchor.dy,
    ),
    items: [
      PopupMenuItem<MemoryMenuAction>(
        value: MemoryMenuAction.export,
        enabled: !isEmpty,
        child: Row(
          children: [
            const Icon(
              LucideIcons.download,
              size: 18,
              color: AppColors.sokoInk,
            ),
            const SizedBox(width: 12),
            Text(
              l10n.memoryMenuExport,
              style: TextStyle(
                color: isEmpty ? AppColors.sokoShade3 : AppColors.sokoInk,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
      PopupMenuItem<MemoryMenuAction>(
        value: MemoryMenuAction.clearAll,
        enabled: !isEmpty,
        child: Row(
          children: [
            Icon(
              LucideIcons.trash_2,
              size: 18,
              color: isEmpty ? AppColors.sokoShade3 : const Color(0xFFA14A4A),
            ),
            const SizedBox(width: 12),
            Text(
              l10n.memoryMenuClearAll,
              style: TextStyle(
                color: isEmpty ? AppColors.sokoShade3 : const Color(0xFFA14A4A),
                fontSize: 14,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
