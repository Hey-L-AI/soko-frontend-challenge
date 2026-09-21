import '../../core/utils/datetime_parsing.dart';

/// Model for an event occurrence (a specific date/time instance of an event)
class EventOccurrence {
  final String id;
  final DateTime startAt;
  final DateTime? endAt;
  final bool isAllDay;
  final String? venueId;
  final String? venueName;
  final String? location; // Combined "Venue, City" string

  /// The occurrence's own city, for events whose location isn't a linked venue
  /// (`location_city` on the legacy occurrence payload). PROD-3950 — the Daily
  /// Drop page's event subtitle reads this first: an event's city lives on the
  /// occurrence, not on the event, and `EventDetailResponse2.city` is null for
  /// events without a linked venue.
  final String? locationCity;

  /// City of the venue linked to this occurrence, when there is one — the
  /// fallback for [locationCity]. Read off the nested `venue` object the legacy
  /// occurrence payload carries.
  final String? venueCity;

  /// Whether the BE has a confirmed time for this occurrence (vs date-only
  /// sources that defaulted to 00:00 at ingest). Defaults to `true` for
  /// transitional safety — payloads predating the BE flag render with the
  /// time visible, matching the legacy behaviour.
  final bool timeKnown;

  const EventOccurrence({
    required this.id,
    required this.startAt,
    this.endAt,
    this.isAllDay = false,
    this.venueId,
    this.venueName,
    this.location,
    this.locationCity,
    this.venueCity,
    this.timeKnown = true,
  });

  factory EventOccurrence.fromJson(Map<String, dynamic> json) {
    return EventOccurrence(
      id: json['id'] as String,
      startAt: parseBackendDateTimeRequired(json['start_at'] as String),
      endAt: parseBackendDateTime(json['end_at'] as String?),
      isAllDay: json['is_all_day'] as bool? ?? false,
      venueId: json['venue_id'] as String?,
      venueName: json['venue_name'] as String?,
      location: json['location'] as String?,
      locationCity: json['location_city'] as String?,
      venueCity: (json['venue'] as Map<String, dynamic>?)?['city'] as String?,
      timeKnown: json['time_known'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'start_at': startAt.toIso8601String(),
      if (endAt != null) 'end_at': endAt!.toIso8601String(),
      'is_all_day': isAllDay,
      if (venueId != null) 'venue_id': venueId,
      if (venueName != null) 'venue_name': venueName,
      if (location != null) 'location': location,
      if (locationCity != null) 'location_city': locationCity,
      if (venueCity != null) 'venue': {'city': venueCity},
      'time_known': timeKnown,
    };
  }

  EventOccurrence copyWith({
    String? id,
    DateTime? startAt,
    DateTime? endAt,
    bool? isAllDay,
    String? venueId,
    String? venueName,
    String? location,
    bool? timeKnown,
  }) {
    return EventOccurrence(
      id: id ?? this.id,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      isAllDay: isAllDay ?? this.isAllDay,
      venueId: venueId ?? this.venueId,
      venueName: venueName ?? this.venueName,
      location: location ?? this.location,
      timeKnown: timeKnown ?? this.timeKnown,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EventOccurrence && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'EventOccurrence(id: $id, startAt: $startAt, endAt: $endAt, '
        'isAllDay: $isAllDay, venueName: $venueName, location: $location)';
  }
}

/// Extension to filter event occurrences to future/ongoing only.
/// Used as a client-side safety net in addition to backend filtering.
extension EventOccurrenceFiltering on List<EventOccurrence> {
  List<EventOccurrence> futureOnly() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    return where((o) {
      final effectiveEnd = o.endAt ?? o.startAt;
      return !effectiveEnd.toLocal().isBefore(todayStart);
    }).toList()..sort((a, b) => a.startAt.compareTo(b.startAt));
  }
}
