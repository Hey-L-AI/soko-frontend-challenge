import '../providers/daily_drop_provider.dart';

/// PROD-2908 — the terminal outcome of a `/drop` deep-link resolution, derived
/// purely from the settled [DailyDropState] (plus whether a `cta_profiling`
/// status is *stale* — finished-locally, BE catching up).
///
/// Extracted from `DiscoveryScreen._resolveDailyDropDeepLink` so the crucial
/// reason split is unit-testable without pumping the whole Discovery screen:
/// [noDrop] (genuinely empty — the poller ran its full course / init failed)
/// must be kept distinct from [generating] (still being produced — a rare
/// defensive-cap case). Conflating them was half the PROD-2908 defect: a drop
/// that already existed but hadn't been fetched yet was reported as "no drop".
///
/// Keep in lockstep with the switch in `_resolveDailyDropDeepLink`.
enum DailyDropDeepLinkOutcome {
  /// A ready drop with a recommendation — open its detail.
  ready,

  /// New, unprofiled user — show the profiling CTA sheet.
  ctaProfiling,

  /// Resolved city outside the launch markets — show the unsupported sheet.
  unsupportedCity,

  /// Genuinely nothing to show today — come-back-tomorrow (`reason='no_drop'`).
  noDrop,

  /// Still being produced (poller alive past the safety cap) — the preparing
  /// sheet (`reason='generating'`), never the come-back-tomorrow lie.
  generating,
}

/// Classify a settled [DailyDropState] into the deep-link [DailyDropDeepLinkOutcome].
///
/// [staleProfilingCta] is the caller's `_isStaleProfilingCta(state)` — a stale
/// CTA is not a real gate (the provider is re-polling toward a drop), so it is
/// treated as still-[generating] rather than [ctaProfiling].
DailyDropDeepLinkOutcome dailyDropDeepLinkOutcome(
  DailyDropState state, {
  required bool staleProfilingCta,
}) {
  if (state.isReady && state.drop != null) {
    return DailyDropDeepLinkOutcome.ready;
  }
  if (state.isCtaProfiling && !staleProfilingCta) {
    return DailyDropDeepLinkOutcome.ctaProfiling;
  }
  if (state.isUnsupportedCity) {
    return DailyDropDeepLinkOutcome.unsupportedCity;
  }
  if (state.hasError) {
    return DailyDropDeepLinkOutcome.noDrop;
  }
  // Non-terminal (isGenerating) leaked past the deep-link safety cap → the drop
  // is still on the way; report it as generating, not a genuine empty.
  return DailyDropDeepLinkOutcome.generating;
}
