import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/environment.dart';
import '../../../core/services/experiment_service.dart';
import '../../../providers/auth_provider.dart';

/// KILL-SWITCH for the non-dismissible chat-onboarding gate (FE-2 / PROD-3887).
///
/// ON for pre-release testing: with BE-1's `/onboarding/state` live and the
/// identity step wired to complete onboarding on its own (INTERIM — see
/// `ApiOnboardingProgressStore.interimCompleteAfterSubturn`), a new user can
/// reach `PUT step=complete` and exit the gate, so enabling it is safe to
/// validate end-to-end. It supersedes the old V6 survey for new users (a gated
/// user can't reach the discovery `cta_profiling` nudge).
///
/// ⚠️ Before RELEASE: only ship this `true` once the real content steps
/// (FE-3/4/5) replace the interim completion — otherwise production users get a
/// name/city/interests-only onboarding. This is mitigated for now by the
/// **new-onboarding cohort** scope in [needsOnboardingProvider]: with the gate
/// on, only that cohort (the PostHog `unskippable-onboarding-v1` flag —
/// admins today via `is_admin` targeting) is routed into the new flow; every
/// other user keeps the legacy Siga/location onboarding. Widen the flag in the
/// dashboard to go GA — no release needed.
const bool kChatOnboardingGateEnabled = true;

/// The NEW-onboarding cohort — the single source of truth flipping OLD (upfront
/// Siga welcome + legacy onboarding) to NEW (no Siga; non-dismissible chat
/// onboarding). Read by [needsOnboardingProvider] (the chat gate), the router's
/// Siga/location bypass (`app_router`), and the menu replay trigger.
///
/// **Purely PostHog-driven, so the rollout changes with no app release**: a user
/// is in the cohort iff the `unskippable-onboarding-v1` flag is on for them. The
/// flag is configured in PostHog to target the `is_admin` person property (set
/// server-side by the backend's PostHog sync), so **admins are in today** and
/// everyone else is out — "normal users see the old onboarding, admins see the
/// new one". Widen (add a % rollout / cohort) or roll back entirely from the
/// dashboard; no deploy.
///
/// Local dev (PostHog disabled) can force it on with
/// `--dart-define=NEW_ONBOARDING=true` ([EnvironmentConfig.newOnboardingEnabled]).
/// Returns `false` for guests / while the profile is still loading. There is no
/// local `role == admin` fallback (deliberate — full dashboard control): if
/// PostHog is unreachable or the flag hasn't resolved, even an admin lands on
/// the OLD onboarding until it loads, the accepted trade-off for deploy-free
/// releases.
final newOnboardingCohortProvider = Provider<bool>((ref) {
  if (!ref.watch(isAuthenticatedProvider)) return false;
  return EnvironmentConfig.newOnboardingEnabled ||
      ref.watch(newOnboardingFlagProvider);
});

/// The raw `unskippable-onboarding-v1` PostHog flag. Split out from
/// [experimentServiceProvider] so the rollout can be overridden in tests without
/// a PostHog fake.
final newOnboardingFlagProvider = Provider<bool>(
  (ref) => ref.watch(experimentServiceProvider).enableNewOnboarding,
);

/// Whether the current user must be routed through chat onboarding.
///
/// Scope: the **new-onboarding cohort** ([newOnboardingCohortProvider]) — the
/// PostHog `unskippable-onboarding-v1` flag (admins today via `is_admin`
/// targeting). Every user outside the cohort returns `false` here and falls
/// through to the legacy Siga-welcome + location-ask gates in the router
/// redirect (see [app_router] — those gates re-engage whenever this provider is
/// not `true`).
///
/// Within that cohort: authenticated (non-guest) users whose onboarding is not
/// complete. Completion is server-authoritative via
/// `/auth/me.onboarding_complete` (grandfathering existing onboarded and
/// WhatsApp-onboarded users, and users who finish the chat flow's
/// `PUT step=complete`). Guests are never gated — they browse until they sign in.
///
/// `null` while the profile is still loading (the router treats null as "don't
/// redirect — let current navigation continue", matching [needsSokoIntroProvider]).
/// Returns `false` while [kChatOnboardingGateEnabled] is off, so the gate is
/// inert until the flow can actually be completed.
final needsOnboardingProvider = Provider<bool?>((ref) {
  if (!kChatOnboardingGateEnabled) return false;
  final isAuthed = ref.watch(isAuthenticatedProvider);
  if (!isAuthed) return false;
  final user = ref.watch(currentUserProvider);
  if (user == null) return null; // profile still resolving
  return computeNeedsOnboarding(
    gateEnabled: true,
    isAuthed: true,
    inNewOnboardingCohort: ref.watch(newOnboardingCohortProvider),
    onboardingComplete: user.onboardingComplete,
  );
});

/// Whether the onboarding routing decision is confident enough to reveal the
/// app past the splash. Watched by `_SplashGate` (`app.dart`) so a cohort user
/// who needs onboarding is painted straight onto `/onboarding-chat` instead of
/// flashing the home page (or the legacy Siga screen) first while the async
/// inputs settle (PROD-3888 follow-up).
///
/// The two inputs that a cold-start routing decision depends on both resolve
/// AFTER `authState.isInitialized` (which is what lifts the splash today):
///   1. the profile — `needsOnboardingProvider` is `null` until `/auth/me`
///      lands (or the cached profile hydrates), so `onboarding_complete` is
///      unknown; and
///   2. the cohort flag — `experimentServiceProvider.flagsConfirmed` is false
///      until the real PostHog value arrives (NOT the premature `loaded`, which
///      flips true on the default-`false` first pass — see [ExperimentState]).
///
/// Returns `true` (don't wait) for guests — they never onboard — so only
/// logged-in users are ever held, and only briefly. Returning users resolve
/// both inputs almost immediately (cached profile + SDK-cached flag fast path),
/// so the added hold is negligible; `_SplashGate` also caps the wait.
final onboardingDecisionReadyProvider = Provider<bool>((ref) {
  // Guests have no onboarding decision to make — reveal immediately.
  if (!ref.watch(isAuthenticatedProvider)) return true;
  // Profile still resolving → onboarding_complete unknown.
  if (ref.watch(needsOnboardingProvider) == null) return false;
  // Cohort flag not yet confirmed → the cohort decision could still flip.
  if (!ref.watch(experimentServiceProvider).flagsConfirmed) return false;
  return true;
});

/// Pure decision for [needsOnboardingProvider], separated so the gate logic is
/// testable independently of the compile-time [kChatOnboardingGateEnabled].
///
/// `inNewOnboardingCohort` implements the staged rollout: users outside the
/// cohort are never gated into the new flow (they keep the legacy Siga/location
/// onboarding). Widen the cohort (via the PostHog `unskippable-onboarding-v1` flag) to
/// graduate the flow to GA.
@visibleForTesting
bool computeNeedsOnboarding({
  required bool gateEnabled,
  required bool isAuthed,
  required bool inNewOnboardingCohort,
  required bool onboardingComplete,
}) {
  if (!gateEnabled) return false;
  if (!isAuthed) return false;
  if (!inNewOnboardingCohort) return false;
  return !onboardingComplete;
}
