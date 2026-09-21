import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../l10n/generated/l10n.dart';
import 'event_day_math.dart';
import 'event_time_formatter.dart';
import 'month_abbr.dart';

/// Locale-aware compact "when" string for an event card row — the same
/// format the Discovery "A acontecer" (Happening) shelf uses on each card:
///
/// - Same day → "Today, 8 PM" / "Hoje, 21h" (or "Hoje" / "Today")
/// - Next day → "Tomorrow, 8 PM" / "Amanhã, 21h" (or "Amanhã" / "Tomorrow")
/// - Within 7 days → "Fri, 8 PM" / "Sex, 21h" (or just "Sex" / "Fri")
/// - Further out → "May 25, 8 PM" / "25 mai, 21h" (or just "25 mai" / "May 25")
///
/// When [timeKnown] is `false` the time component is hidden — the row
/// collapses to just the relative day. Intended for any surface that shows a
/// single upcoming-occurrence event card and wants the same chrome as
/// `HappeningShelf`.
///
/// [allowPast] governs how a date *before* today is rendered. The default
/// (`false`) keeps the legacy Happening-shelf behaviour: a past `startsAt`
/// collapses to "Today" (the shelf is future-filtered, so this only ever
/// happens defensively). Surfaces that legitimately show past events — a
/// saved list / zine — pass `allowPast: true`, which renders the real
/// absolute date instead (with the year when it isn't the current one).
///
/// The l10n keys are intentionally the `discoveryShelfHappeningCardWhen*`
/// set even though the function is shared — the *string* content is
/// identical across surfaces, and forking the key set would duplicate
/// translations for no semantic gain.
String formatEventWhen({
  required BuildContext context,
  required DateTime startsAt,
  required bool timeKnown,
  bool allowPast = false,
}) {
  final l10n = Lt.of(context);
  final locale = Localizations.localeOf(context).toString();
  final isPt = locale.startsWith('pt');

  final start = startsAt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final startDay = DateTime(start.year, start.month, start.day);
  final daysFromToday = startDay.difference(today).inDays;

  final time = timeKnown ? formatEventTime(start, locale) : null;

  // Genuinely-past event, but only where the surface opts in (e.g. a saved
  // list / zine, where past events are a valid state to display). The
  // Happening shelf and search keep the default `allowPast: false`, which
  // preserves the defensive "already-started ⇒ Today" behaviour below.
  if (allowPast && daysFromToday < 0) {
    final monthAbbr = formatMonthAbbr(start, locale);
    final base = isPt ? '${start.day} $monthAbbr' : '$monthAbbr ${start.day}';
    // A saved event can be from a previous year; a bare "25 fev" would then be
    // ambiguous, so append the year whenever it isn't the current one.
    final dated = start.year != now.year ? '$base ${start.year}' : base;
    return time == null ? dated : '$dated, $time';
  }

  if (daysFromToday <= 0) {
    // Same calendar day (or — defensively — already started). The BE
    // 15-day forward filter shouldn't surface negative values on the
    // Happening feed; on search results an event whose `date` is in the
    // past also falls back to "Today".
    return time == null
        ? l10n.discoveryShelfHappeningCardWhenTodayNoTime
        : l10n.discoveryShelfHappeningCardWhenToday(time);
  }
  if (daysFromToday == 1) {
    return time == null
        ? l10n.discoveryShelfHappeningCardWhenTomorrowNoTime
        : l10n.discoveryShelfHappeningCardWhenTomorrow(time);
  }
  if (daysFromToday <= 6) {
    // Short weekday: "Fri" / "Sex" — strip the trailing dot the intl
    // pt-PT short pattern adds ("sex.") and title-case the first letter.
    final raw = DateFormat('EEE', locale).format(start).replaceAll('.', '');
    final weekday = raw.isEmpty
        ? raw
        : '${raw[0].toUpperCase()}${raw.substring(1)}';
    return time == null ? weekday : '$weekday, $time';
  }
  // Absolute fallback for events more than a week out.
  // Order is locale-natural: "May 25" in en, "25 mai" in pt.
  final monthAbbr = formatMonthAbbr(start, locale);
  final date = isPt ? '${start.day} $monthAbbr' : '$monthAbbr ${start.day}';
  return time == null ? date : '$date, $time';
}

