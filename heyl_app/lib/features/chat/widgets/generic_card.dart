import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../shared/widgets/soko_card_image.dart';
import 'card_action_buttons.dart';

// TODO: Re-enable when backend sends proper human-readable reasons (PROD-1485)
const _showReasonEnabled = false;

/// Generic card widget for items that are neither events nor places
/// Matches Lovable SuggestionCard style
class GenericCard extends StatefulWidget {
  final ItemSuggestion item;
  final VoidCallback? onTap;
  final VoidCallback? onBookmark;
  final bool isSaved;
  final double? fixedWidth;
  final List<ButtonAction> buttons;
  final Function(String)? onPostback;

  const GenericCard({
    super.key,
    required this.item,
    this.onTap,
    this.onBookmark,
    this.isSaved = false,
    this.fixedWidth,
    this.buttons = const [],
    this.onPostback,
  });

  @override
  State<GenericCard> createState() => _GenericCardState();
}

class _GenericCardState extends State<GenericCard> {
  bool _showAiReason = false;

  String _getSubtitle() {
    if (widget.item.description != null &&
        widget.item.description!.isNotEmpty) {
      return widget.item.description!;
    }
    if (widget.item.tags.isNotEmpty) {
      return widget.item.tags.join(' \u2022 ');
    }
    return '';
  }

  void _toggleAiReason() {
    setState(() {
      _showAiReason = !_showAiReason;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 768;

    // Responsive sizing — web breakpoint bumped (PROD-1894) to keep the
    // generic card aligned with the enlarged event/venue cards.
    final thumbnailSize = isDesktop ? 96.0 : 56.0;
    final padding = isDesktop ? 12.0 : 6.0;
    final gap = isDesktop ? 16.0 : 8.0;
    final buttonSize = isDesktop ? 36.0 : 24.0;
    final iconSize = isDesktop ? 22.0 : 16.0;
    final badgeSize = isDesktop ? 16.0 : 12.0;
    final aiIconSize = isDesktop ? 36.0 : 28.0;
    final titleSize = isDesktop ? 16.0 : 14.0;
    final subtitleSize = isDesktop ? 14.0 : 12.0;

    // Soko tokens (PROD-1804).
    const surfaceColor = AppColors.sokoPaper;
    const borderColor = AppColors.sokoShade5;
    const textPrimaryColor = AppColors.sokoInk;
    const textSecondaryColor = AppColors.sokoShade3;
    const primaryColor = AppColors.sokoInk;

    final subtitle = _getSubtitle();
    final hasAiReason =
        _showReasonEnabled &&
        widget.item.reason != null &&
        widget.item.reason!.isNotEmpty;
    // On desktop, always show AI reason; on mobile, show when toggled
    final showAiReasonText = hasAiReason && (isDesktop || _showAiReason);

    // Wrap entire card in GestureDetector so tapping anywhere opens detail
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: widget.fixedWidth,
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.isSaved ? AppColors.sokoPink : borderColor,
            width: widget.isSaved ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main row: thumbnail | content | AI icon | bookmark
            Padding(
              padding: EdgeInsets.all(padding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Thumbnail with badges
                  SizedBox(
                    width: thumbnailSize,
                    height: thumbnailSize,
                    child: Stack(
                      children: [
                        // Image
                        SokoCardImage(
                          imageUrl: widget.item.imageUrl,
                          seed:
                              widget.item.venueId ??
                              widget.item.eventId ??
                              widget.item.id,
                          kind: SokoEntityKind.fromTypeString(widget.item.type),
                          width: thumbnailSize,
                          height: thumbnailSize,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        // Real-time indicator (top-right, takes priority)
                        if (widget.item.hasRealTime)
                          Positioned(
                            top: 2,
                            right: 2,
                            child: Container(
                              width: badgeSize,
                              height: badgeSize,
                              decoration: BoxDecoration(
                                color: AppColors.sokoPink.withValues(
                                  alpha: 0.9,
                                ),
                                borderRadius: BorderRadius.circular(
                                  badgeSize / 2,
                                ),
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.radio,
                                  size: badgeSize * 0.6,
                                  color: AppColors.sokoInk,
                                ),
                              ),
                            ),
                          ),
                        // Saved badge (only if not showing real-time)
                        if (widget.isSaved && !widget.item.hasRealTime)
                          Positioned(
                            top: 2,
                            right: 2,
                            child: Container(
                              width: badgeSize,
                              height: badgeSize,
                              decoration: BoxDecoration(
                                color: AppColors.sokoPink,
                                borderRadius: BorderRadius.circular(
                                  badgeSize / 2,
                                ),
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.check,
                                  size: badgeSize * 0.7,
                                  color: AppColors.sokoInk,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  SizedBox(width: gap),

                  // Content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Title
                        Text(
                          widget.item.name,
                          style: TextStyle(
                            fontSize: titleSize,
                            fontWeight: FontWeight.w600,
                            color: textPrimaryColor,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),

                        // Subtitle
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: subtitleSize,
                              color: textSecondaryColor,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),

                  SizedBox(width: gap),

                  // Soko AI icon (shown when AI reason is available)
                  if (hasAiReason)
                    GestureDetector(
                      onTap: isDesktop ? null : _toggleAiReason,
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        width: aiIconSize,
                        height: aiIconSize,
                        child: Image.asset(
                          'assets/images/soko-ai-icon.png',
                          width: aiIconSize,
                          height: aiIconSize,
                        ),
                      ),
                    ),

                  if (hasAiReason) SizedBox(width: gap / 2),

                  // Bookmark button - intercepts tap to prevent card tap
                  GestureDetector(
                    onTap: widget.onBookmark,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: buttonSize,
                      height: buttonSize,
                      child: Center(
                        child: Icon(
                          widget.isSaved
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                          size: iconSize,
                          color: widget.isSaved
                              ? AppColors.sokoPink
                              : textSecondaryColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // AI reason text (shown on desktop always, on mobile when toggled)
            if (showAiReasonText)
              Padding(
                padding: EdgeInsets.fromLTRB(padding, 0, padding, padding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Image.asset(
                      'assets/images/soko-ai-icon.png',
                      width: 24,
                      height: 24,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.item.reason!,
                        style: TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          color: primaryColor,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Action buttons
            if (widget.buttons.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(padding, 0, padding, padding),
                child: CardActionButtons(
                  buttons: widget.buttons,
                  onPostback: widget.onPostback,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
