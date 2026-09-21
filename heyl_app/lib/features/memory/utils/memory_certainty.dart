/// The single user-facing meter on the Memory page: a 5-bar "level" bucketed
/// from the observation's certainty (0..1). One qualitative meter, never a raw
/// percentage and never a second strength word — two competing numbers is what
/// confused users before.
///
/// Certainty is what the frequency model drives: repeated searches / a save
/// raise the certainty of a category's interest, so the meter rises with
/// behaviour over time (and falls as old signals decay). Bands: >=.95 → 5,
/// >=.85 → 4, >=.6 → 3, >=.35 → 2, else 1.
///
/// Level 5 is USER-ONLY: the backend never emits >=0.95 for organic signal
/// (inference caps at 4, however strong the evidence) — only a user pin (a
/// "+" tap on a level-4 chip) lands in the 5 band, and a pin does not decay.
/// See `memory_overrides.py`.
int certaintyTicks(double certainty) {
  if (certainty >= 0.95) return 5;
  if (certainty >= 0.85) return 4;
  if (certainty >= 0.6) return 3;
  if (certainty >= 0.35) return 2;
  return 1;
}

/// Inverse of [certaintyTicks]: a representative certainty squarely inside the
/// band for `ticks` (1..5). Used for the optimistic − / + nudge so the meter
/// moves a whole bar instantly without a server round-trip. Mirrors the
/// backend's band centres in `memory_overrides.py`.
double ticksToCertainty(int ticks) {
  switch (ticks) {
    case 5:
      return 0.97;
    case 4:
      return 0.9;
    case 3:
      return 0.7;
    case 2:
      return 0.5;
    default:
      return 0.25;
  }
}

/// Five-to-eleven is morning, twelve-to-seventeen afternoon, eighteen-to-twenty-two
/// evening, else night. Pure ARB key, no localised string — the caller fetches
/// the label from `l10n.memoryDayPartMorning` etc.
String dayPartKey(int hour) {
  if (hour >= 5 && hour < 12) return 'morning';
  if (hour >= 12 && hour < 18) return 'afternoon';
  if (hour >= 18 && hour < 23) return 'evening';
  return 'night';
}