/// The "when" string for a venue **"Eventos aqui"** / "Mais eventos" event row
/// (PROD-4398). Unlike [formatEventWhen] this reads [endsAt] as well, so a
/// long-running event no longer collapses to a bare start date that reads as
/// already-past — the core complaint in the venue events-here surface, where the
/// backend intentionally includes ongoing events (past `start_at`, future
/// `end_at`).
///
/// Three shapes, in priority order:
///
///  - **Ongoing** (started before today, ends after now) → "A decorrer até
///    2 mai." / "Running until 2 May". Signals it is happening *now*.
///  - **Future multi-day** (start not yet past, end on a later day) → the span
///    "29 abr – 2 mai", matching the event-detail "Datas" section
///    ([`_RangeRow`] in `event_occurrence_section.dart`).
///  - **Single-day / no end** → unchanged from the legacy row: "Qua., 29 abr.
///    • 21h" (the time is dropped when [timeKnown] is false).
///
/// The venue name is *not* part of this string — the caller appends it after a
/// `•` separator, exactly as before.
///
/// [now] is injectable purely so the ongoing / "still running" branch is
/// deterministically testable; it defaults to the wall clock.
String formatVenueEventWhen({
  required BuildContext context,
  required DateTime startsAt,
  DateTime? endsAt,
  required bool timeKnown,
  DateTime? now,
}) {
  final locale = Localizations.localeOf(context).toString();
  final start = startsAt.toLocal();
  final end = endsAt?.toLocal();

  final nowLocal = (now ?? DateTime.now()).toLocal();
  final today = dayOfLocal(nowLocal);
  final startDay = dayOfLocal(start);

  if (end != null) {
    // Night-adjusted last calendar day, so a 21:00 → 02:00 club night reads as
    // one night rather than a fake two-day span (see [nightAdjustedEndDay]).
    final lastDay = nightAdjustedEndDay(end);

    // Only a genuine multi-day span (its night-adjusted last day is a later
    // calendar day than the start) renders as a range or an ongoing label. A
    // single-night event that merely runs past midnight — e.g. 21:00 → 02:00,
    // viewed after midnight — has `lastDay == startDay` and falls through to
    // the legacy row rather than a misleading "A decorrer até <yesterday>".
    if (lastDay.isAfter(startDay)) {
      // Ongoing: began on an earlier day and has not yet ended (the same "not
      // yet ended" instant the backend filters on). Reads as "happening now"
      // so a past start date can't masquerade as a finished event.
      if (startDay.isBefore(today) && end.isAfter(nowLocal)) {
        return Lt.of(
          context,
        ).venueDetailEventOngoingUntil(_dayMonth(lastDay, locale));
      }
      // Future (or today-starting) multi-day span → "29 abr. – 2 mai.".
      return '${_dayMonth(start, locale)} – ${_dayMonth(lastDay, locale)}';
    }
  }

  // Single-day / single-night / open-ended: the legacy row format, byte-for-byte.
  final base = DateFormat('EEE, d MMM.', locale).format(start);
  if (!timeKnown) return base;
  return '$base • ${formatEventTime(start, locale)}';
}

/// Compact "day month" for a venue event span — "29 abr." (pt) / "29 Apr" (en).
/// Uses the same `d MMM` skeleton the single-day branch renders inside its
/// `EEE, d MMM.` pattern, so a range row and a single-day row in the same list
/// carry the same day-first, locale-native month form. Appends the year only
/// when it isn't the current one, so a long exhibition that crosses New Year
/// ("2 jan. 2027") stays unambiguous.
String _dayMonth(DateTime date, String locale) {
  final base = DateFormat('d MMM', locale).format(date);
  return date.year != DateTime.now().year ? '$base ${date.year}' : base;
}

/// A short, day-level relative label for an event card's date sticker:
/// **"Past event" / "Today" / "Tomorrow" / "This weekend" / "Jun 23"**
/// ("23 jun" in pt).
///
/// Unlike [formatEventWhen] this has NO time and buckets the coming weekend
/// instead of showing a weekday abbreviation — the compact form the chat/
/// onboarding poster sticker wants. Reuses the shared `mapDate*` strings
/// (already translated in every ARB).
///
/// A date **before** today no longer collapses to "Today" (the old
/// `<= 0` bug that mislabelled a genuinely-past event) — it returns the
/// "Past event" marker (`listZineEventPast`) instead. Callers that only ever
/// pass future/ongoing dates never hit this branch.
String formatEventStickerDate({
  required BuildContext context,
  required DateTime startsAt,
}) {
  final l10n = Lt.of(context);
  final locale = Localizations.localeOf(context).toString();
  final isPt = locale.startsWith('pt');

  final start = startsAt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final startDay = DateTime(start.year, start.month, start.day);
  final daysFromToday = startDay.difference(today).inDays;

  if (daysFromToday < 0) return l10n.listZineEventPast;
  if (daysFromToday == 0) return l10n.mapDateToday;
  if (daysFromToday == 1) return l10n.mapDateTomorrow;

  // The coming weekend (Sat/Sun). Today/Tomorrow already win for an adjacent
  // Sat/Sun, so this only tags the other weekend day a few days out. On a
  // Sunday the "coming" Saturday is already next week's, so the branch is
  // skipped — next Saturday is not "this" weekend.
  if (today.weekday != DateTime.sunday) {
    final daysUntilSat = DateTime.saturday - today.weekday;
    final comingSat = today.add(Duration(days: daysUntilSat));
    final comingSun = comingSat.add(const Duration(days: 1));
    if (startDay == comingSat || startDay == comingSun) {
      return l10n.mapDateThisWeekend;
    }
  }

  // Absolute short, locale-ordered: "Jun 23" (en) / "23 jun" (pt).
  final monthAbbr = formatMonthAbbr(start, locale);
  return isPt ? '${start.day} $monthAbbr' : '$monthAbbr ${start.day}';
}

