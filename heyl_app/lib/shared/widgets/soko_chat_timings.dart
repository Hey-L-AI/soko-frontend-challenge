/// Shared cadence constants for Soko chat surfaces (onboarding + main chat), so
/// the typewriter type-out and per-turn entrance feel identical across both.
library;

/// Per-turn entrance animation duration (fade + slide + subtle scale).
const Duration sokoBubbleEntranceDuration = Duration(milliseconds: 200);

/// How long a freshly-delivered Soko line takes to "type out" grapheme by
/// grapheme (see [SokoTypewriterText]). ~10 ms/char, floored so a one-word line
/// still reads as typed and capped so a long line doesn't crawl. This is the
/// single source of truth the onboarding controller also holds delivery for, so
/// the type-out and any post-text reveal (cards / CTAs) stay in lock-step.
/// PROD-4394 P0-1: halved from 22 ms/char (cap 1400) — the onboarding script
/// summed to ~54s of pure synthetic pacing, the funnel's single biggest
/// self-inflicted wait. The chat feel survives at 10 ms/char; the wall-clock
/// doesn't at 22.
Duration sokoTypewriterDuration(String text) =>
    Duration(milliseconds: (text.length * 10).clamp(150, 700));
