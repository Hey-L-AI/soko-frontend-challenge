// The single decision point for the relative-timing chip shown on an event
// card / detail hero (`RotatedDateTag`). It replaces the old "one start date →
// one label" logic that mislabelled multi-occurrence events as "Past event":
// a recurring series whose FIRST occurrence has passed, or a backend `startAt`
// that falls back to the earliest occurrence, both read as past even though
// upcoming dates remain.
//
// Instead of reasoning from one date, this reasons from the SHAPE of the whole
// timing:
//
//   * fully past (no upcoming run)      → "Past event"          (red)
//   * >1 discrete upcoming run          → "Recurring event"     (neutral)
//   * one continuous multi-day run      → an exhibition phase:
//         opens today            → "First day"
//         opens tomorrow         → "First day tomorrow"
//         opens later this week  → "Opens this week"
//         opens next week        → "Opens next week"
//         opens further out      → no chip (the date row carries it)
//         final day              → "Last day"            (red)
//         closes ≤7 days          → "Final week"          (red)
//         mid-run                → no chip
//   * one single-day run                → the existing relative label
//                                         (Today / Tomorrow / This weekend / …)
//
// Exhibition (a continuous span) vs recurring (discrete runs) is the pivot: an
// exhibition is ONE multi-day run; a recurring series is MANY runs. Surfaces
// that can't see the collapsed run structure (only a flat occurrence list) pass
// [isRecurringHint] from `occurrence_count` / `has_more_occurrences`.

import 'package:flutter/widgets.dart';

import '../../data/models/chat_message.dart' show ItemSuggestion;
import '../../data/models/event_occurrence.dart';
import '../../data/models/social_proof.dart' show EventDetailResponse2;
import '../../data/models/user_list.dart' show UserListItem;
import '../../data/models/saved_item.dart' show SavedItemType;
import '../../l10n/generated/l10n.dart';
import 'datetime_parsing.dart';
import 'event_when_formatter.dart';
import 'event_day_math.dart' show dayOfLocal, nightAdjustedEndDay;

/// Fill treatment for the chip — maps to a colour at the widget layer
/// ([RotatedDateTag.backgroundFor]).
enum EventChipStyle {
  /// Fully-past event. Soko/Red warning.
  pastRed,

  /// Upcoming single relative date, or a recurring series. Neutral Soko/Paper.
  neutralPaper,

  /// Exhibition opening phase (novelty). Soko/Yellow.
  phaseFirst,

  /// Exhibition final day (last chance). Soko/Red.
  phaseLast,
}

/// The resolved chip. [label] `null` → render no chip at all.
@immutable
class EventTimingChip {
  const EventTimingChip(this.label, this.style);
  const EventTimingChip.none()
    : label = null,
      style = EventChipStyle.neutralPaper;

  final String? label;
  final EventChipStyle style;

  bool get isVisible => label != null;
}

/// One discrete run of an event — a single occurrence, or a continuous
/// exhibition span. [end] null ⇒ a point-in-time / unknown-end run.
@immutable
class EventTimingSpan {
  const EventTimingSpan(this.start, this.end);
  final DateTime start;
  final DateTime? end;
}