/// Always-absolute event date for a detail row — "Sex 12 Jul, 21h" /
/// "Fri Jul 12, 9 PM" (date only when the time is unknown). Unlike
/// [formatEventWhen] this NEVER collapses to Today / Tomorrow / a weekday-only
/// label: the relative status is surfaced separately as the rotated tag over
/// the title (see [eventRelativeTagLabel]), so the detail row always reads as a
/// clean calendar date. Appends the year when it isn't the current one, so a
/// past event from a previous year isn't ambiguous.
String formatEventDateAbsolute({
  required BuildContext context,
  required DateTime startsAt,
  required bool timeKnown,
}) {
  final locale = Localizations.localeOf(context).toString();
  final isPt = locale.startsWith('pt');
  final start = startsAt.toLocal();
  final now = DateTime.now();

  // Short weekday, trailing dot stripped + first letter upper-cased — mirrors
  // the weekday handling in [formatEventWhen] ("sex." → "Sex").
  final rawWeekday = DateFormat(
    'EEE',
    locale,
  ).format(start).replaceAll('.', '');
  final weekday = rawWeekday.isEmpty
      ? rawWeekday
      : '${rawWeekday[0].toUpperCase()}${rawWeekday.substring(1)}';
  final monthAbbr = formatMonthAbbr(start, locale);
  final dayMonth = isPt ? '${start.day} $monthAbbr' : '$monthAbbr ${start.day}';
  final base = '$weekday $dayMonth';
  final dated = start.year != now.year ? '$base ${start.year}' : base;

  final time = timeKnown ? formatEventTime(start, locale) : null;
  return time == null ? dated : '$dated, $time';
}

/// The relative-timing label for the rotated tag over a detail title —
/// **"Past event" / "Today" / "Tomorrow" / "This weekend" / "This week" /
/// "Next week"** — or `null` when the event is far enough out that only the
/// absolute date (shown in the detail row) is worth surfacing. Reuses the
/// already-translated `mapDate*` and `listZineEventPast` strings, so it adds no
/// new ARB keys. Pairs with [formatEventDateAbsolute]: the row shows the clean
/// date, this tag carries the "when-ish".
/// Whether [eventRelativeTagLabel] would tag [startsAt] as "Past event" — the
/// event's (day-truncated, local) start is before today. The single source of
/// truth for the tag's *past-ness*, so its colour (Soko/Red when past) always
/// agrees with its label. Distinct from a model's `isPast` flag, which can be
/// computed from a different occurrence / end time and disagree with the start
/// date this tag is built from.
bool eventRelativeTagIsPast(DateTime startsAt) {
  final start = startsAt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final startDay = DateTime(start.year, start.month, start.day);
  return startDay.isBefore(today);
}

String? eventRelativeTagLabel({
  required BuildContext context,
  required DateTime startsAt,
}) {
  final l10n = Lt.of(context);
  final start = startsAt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final startDay = DateTime(start.year, start.month, start.day);
  final daysFromToday = startDay.difference(today).inDays;

  if (eventRelativeTagIsPast(startsAt)) return l10n.listZineEventPast;
  if (daysFromToday == 0) return l10n.mapDateToday;
  if (daysFromToday == 1) return l10n.mapDateTomorrow;

  // The coming weekend (Sat/Sun) wins over the generic "this week". On a
  // Sunday the "coming" Saturday is already next week's, so the branch is
  // skipped — next Saturday correctly falls through to "Next week".
  if (today.weekday != DateTime.sunday) {
    final daysUntilSat = DateTime.saturday - today.weekday;
    final comingSat = today.add(Duration(days: daysUntilSat));
    final comingSun = comingSat.add(const Duration(days: 1));
    if (startDay == comingSat || startDay == comingSun) {
      return l10n.mapDateThisWeekend;
    }
  }

  // Remainder of the current week (through Sunday) → "This week"; the seven
  // days after that → "Next week"; anything further shows no tag (the row's
  // absolute date carries it).
  final daysUntilSunday =
      DateTime.sunday - today.weekday; // 0 when today is Sun
  if (daysFromToday <= daysUntilSunday) return l10n.mapDateThisWeek;
  if (daysFromToday <= daysUntilSunday + 7) return l10n.mapDateNextWeek;
  return null;
}
