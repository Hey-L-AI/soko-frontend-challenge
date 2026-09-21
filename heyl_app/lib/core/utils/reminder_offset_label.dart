import '../../l10n/generated/l10n.dart';

/// Friendly label for a reminder lead-time in minutes — collapses to the
/// nearest natural unit (`1h` vs `60m`, `1d` vs `1440m`, `1sem` vs
/// `10080m`). Shared by the event-detail reminder picker and the
/// "my reminders" sheet so both render offsets identically.
String reminderOffsetLabel(Lt l10n, int minutes) {
  if (minutes < 60) return l10n.reminderOffsetMinutes(minutes);
  if (minutes < 1440) {
    final hours = minutes ~/ 60;
    final rem = minutes - hours * 60;
    if (rem == 0) return l10n.reminderOffsetHours(hours);
  }
  if (minutes < 10080) {
    final days = minutes ~/ 1440;
    final rem = minutes - days * 1440;
    if (rem == 0) return l10n.reminderOffsetDays(days);
  }
  final weeks = minutes ~/ 10080;
  final rem = minutes - weeks * 10080;
  if (rem == 0 && weeks >= 1) {
    return l10n.reminderOffsetWeeks(weeks);
  }
  return l10n.reminderOffsetMinutes(minutes);
}
