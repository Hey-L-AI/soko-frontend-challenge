import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/event_reminder.dart';
import '../../../providers/api_provider.dart';

/// One-shot fetch for the "My reminders" bottom sheet — every distinct
/// event the current user has at least one pending reminder on, with
/// the user's reminders inlined per event.
///
/// `autoDispose` so the cache only lives while the sheet is mounted;
/// closing + reopening the sheet always re-fetches a fresh list. If the
/// user lands here after saving a new reminder in the event-detail
/// picker, the cache miss surfaces the freshly-saved row without
/// needing an explicit `ref.invalidate` from the picker.
final myEventsWithRemindersProvider =
    FutureProvider.autoDispose<EventsWithReminders>((ref) async {
      final api = ref.read(eventRemindersApiProvider);
      return api.listMyEventsWithReminders();
    });
