import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/datetime_parsing.dart';
import '../../../core/utils/month_abbr.dart';
import '../../../data/models/event_occurrence.dart';
import '../../../data/models/models.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/social_proof_provider.dart';
import '../../../shared/widgets/cached_image.dart';
import '../../../shared/widgets/card_tag_row.dart';
import '../../../shared/widgets/clickable.dart';
import '../../events/widgets/date_range_list_tile.dart';
import 'card_action_buttons.dart';

// TODO: Re-enable when backend sends proper human-readable reasons (PROD-1485)
const _showReasonEnabled = false;

/// Event card widget matching Lovable SuggestionCard style
/// Shows: name, subtitle (date • time • location), social proof, expandable description, bookmark
class EventCard extends ConsumerStatefulWidget {
  final ItemSuggestion event;
  final VoidCallback? onTap;
  final VoidCallback? onBookmark;
  final bool isSaved;
  final double? fixedWidth;
  final List<ButtonAction> buttons;
  final Function(String)? onPostback;

  const EventCard({
    super.key,
    required this.event,
    this.onTap,
    this.onBookmark,
    this.isSaved = false,
    this.fixedWidth,
    this.buttons = const [],
    this.onPostback,
  });

  @override
  ConsumerState<EventCard> createState() => _EventCardState();
}

class _EventCardState extends ConsumerState<EventCard> {
  bool _showAiReason = false;

  /// Format event date with precision-aware time rendering.
  ///
  /// - `"datetime"` (or null legacy payloads) renders `"Sat, Jan 15 • 18:00"`.
  /// - `"date"` renders `"Sat, Jan 15"` — no `00:00` tail (backend stripped time).
  /// - `"unknown"` renders the localized "Date TBD" string.
  String _formatEventDateTime(
    String dateStr,
    String? precision,
    BuildContext context,
  ) {
    if (precision == 'unknown') {
      return Lt.of(context).eventDateUnknown;
    }
    final date = parseBackendDateTime(dateStr);
    if (date == null) return dateStr;
    final dayPart = _formatWeekdayDate(date, context);
    if (precision == 'date') {
      return dayPart;
    }
    final time =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return '$dayPart \u2022 $time';
  }

  /// Locale-aware "weekday, day month" with natural ordering for the
  /// active locale: "Fri, May 7" in en, "Sex., 7 Mai" in pt.
  String _formatWeekdayDate(DateTime date, BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final weekday = _titleCase(DateFormat('EEE', locale).format(date));
    final month = formatMonthAbbr(date, locale);
    final isPt = locale.startsWith('pt');
    return isPt
        ? '$weekday, ${date.day} $month'
        : '$weekday, $month ${date.day}';
  }

  /// Locale-aware "day month" used in compact occurrence lists.
  String _formatDayMonth(DateTime date, String locale) {
    final month = formatMonthAbbr(date, locale);
    final isPt = locale.startsWith('pt');
    return isPt ? '${date.day} $month' : '$month ${date.day}';
  }

  String _titleCase(String s) {
    if (s.isEmpty) return s;
    return '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';
  }

  /// Format multiple occurrence dates as "Apr 1, 2, 3" (en) /
  /// "1, 2, 3 Abr" (pt), with a localized "+N more dates" tail when the
  /// list overflows. Uses [Lt.listZineItemFutureDates] for the tail
  /// (already locale-pluralized).
  String _formatMultipleOccurrences(
    List<EventOccurrence> occurrences,
    BuildContext context,
  ) {
    if (occurrences.isEmpty) return '';
    final locale = Localizations.localeOf(context).toString();
    final isPt = locale.startsWith('pt');

    final firstMonth = occurrences.first.startAt.month;
    final sameMonth = occurrences
        .take(3)
        .every((o) => o.startAt.month == firstMonth);

    final String head;
    if (sameMonth) {
      final monthName = formatMonthAbbr(occurrences.first.startAt, locale);
      final days = occurrences
          .take(3)
          .map((o) => o.startAt.day.toString())
          .join(', ');
      head = isPt ? '$days $monthName' : '$monthName $days';
    } else {
      head = occurrences
          .take(3)
          .map((o) => _formatDayMonth(o.startAt, locale))
          .join(', ');
    }

    final moreCount = occurrences.length - 3;
    if (moreCount > 0) {
      return '$head ${Lt.of(context).listZineItemFutureDates(moreCount)}';
    }
    return head;
  }

