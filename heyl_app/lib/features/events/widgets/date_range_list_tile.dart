import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/event_occurrence.dart';

/// Returns true when [occ] spans multiple calendar days.
bool isMultiDayRange(EventOccurrence occ) {
  if (occ.endAt == null) return false;
  final start = occ.startAt.toLocal();
  final end = occ.endAt!.toLocal();
  return start.year != end.year ||
      start.month != end.month ||
      start.day != end.day;
}

/// A tile showing an event date range as a vertical timeline:
/// start date badge → connector → end date badge.
class DateRangeListTile extends StatelessWidget {
  final EventOccurrence occurrence;
  final VoidCallback? onVenueTap;

  const DateRangeListTile({super.key, required this.occurrence, this.onVenueTap});

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

    final startDate = occurrence.startAt.toLocal();
    final endDate = occurrence.endAt!.toLocal();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Start date row
          _buildDateRow(
            context,
            date: startDate,
            textPrimaryColor: textPrimaryColor,
            textSecondaryColor: textSecondaryColor,
            primaryColor: primaryColor,
            showTime: !occurrence.isAllDay,
            showLocation: true,
            onVenueTap: onVenueTap,
          ),

          // Connector
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: SizedBox(
              width: 48,
              height: 28,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 1.5,
                    height: 14,
                    color: primaryColor.withValues(alpha: 0.3),
                  ),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size: 14,
                    color: primaryColor.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
          ),

          // End date row
          _buildDateRow(
            context,
            date: endDate,
            textPrimaryColor: textPrimaryColor,
            textSecondaryColor: textSecondaryColor,
            primaryColor: primaryColor,
            showTime: false,
            showLocation: false,
          ),
        ],
      ),
    );
  }

  Widget _buildDateRow(
    BuildContext context, {
    required DateTime date,
    required Color textPrimaryColor,
    required Color textSecondaryColor,
    required Color primaryColor,
    required bool showTime,
    required bool showLocation,
    VoidCallback? onVenueTap,
  }) {
    final monthAbbr = DateFormat('MMM').format(date).toUpperCase();
    final dayNum = date.day.toString();
    final fullDate = DateFormat('EEEE, MMMM d, y').format(date);

    return Row(
      children: [
        // Date badge
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

        // Text details
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
              if (showTime || showLocation) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (showTime) ...[
                      Icon(
                        Icons.access_time,
                        size: 14,
                        color: textSecondaryColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        DateFormat('HH:mm').format(occurrence.startAt.toLocal()),
                        style: TextStyle(
                          fontSize: 13,
                          color: textSecondaryColor,
                        ),
                      ),
                      if (showLocation && occurrence.location != null)
                        const SizedBox(width: 12),
                    ],
                    if (showLocation && occurrence.location != null) ...[
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
            ],
          ),
        ),
      ],
    );
  }
}
