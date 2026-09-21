import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/event_time_formatter.dart';
import '../../../core/utils/month_abbr.dart';
import '../../../data/models/event_date_range.dart';
import '../../../data/models/event_occurrence.dart';
import '../../../data/models/social_proof.dart' show EventDetailResponse2;
import '../../../data/models/user_list.dart' show ListSource;
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';
import '../../events/widgets/date_range_list_tile.dart' show isMultiDayRange;
import '../providers/event_detail_provider.dart';
import 'event_save_button.dart';

/// One rendered entry in the "Dates" section — either a single occurrence
/// (rendered as today, save-chip ready) or a backend-computed multi-occurrence
/// date range collapsed into one span row (PROD-3116).
class _DateGroup {
  /// Non-null for a single-occurrence entry.
  final EventOccurrence? occurrence;

  /// Non-null for a collapsed multi-occurrence range.
  final EventDateRange? range;

  /// The occurrences folded into [range] (resolved from ids), used to derive a
  /// common venue for the meta line.
  final List<EventOccurrence> rangeOccurrences;

  const _DateGroup.single(this.occurrence)
    : range = null,
      rangeOccurrences = const [];

  const _DateGroup.multi(this.range, this.rangeOccurrences) : occurrence = null;

  bool get isMulti => range != null;
}

