import 'package:intl/intl.dart';

/// Compact, locale-aware time format used across event surfaces (Happening
/// shelf cards, event detail occurrence rows, venue "Eventos aqui" rows).
///
/// PT: "21h" on the hour, "21h30" off the hour, "9h" / "9h15" for
/// single-digit hours. Midnight is the only padded case: "00h" / "00h05" —
/// the bare "0h" reads as a glitch, whereas "9h" reads as 9am at a glance.
/// EN: locale-aware "9 PM" / "9:30 PM" via [DateFormat].
///
/// Callers must hide the time component entirely when the BE reports
/// `time_known=false` for the event — this helper assumes the time is known.
String formatEventTime(DateTime when, String locale) {
  final hasMinutes = when.minute != 0;
  if (locale.startsWith('pt')) {
    final padMidnight = when.hour == 0;
    final pattern = padMidnight
        ? (hasMinutes ? "HH'h'mm" : "HH'h'")
        : (hasMinutes ? "H'h'mm" : "H'h'");
    return DateFormat(pattern, locale).format(when);
  }
  final pattern = hasMinutes ? 'h:mm a' : 'h a';
  return DateFormat(pattern, locale).format(when);
}
