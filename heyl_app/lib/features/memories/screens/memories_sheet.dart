import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';

/// Memories sheet showing what L. has learned about the user
class MemoriesSheet extends ConsumerWidget {
  final ScrollController scrollController;

  const MemoriesSheet({
    super.key,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memoryState = ref.watch(memoryProvider);
    final itemsByCategory = memoryState.itemsByCategory;
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? AppColors.surfaceDark : AppColors.surface;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;

    return Container(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: borderColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.memoriesTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.memoriesSubtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
          ),

          // Update prompt
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _UpdatePrompt(),
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),

          // Content
          Expanded(
            child: memoryState.isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final category in MemoryCategory.values) ...[
                        if (itemsByCategory[category]?.isNotEmpty ?? false) ...[
                          _CategorySection(
                            category: category,
                            items: itemsByCategory[category]!,
                            onDelete: (item) => _deleteItem(context, ref, item),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteItem(BuildContext context, WidgetRef ref, MemoryItem item) async {
    if (item.index == null) return;
    final l10n = Lt.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.memoriesDeleteTitle),
        content: Text(l10n.memoriesDeleteContent(item.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.memoriesDeleteCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(l10n.memoriesDeleteConfirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(memoryProvider.notifier).deleteItem(item.index!);
    }
  }
}

class _UpdatePrompt extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final textTertiaryColor = isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: primaryColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.edit_note,
              color: primaryColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.memoriesUpdatePromptTitle,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                Text(
                  l10n.memoriesUpdatePromptSubtitle,
                  style: TextStyle(
                    color: textTertiaryColor,
                    fontSize: 12,
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

class _CategorySection extends StatelessWidget {
  final MemoryCategory category;
  final List<MemoryItem> items;
  final Function(MemoryItem) onDelete;

  const _CategorySection({
    required this.category,
    required this.items,
    required this.onDelete,
  });

  Color get _categoryColor {
    switch (category) {
      case MemoryCategory.location:
        return AppColors.memoryLocation;
      case MemoryCategory.preferences:
        return AppColors.memoryPreferences;
      case MemoryCategory.feedback:
        return AppColors.memoryFeedback;
    }
  }

  IconData get _categoryIcon {
    switch (category) {
      case MemoryCategory.location:
        return Icons.location_on_outlined;
      case MemoryCategory.preferences:
        return Icons.favorite_outline;
      case MemoryCategory.feedback:
        return Icons.thumb_up_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category header
        Row(
          children: [
            Icon(_categoryIcon, color: _categoryColor, size: 18),
            const SizedBox(width: 8),
            Text(
              '${category.displayName} (${items.length})',
              style: TextStyle(
                color: _categoryColor,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Items
        ...items.map((item) => _MemoryItemTile(
              item: item,
              color: _categoryColor,
              onDelete: () => onDelete(item),
            )),
      ],
    );
  }
}

class _MemoryItemTile extends StatelessWidget {
  final MemoryItem item;
  final Color color;
  final VoidCallback onDelete;

  const _MemoryItemTile({
    required this.item,
    required this.color,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textTertiaryColor = isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 40,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: SelectableText(
              item.text,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: Icon(
                Icons.close,
                size: 16,
                color: textTertiaryColor,
              ),
              onPressed: onDelete,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 24,
                minHeight: 24,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
