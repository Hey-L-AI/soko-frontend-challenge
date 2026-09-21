// PROD-4006 — the date label on a server-driven feed event card.
//
// The feed's cards show two shapes the Figma frames make explicit:
//
//   single day  →  "Hoje, 12h" · "Qui 13 Ago, 9h" · "25 Mai"
//   multi-day   →  "12 - 15 Ago" · "7 - 11 Out" · "28 Ago - 3 Set"
//
// The single-day form already exists and is already correct:
// [formatEventWhen] handles today / tomorrow / this-week / further-out and
// collapses the time component when `time_known` is false. This file adds only
// the range branch, and delegates everything else — a second relative-day
// implementation is exactly the kind of near-duplicate that drifts.
//
// Why not `core/utils/event_time.dart`: its helpers are extensions on
// `ListItemEventOccurrence` and `EventOccurrence`, so they cannot see a
// `FeedEventItem`. The midnight-sentinel convention they encode is already
// carried on the wire here as `time_known`, which the feed model defaults to
// `true` exactly as `EventOccurrence` does.

import 'package:flutter/widgets.dart';

import '../../data/models/feed_home.dart';
import 'event_day_math.dart';
import 'event_when_formatter.dart';
import 'month_abbr.dart';

/// The date line for one feed event card.
///
/// Ranges deliberately carry **no time**, matching the frames: "12 - 15 Ago"
/// spans four days, and a start time on a multi-day festival describes only its
/// first day, so showing one implies a precision the field does not have.
String formatFeedEventDate(BuildContext context, FeedEventItem item) {
  final start = item.startsAt.toLocal();
  final end = item.endsAt?.toLocal();

  if (end != null) {
    // The night-shifted end date, used for BOTH the is-this-a-range decision
    // and the day actually printed — so a festival finishing 03:00 on the 16th
    // reads "12 - 15 Ago", the way a person would write it.
    final lastDay = nightAdjustedEndDay(end);
    if (lastDay.isAfter(dayOfLocal(start))) {
      return _formatDateRange(context, start, lastDay);
    }
  }

  return formatEventWhen(
    context: context,
    startsAt: item.startsAt,
    timeKnown: item.timeKnown,
  );
}

/// "12 - 15 Ago" within one month, "28 Ago - 3 Set" across two.
///
/// The month is written once when both ends share it — that is what the frames
/// show, and it is how the range reads aloud in every locale the app ships.
String _formatDateRange(BuildContext context, DateTime start, DateTime end) {
  final locale = Localizations.localeOf(context).toString();
  final isPt = locale.startsWith('pt');

  final endMonth = formatMonthAbbr(end, locale);

  if (start.year == end.year && start.month == end.month) {
    // Same month: the abbreviation trails the pair in pt/es ("12 - 15 Ago")
    // and leads it in en ("Aug 12 - 15"), matching how `formatEventWhen` and
    // `formatEventStickerDate` already order day and month per locale.
    return isPt
        ? '${start.day} - ${end.day} $endMonth'
        : '$endMonth ${start.day} - ${end.day}';
  }

  final startMonth = formatMonthAbbr(start, locale);
  return isPt
      ? '${start.day} $startMonth - ${end.day} $endMonth'
      : '$startMonth ${start.day} - $endMonth ${end.day}';
}
