import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../utils/bottom_sheet_utils.dart';
import 'dashed_border_painter.dart';
import 'ds_sheet_shell.dart';

/// View-model for one row inside [ChatItemsPickerSheet]. Each caller maps
/// its own domain object (chat `CardItem`, IG-share `UserListItem`, …) to
/// this struct.
class PickerItem {
  const PickerItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.badgeLabel,
    this.defaultSelected = true,
  });

  /// Stable identifier surfaced back to the caller in the result set.
  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;

  /// Small inline pill rendered after the title (e.g. "Venue"). Null hides.
  final String? badgeLabel;

  /// Initial checked state on open.
  final bool defaultSelected;
}

/// Show the unified chat-items picker sheet. Used by:
///   - Chat "Create list" — pre-flight picker to choose which conversation
///     cards seed the new list.
///   - Instagram share review — choose which detected events/venues stay
///     in the target list.
///
/// Visual chrome mirrors [AddToListSheet] (PROD-1861): pink banner header
/// with the drag handle inside, dashed/solid-bordered rows, sticky pink
/// CTA footer. The reconciliation logic stays with the caller — this sheet
/// just returns the selected ids.
///
/// Returns the set of selected ids on confirm, `null` on dismiss.
Future<Set<String>?> showChatItemsPickerSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String title,
  required String subtitle,
  required String ctaLabel,
  required List<PickerItem> items,
}) {
  return showBottomSheetWithHiddenNav<Set<String>>(
    context: context,
    ref: ref,
    builder: (_) => ChatItemsPickerSheet(
      title: title,
      subtitle: subtitle,
      ctaLabel: ctaLabel,
      items: items,
    ),
  );
}

class ChatItemsPickerSheet extends StatefulWidget {
  const ChatItemsPickerSheet({
    super.key,
    required this.title,
    required this.subtitle,
    required this.ctaLabel,
    required this.items,
  });

  final String title;
  final String subtitle;
  final String ctaLabel;
  final List<PickerItem> items;

  @override
  State<ChatItemsPickerSheet> createState() => _ChatItemsPickerSheetState();
}

class _ChatItemsPickerSheetState extends State<ChatItemsPickerSheet> {
  late final Set<String> _selected = {
    for (final item in widget.items)
      if (item.defaultSelected) item.id,
  };

  void _toggle(PickerItem item) {
    setState(() {
      if (_selected.contains(item.id)) {
        _selected.remove(item.id);
      } else {
        _selected.add(item.id);
      }
    });
  }

  void _onConfirm() {
    Navigator.of(context).pop<Set<String>>(Set<String>.from(_selected));
  }

  @override
  Widget build(BuildContext context) {
    return DSSheetShell(
      // Drag handle hosted inside the pink header so the top edge of the
      // sheet is fully pink — matches the AddToListSheet treatment.
      showDragHandle: false,
      header: PickerPinkHeader(title: widget.title, subtitle: widget.subtitle),
      body: widget.items.isEmpty
          ? const SizedBox.shrink()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              itemCount: widget.items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, index) {
                final item = widget.items[index];
                return PickerRow(
                  item: item,
                  isSelected: _selected.contains(item.id),
                  onTap: () => _toggle(item),
                );
              },
            ),
      footer: _PickerStickyFooter(
        label: widget.ctaLabel,
        enabled: _selected.isNotEmpty,
        onTap: _onConfirm,
      ),
    );
  }
}

class PickerPinkHeader extends StatelessWidget {
  const PickerPinkHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoLight3,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.sokoShade4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    height: 1.0,
                    letterSpacing: -0.36,
                    color: AppColors.sokoInk,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    height: 1.2,
                    letterSpacing: -0.14,
                    color: AppColors.sokoShade3,
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

class PickerRow extends StatelessWidget {
  const PickerRow({
    super.key,
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  final PickerItem item;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rowContent = Material(
      color: isSelected ? AppColors.sokoLight3 : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              _Thumbnail(imageUrl: item.imageUrl),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.title,
                            style: const TextStyle(
                              fontFamily: 'Zalando Sans',
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                              height: 1.0,
                              letterSpacing: -0.36,
                              color: AppColors.sokoInk,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.badgeLabel != null) ...[
                          const SizedBox(width: 6),
                          _RowBadge(label: item.badgeLabel!),
                        ],
                      ],
                    ),
                    if (item.subtitle != null && item.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.subtitle!,
                        style: const TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 14,
                          fontWeight: FontWeight.w300,
                          height: 1.2,
                          letterSpacing: -0.14,
                          color: AppColors.sokoShade4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _PickerChip(isSelected: isSelected),
              ),
            ],
          ),
        ),
      ),
    );

    if (isSelected) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.sokoPink, width: 1),
        ),
        child: rowContent,
      );
    }
    return CustomPaint(
      painter: DashedBorderPainter(
        color: AppColors.sokoInk.withValues(alpha: 0.30),
      ),
      child: rowContent,
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    // Match the AddToListSheet's ListThumbnailStack footprint: 45 × 60 tile,
    // left-side rounded 6 so it flushes against the row's rounded border.
    const radius = BorderRadius.only(
      topLeft: Radius.circular(6),
      bottomLeft: Radius.circular(6),
    );
    final placeholder = ColoredBox(
      color: AppColors.sokoShade5,
      child: const Center(
        child: Icon(
          Icons.image_outlined,
          size: 18,
          color: AppColors.sokoShade3,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: 45,
        height: 60,
        child: imageUrl == null || imageUrl!.isEmpty
            ? placeholder
            : Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder,
              ),
      ),
    );
  }
}

class _RowBadge extends StatelessWidget {
  const _RowBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.sokoPink.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontFamily: 'Zalando Sans',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1.0,
          letterSpacing: 0.2,
          color: AppColors.sokoInk,
        ),
      ),
    );
  }
}

class _PickerChip extends StatelessWidget {
  const _PickerChip({required this.isSelected});

  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: isSelected
            ? AppColors.sokoPink
            : AppColors.sokoInk.withValues(alpha: 0.08),
        shape: BoxShape.circle,
      ),
      child: Icon(
        isSelected ? Icons.check_rounded : Icons.add_rounded,
        size: 16,
        color: AppColors.sokoInk,
      ),
    );
  }
}

class _PickerStickyFooter extends StatelessWidget {
  const _PickerStickyFooter({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        boxShadow: [
          BoxShadow(
            color: AppColors.sokoInk.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: SizedBox(
        height: 44,
        width: double.infinity,
        child: ElevatedButton(
          onPressed: enabled ? onTap : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.sokoPink,
            foregroundColor: AppColors.sokoInk,
            disabledBackgroundColor: AppColors.sokoPink.withValues(alpha: 0.4),
            disabledForegroundColor: AppColors.sokoInk.withValues(alpha: 0.5),
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 14,
              fontWeight: FontWeight.w400,
              height: 1.2,
              letterSpacing: -0.14,
            ),
          ),
        ),
      ),
    );
  }
}