/// The shared classifier. Every surface normalises its own model onto
/// [representativeStart] + [spans] (+ optional hints) and calls this, so the
/// past/recurring/exhibition/single decision lives in exactly one place.
///
/// - [representativeStart]: the date the single-occurrence relative label reads
///   from (the next-future occurrence on most surfaces).
/// - [spans]: the discrete runs (past + future both fine). May be empty.
/// - [isPastOverride]: the model's authoritative past flag when it has one
///   (event detail's `EventDetailResponse2.isPast`, false ⇔ upcoming exists).
///   Wins over the span-derived past check.
/// - [isRecurringHint]: force the recurring branch when the span list is a
///   future-only or truncated view that can't reveal a >1 run count
///   (`occurrence_count > 1` / `has_more_occurrences`).
EventTimingChip resolveEventTimingChip({
  required BuildContext context,
  required DateTime? representativeStart,
  required List<EventTimingSpan> spans,
  bool? isPastOverride,
  bool isRecurringHint = false,
}) {
  final l10n = Lt.of(context);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = today.add(const Duration(days: 1));

  // Last day this event is "live", night-adjusted so a 02:00 close still counts
  // as the prior day (matches the feed range label).
  DateTime lastLiveDay(EventTimingSpan s) =>
      s.end != null ? nightAdjustedEndDay(s.end!) : dayOfLocal(s.start);

  final bool hasUpcoming = isPastOverride != null
      ? !isPastOverride
      : spans.any((s) => !lastLiveDay(s).isBefore(today));

  // 1. Fully past (incl. an all-past recurring series).
  if (!hasUpcoming) {
    return EventTimingChip(l10n.listZineEventPast, EventChipStyle.pastRed);
  }

  // 2a. Recurring: more than one discrete run, or a hint from a count field.
  if (isRecurringHint || spans.length > 1) {
    return EventTimingChip(
      l10n.eventTimingRecurring,
      EventChipStyle.neutralPaper,
    );
  }

  // 2b. Exhibition: one continuous multi-day run.
  if (spans.length == 1 && spans.first.end != null) {
    final span = spans.first;
    final firstDay = dayOfLocal(span.start);
    final lastDay = nightAdjustedEndDay(span.end!);
    if (lastDay.isAfter(firstDay)) {
      if (firstDay == today) {
        return EventTimingChip(
          l10n.eventTimingFirstDay,
          EventChipStyle.phaseFirst,
        );
      }
      if (firstDay == tomorrow) {
        return EventTimingChip(
          l10n.eventTimingFirstDayTomorrow,
          EventChipStyle.phaseFirst,
        );
      }
      if (firstDay.isAfter(today)) {
        // Same week windows as [eventRelativeTagLabel]: the rest of the
        // current calendar week (through Sunday) → "Opens this week"; the
        // seven days after that → "Opens next week"; anything further out
        // shows no chip — the absolute date row already carries it. (The old
        // unbounded branch stamped "Opens next week" on an exhibition opening
        // months away.)
        final daysToOpen = firstDay.difference(today).inDays;
        final daysUntilSunday =
            DateTime.sunday - today.weekday; // 0 when today is Sun
        if (daysToOpen <= daysUntilSunday) {
          return EventTimingChip(
            l10n.eventTimingOpensThisWeek,
            EventChipStyle.phaseFirst,
          );
        }
        if (daysToOpen <= daysUntilSunday + 7) {
          return EventTimingChip(
            l10n.eventTimingOpensNextWeek,
            EventChipStyle.phaseFirst,
          );
        }
        return const EventTimingChip.none();
      }
      // Already running.
      if (lastDay == today) {
        return EventTimingChip(
          l10n.eventTimingLastDay,
          EventChipStyle.phaseLast,
        );
      }
      // Closing within the coming week — "última semana" last-chance cue for a
      // long run that isn't down to its final day yet.
      final daysToClose = lastDay.difference(today).inDays;
      if (daysToClose > 0 && daysToClose <= 7) {
        return EventTimingChip(
          l10n.eventTimingFinalWeek,
          EventChipStyle.phaseLast,
        );
      }
      // Mid-run — no chip (the date row already carries the span).
      return const EventTimingChip.none();
    }
  }

  // 2c. Single-day upcoming event → the existing relative label. A null label
  // (event beyond next week) is explicitly the no-chip state.
  if (representativeStart == null) return const EventTimingChip.none();
  final relativeLabel = eventRelativeTagLabel(
    context: context,
    startsAt: representativeStart,
  );
  if (relativeLabel == null) return const EventTimingChip.none();
  return EventTimingChip(relativeLabel, EventChipStyle.neutralPaper);
}

