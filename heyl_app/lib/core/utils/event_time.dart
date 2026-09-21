// PROD-2018 follow-up — shared time-of-day helpers for event occurrences.
//
// Encodes the "midnight = unknown time" convention: the upstream events
// pipeline emits a `start_at` whose time-of-day is exactly `00:00:00`
// when only a date is known. UI cannot distinguish "show starts at
// midnight" from "time not yet known". Until the backend fixes the
// gap, we treat midnight as "no known time" and omit the time line.
//
// When the data gap is fixed (occurrences arrive with an explicit
// time-or-null flag), `hasKnownStartTime` should become a simple
// nullability check and every caller of `formatOccurrenceTimeRange`
// should be revisited. Refactor-after-fix sites listed in
// `docs/investigations/context/prod-2018-app-wide-calendar-ux-redesign.md`.
import 'package:intl/intl.dart';

import '../../data/models/event_occurrence.dart';
import '../../data/models/user_list.dart';
import '../../l10n/generated/l10n.dart';

/// Midnight-as-unknown predicates. See file header for the data-gap
/// background.
extension ListItemEventOccurrenceTime on ListItemEventOccurrence {
  bool get hasKnownStartTime => !_isMidnight(startAt);
  bool get hasKnownEndTime => endAt != null && !_isMidnight(endAt!);
}

/// Same predicate for the events-API occurrence model, which additionally
/// carries the backend's explicit [EventOccurrence.timeKnown] flag — so this
/// trusts that first and falls back to the midnight sentinel for payloads that
/// predate it (the flag defaults to `true`, which is why the sentinel check is
/// still needed rather than redundant).
extension EventOccurrenceTime on EventOccurrence {
  bool get hasKnownStartTime => timeKnown && !_isMidnight(startAt);
}

bool _isMidnight(DateTime d) => d.hour == 0 && d.minute == 0 && d.second == 0;

/// The time-of-day line shown on the calendar agenda card. Returns
/// `null` when no usable time is available — caller should omit the
/// line entirely. Branches:
///
///   * both known → `"9:00 - 12:30"`
///   * only start known → localized "Starts at 9:00"
///   * start unknown (midnight) → `null`
String? formatOccurrenceTimeRange(
  ListItemEventOccurrence occ,
  Lt l10n, {
  String pattern = 'HH:mm',
}) {
  if (!occ.hasKnownStartTime) return null;
  final fmt = DateFormat(pattern);
  final startStr = fmt.format(occ.startAt);
  if (occ.hasKnownEndTime) {
    return '$startStr - ${fmt.format(occ.endAt!)}';
  }
  return l10n.eventTimeStartsAt(startStr);
}
