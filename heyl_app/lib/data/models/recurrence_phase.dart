/// PROD-3379 / PROD-3114 — the confident recurrence phase a surface can render
/// as a chip ("Primeiros dias" / "Últimos dias").
///
/// Sourced from the backend `recurrence_phase` field. Today it rides on
/// `POST /map/pins` event pins (BE-6 / PROD-3378); the same field + vocabulary
/// is planned for `/map/hydrate` event results and `EventDetailOut`, and later
/// the "This Week" list items + re-platformed Happening cards — hence a shared
/// model + a reusable chip ([RecurrencePhaseChip]).
///
/// The backend only emits a value when it is **highly confident** ("silence
/// over speculation"): `last_days` only for a final, end-confirmed run;
/// `new` only when the event was known before its run began. So the FE renders
/// the value literally — no thresholds, no second-guessing.
library;

enum RecurrencePhase {
  /// Opening days of a recurring event's run (novelty). Wire value: `"new"`.
  newRun,

  /// Closing days of a final, end-confirmed run (last chance). Wire: `"last_days"`.
  lastDays,
}

/// Parse the backend `recurrence_phase` wire value into a [RecurrencePhase].
///
/// Forward-compatible by design: `null`, an absent key, a non-string, or any
/// unrecognised value → `null` (render no chip). So if the backend ever adds a
/// third public phase, an un-upgraded client degrades cleanly to "no chip"
/// rather than throwing.
RecurrencePhase? recurrencePhaseFromWire(Object? value) {
  switch (value) {
    case 'new':
      return RecurrencePhase.newRun;
    case 'last_days':
      return RecurrencePhase.lastDays;
    default:
      return null;
  }
}

extension RecurrencePhaseWire on RecurrencePhase {
  /// The backend wire value — inverse of [recurrencePhaseFromWire]. Used when
  /// re-serialising a model that round-trips through a local cache (e.g.
  /// `ItemSuggestion.toJson`).
  String get wireValue => switch (this) {
    RecurrencePhase.newRun => 'new',
    RecurrencePhase.lastDays => 'last_days',
  };
}
