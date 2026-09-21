import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/entity_signal.dart';
import '../../models/event_reminder.dart';
import '../../models/notification_item.dart';
import 'api_client.dart';

/// PROD-2525 T-K3 — wraps the event-reminders endpoints defined in
/// `open-api/heyl-webapp-v1.openapi.yaml` (PROD-2516 T-K1 backend).
class EventRemindersApi {
  final ApiClient _apiClient;

  EventRemindersApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// GET /api/v1/app/events/{event_id}/reminders
  Future<EventReminderList> listForEvent(String eventId) async {
    final response = await _dio.get(ApiConstants.eventReminders(eventId));
    return EventReminderList.fromJson(response.data as Map<String, dynamic>);
  }

  /// PUT /api/v1/app/events/{event_id}/reminders — reconcile the caller's
  /// reminders to the FULL desired set. The reminders API is THE going writer
  /// (PROD-2930 #21): the backend reconciles to exactly [reminders], stamps
  /// `marked_going_at` iff non-empty, and records occurrence-level going marks.
  /// Returns the resolved signal from `ReminderConfigOut` (reminders come back
  /// too, but callers read them via the reminder-list provider).
  Future<EntitySignal> setConfig(
    String eventId,
    List<({String occurrenceId, int offsetMinutes})> reminders,
  ) async {
    final response = await _dio.put(
      ApiConstants.eventReminders(eventId),
      data: {
        'reminders': [
          for (final r in reminders)
            {
              'occurrence_id': r.occurrenceId,
              'offset_minutes': r.offsetMinutes,
            },
        ],
      },
    );
    final data = response.data as Map<String, dynamic>;
    return EntitySignal.fromJson(data['signal'] as Map<String, dynamic>);
  }

  /// POST /api/v1/app/events/{event_id}/reminders — idempotent on
  /// `(user, occurrence, offset_minutes)`.
  Future<EventReminder> create({
    required String eventId,
    required String occurrenceId,
    required int offsetMinutes,
  }) async {
    final response = await _dio.post(
      ApiConstants.eventReminders(eventId),
      data: {'occurrence_id': occurrenceId, 'offset_minutes': offsetMinutes},
    );
    return EventReminder.fromJson(response.data as Map<String, dynamic>);
  }

  /// DELETE /api/v1/app/event-reminders/{reminder_id} — idempotent cancel.
  /// Returns `changed=true` only on the first delete.
  Future<NotificationChangeResult> cancel(String reminderId) async {
    final response = await _dio.delete(
      ApiConstants.eventReminderById(reminderId),
    );
    return NotificationChangeResult.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// GET /api/v1/app/users/me/event-reminders — every pending reminder
  /// for the current user, soonest first.
  Future<EventReminderList> listUpcoming() async {
    final response = await _dio.get(ApiConstants.myEventReminders);
    return EventReminderList.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/app/users/me/events-with-reminders — one row per
  /// distinct event the current user has at least one pending reminder
  /// on, with the user's reminders inlined (sorted by `fire_at` ASC).
  /// Outer items ordered by each event's soonest pending `fire_at`.
  /// Powers the "My reminders" bottom sheet on Discovery + Yours.
  Future<EventsWithReminders> listMyEventsWithReminders() async {
    final response = await _dio.get(ApiConstants.myEventsWithReminders);
    return EventsWithReminders.fromJson(response.data as Map<String, dynamic>);
  }
}
