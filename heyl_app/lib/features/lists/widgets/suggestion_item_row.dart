import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/models.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/soko_card_image.dart';
import 'list_view_mode/list_view_item_row.dart';

// TODO: Re-enable when backend sends proper human-readable reasons (PROD-1485)
const _showReasonEnabled = false;

/// Row widget for displaying a suggestion item in the suggestions section.
///
/// Matches the layout dimensions of [ListItemRow]:
/// - 54x54 thumbnail with 6px border radius
/// - 17px title, single line with ellipsis
/// - AI reason in italic primary color (multi-line, wraps freely)
///
/// Owner-side trailing chips per `docs/designs/list-page-redesign.md`
/// § 8.3:
/// - **Plus-circle** ([onAdd]) — add the suggestion to *this* list.
/// - **Bookmark chip** ([onSaveToOtherList]) — save to one of *my* lists.
class SuggestionItemRow extends StatelessWidget {
  final ItemSuggestion suggestion;
  final bool isSaved;
  final VoidCallback? onTap;
  final VoidCallback? onAdd;
  final VoidCallback? onSaveToOtherList;

  const SuggestionItemRow({
    super.key,
    required this.suggestion,
    this.isSaved = false,
    this.onTap,
    this.onAdd,
    this.onSaveToOtherList,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final textColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;

    // Match ListItemRow: vertical padding 6px
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Thumbnail — 54x54, borderRadius 6, matches ListItemRow
          Clickable(onTap: onTap, child: _buildThumbnail(context)),
          const SizedBox(width: 12),

          // Title + AI reason
          Expanded(
            child: Clickable(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title — 17px, w400, 1 line, ellipsis (matches ListItemRow)
                  Text(
                    suggestion.name,
                    style: AppTheme.listItemTitle(color: textColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_showReasonEnabled &&
                      suggestion.reason != null &&
                      suggestion.reason!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    // AI reason with Soko icon
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Image.asset(
                            'assets/images/soko-ai-icon.png',
                            width: 14,
                            height: 14,
                            color: isDark ? null : primaryColor,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            suggestion.reason!,
                            style: TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              color: primaryColor,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Action chips per § 8.3 — both 30×30, Soko/Ink @ 8 % bg
          // (Figma `Frame9235` + `Frame9236` — `6197:4858`/`6197:4863`),
          // separated by a 6 px gap.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PlusCircleChip(onTap: isSaved ? null : onAdd, isSaved: isSaved),
              const SizedBox(width: 6),
              BookmarkChip(onTap: onSaveToOtherList),
            ],
          ),
        ],
      ),
    );
  }

  /// Thumbnail matching ListItemRow: 54x54, borderRadius 6, with fallback icon
  Widget _buildThumbnail(BuildContext context) {
    return SokoCardImage(
      imageUrl: suggestion.imageUrl,
      seed: suggestion.venueId ?? suggestion.eventId ?? suggestion.id,
      kind: SokoEntityKind.fromTypeString(suggestion.type),
      width: 54,
      height: 54,
      borderRadius: BorderRadius.circular(6),
    );
  }
}
