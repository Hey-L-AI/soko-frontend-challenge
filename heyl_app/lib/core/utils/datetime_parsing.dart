// Shared parser for backend-supplied datetime strings.
//
// The HeyL backend serialises all datetimes as ISO-8601 UTC strings
// (e.g. `2026-05-21T12:00:00Z`). `DateTime.parse` keeps the result
// UTC-anchored — formatting it with `DateFormat(...)` then reads the
// raw UTC components and the user sees a time shifted by their
// timezone offset (e.g. one hour earlier during Lisbon WEST).
//
// PR #478 fixed the visible occurrence of this in the venue "Events
// here" + Happening shelf path by calling `.toLocal()` after parsing.
// Same root cause shows up everywhere the app renders a backend-
// supplied datetime (calendar agenda, event detail headers, weekly
// bundle, etc.) so we centralise the conversion here. Every model
// `fromJson` that stores a datetime field should use this helper.
//
// **Why the parse layer, not the format layer.** Pushing `.toLocal()`
// into every `DateFormat(...).format(date)` call is leaky — each new
// formatter has to remember it. Normalising at parse time means
// downstream code can treat the model field as already-local; the
// only thing to remember is "use the helper at the model layer".
//
// **Known limitation** (mirrors PR #478's note): we render in the
// device's local timezone, not the event's venue timezone. Holds for
// Lisbon users on Lisbon events but breaks for travelling users +
// multi-city expansion. Tracked as a follow-up; surfaces
// `EventOccurrence.timezone` on the wire and switches the renderer to
// venue-local.

/// Parse a backend-supplied ISO-8601 datetime string into a local
/// [DateTime]. Returns `null` for `null` input or when the string is
/// malformed.
///
/// Use this anywhere a `fromJson` reads a datetime field. Do NOT use
/// raw `DateTime.parse(...)` for backend strings — see the file
/// header for context.
DateTime? parseBackendDateTime(String? raw) {
  if (raw == null) return null;
  try {
    return DateTime.parse(raw).toLocal();
  } catch (_) {
    return null;
  }
}

/// Required variant — parses or throws. Use only when the field is
/// known to be present and well-formed at the call site (e.g. an
/// OpenAPI-required field on a typed model).
DateTime parseBackendDateTimeRequired(String raw) =>
    DateTime.parse(raw).toLocal();
