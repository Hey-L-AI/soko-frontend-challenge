import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'bottom_sheet/dashed_border_painter.dart';

/// Visual mirror of `PickerRow` in `chat_items_picker_sheet.dart` — used
/// by the Instagram-share + chat-items pickers. Shared selectable row for
/// title + subtitle + selected-state multi-select surfaces (Preferences
/// language/WhatsApp pickers, fake-door campaign option cards).
///
/// - Selected: solid `sokoPink` 1 px border, `sokoLight3` fill, pink chip
///   with `Icons.check_rounded`.
/// - Unselected: dashed `sokoInk@30%` border (via [DashedBorderPainter]),
///   transparent fill, `sokoInk@8%` chip with `Icons.add_rounded`.
///
/// [leading] slots an optional widget (e.g. an emoji glyph) before the
/// title; omit it for the plain text row.
class PickerSelectRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isSelected;
  final bool isLoading;
  final Widget? leading;
  final VoidCallback? onTap;

  const PickerSelectRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.isSelected,
    this.isLoading = false,
    this.leading,
    required this.onTap,
  });

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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 10)],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.0,
                          letterSpacing: -0.28,
                          color: AppColors.sokoInk,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle.isNotEmpty && subtitle != title) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontFamily: 'Zalando Sans',
                            fontSize: 12,
                            fontWeight: FontWeight.w300,
                            height: 1.2,
                            letterSpacing: -0.12,
                            color: AppColors.sokoShade4,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _PickerChip(isSelected: isSelected, isLoading: isLoading),
              ],
            ),
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

class _PickerChip extends StatelessWidget {
  const _PickerChip({required this.isSelected, this.isLoading = false});

  final bool isSelected;
  final bool isLoading;

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
      child: isLoading
          ? const Padding(
              padding: EdgeInsets.all(7),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.sokoInk),
              ),
            )
          : Icon(
              isSelected ? Icons.check_rounded : Icons.add_rounded,
              size: 16,
              color: AppColors.sokoInk,
            ),
    );
  }
}
