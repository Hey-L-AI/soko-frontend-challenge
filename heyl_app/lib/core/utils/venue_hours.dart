// PROD-1717 — locale-aware venue opening-hours formatter.
//
// Backend (Google Places) returns opening hours as either:
//   * a string per weekday, e.g. "9:30 AM – 12:30 PM, 2:30 – 6:00 PM",
//     "Closed", or "Open 24 hours"
//   * a list of slots, e.g. [{"open":"11:00","close":"21:00"}]
//
// Locale rules:
//   * EN: pass through Google's textual output unchanged. Closed / 24h
//     markers still get the localized label; slot lists are rendered as
//     HH:MM - HH:MM since they aren't Google's textual form.
//   * PT / PT-BR: re-render every range as `HH:MM - HH:MM` (24h, colon,
//     leading-zero hours, minutes always two digits incl. ":00", ASCII
//     hyphen with single spaces).
//
// 24-hour collapse is conservative: only a literal "Open 24 hours" /
// "24 horas" / "24/7" marker, OR a single period that spans the full
// day (00:00 → 00:00 or 00:00 → 24:00). Multi-period inputs — the
// real "12–6 am, 5 pm–12 am" from Casa Capitão — NEVER collapse, even
// when the combined ranges happen to cover the day.
//
// Shared AM/PM marker: Google emits ranges like "2:30 – 6:00 PM" where
// only one side carries the marker. The unmarked side inherits it.
//
// Defensive contract: if any part of the input fails to parse, return
// the original string unchanged and log via debugPrint, so unhandled
// formats surface in testing without making the UI worse than before.

import 'package:flutter/foundation.dart';

/// Localized strings used by [formatVenueHours]. Caller pulls these
/// from `Lt.of(context)` and passes them in so this file stays
/// pure-Dart and unit-testable.
class VenueHoursStrings {
  final String closed;
  final String open24h;

  const VenueHoursStrings({required this.closed, required this.open24h});
}

/// Format a single weekday's opening-hours value for display. Returns
/// `null` when there's nothing to show (null / empty input).
String? formatVenueHours(
  dynamic value,
  String locale,
  VenueHoursStrings strings,
) {
  if (value == null) return null;
  final isPt = locale.startsWith('pt');

  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return _formatString(trimmed, isPt, strings);
  }

  if (value is List) {
    if (value.isEmpty) return null;
    return _formatSlotList(value, strings);
  }

  debugPrint('[venue_hours] unhandled value type: ${value.runtimeType}');
  return value.toString();
}

String _formatString(String raw, bool isPt, VenueHoursStrings strings) {
  final parts = raw
      .split(',')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  final multiPart = parts.length > 1;

  final rendered = <String>[];
  for (final part in parts) {
    final p = _formatStringPart(part, isPt, strings, allow24h: !multiPart);
    if (p == null) {
      debugPrint('[venue_hours] unhandled string: $raw');
      return raw;
    }
    rendered.add(p);
  }
  return rendered.join(', ');
}

/// Format one comma-separated chunk. Returns null on parse failure so
/// the caller can fall back to the original full string.
String? _formatStringPart(
  String raw,
  bool isPt,
  VenueHoursStrings strings, {
  required bool allow24h,
}) {
  final lower = raw.toLowerCase();

  if (lower == 'closed' || lower == 'fechado') return strings.closed;

  if (lower.contains('24 hour') ||
      lower.contains('24 horas') ||
      lower == '24/7') {
    return strings.open24h;
  }

  final pieces = raw.split(RegExp(r'\s*[-–—]\s*'));
  if (pieces.length != 2) return null;

  final range = _parseRangeWithInheritance(pieces[0], pieces[1]);
  if (range == null) return null;
  final (oh, om, ch, cm) = range;

  if (allow24h && _isFullDay(oh, om, ch, cm)) return strings.open24h;

  if (!isPt) return raw;

  final closeH = ch == 24 ? 0 : ch;
  return '${_pad(oh)}:${_pad(om)} - ${_pad(closeH)}:${_pad(cm)}';
}

