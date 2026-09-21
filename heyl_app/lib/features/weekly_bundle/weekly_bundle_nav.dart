/// Navigation marker passed as the go_router `extra` when the app opens the
/// Weekly Bundle overlay from *within* a live session (PROD-2564).
///
/// Its presence is how the `/weekly-bundle` route redirect distinguishes an
/// in-app overlay push (→ render the overlay) from an external/cold deep-link
/// entry (→ bounce through Discovery to prime the provider + get a real
/// back-stack). `extra` can't survive URL serialization or browser
/// state-restoration (go_router drops a complex `extra` to `null` without an
/// `extraCodec`), so `extra is WeeklyBundleNav` reliably means "live in-app
/// push this session"; its absence falls to the safe bounce arm.
///
/// It also carries the analytics open-reason the overlay reads on mount
/// (in-app tap → `null`; deep-link landing → `'deep_link'`).
class WeeklyBundleNav {
  /// In-app section tap — a normal open, no deep-link attribution.
  const WeeklyBundleNav.inApp() : openReason = null;

  /// Deep-link happy path — tags the overlay's `weekly_bundle_open` as
  /// `deep_link` so Growth can tell a successful deep-link landing from a
  /// normal in-app open.
  const WeeklyBundleNav.deepLink() : openReason = 'deep_link';

  /// `reason` value forwarded to `trackWeeklyBundleOpen`, or `null` for a
  /// normal in-app open.
  final String? openReason;
}