// ── Per-model adapters ───────────────────────────────────────────────────────
// Thin mappers so no surface duplicates the model→spans normalisation.

/// Event detail hero + title ([EventDetailResponse2] + the future-only
/// occurrence list). Prefers the backend-collapsed [EventDetailResponse2.dateRanges]
/// for the run count (one multi-day range = exhibition; many = recurring) and
/// the authoritative [EventDetailResponse2.isPast] flag.
EventTimingChip chipForEventDetail(
  BuildContext context,
  EventDetailResponse2 event,
) {
  final spans = event.dateRanges
      .map((r) => EventTimingSpan(r.start, r.end))
      .toList(growable: false);
  return resolveEventTimingChip(
    context: context,
    representativeStart: event.startAt,
    spans: spans,
    isPastOverride: event.isPast,
  );
}

/// Chat / onboarding event card ([ItemSuggestion]). Uses the future-only
/// occurrences for the timing shape, with `occurrence_count` / `has_more`
/// as the recurring hint (the list can be a truncated view), and falls back to
/// the flat `date` when no occurrences are present — routing a stale past date
/// through the past check instead of blindly labelling it "Past event".
EventTimingChip? chipForItemSuggestion(
  BuildContext context,
  ItemSuggestion event,
) {
  // Preserve the existing "unknown date precision → no sticker" guard.
  if (event.datePrecision == 'unknown') return null;

  final future = event.occurrences.futureOnly();
  final List<EventTimingSpan> spans;
  final DateTime? representativeStart;
  if (future.isNotEmpty) {
    spans = future
        .map((o) => EventTimingSpan(o.startAt, o.endAt))
        .toList(growable: false);
    representativeStart = future.first.startAt;
  } else {
    final flat = parseBackendDateTime(event.date);
    if (flat == null) return null;
    spans = [EventTimingSpan(flat, null)];
    representativeStart = flat;
  }

  final recurringHint =
      event.hasMoreOccurrences ||
      (event.occurrenceCount ?? 0) > 1 ||
      event.occurrences.length > 1;

  final chip = resolveEventTimingChip(
    context: context,
    representativeStart: representativeStart,
    spans: spans,
    isRecurringHint: recurringHint,
  );
  return chip.isVisible ? chip : null;
}

/// Zine saved-list event card ([UserListItem]). Built from the item's occurrence
/// dates (all of them, past + future) and day set — `occurrenceDates.length > 1`
/// is recurring; a single occurrence spanning `occurrenceDays.length > 1` is an
/// exhibition; otherwise a single-day event.
EventTimingChip chipForUserListItem(BuildContext context, UserListItem item) {
  if (item.itemType != SavedItemType.event) {
    return const EventTimingChip.none();
  }
  final starts = item.occurrenceDates; // ASC, may include past dates
  final List<EventTimingSpan> spans;
  if (starts.length > 1) {
    spans = starts.map((d) => EventTimingSpan(d, null)).toList(growable: false);
  } else if (starts.length == 1) {
    final days = item.occurrenceDays;
    final end = days.length > 1
        ? days.reduce((a, b) => a.isAfter(b) ? a : b)
        : null;
    spans = [EventTimingSpan(starts.first, end)];
  } else {
    final d = item.eventDate;
    spans = d != null ? [EventTimingSpan(d, null)] : const [];
  }
  return resolveEventTimingChip(
    context: context,
    representativeStart: item.eventDate,
    spans: spans,
  );
}

/// A bare single start ([onboarding vibe] — only a `startsAt` is known). Always
/// the single/past path; never recurring or exhibition.
EventTimingChip chipForSingleStart(BuildContext context, DateTime? startsAt) {
  return resolveEventTimingChip(
    context: context,
    representativeStart: startsAt,
    spans: startsAt != null ? [EventTimingSpan(startsAt, null)] : const [],
  );
}
