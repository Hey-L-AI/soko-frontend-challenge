import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/month_abbr.dart';
import '../../../data/models/models.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/press_pop.dart';
import '../../../shared/widgets/soko_card_image.dart';

/// Compact card for displaying a search result (place or event)
/// with an add button to add to the current list.
///
/// PROD-1852 redesign: 44 px thumbnail, Soko/Ink text, 30 px `Icon/Add`
/// button — a circular fill behind the glyph (`plus` when not yet
/// added, `check` when added). Default state uses a light Soko/Ink @ 8 %
/// background; added state shifts both the row tint *and* the button
/// fill to the item's accent (Soko/Blue for places, Soko/Green for
/// events), with the button fill landing on a darker shade of that
/// accent so it still reads against the row. Ratings and social-proof
/// badge removed from this surface (they live on the venue/event detail
/// pages instead).
class SearchResultCard extends ConsumerWidget {
  final ItemSuggestion item;
  final VoidCallback? onTap;
  final VoidCallback? onAdd;

  /// PROD-2014: tap on the check icon when the row is already in the
  /// list. Wired to a remove-from-list flow by the parent. When null,
  /// the added state falls back to the legacy "no-op" behavior.
  final VoidCallback? onRemove;
  final bool isAdding;
  final bool isAdded;

  const SearchResultCard({
    super.key,
    required this.item,
    this.onTap,
    this.onAdd,
    this.onRemove,
    this.isAdding = false,
    this.isAdded = false,
  });

  /// Soko/Blue for places, Soko/Green for events — matches the active
  /// tab pill so the added-card colour and the tab indicator agree.
  Color get _accentColor =>
      item.type == 'event' ? AppColors.sokoGreen : AppColors.sokoBlue;

  String _getSubtitle(BuildContext context) {
    if (item.type == 'event') {
      final parts = <String>[];
      final dateText = _formatEventDate(context);
      if (dateText.isNotEmpty) {
        parts.add(dateText);
      }
      if (item.location != null && item.location!.isNotEmpty) {
        parts.add(item.location!);
      } else if (item.city != null && item.city!.isNotEmpty) {
        parts.add(item.city!);
      }
      return parts.join(' \u2022 ');
    }

    // Places: [type] • [neighborhood] • [city].
    return item.locationSubtitle();
  }

  /// Locale-aware event date for the search row. Prefers the structured
  /// `startAt` from `SearchApi.searchEvents` (PROD-1719 follow-up). Falls
  /// back to the backend's pre-formatted English `item.date` string only
  /// when no structured occurrence is available.
  String _formatEventDate(BuildContext context) {
    final occ = item.occurrences.isNotEmpty ? item.occurrences.first : null;
    if (occ != null) {
      final locale = Localizations.localeOf(context).toString();
      final start = occ.startAt.toLocal();
      final weekday = _titleCase(DateFormat('EEE', locale).format(start));
      final month = formatMonthAbbr(start, locale);
      final isPt = locale.startsWith('pt');
      final datePart = isPt
          ? '$weekday, ${start.day} $month ${start.year}'
          : '$weekday, $month ${start.day}, ${start.year}';
      if (occ.isAllDay || !occ.timeKnown) {
        return datePart;
      }
      final time =
          '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
      return '$datePart, $time';
    }
    return item.date ?? '';
  }

  String _titleCase(String s) {
    if (s.isEmpty) return s;
    return '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitle = _getSubtitle(context);

    return Container(
      // Figma frame 6353:28468 — rows are tightly stacked (~56 px each).
      // 6 px vertical padding gives a 44 px thumb + 12 px padding total,
      // matching the Figma compact rhythm. When added, the accent fill
      // takes over as the divider so the bottom border drops out — two
      // adjacent dividers would read as a stripe.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: isAdded ? _accentColor : null,
        border: isAdded
            ? null
            : Border(
                bottom: BorderSide(
                  color: AppColors.sokoInk.withValues(alpha: 0.06),
                ),
              ),
      ),
      child: Row(
        children: [
          // Tappable area: thumbnail + content (opens detail).
          Expanded(
            child: Clickable(
              onTap: onTap,
              child: Row(
                children: [
                  // 44×44 thumbnail (was 48 — tighter rows in Figma).
                  SokoCardImage(
                    imageUrl: item.imageUrl,
                    seed: item.venueId ?? item.eventId ?? item.id,
                    kind: SokoEntityKind.fromTypeString(item.type),
                    width: 44,
                    height: 44,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(width: 12),

                  // Text content.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: AppColors.sokoInk,
                            height: 1.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 1),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w300,
                              color: AppColors.sokoInk.withValues(alpha: 0.35),
                              height: 1.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),

          // Add button (separate tap target).
          _AddButton(
            onAdd: onAdd,
            onRemove: onRemove,
            isAdding: isAdding,
            isAdded: isAdded,
            accentColor: _accentColor,
          ),
        ],
      ),
    );
  }
}

/// 30 px circular add button (Figma frame 9237). Default fill is
/// Soko/Shade5 with the `Icon/Add-L` glyph (`LucideIcons.circle_plus`)
/// — same chip treatment as `_HeaderActionButton` (`Soko/Ink @ N %` was
/// too subtle to read as a deliberate chip). Added state swaps to
/// `circle_check` over a darker shade of the row's accent (20 % blend
/// toward Soko/Ink). The glyph carries the inner ring; the chip fill
/// provides the deliberate-button surface behind it. Icon swap is
/// instant (no AnimatedSwitcher) per Figma spec "Animate: Instantâneo".
class _AddButton extends StatelessWidget {
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;
  final bool isAdding;
  final bool isAdded;
  final Color accentColor;

  const _AddButton({
    this.onAdd,
    this.onRemove,
    this.isAdding = false,
    this.isAdded = false,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    if (isAdding) {
      return const SizedBox(
        width: 30,
        height: 30,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      );
    }

    final glyph = isAdded ? LucideIcons.circle_check : LucideIcons.circle_plus;
    final circleColor = isAdded
        ? Color.lerp(accentColor, AppColors.sokoInk, 0.2)!
        : AppColors.sokoShade5;

    // PROD-2014: tapping the check toggles the row OUT of the list.
    // Previously this branch passed `null` (the chip was a passive
    // confirmation). If no `onRemove` is provided, the legacy passive
    // behavior is preserved.
    final action = isAdded ? onRemove : onAdd;
    final chip = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: circleColor, shape: BoxShape.circle),
      child: Icon(glyph, size: 14, color: AppColors.sokoInk),
    );
    // Passive confirmation (no action) stays non-interactive; otherwise PressPop
    // (pop + web pointer cursor) matches the save/like/dislike pop elsewhere.
    if (action == null) return chip;
    return PressPop(onTap: action, child: chip);
  }
}
