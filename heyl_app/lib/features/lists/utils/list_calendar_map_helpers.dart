import '../../../data/models/models.dart';

/// Helpers shared between the new list-page bodies (Zine view + List view)
/// — both compose around a multi-pin map of unique venues and a calendar
/// that auto-picks the month of the closest events to today.

/// Returns one [UserListItem] per unique physical venue, dropping items
/// without resolved coordinates. Lat/lng is the dedupe key (not `venueId`)
/// so ad-hoc events that resolve to a venue location collapse alongside
/// place rows pointing at the same venue. Per
/// [`docs/designs/list-page-redesign.md`](../../../../docs/designs/list-page-redesign.md)
/// § 9.2 #21 — "one pin per unique venue".
///
/// PROD-1967 — the **list page** no longer calls this; its cover map now
/// reads from `UnifiedListState.mapPins`, which is server-deduped by the
/// slim endpoint (PROD-1966 § Server-side dedupe semantics). This helper
/// is retained for the `/lists` hub map, which builds its pin set
/// client-side from independent `listMyMapPins` + `listMyCalendarEvents`
/// payloads and still needs FE dedupe across the two sources.
List<UserListItem> dedupeItemsForMap(Iterable<UserListItem> items) {
  final seen = <String>{};
  final out = <UserListItem>[];
  for (final item in items) {
    if (item.latitude == null || item.longitude == null) continue;
    final key = '${item.latitude},${item.longitude}';
    if (seen.add(key)) out.add(item);
  }
  return out;
}

/// Returns the first day of the month containing the closest event to
/// today, per § 6 of the list-page redesign doc:
///
/// 1. If any upcoming dates (>= now) exist → the month of the **earliest**
///    upcoming one.
/// 2. Otherwise, if any past dates exist → the month of the **latest**
///    past one.
/// 3. If [dates] yields no non-null entries → returns null. Callers should
///    hide the calendar entirely (per § 9.2 #9).
///
/// Accepts nullables so callers can pass results from `eventDate` getters
/// directly without filtering first.
DateTime? autoPickMonthFromDates(Iterable<DateTime?> dates) {
  final concrete = dates.whereType<DateTime>().toList();
  if (concrete.isEmpty) return null;
  final now = DateTime.now();
  final upcoming = concrete.where((d) => !d.isBefore(now)).toList()..sort();
  if (upcoming.isNotEmpty) return _firstOfMonth(upcoming.first);
  final past = [...concrete]..sort((a, b) => b.compareTo(a));
  return _firstOfMonth(past.first);
}

/// Convenience — for a list of [UserListItem]s, derive the auto-pick
/// month from each item's `eventDate` getter. Wraps [autoPickMonthFromDates].
DateTime? autoPickMonthFromItems(Iterable<UserListItem> items) {
  return autoPickMonthFromDates(items.map((i) => i.eventDate));
}

DateTime _firstOfMonth(DateTime d) => DateTime(d.year, d.month, 1);
