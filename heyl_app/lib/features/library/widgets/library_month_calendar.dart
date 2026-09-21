import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/clickable.dart';
import '../models/library_filter.dart';

/// Compact month grid for the Date dropdown. Pink = days with events.
class LibraryMonthCalendar extends StatefulWidget {
  const LibraryMonthCalendar({
    super.key,
    this.selectedDate,
    this.eventDays = const {},
    required this.onPicked,
  });

  final DateTime? selectedDate;

  /// Local calendar days that have at least one saved event.
  final Set<DateTime> eventDays;

  final ValueChanged<DateTime> onPicked;

  @override
  State<LibraryMonthCalendar> createState() => _LibraryMonthCalendarState();
}

class _LibraryMonthCalendarState extends State<LibraryMonthCalendar> {
  late DateTime _month;
  late Set<int> _eventKeys;

  @override
  void initState() {
    super.initState();
    final seed = widget.selectedDate ?? DateTime.now();
    _month = DateTime(seed.year, seed.month);
    _eventKeys = widget.eventDays.map(_dayKey).toSet();
  }

  static int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  @override
  void didUpdateWidget(covariant LibraryMonthCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventDays != widget.eventDays) {
      _eventKeys = widget.eventDays.map(_dayKey).toSet();
    }
  }

  @override
  Widget build(BuildContext context) {
    final localeTag = Localizations.localeOf(context).toLanguageTag();
    return SizedBox(
      width: 292,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(localeTag),
            const SizedBox(height: 8),
            _weekdays(localeTag),
            const SizedBox(height: 4),
            _grid(),
          ],
        ),
      ),
    );
  }

  Widget _header(String localeTag) {
    final label = DateFormat.yMMMM(localeTag).format(_month);
    return Row(
      children: [
        _chevron(
          Icons.chevron_left,
          () =>
              setState(() => _month = DateTime(_month.year, _month.month - 1)),
        ),
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppTheme.mobileB2Reg(color: AppColors.sokoInk),
          ),
        ),
        _chevron(
          Icons.chevron_right,
          () =>
              setState(() => _month = DateTime(_month.year, _month.month + 1)),
        ),
      ],
    );
  }

  Widget _chevron(IconData icon, VoidCallback onTap) {
    return Clickable(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(icon, size: 20, color: AppColors.sokoInk),
      ),
    );
  }

  Widget _weekdays(String localeTag) {
    final dayFormat = DateFormat.E(localeTag);
    final sunday = DateTime(2026, 1, 4);
    return Row(
      children: List.generate(7, (i) {
        final d = DateTime(sunday.year, sunday.month, sunday.day + i);
        return Expanded(
          child: Center(
            child: Text(
              dayFormat.format(d),
              style: AppTheme.mobileB2Reg(color: AppColors.sokoShade3),
            ),
          ),
        );
      }),
    );
  }

  Widget _grid() {
    final first = DateTime(_month.year, _month.month, 1);
    final last = DateTime(_month.year, _month.month + 1, 0);
    final daysFromPrev = first.weekday == DateTime.sunday ? 0 : first.weekday;
    final totalCells = ((daysFromPrev + last.day) / 7).ceil() * 7;
    final rows = totalCells ~/ 7;

    return Column(
      children: List.generate(rows, (row) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: List.generate(7, (col) {
              final cellIndex = row * 7 + col;
              final dayOffset = cellIndex - daysFromPrev;
              final date = DateTime(_month.year, _month.month, dayOffset + 1);
              return Expanded(child: _cell(date));
            }),
          ),
        );
      }),
    );
  }

  static final Color _pinkLight = Color.lerp(
    AppColors.sokoPink,
    AppColors.sokoPaper,
    0.65,
  )!;

  Widget _cell(DateTime date) {
    final inMonth = date.month == _month.month;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cellDay = DateTime(date.year, date.month, date.day);
    final hasEvents = _eventKeys.contains(_dayKey(cellDay));
    final sel = widget.selectedDate;
    final isSelected =
        sel != null &&
        sel.year == date.year &&
        sel.month == date.month &&
        sel.day == date.day;
    final isToday = cellDay.isAtSameMomentAs(today);

    Color? fill;
    Border? border;
    Color textColor = inMonth ? AppColors.sokoInk : AppColors.sokoShade3;

    if (isSelected) {
      fill = AppColors.sokoInk;
      textColor = AppColors.sokoPaper;
    } else if (hasEvents && inMonth) {
      fill = _pinkLight;
      textColor = AppColors.sokoInk;
      if (isToday) {
        border = Border.all(color: AppColors.sokoInk, width: 2);
      }
    } else if (isToday && inMonth) {
      border = Border.all(color: AppColors.sokoInk, width: 2);
    }

    return Clickable(
      onTap: inMonth ? () => widget.onPicked(calendarDay(date)) : null,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(8),
              border: border,
            ),
            alignment: Alignment.center,
            child: Text(
              '${date.day}',
              style: TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 14,
                fontWeight: isSelected || hasEvents
                    ? FontWeight.w600
                    : FontWeight.w400,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
