// PROD-2525 T-K3 — DTOs mirroring `EventReminderOut` /
// `EventReminderListOut` / `CreateEventReminderRequest` /
// `DeleteReminderOut` in `open-api/heyl-webapp-v1.openapi.yaml`
// (PROD-2516 T-K1 + PROD-2517 T-K2 backend).

enum EventReminderStatus {
  pending,
  fired,
  cancelled,
  eventPassed,
  unknown;

  static EventReminderStatus fromWire(String? raw) {
    switch (raw) {
      case 'pending':
        return EventReminderStatus.pending;
      case 'fired':
        return EventReminderStatus.fired;
      case 'cancelled':
        return EventReminderStatus.cancelled;
      case 'event_passed':
        return EventReminderStatus.eventPassed;
      default:
        return EventReminderStatus.unknown;
    }
  }
}

class EventReminder {
  final String id;
  final String eventId;
  final String eventOccurrenceId;
  final int offsetMinutes;
  final DateTime fireAt;
  final EventReminderStatus status;
  final DateTime createdAt;
  final DateTime? firedAt;

  const EventReminder({
    required this.id,
    required this.eventId,
    required this.eventOccurrenceId,
    required this.offsetMinutes,
    required this.fireAt,
    required this.status,
    required this.createdAt,
    required this.firedAt,
  });

  bool get isPending => status == EventReminderStatus.pending;

  factory EventReminder.fromJson(Map<String, dynamic> json) {
    return EventReminder(
      // Defensive nullable cast on the identity field (see
      // docs/platform/error-handling-discipline.md). A missing `id`
      // would otherwise crash the upcoming-reminders list via TypeError.
      id: json['id'] as String? ?? '',
      eventId: json['event_id'] as String? ?? '',
      eventOccurrenceId: json['event_occurrence_id'] as String? ?? '',
      offsetMinutes: (json['offset_minutes'] as num?)?.toInt() ?? 0,
      fireAt: _parseTime(json['fire_at']) ?? DateTime.now().toUtc(),
      status: EventReminderStatus.fromWire(json['status'] as String?),
      createdAt: _parseTime(json['created_at']) ?? DateTime.now().toUtc(),
      firedAt: _parseTime(json['fired_at']),
    );
  }

  static DateTime? _parseTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}

class EventReminderList {
  final List<EventReminder> items;
  const EventReminderList({required this.items});

  factory EventReminderList.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    return EventReminderList(
      items: raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(EventReminder.fromJson)
                .toList(growable: false)
          : const [],
    );
  }
}

/// One pending reminder as it appears inside an
/// [EventReminderEventCard] — the occurrence's date + venue context are
/// inlined so the "My reminders" sheet can render the specific
/// occurrence the reminder fires for without a second round-trip to
/// `/events/{id}`. Distinct from [EventReminder] because the latter is
/// the canonical per-event reminder shape (no occurrence/venue context
/// — that's what the event-detail screen reads from its own provider).
class EventReminderCard {
  final String id;
  final String eventOccurrenceId;
  final int offsetMinutes;
  final DateTime fireAt;
  final DateTime occurrenceStartAt;
  final DateTime? occurrenceEndAt;
  final String? venueId;
  final String? venueName;
  final String? venueAddress;
  final String? venueCity;
  final double? latitude;
  final double? longitude;

  const EventReminderCard({
    required this.id,
    required this.eventOccurrenceId,
    required this.offsetMinutes,
    required this.fireAt,
    required this.occurrenceStartAt,
    required this.occurrenceEndAt,
    required this.venueId,
    required this.venueName,
    required this.venueAddress,
    required this.venueCity,
    required this.latitude,
    required this.longitude,
  });

  factory EventReminderCard.fromJson(Map<String, dynamic> json) {
    return EventReminderCard(
      id: json['id'] as String? ?? '',
      eventOccurrenceId: json['event_occurrence_id'] as String? ?? '',
      offsetMinutes: (json['offset_minutes'] as num?)?.toInt() ?? 0,
      fireAt:
          EventReminder._parseTime(json['fire_at']) ?? DateTime.now().toUtc(),
      occurrenceStartAt:
          EventReminder._parseTime(json['occurrence_start_at']) ??
          DateTime.now().toUtc(),
      occurrenceEndAt: EventReminder._parseTime(json['occurrence_end_at']),
      venueId: json['venue_id'] as String?,
      venueName: json['venue_name'] as String?,
      venueAddress: json['venue_address'] as String?,
      venueCity: json['venue_city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
    );
  }
}

/// One distinct event the current user has at least one pending
/// reminder for. Used by the "My reminders" sheet on Discovery / Yours.
/// Each card carries the event's display fields plus the user's
/// pending reminders for it (sorted by `fire_at` ASC).
class EventReminderEventCard {
  final String eventId;
  final String title;
  final List<EventReminderCard> reminders;
  final String? descriptionShort;
  final String? imageUrl;
  final String? category;
  final String? url;

  const EventReminderEventCard({
    required this.eventId,
    required this.title,
    required this.reminders,
    required this.descriptionShort,
    required this.imageUrl,
    required this.category,
    required this.url,
  });

  factory EventReminderEventCard.fromJson(Map<String, dynamic> json) {
    final rawReminders = json['reminders'];
    return EventReminderEventCard(
      eventId: json['event_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      reminders: rawReminders is List
          ? rawReminders
                .whereType<Map<String, dynamic>>()
                .map(EventReminderCard.fromJson)
                .toList(growable: false)
          : const [],
      descriptionShort: json['description_short'] as String?,
      imageUrl: json['image_url'] as String?,
      category: json['category'] as String?,
      url: json['url'] as String?,
    );
  }
}

/// Wrapper for the "events the user has pending reminders for" list.
/// Mirrors `EventsWithRemindersOut` in the OpenAPI spec.
class EventsWithReminders {
  final List<EventReminderEventCard> items;
  final int total;

  const EventsWithReminders({required this.items, required this.total});

  factory EventsWithReminders.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final items = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(EventReminderEventCard.fromJson)
              .toList(growable: false)
        : const <EventReminderEventCard>[];
    return EventsWithReminders(
      items: items,
      // Defensive — fall back to derived `len(items)` if the server
      // ever drops the count field. Cheaper than failing to render.
      total: (json['total'] as num?)?.toInt() ?? items.length,
    );
  }
}

/// Canonical offset chip presets shared between the per-event picker
/// (T-K3 sheet) and the user-defaults editor (preferences screen).
class ReminderOffset {
  final int minutes;
  final String labelKey;

  const ReminderOffset({required this.minutes, required this.labelKey});

  static const presets = <ReminderOffset>[
    ReminderOffset(minutes: 15, labelKey: 'reminderOffset15Min'),
    ReminderOffset(minutes: 30, labelKey: 'reminderOffset30Min'),
    ReminderOffset(minutes: 60, labelKey: 'reminderOffset1Hour'),
    ReminderOffset(minutes: 1440, labelKey: 'reminderOffset1Day'),
    ReminderOffset(minutes: 10080, labelKey: 'reminderOffset1Week'),
  ];

  /// Max offset enforced by the spec (`offset_minutes` 1-40320).
  static const int maxOffsetMinutes = 40320;
}