  /// Format a date range occurrence as compact text.
  /// Past start → "Until Feb 28", future start → "Jan 24 until Feb 28".
  String _formatDateRange(EventOccurrence occ, BuildContext context) {
    final l10n = Lt.of(context);
    final locale = Localizations.localeOf(context).toString();
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final start = occ.startAt.toLocal();
    final end = occ.endAt!.toLocal();
    final endStr = _formatDayMonth(end, locale);

    if (start.isBefore(todayStart)) {
      return l10n.eventDateRangeUntilDate(endStr);
    }
    final startStr = _formatDayMonth(start, locale);
    return '$startStr ${l10n.eventDateRangeUntil} $endStr';
  }

  /// Just the date portion (date / time / occurrences), rendered alongside
  /// a calendar icon on its own line. Returns empty if no usable date data.
  String _getDateText(BuildContext context) {
    final occurrences = widget.event.occurrences.futureOnly();
    if (occurrences.length == 1 && isMultiDayRange(occurrences.first)) {
      return _formatDateRange(occurrences.first, context);
    }
    if (occurrences.length > 1) {
      return _formatMultipleOccurrences(occurrences, context);
    }
    if (widget.event.date != null) {
      return _formatEventDateTime(
        widget.event.date!,
        widget.event.datePrecision,
        context,
      );
    }
    return '';
  }

  /// "[venue], [city]" \u2014 rendered alongside a map-pin icon on its own line.
  String _getLocationText() => widget.event.eventLocationSummary();

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

    // Soko tokens (PROD-1804). Event cards adopt the event detail-page
    // palette: sokoEvent surface, sokoEventAccent tag/accent. Mirrors
    // `discovery_shell.dart` so chat cards echo the page they open into.
    const surfaceColor = AppColors.sokoEvent;
    const borderColor = Colors.transparent;
    const textPrimaryColor = AppColors.sokoInk;
    const textSecondaryColor = AppColors.sokoInk;
    const surfaceVariantColor = AppColors.sokoPaper;
    const accentColor = AppColors.sokoEventAccent;

    final dateText = _getDateText(context);
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
                      widget.event.imageUrl != null
                          ? CachedThumbnail(
                              imageUrl: widget.event.imageUrl!,
                              size: thumbnailSize,
                              borderRadius: BorderRadius.circular(6),
                              errorIcon: Icons.event,
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: _buildPlaceholder(
                                thumbnailSize,
                                surfaceVariantColor,
                                textSecondaryColor,
                              ),
                            ),
                      if (widget.event.hasRealTime)
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
                      if (widget.isSaved && !widget.event.hasRealTime)
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

                // Content — title + date/location meta lines. Description
                // moved out to a full-width row below so it has more room
                // to breathe (PROD-1894 follow-up).
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.event.name,
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
                      CardTagRow(itemType: 'event', saveCount: saveCount),
                      if (dateText.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _MetaLine(
                          icon: Icons.event_outlined,
                          text: dateText,
                          iconSize: infoIconSize,
                          textSize: infoTextSize,
                          iconColor: infoIconColor,
                        ),
                      ],
                      if (locationText.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _MetaLine(
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
                    widget.event.reason != null &&
                    widget.event.reason!.isNotEmpty &&
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
              widget.event.reason != null &&
              widget.event.reason!.isNotEmpty &&
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
                      widget.event.reason!,
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
        widget.event.socialProof ??
        (widget.event.eventId != null
            ? ref.watch(socialProofProvider)[widget.event.eventId!]
            : null);

    if (proof == null && widget.event.eventId != null) {
      ref
          .read(socialProofProvider.notifier)
          .getSocialProof(widget.event.eventId!, 'event');
    }
    return proof;
  }

  Widget _buildPlaceholder(double size, Color bgColor, Color iconColor) {
    return Container(
      width: size,
      height: size,
      color: bgColor,
      child: Icon(Icons.event, color: iconColor, size: size * 0.5),
    );
  }
}

/// One-line meta row used inside chat event/venue cards: small icon + text.
/// Mirrors the date/location lines on the detail page.
class _MetaLine extends StatelessWidget {
  const _MetaLine({
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
