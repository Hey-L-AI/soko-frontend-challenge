import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';

/// Widget displaying the list summary: owner info, stats, and description
/// Matches Lovable's ListSummaryCard layout:
/// - Row 1: Avatar + "by Creator" on left, stats (item count + followers) on right
/// - Row 2: Description (expandable if long)
class ListOwnerInfo extends StatefulWidget {
  final String ownerName;
  final bool isOwner;
  final String? avatarUrl; // Future: when profile images are available
  final String? description;
  final int itemCount;
  final int followerCount;
  final double avatarSize;

  const ListOwnerInfo({
    super.key,
    required this.ownerName,
    this.isOwner = false,
    this.avatarUrl,
    this.description,
    this.itemCount = 0,
    this.followerCount = 0,
    this.avatarSize = 24,
  });

  @override
  State<ListOwnerInfo> createState() => _ListOwnerInfoState();
}

class _ListOwnerInfoState extends State<ListOwnerInfo> {
  bool _isDescriptionExpanded = false;

  static const int _descriptionTruncateLength = 80;

  bool get _isLongDescription =>
      widget.description != null &&
      widget.description!.length > _descriptionTruncateLength;

  String get _displayDescription {
    if (widget.description == null) return '';
    if (_isLongDescription && !_isDescriptionExpanded) {
      return '${widget.description!.substring(0, _descriptionTruncateLength - 3)}...';
    }
    return widget.description!;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final textColor = isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final textSecondaryColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    final l10n = Lt.of(context);
    final displayName = widget.isOwner
        ? l10n.listsCreatorYou
        : widget.ownerName;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Owner info left, stats right
          Row(
            children: [
              // Left: Avatar + "by Owner Name"
              Expanded(
                child: Row(
                  children: [
                    // Circular avatar
                    Container(
                      width: widget.avatarSize,
                      height: widget.avatarSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: primaryColor.withValues(alpha: 0.1),
                        border: Border.all(color: borderColor, width: 1),
                      ),
                      child: Center(
                        child: Text(
                          displayName.isNotEmpty
                              ? displayName[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            color: primaryColor,
                            fontWeight: FontWeight.w600,
                            fontSize: widget.avatarSize * 0.42,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // "by Owner Name" text
                    Flexible(
                      child: Text(
                        l10n.publicListOwnerBy(displayName),
                        style: TextStyle(
                          fontSize: 14,
                          color: textSecondaryColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // Right: Stats (item count + followers)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Item count
                  Text(
                    l10n.listsItemCount(widget.itemCount),
                    style: TextStyle(
                      fontSize: 14,
                      color: textSecondaryColor,
                    ),
                  ),
                  // Follower count (if > 0)
                  if (widget.followerCount > 0) ...[
                    const SizedBox(width: 12),
                    Icon(
                      Icons.bookmark_outline,
                      size: 14,
                      color: textSecondaryColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      l10n.listsFollowerCount(widget.followerCount),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),

          // Row 2: Description (if present)
          if (widget.description != null && widget.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Clickable(
              onTap: _isLongDescription
                  ? () {
                      setState(() {
                        _isDescriptionExpanded = !_isDescriptionExpanded;
                      });
                    }
                  : null,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      _displayDescription,
                      style: TextStyle(
                        fontSize: 14,
                        color: textSecondaryColor,
                        height: 1.4,
                      ),
                    ),
                  ),
                  if (_isLongDescription) ...[
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _isDescriptionExpanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: textSecondaryColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
