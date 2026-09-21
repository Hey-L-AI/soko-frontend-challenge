// Day-level date math for event ranges, shared across the surfaces that decide
// whether a start/end pair is a genuine multi-day span or a single night that
// merely crosses midnight. Lives on its own — below both [formatFeedEventDate]
// (`feed_event_date.dart`), [resolveEventTimingChip] (`event_timing_chip.dart`)
// and [formatVenueEventWhen] (`event_when_formatter.dart`) — so all of them
// day-truncate and fold late-night finishes identically, with no second
// implementation that drifts.

/// Hour before which an end time still belongs to the **previous** night.
///
/// A gig listed 21:00 Thursday → 02:00 Friday crosses midnight on the calendar
/// but is one night out, and "13 - 14 Ago" describes it worse than
/// "Qui 13 Ago, 21h" does. Club nights are the common case in this corpus, not
/// an edge case, so a naive calendar-day comparison would mislabel a large
/// share of the feed.
///
/// 6 a.m. is the usual closing hour in the launch markets. Anything later
/// genuinely is a second day.
const int _nightEndsAtHour = 6;

/// Midnight of [d]'s calendar day (local). Shared so every event-range surface
/// day-truncates identically.
DateTime dayOfLocal(DateTime d) {
  final local = d.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// The calendar day an end time belongs to, folding a late-night finish back
/// into the day the night started:
///
///   02:00 Fri  → Thu     (still Thursday night)
///   23:00 15th → 15th    (unchanged)
///   09:00 13th → 13th    (unchanged — a genuine second day)
///   00:00 11th → 11th    (date-only sentinel, NOT shifted — see below)
///
/// An `end` that precedes `start` (bad data) therefore yields an earlier day
/// and is not treated as a range, which beats rendering "15 - 12 Ago".
DateTime nightAdjustedEndDay(DateTime end) {
  end = end.toLocal();
  // Exactly midnight is the crawler's "only the date is known" sentinel — the
  // same convention `core/utils/event_time.dart` documents for starts, and the
  // reason the wire carries `time_known` at all. So `2026-10-11T00:00:00` means
  // "ends on the 11th", not "ends the instant the 11th begins", and shifting it
  // back would silently print every date-only range a day short.
  //
  // The cost is a genuine 00:00 finish being read as date-only. That is
  // indistinguishable in this data, and getting the common case right matters
  // more than the one we cannot detect.
  if (end.hour == 0 && end.minute == 0 && end.second == 0) {
    return dayOfLocal(end);
  }
  return dayOfLocal(end.subtract(const Duration(hours: _nightEndsAtHour)));
}
