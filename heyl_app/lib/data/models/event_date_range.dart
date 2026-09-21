import '../../core/utils/datetime_parsing.dart';

/// A contiguous span of an event's occurrences (PROD-3116).
///
/// Backend-computed (`EventDetailOut.date_ranges` / the list-item event blob's
/// `date_ranges`) so the "Dates" section can render "14–17 Jul" instead of one
/// repeated-title row per occurrence. Consecutive occurrences collapse into one
/// range; a significant gap (> 2 calendar days) starts a new range.
///
/// [occurrenceIds] preserves the individual occurrence UUIDs (ascending by
/// start) so the client can expand a range back to its occurrences — e.g. for
/// per-occurrence saving.
class EventDateRange {
  final DateTime start;
  final DateTime end;
  final int occurrenceCount;
  final List<String> occurrenceIds;

  const EventDateRange({
    required this.start,
    required this.end,
    required this.occurrenceCount,
    this.occurrenceIds = const [],
  });

  /// Whether this range folds more than one occurrence (worth showing as a span).
  bool get isMulti => occurrenceCount > 1;

  factory EventDateRange.fromJson(Map<String, dynamic> json) {
    // TODO(PROD-2264): identity-field casts retained pending Phase 3
    // `requireString` helper (see docs/platform/error-handling-discipline.md).
    // `start`/`end` define the range and are required by the OpenAPI contract.
    return EventDateRange(
      start: parseBackendDateTimeRequired(
        json['start']
            as String, // gstack:allow check-error-handling json-cast-string
      ),
      end: parseBackendDateTimeRequired(
        json['end']
            as String, // gstack:allow check-error-handling json-cast-string
      ),
      occurrenceCount: json['occurrence_count'] as int? ?? 1,
      occurrenceIds:
          (json['occurrence_ids'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );
  }

  @override
  String toString() =>
      'EventDateRange(start: $start, end: $end, count: $occurrenceCount)';
}