String? _formatSlotList(List value, VenueHoursStrings strings) {
  final multi = value.length > 1;
  final out = <String>[];
  for (final slot in value) {
    if (slot is! Map) {
      debugPrint('[venue_hours] unhandled slot shape: $slot');
      return value.toString();
    }
    final open = slot['open']?.toString();
    final close = slot['close']?.toString();
    if (open == null || close == null) {
      debugPrint('[venue_hours] missing open/close: $slot');
      return value.toString();
    }
    final o = _parseTime(open);
    final c = _parseTime(close);
    if (o == null || c == null) {
      debugPrint('[venue_hours] unhandled slot time: $slot');
      return value.toString();
    }
    if (!multi && _isFullDay(o.$1, o.$2, c.$1, c.$2)) {
      return strings.open24h;
    }
    final closeH = c.$1 == 24 ? 0 : c.$1;
    out.add('${_pad(o.$1)}:${_pad(o.$2)} - ${_pad(closeH)}:${_pad(c.$2)}');
  }
  return out.join(', ');
}

/// Parse a range where either side may inherit the other's AM/PM
/// marker. Examples upstream is known to emit:
///   * "2:30 – 6:00 PM"  — left inherits PM
///   * "12 – 6 am"       — left inherits AM
///   * "5 pm – 12 am"    — both marked, no inheritance
///   * "14:00 - 21:00"   — neither marked, 24h on both sides
(int, int, int, int)? _parseRangeWithInheritance(String left, String right) {
  final leftTrim = left.trim();
  final rightTrim = right.trim();
  final leftMarker = _findAmPm(leftTrim);
  final rightMarker = _findAmPm(rightTrim);

  var resolvedLeft = leftTrim;
  var resolvedRight = rightTrim;
  if (leftMarker == null && rightMarker != null) {
    resolvedLeft = '$leftTrim $rightMarker';
  } else if (rightMarker == null && leftMarker != null) {
    resolvedRight = '$rightTrim $leftMarker';
  }

  final l = _parseTime(resolvedLeft);
  final r = _parseTime(resolvedRight);
  if (l == null || r == null) return null;
  return (l.$1, l.$2, r.$1, r.$2);
}

String? _findAmPm(String s) {
  final m = RegExp(r'\b(AM|PM)\b', caseSensitive: false).firstMatch(s);
  return m?.group(1)?.toUpperCase();
}

/// Parse "11:00 AM", "11:00", "9 PM", "23:30" into (hour24, minute).
/// Returns null on failure.
(int, int)? _parseTime(String input) {
  final normalized = input.toUpperCase().trim();

  final ampm = RegExp(
    r'^(\d{1,2})(?::(\d{1,2}))?\s*(AM|PM)$',
  ).firstMatch(normalized);
  if (ampm != null) {
    var hour = int.parse(ampm.group(1)!);
    final minute = int.tryParse(ampm.group(2) ?? '0') ?? 0;
    final isPm = ampm.group(3) == 'PM';
    if (hour < 1 || hour > 12) return null;
    if (minute < 0 || minute > 59) return null;
    // US convention: 12 AM = 00:00, 12 PM = 12:00.
    if (hour == 12) hour = 0;
    if (isPm) hour += 12;
    return (hour, minute);
  }

  final military = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(normalized);
  if (military != null) {
    final hour = int.parse(military.group(1)!);
    final minute = int.parse(military.group(2)!);
    if (hour < 0 || hour > 24) return null;
    if (minute < 0 || minute > 59) return null;
    if (hour == 24 && minute != 0) return null;
    return (hour, minute);
  }

  return null;
}

bool _isFullDay(int oh, int om, int ch, int cm) {
  if (oh != 0 || om != 0) return false;
  return (ch == 0 && cm == 0) || (ch == 24 && cm == 0);
}

String _pad(int n) => n.toString().padLeft(2, '0');
