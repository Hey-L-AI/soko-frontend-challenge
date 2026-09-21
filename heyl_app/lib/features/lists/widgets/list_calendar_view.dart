import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/glassmorphic_popup_menu.dart';
import '../../library/widgets/library_item_row.dart' show kLibraryRowGap;
import 'list_item_row.dart';

/// Calendar view for displaying list events by date.
///
/// PROD-2018: compact month grid with Soko-pink cells for days that have
/// saved events, Soko-ink outline for today, Soko-ink fill for the
/// selected day, functional month + year dropdown selectors, and a per-day
/// agenda list below the grid that dedupes the same entity saved across
/// multiple lists (PROD-1975). Mobile and desktop render identical layouts.
class ListCalendarView extends StatefulWidget {
  final List<UserListItem> items;
  final Function(UserListItem)? onItemTap;
  final Function(UserListItem)? onItemRemove;
  final bool isEditMode;

  /// Callback to check if an item is saved in any owned list
  final bool Function({
    String? eventId,
    String? venueId,
    String? googlePlaceId,
  })?
  isItemSaved;

  /// The ID of the current list being viewed
  final String? currentListId;

  /// Callback when item is removed from the current list via bookmark sheet
  final void Function(UserListItem item)? onRemovedFromCurrentList;

  /// Whether the user is authenticated (if false, bookmark shows login prompt)
  final bool isAuthenticated;

  /// Callback when non-authenticated user tries to save item (shows login prompt)
  final VoidCallback? onLoginRequired;

  /// Currently selected date (controlled by parent to persist across rebuilds)
  final DateTime? selectedDate;

  /// Currently displayed month (controlled by parent to persist across rebuilds)
  final DateTime? currentMonth;

  /// Callback when selected date changes
  final void Function(DateTime date)? onSelectedDateChanged;

  /// Callback when current month changes
  final void Function(DateTime month)? onCurrentMonthChanged;

  /// PROD-1979 — items whose calendar chip should render blurred and
  /// non-interactive (used by the list-view guest gate so chips for the
  /// rows hidden under [GuestListGateOverlay] match the surrounding
  /// blur). Pass the [UserListItem.id]s of the gated items; everything
  /// not in the set renders normally. `null` / empty = no chip is
  /// blurred (default for authenticated users and the zine view).
  final Set<String>? hiddenItemIds;

  const ListCalendarView({
    super.key,
    required this.items,
    this.onItemTap,
    this.onItemRemove,
    this.isEditMode = false,
    this.isItemSaved,
    this.currentListId,
    this.onRemovedFromCurrentList,
    this.isAuthenticated = true,
    this.onLoginRequired,
    this.selectedDate,
    this.currentMonth,
    this.onSelectedDateChanged,
    this.onCurrentMonthChanged,
    this.hiddenItemIds,
  });

  @override
  State<ListCalendarView> createState() => _ListCalendarViewState();
}

class _ListCalendarViewState extends State<ListCalendarView> {
  late DateTime _currentMonth;
  DateTime? _selectedDate;

  /// The displayed month + selected date are owned locally so internal
  /// chevron / dropdown taps update the grid even when the parent passes
  /// the controlled-prop equivalents without a matching callback. The
  /// props themselves seed initial state in [initState] and re-sync via
  /// [didUpdateWidget] when the parent forces an external change.
  DateTime? get effectiveSelectedDate => _selectedDate;
  DateTime get effectiveCurrentMonth => _currentMonth;

