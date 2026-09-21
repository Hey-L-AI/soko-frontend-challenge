import 'dart:convert';

/// Owner opening-hours model + (de)serialisation for the venue edit sheet
/// (PROD-4040 T2.3). Pure Dart, unit-tested.
///
/// Wire shape (a freeform `opening_hours` object per the API; the *client*
/// convention read by `venue_details_grid.dart` / `venue_hours.dart`):
///   - keys are lowercase weekday names, `monday`…`sunday`
///   - each value is either a slot list `[{"open":"18:00","close":"02:00"}]`
///     (24h `HH:MM`, `close < open` means it runs past midnight) or the string
///     `"Closed"`. Days with no value are simply absent.
///
/// Google-Places-derived textual strings (e.g. `"9:30 AM – 12:30 PM"`) are NOT
/// reverse-parsed into slots — reconstructing them reliably is fragile (AM/PM,
/// multi-period, shared markers; see `venue_hours.dart`). They're preserved
/// verbatim ([DayHoursMode.raw]) and shown read-only; editing that day replaces
/// the text with structured slots the owner sets.

const List<String> ownerHoursDayKeys = <String>[
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

enum DayHoursMode {
  /// No value for this day — the owner hasn't set anything.
  unset,

  /// Explicitly closed (`"Closed"`).
  closed,

  /// One or more open [slots].
  open,

  /// An unparsed textual value (Google's form); kept verbatim in [raw].
  raw,
}

class HourSlot {
  const HourSlot({required this.open, required this.close});

  /// `HH:MM`, 24-hour.
  final String open;

  /// `HH:MM`, 24-hour. When earlier than [open] the slot runs past midnight.
  final String close;

  HourSlot copyWith({String? open, String? close}) =>
      HourSlot(open: open ?? this.open, close: close ?? this.close);

  Map<String, String> toJson() => {'open': open, 'close': close};

  @override
  bool operator ==(Object other) =>
      other is HourSlot && other.open == open && other.close == close;

  @override
  int get hashCode => Object.hash(open, close);
}

class DayHours {
  const DayHours({
    required this.key,
    required this.mode,
    this.slots = const [],
    this.raw,
  });

  final String key;
  final DayHoursMode mode;
  final List<HourSlot> slots;
  final String? raw;

  DayHours copyWith({DayHoursMode? mode, List<HourSlot>? slots, String? raw}) {
    return DayHours(
      key: key,
      mode: mode ?? this.mode,
      slots: slots ?? this.slots,
      raw: raw ?? this.raw,
    );
  }

  /// Switch to open with a sensible default slot when none exist.
  DayHours asOpen() {
    if (mode == DayHoursMode.open && slots.isNotEmpty) return this;
    return DayHours(
      key: key,
      mode: DayHoursMode.open,
      slots: const [HourSlot(open: '09:00', close: '17:00')],
    );
  }

  DayHours asClosed() => DayHours(key: key, mode: DayHoursMode.closed);

  DayHours asUnset() => DayHours(key: key, mode: DayHoursMode.unset);
}

/// Parse the `opening_hours` map into a fixed 7-day list (mon→sun).
List<DayHours> parseOwnerHours(Map<String, dynamic>? map) {
  return ownerHoursDayKeys.map((key) {
    final value = map == null ? null : map[key];
    if (value == null) return DayHours(key: key, mode: DayHoursMode.unset);

    if (value is List) {
      final slots = <HourSlot>[];
      for (final entry in value) {
        if (entry is Map) {
          final open = _normaliseHhmm(entry['open']);
          final close = _normaliseHhmm(entry['close']);
          if (open != null && close != null) {
            slots.add(HourSlot(open: open, close: close));
          }
        }
      }
      if (slots.isEmpty) return DayHours(key: key, mode: DayHoursMode.unset);
      return DayHours(key: key, mode: DayHoursMode.open, slots: slots);
    }

    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return DayHours(key: key, mode: DayHoursMode.unset);
      if (_isClosedWord(trimmed)) {
        return DayHours(key: key, mode: DayHoursMode.closed);
      }
      // Only reconstruct a strict 24h `HH:MM - HH:MM` range; anything else
      // (Google's AM/PM textual form) stays raw.
      final slot = _parseStrictRange(trimmed);
      if (slot != null) {
        return DayHours(key: key, mode: DayHoursMode.open, slots: [slot]);
      }
      return DayHours(key: key, mode: DayHoursMode.raw, raw: trimmed);
    }

    return DayHours(key: key, mode: DayHoursMode.raw, raw: value.toString());
  }).toList();
}

/// Serialise the editor state back to the wire `opening_hours` map. Unset days
/// are omitted; closed days become `"Closed"`; open days become slot lists;
/// raw days keep their original text.
Map<String, dynamic> serializeOwnerHours(List<DayHours> days) {
  final map = <String, dynamic>{};
  for (final day in days) {
    switch (day.mode) {
      case DayHoursMode.unset:
        break;
      case DayHoursMode.closed:
        map[day.key] = 'Closed';
      case DayHoursMode.open:
        if (day.slots.isNotEmpty) {
          map[day.key] = day.slots.map((s) => s.toJson()).toList();
        }
      case DayHoursMode.raw:
        if (day.raw != null) map[day.key] = day.raw;
    }
  }
  return map;
}

/// Stable equality of two serialised hour maps — [serializeOwnerHours] emits a
/// deterministic key/slot order, so a JSON compare is canonical. Used for
/// change detection against the editor's initial state (never against the raw
/// backend map, whose slot formatting may differ, e.g. `9:00` vs `09:00`).
bool ownerHoursMapsEqual(Map<String, dynamic> a, Map<String, dynamic> b) {
  return jsonEncode(a) == jsonEncode(b);
}

bool _isClosedWord(String value) {
  final lower = value.toLowerCase();
  return lower == 'closed' || lower == 'fechado' || lower == 'cerrado';
}

/// Parse a strict `HH:MM - HH:MM` / `HH:MM – HH:MM` 24-hour range. Returns null
/// for anything else (Google's AM/PM text, multi-period, etc.).
HourSlot? _parseStrictRange(String value) {
  final parts = value.split(RegExp(r'\s*[–-]\s*'));
  if (parts.length != 2) return null;
  final open = _normaliseHhmm(parts[0]);
  final close = _normaliseHhmm(parts[1]);
  if (open == null || close == null) return null;
  return HourSlot(open: open, close: close);
}

/// Normalise `H:MM` / `HH:MM` (24h) to zero-padded `HH:MM`; null if invalid.
String? _normaliseHhmm(Object? value) {
  if (value is! String) return null;
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
