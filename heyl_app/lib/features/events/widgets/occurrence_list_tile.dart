import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/event_occurrence.dart';

/// A list tile showing an event occurrence with date box and time details
class OccurrenceListTile extends StatelessWidget {
  final EventOccurrence occurrence;
  final VoidCallback? onTap;
  final VoidCallback? onVenueTap;

  const OccurrenceListTile({
    super.key,
    required this.occurrence,
    this.onTap,
    this.onVenueTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final surfaceColor = isDark ? AppColors.surfaceDark : AppColors.surface;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final textPrimaryColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final textSecondaryColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    final date = occurrence.startAt;
    final monthAbbr = DateFormat('MMM').format(date).toUpperCase();
    final dayNum = date.day.toString();
    final fullDate = DateFormat('EEEE, MMMM d, y').format(date);

    // Format time range
    String timeStr;
    if (occurrence.isAllDay) {
      timeStr = 'All day';
    } else {
      final startTime = DateFormat('HH:mm').format(date);
      if (occurrence.endAt != null) {
        final endTime = DateFormat('HH:mm').format(occurrence.endAt!);
        timeStr = '$startTime - $endTime';
      } else {
        timeStr = startTime;
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            // Date box
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    monthAbbr,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: primaryColor,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    dayNum,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: primaryColor,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Date and time details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fullDate,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 14,
                        color: textSecondaryColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 13,
                          color: textSecondaryColor,
                        ),
                      ),
                      if (occurrence.location != null) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: onVenueTap,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.location_on_outlined,
                                  size: 14,
                                  color: onVenueTap != null ? primaryColor : textSecondaryColor,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    occurrence.location!,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: onVenueTap != null ? primaryColor : textSecondaryColor,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (onVenueTap != null)
                                  Icon(Icons.chevron_right, size: 14, color: primaryColor),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