  /// Event items with no known dates (no `event.occurrences` and no
  /// `start_datetime`). Rendered in a separate "no date" section below
  /// the calendar. Deduped by entity so the same event saved across
  /// multiple lists shows up once (PROD-1975).
  List<UserListItem> get _eventsWithoutDates {
    final seen = <String>{};
    final out = <UserListItem>[];
    for (final i in widget.items) {
      if (i.itemType != SavedItemType.event) continue;
      if (i.occurrenceDays.isNotEmpty) continue;
      final key = _itemEntityKey(i);
      if (seen.add(key)) out.add(i);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _currentMonth = widget.currentMonth ?? DateTime.now();
    _selectedDate = widget.selectedDate ?? DateTime.now();
  }

  @override
  void didUpdateWidget(covariant ListCalendarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the parent forces a new currentMonth / selectedDate from outside
    // (e.g. the hub re-fetches data for a different window), pick it up.
    // We compare against the old prop value rather than against local
    // state so that the local in-flight value from a chevron tap is not
    // clobbered when the parent simply re-renders with the same prop.
    if (widget.currentMonth != null &&
        widget.currentMonth != oldWidget.currentMonth) {
      _currentMonth = widget.currentMonth!;
    }
    if (widget.selectedDate != null &&
        widget.selectedDate != oldWidget.selectedDate) {
      _selectedDate = widget.selectedDate;
    }
  }

  void _setSelectedDate(DateTime date) {
    setState(() => _selectedDate = date);
    widget.onSelectedDateChanged?.call(date);
  }

  void _setCurrentMonth(DateTime month) {
    setState(() => _currentMonth = month);
    widget.onCurrentMonthChanged?.call(month);
  }

  /// Index key for a calendar day — packs y/m/d into a single int
  /// (`yyyymmdd`) for fast Map lookups.
  static int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  /// Stable identity for one item across lists. Falls back to the item's
  /// own row id when no underlying entity reference exists.
  static String _itemEntityKey(UserListItem item) => item.entityKey ?? item.id;

  /// Precomputed `dayKey → items` index, built once per render of
  /// [_buildCalendarGrid]. Avoids re-scanning every item's occurrence
  /// list for each of the ~35 cells in a month grid.
  Map<int, List<UserListItem>>? _eventsByDay;

  /// (Re)builds [_eventsByDay] from the current `widget.items` and caches
  /// it on the state for the duration of one frame. Cleared at the top of
  /// every `build` so widget-prop changes invalidate it.
  ///
  /// Two layers of dedup apply (PROD-1975 + same-day occurrences):
  ///   1. Within a single item, occurrences that fall on the same calendar
  ///      day (e.g. morning + evening Saturday show) collapse to one entry.
  ///   2. Across items, the same underlying entity saved into multiple
  ///      lists (same `entityKey`) collapses to one entry per day.
  Map<int, List<UserListItem>> _indexedEvents() {
    final cached = _eventsByDay;
    if (cached != null) return cached;
    final index = <int, List<UserListItem>>{};
    for (final item in widget.items) {
      final seenDaysForItem = <int>{};
      for (final occ in item.occurrenceDays) {
        final k = _dayKey(occ);
        if (!seenDaysForItem.add(k)) continue;
        final bucket = (index[k] ??= <UserListItem>[]);
        final entityKey = _itemEntityKey(item);
        if (bucket.any((existing) => _itemEntityKey(existing) == entityKey)) {
          continue;
        }
        bucket.add(item);
      }
    }
    _eventsByDay = index;
    return index;
  }

  /// All items that have an occurrence on [date]. Deduped by entity (so a
  /// single event saved across multiple lists shows up once).
  List<UserListItem> _getEventsForDate(DateTime date) {
    return _indexedEvents()[_dayKey(date)] ?? const [];
  }

  /// Year range available in the year dropdown — current displayed year
  /// ± 3 years, plus every year that appears in any item's occurrences.
  /// Always includes today's year so the user can return to "now".
  List<int> _availableYears() {
    final years = <int>{};
    final pivot = effectiveCurrentMonth.year;
    for (int y = pivot - 3; y <= pivot + 3; y++) {
      years.add(y);
    }
    years.add(DateTime.now().year);
    for (final item in widget.items) {
      for (final d in item.occurrenceDays) {
        years.add(d.year);
      }
    }
    final sorted = years.toList()..sort();
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    // PROD-1805: gracefully handle empty lists — when the host passes
    // zero items, the calendar grid would render with no event chips
    // and no "no date" section, which can read as a load error.
    // Callers like the list cover (`autoMonth != null`) and list view
    // body (`hasCalendar`) already short-circuit, but mirror the safety
    // at the widget level too so it can be mounted without the guard.
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }
    // Invalidate the per-frame cache so widget-prop changes (new items
    // from the hub provider, month-pagination refetch, etc.) rebuild it.
    _eventsByDay = null;
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final localeTag = Localizations.localeOf(context).toLanguageTag();

    final textSecondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.sokoShade3;

    final selectedEvents = effectiveSelectedDate != null
        ? _getEventsForDate(effectiveSelectedDate!)
        : <UserListItem>[];

    return Column(
      children: [
        // Calendar card — header + weekday strip + month grid
        // The component is authored against a 400-px content column, and the
        // grid's proportions are read off that width. The library page sits
        // inside `PageContent`, which caps its column at 480 on desktop — so
        // without a cap of its own the card grew to 448, the cells pinned at
        // their 40-px maximum, and all the slack went into the gaps (22 px
        // against the design's 14). Capping the card at the width it was
        // drawn for keeps the grid 1:1 with Figma on any viewport at or above
        // 400, and lets it shrink proportionally below that.
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _cardDesignWidth),
              child: _card(isDark, localeTag),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Events list (parent handles scrolling)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Selected date events
              if (effectiveSelectedDate != null) ...[
                Text(
                  _formatSelectedDateHeader(effectiveSelectedDate!, localeTag),
                  // Mobile/B2 Reg with the section-label weight — the token
                  // carries the family, size and tracking; only the weight is
                  // lifted, so this stays one step off the body style rather
                  // than a hand-rolled TextStyle.
                  style: AppTheme.mobileB2Reg(
                    color: textSecondaryColor,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                if (selectedEvents.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.surfaceDark : AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? AppColors.borderDarkMode
                            : AppColors.border,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        l10n.calendarNoEvents,
                        style: AppTheme.mobileB2Reg(color: textSecondaryColor),
                      ),
                    ),
                  )
                else
                  ...selectedEvents.map((item) => _buildSelectedEventRow(item)),
              ],

              // Events without dates
              if (_eventsWithoutDates.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  l10n.calendarNoDateEvents,
                  style: AppTheme.mobileB2Reg(
                    color: AppColors.sokoInk,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ..._eventsWithoutDates.map(
                  (item) => _buildSelectedEventRow(item),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _card(bool isDark, String localeTag) {
    return Container(
      padding: const EdgeInsets.all(_cardPadding),
      decoration: BoxDecoration(
        // Soko/Ink at 8 %, not an opaque shade. Sampling the Figma frame
        // gives #EADFDF, which is exactly `sokoInk8` composited over
        // `sokoPaper` — the shade ramp has no such step, which is why
        // `sokoShade5` (#F1E5E6) read too light against the page.
        color: isDark ? AppColors.surfaceDark : AppColors.sokoInk8,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
      child: Column(
        children: [
          _buildHeader(localeTag),
          const SizedBox(height: _headerToTableGap),
          // The weekday strip and the day grid share one measurement so
          // their columns line up exactly; measuring them separately let
          // rounding drift a fraction of a pixel per column.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _tableExtraInset),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cell = _cellSizeFor(constraints.maxWidth);
                return Column(
                  children: [
                    _buildWeekdayStrip(localeTag, cell),
                    const SizedBox(height: _weekdayToGridGap),
                    _buildCalendarGrid(cell),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Figma `6453:11699` (Soko -- shared) — the calendar is authored against
  /// the 400-px content column, and every number below is read off that
  /// frame rather than eyeballed:
  ///
  /// ```
  /// card      400 wide, 16 padding on all four sides
  /// header     368 x 36   — 36-px icon button, centred 264-wide select
  ///                          group (16 either side), 36-px icon button
  /// table      364 wide, inset a further 2 px, starting 16 below the header
  /// weekdays   20 tall
  /// grid       40-px cells on a 54-px horizontal pitch (14 gap) and a
  ///            46-px vertical pitch (6 gap)
  /// ```
  /// The width the whole component is drawn at in Figma.
  static const double _cardDesignWidth = 400;
  static const double _cardPadding = 16;
  static const double _headerHeight = 36;
  static const double _headerChevronSize = 36;
  static const double _selectGroupInset = 16;
  static const double _selectFieldHeight = 29;
  static const double _selectFieldGap = 8;
  static const double _headerToTableGap = 16;
  static const double _tableExtraInset = 2;
  static const double _weekdayRowHeight = 20;
  static const double _weekdayToGridGap = 0;
  static const double _cellSize = 40;
  static const double _cellGapX = 14;
  static const double _cellGapY = 6;
  static const double _cardRadius = 6;

  /// The day cells are all but square — a 2-px round on a 40-px cell, just
  /// enough to take the hard point off. The previous 8 turned them into
  /// visibly rounded chips.
  static const double _cellRadius = 2;

  /// Width of one grid row expressed in cell-widths: `7 cells + 6 gaps`.
  /// Dividing the available width by this reproduces the Figma cell size
  /// exactly at the design's 364-px table, and shrinks cells and gaps
  /// *together* on narrower phones instead of crushing the gaps to zero.
  static const double _gridWidthInCells =
      (7 * _cellSize + 6 * _cellGapX) / _cellSize;

  /// Cell edge for a table [width]. Capped at the design's 40 px so a wide
  /// desktop column spaces the cells out rather than inflating them.
  static double _cellSizeFor(double width) =>
      math.min(_cellSize, width / _gridWidthInCells);

  Widget _buildHeader(String localeTag) {
    final monthFormat = DateFormat.MMM(localeTag);
    final yearFormat = DateFormat.y(localeTag);
    return SizedBox(
      height: _headerHeight,
      child: Row(
        children: [
          _HeaderChevron(
            icon: Icons.chevron_left,
            onTap: () {
              _setCurrentMonth(
                DateTime(
                  effectiveCurrentMonth.year,
                  effectiveCurrentMonth.month - 1,
                ),
              );
            },
          ),
          // The two fields share the space between the chevrons equally and
          // stretch to fill it — in the design they are two halves of one
          // 264-wide select group, not two chips hugging their own labels.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _selectGroupInset,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _MonthYearDropdown<int>(
                      label: monthFormat.format(effectiveCurrentMonth),
                      items: List<int>.generate(12, (i) => i + 1),
                      itemLabel: (m) => monthFormat.format(
                        DateTime(effectiveCurrentMonth.year, m),
                      ),
                      onSelected: (m) {
                        _setCurrentMonth(
                          DateTime(effectiveCurrentMonth.year, m),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: _selectFieldGap),
                  Expanded(
                    child: _MonthYearDropdown<int>(
                      label: yearFormat.format(effectiveCurrentMonth),
                      items: _availableYears(),
                      itemLabel: (y) => yearFormat.format(DateTime(y)),
                      onSelected: (y) {
                        _setCurrentMonth(
                          DateTime(y, effectiveCurrentMonth.month),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          _HeaderChevron(
            icon: Icons.chevron_right,
            onTap: () {
              _setCurrentMonth(
                DateTime(
                  effectiveCurrentMonth.year,
                  effectiveCurrentMonth.month + 1,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Sunday-first weekday labels, locale-aware.
  ///
  /// The design writes them two letters wide ("Su Mo Tu We Th Fr Sa"), which
  /// only works where two letters still tell the seven days apart. They do
  /// not in pt — `seg./sex.` and `qua./qui.` both collapse to `se` and `qu` —
  /// so a locale that would produce a duplicate falls back to intl's full
  /// abbreviation rather than shipping an ambiguous strip. The 1-letter
  /// narrow form is not an option for the same reason, only worse.
  static List<String> _weekdayLabels(String localeTag) {
    final dayFormat = DateFormat.E(localeTag);
    // Anchor on any known Sunday. 2026-01-04 is a Sunday in the
    // proleptic Gregorian calendar; iterating 7 days forward yields
    // Sun..Sat regardless of the host platform locale.
    final sunday = DateTime(2026, 1, 4);
    final full = List.generate(
      7,
      (i) =>
          dayFormat.format(DateTime(sunday.year, sunday.month, sunday.day + i)),
    );
    final short = [
      for (final label in full) label.characters.take(2).toString(),
    ];
    return short.toSet().length == 7 ? short : full;
  }

  Widget _buildWeekdayStrip(String localeTag, double cell) {
    final labels = _weekdayLabels(localeTag);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final label in labels)
          SizedBox(
            width: cell,
            height: _weekdayRowHeight,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                // The 12-px Zalando Regular body token. The name is
                // historical (it started life on the hub) — it is the
                // design system's 12-px step, which is what the design
                // asks for here.
                style: AppTheme.hubDescription(color: AppColors.sokoShade4),
              ),
            ),
          ),
      ],
    );
  }

  /// Selected-date / no-date row. When the item is in [widget.hiddenItemIds]
  /// (guest cap), the row renders blurred + non-interactive, mirroring the
  /// chip blur in the grid above (PROD-1979).
  Widget _buildSelectedEventRow(UserListItem item) {
    final isHidden = widget.hiddenItemIds?.contains(item.id) ?? false;
    final row = Padding(
      // The shared row gap, not a card margin — the agenda rows sit directly
      // on the page like every other Soko list. The bordered white card that
      // used to wrap each one existed nowhere else in the app.
      padding: const EdgeInsets.only(bottom: kLibraryRowGap),
      child: Builder(
        builder: (context) => ListItemRow(
          item: item,
          selectedDay: effectiveSelectedDate,
          onTap: isHidden ? null : () => widget.onItemTap?.call(item),
          onRemove: isHidden || widget.onItemRemove == null
              ? null
              : () => widget.onItemRemove?.call(item),
          isEditMode: widget.isEditMode,
          isSaved:
              widget.isItemSaved?.call(
                eventId: item.eventId,
                venueId: item.venueId,
                googlePlaceId: item.googlePlaceId,
              ) ??
              false,
          currentListId: widget.currentListId,
          onRemovedFromCurrentList: widget.onRemovedFromCurrentList,
          isAuthenticated: widget.isAuthenticated,
          onLoginRequired: widget.onLoginRequired,
        ),
      ),
    );
    if (!isHidden) return row;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
      child: IgnorePointer(child: Opacity(opacity: 0.5, child: row)),
    );
  }

  Widget _buildCalendarGrid(double cell) {
    final firstDayOfMonth = DateTime(
      effectiveCurrentMonth.year,
      effectiveCurrentMonth.month,
      1,
    );
    final lastDayOfMonth = DateTime(
      effectiveCurrentMonth.year,
      effectiveCurrentMonth.month + 1,
      0,
    );

    // Sunday-first leading offset. DateTime.weekday is Mon=1..Sun=7;
    // mapping Sun→0..Sat→6 puts Sunday at column 0.
    final startWeekday = firstDayOfMonth.weekday;
    final daysFromPrevMonth = startWeekday == DateTime.sunday
        ? 0
        : startWeekday;

    final totalCells =
        ((daysFromPrevMonth + lastDayOfMonth.day) / 7).ceil() * 7;
    final totalRows = totalCells ~/ 7;

    return Column(
      children: List.generate(totalRows, (row) {
        return Padding(
          // 46-px vertical pitch on a 40-px cell — the gap sits below every
          // row but the last, so the grid ends flush with the card padding.
          padding: EdgeInsets.only(
            bottom: row == totalRows - 1 ? 0 : _cellGapY,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(7, (col) {
              final cellIndex = row * 7 + col;
              final dayOffset = cellIndex - daysFromPrevMonth;
              final date = DateTime(
                effectiveCurrentMonth.year,
                effectiveCurrentMonth.month,
                dayOffset + 1,
              );
              return _buildDayCell(date, cell);
            }),
          ),
        );
      }),
    );
  }

  /// PROD-2018 — pink-density shades for the "has events" cell state.
  /// Three solid colors with the visual weight growing with event count:
  /// light (1 event) → medium / sokoPink (2 events) → middle (3+ events).
  /// Light is a lerp of sokoPink toward sokoPaper to keep it in-palette;
  /// the deeper shade is sokoPinkMiddle, a first-class design token.
  static final Color _pinkLight = Color.lerp(
    AppColors.sokoPink,
    AppColors.sokoPaper,
    0.65,
  )!;
  static const Color _pinkMedium = AppColors.sokoPink;
  static const Color _pinkStrong = AppColors.sokoPinkMiddle;

  static Color _pinkForEventCount(int count) {
    if (count <= 1) return _pinkLight;
    if (count == 2) return _pinkMedium;
    return _pinkStrong;
  }

  Widget _buildDayCell(DateTime date, double cell) {
    final dayEvents = _getEventsForDate(date);
    final eventCount = dayEvents.length;
    final hasEvents = eventCount > 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cellDay = DateTime(date.year, date.month, date.day);
    final isToday = cellDay.isAtSameMomentAs(today);
    final isPast = cellDay.isBefore(today);
    final sel = effectiveSelectedDate;
    final isSelected =
        sel != null &&
        sel.year == date.year &&
        sel.month == date.month &&
        sel.day == date.day;
    // Leading / trailing days belong to the neighbouring month. The design
    // calls this the `Disabled` cell state: still there, still tappable, but
    // stepped back to Soko/Shade4 so the month being browsed reads as one
    // block. Previously they inherited full Soko/Ink, so October's 1st looked
    // exactly as present as September's 30th.
    final inMonth =
        date.month == effectiveCurrentMonth.month &&
        date.year == effectiveCurrentMonth.year;

    Color? fill;
    Border? border;
    Color textColor;

    if (!inMonth) {
      textColor = AppColors.sokoShade4;
    } else if (isSelected) {
      // Soko-ink fill takes precedence over the other states.
      fill = AppColors.sokoInk;
      textColor = AppColors.sokoPaper;
    } else if (isPast) {
      // Past days → grey text. Days that had events get a fill so they stay
      // distinguishable from past days that had nothing, but only just: one
      // more step of `sokoInk8` over the card's own, the same way the header
      // field is built. This used to be solid `sokoShade4`, which is ~3x the
      // contrast against the card and made a finished day heavier on the eye
      // than an upcoming one — the pink density signal is reserved for
      // current / future days precisely so the eye lands on actionable cells
      // first, and the dark grey was fighting it. Today is never past
      // (cellDay < today is strict), so its outline branch below is
      // unaffected.
      if (hasEvents) {
        fill = AppColors.sokoInk8;
      }
      textColor = AppColors.sokoShade3;
    } else if (hasEvents) {
      // Density-driven pink (PROD-2018): 1 / 2 / 3+ events → light /
      // medium / deep shade.
      fill = _pinkForEventCount(eventCount);
      textColor = AppColors.sokoInk;
      if (isToday) {
        border = Border.all(color: AppColors.sokoInk, width: 2);
      }
    } else if (isToday) {
      border = Border.all(color: AppColors.sokoInk, width: 2);
      textColor = AppColors.sokoInk;
    } else {
      textColor = AppColors.sokoInk;
    }

    return Clickable(
      // Tapping a neighbouring month's day pages the grid to that month as
      // well as selecting it. Without this the selection lands somewhere the
      // visible grid cannot draw, and the agenda below silently swaps to a
      // day the user can no longer see highlighted.
      onTap: () {
        if (!inMonth) _setCurrentMonth(DateTime(date.year, date.month));
        _setSelectedDate(date);
      },
      child: Container(
        width: cell,
        height: cell,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(_cellRadius),
          border: border,
        ),
        alignment: Alignment.center,
        child: Text(
          '${date.day}',
          // Mobile/B2 Reg in every state. The design deliberately holds one
          // weight across the grid and lets the fill carry the state — the
          // old w600-when-it-has-events rule double-signalled what the pink
          // already says, and made an event day read as a second heading.
          style: AppTheme.mobileB2Reg(color: textColor),
        ),
      ),
    );
  }

  String _formatSelectedDateHeader(DateTime date, String localeTag) {
    // "Sat, Apr 23, 2026" — locale-aware via intl. Matches Material's
    // common date-header style without coupling to MaterialLocalizations.
    return DateFormat.yMMMEd(localeTag).format(date);
  }
}

/// Chevron at either end of the calendar header. Steps ±1 month on tap.
///
/// The design's `Icon Button / Subtle` — a 36-px hit target with no ground
/// of its own, so the two chevrons read as part of the card rather than as
/// buttons sitting on it. Material's `IconButton` is deliberately not used:
/// it paints a ripple and enforces its own 48-px minimum, both of which
/// break the 36-px block the header is measured against.
class _HeaderChevron extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _HeaderChevron({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: onTap,
      child: SizedBox(
        width: _ListCalendarViewState._headerChevronSize,
        height: _ListCalendarViewState._headerChevronSize,
        child: Icon(icon, size: 20, color: AppColors.sokoInk),
      ),
    );
  }
}

/// Select field that opens a popover list of options. Used for the month
/// and year selectors in the calendar header — same chrome, different items.
///
/// Fills the width it is given (the two fields split the header's centre
/// between them) with the value left-aligned and the chevron pinned right,
/// rather than hugging its label.
class _MonthYearDropdown<T> extends StatelessWidget {
  final String label;
  final List<T> items;
  final String Function(T value) itemLabel;
  final ValueChanged<T> onSelected;

  const _MonthYearDropdown({
    required this.label,
    required this.items,
    required this.itemLabel,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GlassmorphicPopupMenu<T>(
      backgroundColor: AppColors.sokoShade5,
      border: Border.all(
        color: AppColors.sokoInk.withValues(alpha: 0.08),
        width: 1,
      ),
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      offset: const Offset(0, 4),
      blurSigma: 0,
      hoverColor: AppColors.sokoPaper.withValues(alpha: 0.8),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      items: items
          .map(
            (v) => GlassmorphicMenuItem<T>(
              value: v,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Text(
                  itemLabel(v),
                  style: AppTheme.mobileB2Reg(color: AppColors.sokoInk),
                ),
              ),
            ),
          )
          .toList(),
      onSelected: onSelected,
      child: Container(
        height: _ListCalendarViewState._selectFieldHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          // The same `sokoInk8` as the card, layered over it — the design
          // builds both surfaces from one token rather than picking two
          // steps off the shade ramp, which is what makes the field read as
          // a recess in the card instead of a separate chip on top of it.
          color: AppColors.sokoInk8,
          borderRadius: BorderRadius.circular(
            _ListCalendarViewState._cardRadius,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mobileB2Reg(color: AppColors.sokoInk),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 16,
              color: AppColors.sokoInk,
            ),
          ],
        ),
      ),
    );
  }
}
