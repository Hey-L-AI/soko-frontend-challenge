import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/event_reminder.dart';
import '../../../providers/api_provider.dart';

/// Raw reminder list for [eventId] — every reminder the current user
/// ever set for this event across all occurrences, in all statuses
/// (`pending` / `fired` / `cancelled` / `event_passed`). Mirrors
/// `GET /api/v1/app/events/{event_id}/reminders`.
///
/// The bell button in the event-detail chrome derives its filled/
/// outline state from this list, but only counts pending rows whose
/// occurrence is still upcoming — matching the picker sheet's own
/// filter in `_loadExisting`. Filtering has to happen at the call
/// site because the upcoming-occurrence set is derived from the
/// event-detail snapshot (past-occurrence rows would otherwise light
/// the bell for a reminder the picker can't show or cancel — see
/// `reminder_picker_sheet.dart:171-184`).
///
/// `autoDispose.family` so the cache only lives for the lifetime of
/// the chrome that watches it; the picker's confirm path calls
/// `ref.invalidate(eventReminderListProvider(eventId))` so the icon
/// flips immediately after a save (POST/DELETE) instead of waiting
/// for the next mount.
final eventReminderListProvider = FutureProvider.autoDispose
    .family<EventReminderList, String>((ref, eventId) async {
      final api = ref.read(eventRemindersApiProvider);
      return api.listForEvent(eventId);
    });
