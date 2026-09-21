import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../providers/social_proof_provider.dart';
import '../../../shared/widgets/card_tag_row.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/soko_card_image.dart';
import 'card_action_buttons.dart';

// TODO: Re-enable when backend sends proper human-readable reasons (PROD-1485)
const _showReasonEnabled = false;

/// Place card widget matching Lovable SuggestionCard style
/// Shows: name, subtitle (shortDesc • location), social proof, expandable description, bookmark
class VenueCard extends ConsumerStatefulWidget {
  final ItemSuggestion place;
  final VoidCallback? onTap;
  final VoidCallback? onBookmark;
  final bool isSaved;
  final double? fixedWidth;
  final List<ButtonAction> buttons;
  final Function(String)? onPostback;

  const VenueCard({
    super.key,
    required this.place,
    this.onTap,
    this.onBookmark,
    this.isSaved = false,
    this.fixedWidth,
    this.buttons = const [],
    this.onPostback,
  });

  @override
  ConsumerState<VenueCard> createState() => _VenueCardState();
}

class _VenueCardState extends ConsumerState<VenueCard> {
  bool _showAiReason = false;

  /// Location summary `[type] • [neighborhood] • [city]` — shared with
  /// `SearchResultCard` via `ItemSuggestion.locationSubtitle()`. Rendered
  /// next to a map-pin icon in the meta row.
  String _getLocationText() => widget.place.locationSubtitle();

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 768;

    // Responsive sizing — web breakpoint bumped (PROD-1894) so chat cards
    // feel less cramped on desktop and the new tag row reads at a glance.
    final thumbnailSize = isDesktop ? 96.0 : 56.0;
    final padding = isDesktop ? 12.0 : 6.0;
    final gap = isDesktop ? 16.0 : 8.0;
    final buttonSize = isDesktop ? 36.0 : 24.0;
    final iconSize = isDesktop ? 22.0 : 16.0;
    final badgeSize = isDesktop ? 16.0 : 12.0;
    final titleSize = isDesktop ? 16.0 : 14.0;

    // Soko tokens (PROD-1804). Venue cards adopt the venue detail-page
    // palette: sokoVenue surface, sokoVenueAccent tag/accent. Mirrors
    // `discovery_shell.dart` so chat cards visually echo the page
    // they open into.
    const surfaceColor = AppColors.sokoVenue;
    const borderColor = Colors.transparent;
    const textPrimaryColor = AppColors.sokoInk;
    const textSecondaryColor = AppColors.sokoInk;
    const accentColor = AppColors.sokoVenueAccent;

    final locationText = _getLocationText();
    final saveCount = _getSocialProof()?.saveCount ?? 0;
    final infoIconSize = isDesktop ? 14.0 : 12.0;
    final infoTextSize = isDesktop ? 13.0 : 11.5;
    final infoIconColor = AppColors.sokoInk.withValues(alpha: 0.55);

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: widget.fixedWidth,
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isSaved ? AppColors.sokoInk : borderColor,
          width: widget.isSaved ? 2 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Main row: thumbnail | content | bookmark
          Padding(
            padding: EdgeInsets.all(padding),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail with overlay badges only — tag row now lives
                // inline inside the content column.
                SizedBox(
                  width: thumbnailSize,
                  height: thumbnailSize,
                  child: Stack(
                    children: [
                      SokoCardImage(
                        imageUrl: widget.place.imageUrl,
                        seed:
                            widget.place.venueId ??
                            widget.place.eventId ??
                            widget.place.id,
                        kind: SokoEntityKind.venue,
                        width: thumbnailSize,
                        height: thumbnailSize,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      if (widget.place.hasRealTime)
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Container(
                            width: badgeSize,
                            height: badgeSize,
                            decoration: BoxDecoration(
                              color: AppColors.sokoPink.withValues(alpha: 0.9),
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
                      if (widget.isSaved && !widget.place.hasRealTime)
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Container(
                            width: badgeSize,
                            height: badgeSize,
                            decoration: BoxDecoration(
                              color: accentColor,
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

                // Content — title + location meta line. Description moved
                // out to a full-width row below so it has more room to
                // breathe (PROD-1894 follow-up).
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.place.name,
                        style: TextStyle(
                          fontSize: titleSize,
                          fontWeight: FontWeight.w600,
                          color: textPrimaryColor,
                          height: 1.15,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      CardTagRow(itemType: 'place', saveCount: saveCount),
                      if (locationText.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _VenueMetaLine(
                          icon: Icons.place_outlined,
                          text: locationText,
                          iconSize: infoIconSize,
                          textSize: infoTextSize,
                          iconColor: infoIconColor,
                        ),
                      ],
                    ],
                  ),
                ),

                SizedBox(width: gap),

                // AI Sparkles button - only show on mobile if there's a reason
                if (_showReasonEnabled &&
                    widget.place.reason != null &&
                    widget.place.reason!.isNotEmpty &&
                    !isDesktop)
                  GestureDetector(
                    onTap: () => setState(() => _showAiReason = !_showAiReason),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: buttonSize,
                      height: buttonSize,
                      decoration: BoxDecoration(
                        color: _showAiReason
                            ? AppColors.sokoShade5
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(buttonSize / 2),
                      ),
                      child: Center(
                        child: Image.asset(
                          'assets/images/soko-ai-icon.png',
                          width: iconSize,
                          height: iconSize,
                        ),
                      ),
                    ),
                  ),

                // Bookmark button - intercepts tap to prevent card tap
                GestureDetector(
                  onTap: widget.onBookmark,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: buttonSize,
                    height: buttonSize,
                    child: Center(
                      child: Icon(
                        widget.isSaved ? Icons.bookmark : Icons.bookmark_border,
                        size: iconSize,
                        color: widget.isSaved
                            ? AppColors.sokoInk
                            : textSecondaryColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // AI Recommendation reason - mobile: expandable, desktop: always visible
          if (_showReasonEnabled &&
              widget.place.reason != null &&
              widget.place.reason!.isNotEmpty &&
              (isDesktop || _showAiReason))
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
                      widget.place.reason!,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.sokoInk,
                        fontStyle: FontStyle.italic,
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
    );

    // Wrap entire card in Clickable so tapping anywhere opens detail.
    // `Clickable` switches the web cursor to a pointer on hover.
    return Clickable(onTap: widget.onTap, child: card);
  }

  SocialProof? _getSocialProof() {
    final proof =
        widget.place.socialProof ??
        (widget.place.venueId != null
            ? ref.watch(socialProofProvider)[widget.place.venueId!]
            : null);

    if (proof == null && widget.place.venueId != null) {
      ref
          .read(socialProofProvider.notifier)
          .getSocialProof(widget.place.venueId!, 'place');
    }
    return proof;
  }
}

/// One-line meta row (icon + ellipsised text) used inside venue cards.
/// Mirrors the event-card `_MetaLine` so both kinds read consistently.
class _VenueMetaLine extends StatelessWidget {
  const _VenueMetaLine({
    required this.icon,
    required this.text,
    required this.iconSize,
    required this.textSize,
    required this.iconColor,
  });

  final IconData icon;
  final String text;
  final double iconSize;
  final double textSize;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: iconSize, color: iconColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: textSize,
              color: AppColors.sokoInk.withValues(alpha: 0.75),
              height: 1.25,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