/// Fold the future occurrences into display groups using the backend-computed
/// [dateRanges]. Consecutive occurrences collapse into one range; singles stay
/// individual rows (so their per-occurrence save chip still works). Falls back
/// to one group per occurrence when no ranges are present.
List<_DateGroup> _buildDateGroups(
  List<EventOccurrence> occurrences,
  List<EventDateRange> dateRanges,
) {
  if (dateRanges.isEmpty) {
    return occurrences.map((o) => _DateGroup.single(o)).toList();
  }
  final byId = {for (final o in occurrences) o.id: o};
  final groups = <_DateGroup>[];
  for (final range in dateRanges) {
    final members = [
      for (final id in range.occurrenceIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (range.isMulti) {
      groups.add(_DateGroup.multi(range, members));
    } else if (members.isNotEmpty) {
      groups.add(_DateGroup.single(members.first));
    } else {
      // No matching occurrence loaded (legacy call failed) — still show the
      // range so the date isn't lost.
      groups.add(_DateGroup.multi(range, const []));
    }
  }
  return groups;
}

/// Event-page occurrence section (Figma `6181:5715` group). Replaces the
/// venue page's "Eventos aqui" block.
///
/// Single-occurrence events show one row; multi-occurrence events show up
/// to [_initialOccurrencesToShow] rows with a "Mais datas" footer that
/// expands by [_occurrenceBatchSize] each tap (mirrors the legacy item
/// detail sheet's `_buildOccurrenceList` behaviour).
///
/// The whole section collapses when there are no future occurrences.
///
/// Row chrome (per Figma `6181:5716`):
///   - 50×63 date box (Soko/Ink @ 6 % bg, radius 2): day number above
///     month abbr, both Zalando Sans Light 18 px Soko/Ink.
///   - Title: Mobile/B1 Reg (Zalando Sans Light 18 px Soko/Ink).
///   - Meta line: "Day, DD MMM • HH:mm • Venue" — Mobile/B2 Reg Soko/Ink
///     @ 30 % opacity, separated by `•`.
///   - Trailing 30×30 slot — empty in v1 (per-occurrence saving is a
///     future affordance).
class EventOccurrenceSection extends ConsumerStatefulWidget {
  final EventDetailSnapshot snapshot;

  const EventOccurrenceSection({super.key, required this.snapshot});

  static const int _initialOccurrencesToShow = 5;
  static const int _occurrenceBatchSize = 20;

  @override
  ConsumerState<EventOccurrenceSection> createState() =>
      _EventOccurrenceSectionState();
}

class _EventOccurrenceSectionState
    extends ConsumerState<EventOccurrenceSection> {
  int _visibleCount = EventOccurrenceSection._initialOccurrencesToShow;

  /// Ranges the user has expanded to reveal their folded occurrences, keyed by
  /// [_rangeKey]. Kept in the section state (not a local widget flag) so it
  /// survives the `groups.take(_visibleCount)` rebuild when "More dates" grows
  /// the list.
  final Set<String> _expandedKeys = {};

  /// Stable identity for a range across rebuilds — its first occurrence id when
  /// resolved, else its start/end span.
  String _rangeKey(EventDateRange r) => r.occurrenceIds.isNotEmpty
      ? r.occurrenceIds.first
      : '${r.start.toIso8601String()}_${r.end.toIso8601String()}';

  /// A collapsed range plus, when expanded, its folded occurrences rendered as
  /// indented [_OccurrenceRow]s (each with a working per-occurrence save chip).
  /// The whole group is wrapped in an [AnimatedSize] so expand/collapse eases.
  List<Widget> _buildRangeGroup({
    required _DateGroup group,
    required String eventTitle,
    required String? venueName,
    required List<EventOccurrence> occurrences,
  }) {
    final range = group.range!;
    final members = group.rangeOccurrences;
    final expandable = members.isNotEmpty;
    final key = _rangeKey(range);
    final expanded = expandable && _expandedKeys.contains(key);
    return [
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RangeRow(
              range: range,
              occurrences: members,
              eventTitle: eventTitle,
              parentVenueName: venueName,
              expanded: expanded,
              onToggle: expandable
                  ? () => setState(() {
                      if (expanded) {
                        _expandedKeys.remove(key);
                      } else {
                        _expandedKeys.add(key);
                      }
                    })
                  : null,
            ),
            if (expanded)
              for (final occ in members) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: _OccurrenceRow(
                    occurrence: occ,
                    event: widget.snapshot.event,
                    occurrences: occurrences,
                    eventTitle: eventTitle,
                    parentVenueName: venueName,
                  ),
                ),
              ],
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final occurrences = widget.snapshot.occurrences;
    // PROD-3116: collapse consecutive occurrences into backend-computed ranges.
    final groups = _buildDateGroups(
      occurrences,
      widget.snapshot.event.dateRanges,
    );
    if (groups.isEmpty) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    final venueName = widget.snapshot.event.venueName;
    final eventTitle = widget.snapshot.event.title;
    final total = groups.length;
    final toShow = groups.take(_visibleCount).toList();
    final hidden = total - toShow.length;
    final hasMore = hidden > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.eventDetailDatesTitle,
          style: const TextStyle(
            fontFamily: 'ZalandoSans',
            fontWeight: FontWeight.w500,
            fontSize: 18,
            height: 1.0,
            letterSpacing: -0.36,
            color: AppColors.sokoInk,
          ),
        ),
        // Title is its own top-level section in Figma `6181:5531`
        // (sibling of the occurrence list under a `flex-col gap-[30px]`
        // container), so the title→list gap is a section-level 30 px.
        // Internal row gaps stay at 10 px (Figma `6181:5715` gap-[10px]).
        const SizedBox(height: 30),
        for (var i = 0; i < toShow.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          if (toShow[i].isMulti)
            ..._buildRangeGroup(
              group: toShow[i],
              eventTitle: eventTitle,
              venueName: venueName,
              occurrences: occurrences,
            )
          else
            _OccurrenceRow(
              occurrence: toShow[i].occurrence!,
              event: widget.snapshot.event,
              occurrences: occurrences,
              eventTitle: eventTitle,
              parentVenueName: venueName,
            ),
        ],
        if (hasMore) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Clickable(
              onTap: () {
                setState(() {
                  _visibleCount += EventOccurrenceSection._occurrenceBatchSize;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppColors.sokoInk, width: 1),
                  ),
                ),
                child: Text(
                  l10n.eventDetailMoreDatesLink,
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w300,
                    fontSize: 14,
                    height: 1.2,
                    letterSpacing: -0.14,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _OccurrenceRow extends StatelessWidget {
  final EventOccurrence occurrence;
  final EventDetailResponse2 event;
  final List<EventOccurrence> occurrences;
  final String eventTitle;
  final String? parentVenueName;

  const _OccurrenceRow({
    required this.occurrence,
    required this.event,
    required this.occurrences,
    required this.eventTitle,
    this.parentVenueName,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 63,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _DateBox(date: occurrence.startAt),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _titleForRow(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w300,
                    fontSize: 18,
                    height: 1.0,
                    letterSpacing: -0.36,
                    color: AppColors.sokoInk,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _metaLine(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w300,
                    fontSize: 14,
                    height: 1.2,
                    letterSpacing: -0.14,
                    color: AppColors.sokoInk.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Trailing 30×30 slot — per-occurrence save chip (PROD-3116). Saves
          // just this date to the calendar/notifications rather than the whole
          // event. Collapsed multi-occurrence ranges have no single occurrence
          // to save, so their slot stays empty (range expansion is a follow-up).
          EventSaveButton(
            event: event,
            occurrences: occurrences,
            size: 30,
            source: ListSource.detail,
            eventOccurrenceId: occurrence.id,
          ),
        ],
      ),
    );
  }

  String _titleForRow(BuildContext context) {
    // For multi-day ranges the row title is "DD–DD MMM" so the user can
    // see the span at a glance. Single-day rows show the event title —
    // the venue already appears in the meta line (and was the same value
    // repeated on every row when used here previously).
    if (isMultiDayRange(occurrence)) {
      final start = occurrence.startAt.toLocal();
      final end = occurrence.endAt!.toLocal();
      final fmt = DateFormat('d MMM');
      return '${fmt.format(start)} – ${fmt.format(end)}';
    }
    final fallback = Lt.of(context).eventDetailTagTypeEvent;
    return eventTitle.isNotEmpty ? eventTitle : fallback;
  }

  /// "Qua., 29 Abr. • 19h • Casa Capitão" — falls back gracefully when any
  /// piece is missing. Time component is hidden for all-day occurrences and
  /// for occurrences the BE flagged `time_known=false`.
  String _metaLine(BuildContext context) {
    final parts = <String>[];
    final locale = Localizations.localeOf(context).toString();
    final start = occurrence.startAt.toLocal();
    parts.add(DateFormat('EEE, d MMM', locale).format(start));
    if (!occurrence.isAllDay && occurrence.timeKnown) {
      parts.add(formatEventTime(start, locale));
    }
    final venue = occurrence.location ?? parentVenueName;
    if ((venue ?? '').isNotEmpty) parts.add(venue!);
    return parts.join(' • ');
  }
}

/// A collapsed multi-occurrence date range (PROD-3116): "14 – 17 Jul" plus a
/// meta line with the occurrence count and, when every folded occurrence sits
/// at the same place, the shared venue. Replaces the old N-identical-rows list.
class _RangeRow extends StatelessWidget {
  final EventDateRange range;
  final List<EventOccurrence> occurrences;
  final String eventTitle;
  final String? parentVenueName;

  /// Whether this range is currently expanded to reveal its folded occurrences.
  final bool expanded;

  /// Toggles expansion. Null when the range has no resolved occurrences to
  /// reveal (legacy call failed) — the row then stays inert with no chevron.
  final VoidCallback? onToggle;

  const _RangeRow({
    required this.range,
    required this.occurrences,
    required this.eventTitle,
    this.parentVenueName,
    this.expanded = false,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: 63,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _DateBox(date: range.start),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _spanTitle(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w300,
                    fontSize: 18,
                    height: 1.0,
                    letterSpacing: -0.36,
                    color: AppColors.sokoInk,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _metaLine(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w300,
                    fontSize: 14,
                    height: 1.2,
                    letterSpacing: -0.14,
                    color: AppColors.sokoInk.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Trailing 30×30 slot — expand chevron when the range can reveal its
          // folded occurrences (per-occurrence save lives on the child rows).
          _trailing(),
        ],
      ),
    );
    if (onToggle == null) return row;
    final l10n = Lt.of(context);
    return Semantics(
      button: true,
      label: expanded ? l10n.eventDetailHideDates : l10n.eventDetailShowDates,
      child: Clickable(onTap: onToggle, child: row),
    );
  }

  Widget _trailing() {
    if (onToggle == null) return const SizedBox(width: 30, height: 30);
    return SizedBox(
      width: 30,
      height: 30,
      child: Center(
        child: AnimatedRotation(
          duration: const Duration(milliseconds: 200),
          turns: expanded ? 0.5 : 0,
          child: Icon(
            Icons.expand_more,
            size: 20,
            color: AppColors.sokoInk.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  /// Whether every folded occurrence sits on one calendar day (start == end
  /// day). Same-day folds are real ranges (PROD-3116) but must not render as a
  /// fake "31 Jul – 31 Jul" span or be counted as "N dates" (PROD-3582).
  bool get _isSingleDay {
    final start = range.start.toLocal();
    final end = range.end.toLocal();
    return start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
  }

  /// Multi-day: "14 – 17 Jul". Same day: the date once plus the distinct known
  /// occurrence times, e.g. "31 Jul, 19h, 21h" (PROD-3582) — falling back to
  /// just the date when no times are known / no occurrences resolved.
  String _spanTitle(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final fmt = DateFormat('d MMM', locale);
    final start = range.start.toLocal();
    if (!_isSingleDay) {
      return '${fmt.format(start)} – ${fmt.format(range.end.toLocal())}';
    }
    final date = fmt.format(start);
    final times = _distinctTimes(locale);
    if (times.isEmpty) return date;
    return '$date, ${times.join(', ')}';
  }

  /// Distinct wall-clock times of the folded occurrences (ascending, no
  /// duplicates), skipping all-day / time-unknown ones. Empty when none qualify
  /// or nothing resolved.
  List<String> _distinctTimes(String locale) {
    final seen = <String>{};
    final result = <String>[];
    for (final o in occurrences) {
      if (o.isAllDay || !o.timeKnown) continue;
      final label = formatEventTime(o.startAt.toLocal(), locale);
      if (seen.add(label)) result.add(label);
    }
    return result;
  }

  /// Multi-day: "4 datas • 19h • Casa Capitão" — count first, then the shared
  /// start time when every folded occurrence agrees on one (and none is all-day
  /// / time-unknown), then the shared venue when they agree on one.
  /// Same day (PROD-3582): "2 sessões • Casa Capitão" — "sessions" not "dates",
  /// and no time (the distinct times already live in the title). Any part is
  /// dropped when the fold isn't unanimous, so we never show a fabricated hour.
  String _metaLine(BuildContext context) {
    final l10n = Lt.of(context);
    final locale = Localizations.localeOf(context).toString();
    // Prefer the count of resolved occurrences so the label always equals the
    // number of rows the expansion reveals; fall back to the backend
    // `occurrence_count` only when none resolved (nothing to expand).
    final count = occurrences.isNotEmpty
        ? occurrences.length
        : range.occurrenceCount;
    final singleDay = _isSingleDay;
    final parts = <String>[
      singleDay
          ? l10n.eventDetailSessionsCount(count)
          : l10n.eventDetailDatesCount(count),
    ];
    if (!singleDay) {
      // Same-day folds put the distinct times in the title (PROD-3582), so the
      // meta line shows no time; multi-day folds add the shared time when known.
      final time = _commonTime();
      if (time != null) parts.add(formatEventTime(time, locale));
    }
    final venue = _commonVenue() ?? parentVenueName;
    if ((venue ?? '').isNotEmpty) parts.add(venue!);
    return parts.join(' • ');
  }

  /// The wall-clock start time shared by every folded occurrence, or null when
  /// they differ, any is all-day / time-unknown, or none were resolved. Mirrors
  /// [_commonVenue]: show a time on the range row only when it is unambiguous.
  DateTime? _commonTime() {
    if (occurrences.isEmpty) return null;
    DateTime? first;
    for (final o in occurrences) {
      if (o.isAllDay || !o.timeKnown) return null;
      final local = o.startAt.toLocal();
      if (first == null) {
        first = local;
      } else if (local.hour != first.hour || local.minute != first.minute) {
        return null;
      }
    }
    return first;
  }

  /// The venue shared by every folded occurrence, or null when they differ /
  /// none were resolved.
  String? _commonVenue() {
    if (occurrences.isEmpty) return null;
    final first = occurrences.first.location ?? occurrences.first.venueName;
    if ((first ?? '').isEmpty) return null;
    for (final o in occurrences) {
      if ((o.location ?? o.venueName) != first) return null;
    }
    return first;
  }
}

class _DateBox extends StatelessWidget {
  /// The date to display (an occurrence start, or a range's start day).
  final DateTime date;

  const _DateBox({required this.date});

  @override
  Widget build(BuildContext context) {
    final start = date.toLocal();
    final dayNum = start.day.toString();
    final locale = Localizations.localeOf(context).toString();
    // `formatMonthAbbr` capitalises for us — it used to not, which is why
    // this had its own copy of the logic.
    final monthAbbr = formatMonthAbbr(start, locale);

    return Container(
      width: 50,
      height: 63,
      decoration: BoxDecoration(
        color: AppColors.sokoInk.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              dayNum,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontWeight: FontWeight.w300,
                fontSize: 18,
                height: 1.0,
                letterSpacing: -0.36,
                color: AppColors.sokoInk,
              ),
            ),
            Text(
              monthAbbr,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontWeight: FontWeight.w300,
                fontSize: 18,
                height: 1.0,
                letterSpacing: -0.36,
                color: AppColors.sokoInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
