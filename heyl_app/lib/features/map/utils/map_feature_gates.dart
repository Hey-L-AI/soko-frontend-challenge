/// Runtime gates for the two map pin-churn features (PROD-3656, PROD-3657).
///
/// Both shipped in 1.1.20+109 and made the pin set change more often than
/// intended, so each is behind its own PostHog kill-switch — remote, because
/// the code is already inside a store binary and a compile-time constant could
/// not reach those users. Default off ⇒ pre-PROD-3656/3657 behaviour, which is
/// also what a PostHog outage falls back to.
///
/// The dart-define half is local dev only: PostHog is disabled there, so the
/// flags would always resolve to their off default and the behaviour could not
/// be tuned on a dev machine.
///
/// Kept as plain selectors over [ExperimentState] (rather than providers) so
/// they compose with `experimentServiceProvider.select(...)` at every read
/// site — a `.select` is what keeps a flag read from widening a consumer's
/// rebuild surface.
library;

import '../../../core/config/environment.dart';
import '../../../core/services/experiment_service.dart';

/// PROD-3656 — auto-promote pool results into the marker slots a zoom-in
/// frees. Off ⇒ a live camera move can only ever remove pins, and new ones
/// arrive only when a `/map/pins` response lands.
bool mapPinAutoPromotionEnabled(ExperimentState s) =>
    EnvironmentConfig.mapPinAutoPromotionEnabled || s.enableMapPinAutoPromotion;

/// PROD-3657 — cache `/map/pins` pools and pre-paint one while the next
/// response is in flight. Off ⇒ one last-good response as before, no cache
/// stored, no pre-paint, and PROD-3656's widened promotion pool (which reads
/// the same cache) is empty.
bool mapPinsCacheEnabled(ExperimentState s) =>
    EnvironmentConfig.mapPinsCacheEnabled || s.enableMapPinsCache;
