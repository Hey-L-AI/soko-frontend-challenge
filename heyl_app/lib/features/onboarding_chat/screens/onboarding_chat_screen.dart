import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/att_trigger.dart';
import '../../../core/services/storage_service.dart'
    show sharedPreferencesProvider;
import '../../../core/services/unified_analytics_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/memory_twin_provider.dart';
import '../../../data/models/onboarding_state_models.dart';
import '../../../data/models/vibe_candidate.dart';
import '../../profile/providers/people_providers.dart';
import '../data/api_onboarding_progress_store.dart';
import '../data/onboarding_interest_catalog.dart';
import '../models/onboarding_chat_models.dart';
import '../providers/onboarding_chat_controller.dart';
import '../providers/onboarding_vibe_controller.dart';
import '../providers/onboarding_zines_controller.dart';
import 'onboarding_identity_name_screen.dart';

/// Production chat-onboarding flow (FE-1 + FE-2). Backed by the resumable
/// [ApiOnboardingProgressStore] (server is the source of truth for progress)
/// and localized from ARB. Non-dismissible: system back is blocked here and the
/// router gate ([needsOnboardingProvider]) bounces any escape back until the
/// user is `onboarding_complete`.
///
/// Only the identity/name step is scripted today; the content steps land with
/// FE-3/4/5, at which point the gate kill-switch flips on.
class OnboardingChatScreen extends ConsumerStatefulWidget {
  const OnboardingChatScreen({super.key});

  @override
  ConsumerState<OnboardingChatScreen> createState() =>
      _OnboardingChatScreenState();
}

class _OnboardingChatScreenState extends ConsumerState<OnboardingChatScreen> {
  StateNotifierProvider<OnboardingChatController, OnboardingChatState>?
  _provider;
  StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>?
  _vibeVenuesProvider;
  StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>?
  _vibeEventsProvider;
  StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>?
  _zinesProvider;
  StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>?
  _suggestedZinesProvider;
  ProviderContainer? _container;
  late OnboardingIdentityNameCopy _copy;

  /// Last rendered locale — used to detect a mid-flow language switch and
  /// re-translate already-delivered Soko bubbles.
  Locale? _lastLocale;

  /// Bumped by the admin "restart onboarding" action to force a fresh inner
  /// screen State (so the transcript replays from step 1).
  int _flowGeneration = 0;

  /// When this onboarding session began (first entry / restart). Feeds
  /// `total_time_seconds` on the `onboarding_complete` funnel event. Best-effort:
  /// a resume in a later session remeasures from the resumed screen's mount, so
  /// the duration reflects the final session rather than the whole funnel.
  DateTime? _startedAt;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);

    // Rebuild the screen-chrome copy on EVERY dependency change (crucially, a
    // locale switch via the header language button) so the header titles +
    // composer labels re-translate live. Must run BEFORE the `_provider` guard
    // below — the guard protects the one-time flow seeding, not this copy.
    final l10n = Lt.of(context);
    _copy = OnboardingIdentityNameCopy(
      headerTitle: l10n.onboardingChatIdentityHeaderTitle,
      stepLabel: '1/5',
      namePlaceholder: l10n.onboardingChatNamePlaceholder,
      cityPlaceholder: l10n.onboardingChatCityPlaceholder,
      interestsConfirmLabel: l10n.onboardingChatInterestsConfirm,
      interestsOptions: onboardingInterestOptions(l10n),
      useMyLocationLabel: l10n.onboardingChatUseMyLocation,
      chooseLocationLabel: l10n.onboardingChatChooseLocation,
      nameMaxLength: 40,
      firstNamePlaceholder: l10n.onboardingChatFirstNamePlaceholder,
      surnamePlaceholder: l10n.onboardingChatSurnamePlaceholder,
      extraYesLabel: l10n.onboardingChatExtraYes,
      extraNoLabel: l10n.onboardingChatExtraNo,
      extraPlaceholder: l10n.onboardingChatExtraPlaceholder,
      extraConfirmLabel: l10n.onboardingChatExtraConfirm,
      extraAck: l10n.onboardingChatExtraAck,
      vibeHeaderTitle: l10n.onboardingChatVibeHeaderTitle,
      vibeContinueLabel: l10n.onboardingChatVibeContinue,
      vibePlacesLabel: l10n.onboardingChatVibePlaces,
      vibeEventsLabel: l10n.onboardingChatVibeEvents,
      vibeErrorLabel: l10n.onboardingChatVibeError,
      vibeSearchingPlaces: l10n.onboardingChatVibeSearchingPlaces,
      vibeSearchingEvents: l10n.onboardingChatVibeSearchingEvents,
      vibeSharePlaceholder: l10n.onboardingChatVibeSharePlaceholder,
      vibeShareEmpty: l10n.onboardingChatVibeShareEmpty,
      zinesHeaderTitle: l10n.onboardingChatZinesHeaderTitle,
      zinesSaveLabel: l10n.onboardingChatZinesSave,
      zinesSavedLabel: l10n.onboardingChatZinesSaved,
      zinesErrorLabel: l10n.onboardingChatZinesError,
      profileHeaderTitle: l10n.onboardingChatProfileHeaderTitle,
      profileEditLaterLabel: l10n.onboardingChatProfileEditLater,
      profileEditCtaLabel: l10n.onboardingChatProfileEditCta,
      profileFindContactsLabel: l10n.onboardingChatProfileFindContacts,
      profileContinueLabel: l10n.onboardingChatProfileContinue,
      profileFollowsErrorLabel: l10n.onboardingChatProfileFollowsError,
      ritualsHeaderTitle: l10n.onboardingChatRitualsHeaderTitle,
      ritualsCtaLabel: l10n.onboardingChatRitualsCta,
      ritualsDailyTitle: l10n.onboardingChatRitualsDailyTitle,
      ritualsDailySubtitle: l10n.onboardingChatRitualsDailySubtitle,
      ritualsWeeklyTitle: l10n.onboardingChatRitualsWeeklyTitle,
      ritualsWeeklySubtitle: l10n.onboardingChatRitualsWeeklySubtitle,
      ritualsExploreMapLabel: l10n.onboardingChatRitualsExploreMap,
      ritualsChatLabel: l10n.onboardingChatRitualsChat,
      notLocalHeaderTitle: l10n.onboardingChatNotLocalHeaderTitle,
      notLocalFalaComigo: l10n.onboardingChatNotLocalFalaComigo,
      notLocalOrContinue: l10n.onboardingChatNotLocalOrContinue,
      persistenceError: l10n.onboardingChatPersistenceError,
      retryLabel: l10n.onboardingChatRetry,
      editAnswerLabel: l10n.onboardingChatEditAnswer,
    );

    // On a mid-flow language switch, re-translate the Soko bubbles already in
    // the transcript by their stable turn ids (the header/composer/cards already
    // re-render from the rebuilt `_copy` above). First run seeds `_lastLocale`
    // only — the flow isn't built yet, so there's nothing to re-map.
    final locale = Localizations.localeOf(context);
    final provider = _provider;
    if (provider != null && locale != _lastLocale) {
      _container
          ?.read(provider.notifier)
          .retranslate(_localizedScript(l10n).messageTextById());
    }
    _lastLocale = locale;

    // We deliberately do NOT re-fetch already-loaded server content (vibe
    // carousels, zines) on a mid-flow switch:
    //   - Vibe candidates carry the user's 👍/👎 (`sentiments`) and gate the
    //     step; a re-fetch would return a different card set and wipe in-flight
    //     selections. Their text is mostly proper-noun venue/event names.
    //   - Preliminary zines are pre-generated server-side (background Celery
    //     task) in the locale that was active at enqueue time; a re-fetch just
    //     returns the same cached copy — regenerating on a new `Accept-Language`
    //     is a backend concern (see docs/learnings/onboarding-content-locale.md).
    // Content not yet loaded when the switch happens (the common case — the user
    // switches early) fetches fresh in the new locale via `Accept-Language`,
    // which reads the live `apiLocaleCodeProvider`. The localized chrome around
    // discovery (city/area labels) follows the switch because the geo providers
    // now read the live locale too (see resolved_search_location_provider.dart).
    // Everything below is one-time flow setup; a locale change re-runs
    // didChangeDependencies but must NOT re-seed the chat (that would replay it).
    if (_provider != null) return;

    _buildFlowProviders();
    _startedAt = DateTime.now();
    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(step: 'start', action: 'started');

    // Trigger the iOS ATT (Meta/attribution) prompt at the very start of the
    // onboarding chat — before the mid-flow location prompt and the rituals push
    // prompt, so the privacy dialogs never race back-to-back. Idempotent + a
    // no-op on Android/web and when ATT is already resolved (see
    // `triggerAttIfNeeded`), so an early duplicate vs. Siga is harmless.
    // Fire-and-forget: it has its own try/catch and shows the modal out of band.
    unawaited(triggerAttIfNeeded(ref));
  }

  /// Builds the screen-local flow providers (chat controller + per-shelf vibe/
  /// zines providers). Called on first entry and again after an admin restart,
  /// so it reads its own [Lt] rather than closing over one.
  void _buildFlowProviders() {
    final l10n = Lt.of(context);
    _vibeVenuesProvider = buildLiveOnboardingVibeProvider(
      VibeCandidateType.place,
    );
    _vibeEventsProvider = buildLiveOnboardingVibeProvider(
      VibeCandidateType.event,
    );
    _zinesProvider = buildLiveOnboardingZinesProvider();
    _suggestedZinesProvider = buildLiveOnboardingSuggestedZinesProvider();
    // PROD-4394 D4: durable per-user branch fallback. Past identity.extra the
    // resume graph requires a branch; if the server envelope ever fails to
    // echo it, this cache (instead of the old process-memory-only fallback)
    // keeps a restarted app from looping on "anything else?" forever.
    final prefs = ref.read(sharedPreferencesProvider);
    final userId = ref.read(authStateProvider).user?.id;
    final branchKey = 'onboarding.branch.${userId ?? 'anon'}';
    _provider = createOnboardingChatProvider(
      progressStore: ApiOnboardingProgressStore(
        api: ref.read(onboardingStateApiProvider),
        readCachedBranch: () => prefs.getString(branchKey),
        writeCachedBranch: (wire) => prefs.setString(branchKey, wire),
        // Finish onboarding at the end of the rituals step (the last step) so a
        // supported-city user reaches `PUT step=complete` and the gate releases.
        interimCompleteAfterSubturn: OnboardingSubturnId.ritualsReady,
        // On resume the server only has the raw answer value; map interest ids
        // back to their labels so the bubble reads "Live music, Art…" not ids.
        displayTextFor: (subturnId, value) {
          if (subturnId == OnboardingSubturnId.identityInterests &&
              value is List) {
            final byId = {
              for (final o in onboardingInterestOptions(l10n)) o.id: o.label,
            };
            return value.map((id) => byId[id] ?? '$id').join(', ');
          }
          // The vibe answers are structured maps with no user bubble in the live
          // flow — vibeTaste is {liked, disliked, *_candidates}, vibeShare is
          // {picks: [...]}. Keep both blank on resume (the empty bubble is
          // suppressed by the transcript) instead of dumping raw JSON like `{}`.
          if (subturnId == OnboardingSubturnId.vibeTaste ||
              subturnId == OnboardingSubturnId.vibeShare) {
            return '';
          }
          // The zines/profile/rituals answers are structured maps with no user
          // bubble — blank them on resume too rather than dumping JSON.
          if (subturnId == OnboardingSubturnId.zinesGenerated ||
              subturnId == OnboardingSubturnId.profileCard ||
              subturnId == OnboardingSubturnId.profileFollows ||
              subturnId == OnboardingSubturnId.ritualsReady) {
            return '';
          }
          return value?.toString() ?? '';
        },
      ),
      script: _localizedScript(l10n),
      // Holds each carousel's "searching…" label until its real fetch resolves,
      // so Places loads and shows fully before the Events beat begins (instead
      // of both shelves appearing at once, one still spinning).
      contentReady: _awaitShelfLoaded,
    );
    // NOTE: `start/started` is fired once from `initState` (initial entry) and
    // `start/restarted` from `_restartOnboarding`. `_buildFlowProviders` runs on
    // both paths, so it must NOT emit its own `started` (that double-counted
    // first-run starts).
  }

  /// The scripted onboarding conversation in the given locale. Built once for
  /// the live flow and rebuilt on a locale switch to re-translate already
  /// delivered Soko bubbles (see `didChangeDependencies` → `retranslate`).
  OnboardingScript _localizedScript(Lt l10n) => OnboardingScript.identity(
    greeting: l10n.onboardingChatGreeting,
    askName: l10n.onboardingChatAskName,
    askCity: l10n.onboardingChatAskCity,
    askInterests: l10n.onboardingChatAskInterests,
    interestsHint: l10n.onboardingChatInterestsHint,
    askExtra: l10n.onboardingChatAskExtra,
    extraExamples: l10n.onboardingChatExtraExamples,
    notLocalKnowWhere: l10n.onboardingChatNotLocalKnowWhere,
    notLocalNotYet: l10n.onboardingChatNotLocalNotYet,
    notLocalExplore: l10n.onboardingChatNotLocalExplore,
    notLocalOrContinue: l10n.onboardingChatNotLocalOrContinue,
    vibeIntro: l10n.onboardingChatVibeIntro,
    vibeAsk: l10n.onboardingChatVibeAsk,
    vibeGate: l10n.onboardingChatVibeGate,
    vibeSearchReveal: l10n.onboardingChatVibeSearchReveal,
    vibeSearchingPlaces: l10n.onboardingChatVibeSearchingPlaces,
    vibeSearchingEvents: l10n.onboardingChatVibeSearchingEvents,
    vibeShareIntro: l10n.onboardingChatVibeShareIntro,
    zinesIntro: l10n.onboardingChatZinesIntro,
    zinesSaveHint: l10n.onboardingChatZinesSaveHint,
    zinesMadeForYou: l10n.onboardingChatZinesMadeForYou,
    zinesSearching: l10n.onboardingChatZinesSearching,
    zinesSuggestedIntro: l10n.onboardingChatZinesSuggestedIntro,
    zinesSuggestedSearching: l10n.onboardingChatZinesSuggestedSearching,
    profileIntro: l10n.onboardingChatProfileIntro,
    profileFollowsIntro: l10n.onboardingChatProfileFollowsIntro,
    profileFollowsSearching: l10n.onboardingChatProfileFollowsSearching,
    ritualsIntro: l10n.onboardingChatRitualsIntro,
    ritualsBody: l10n.onboardingChatRitualsBody,
    ritualsSearching: l10n.onboardingChatRitualsSearching,
    ritualsDeliveryAsk: l10n.onboardingChatRitualsDeliveryAsk,
    ritualsReadyMsg: l10n.onboardingChatRitualsReadyMsg,
  );

  /// Bridges the chat controller's "searching…" beat to a shelf's real fetch:
  /// for every content row that loads async (generated + suggested zines, the
  /// two vibe carousels, the follow/people row) returns a future that completes
  /// once that shelf's data has settled. Content ids with nothing to await
  /// return null, so the controller uses its fixed beat instead.
  Future<void>? _awaitShelfLoaded(String contentId) {
    // Hold the "searching…" label until the real fetch resolves, so every
    // listing mounts WITH its cards and animates in — never a spinner
    // (PROD-4032). Every wait is bounded (PROD-4394 F1): the awaited futures
    // are self-bounding AND each carries a defensive outer deadline, so an
    // optional shelf can never own the flow.
    final zinesProvider = switch (contentId) {
      zinesCarouselContentId => _zinesProvider,
      zinesSuggestedCarouselContentId => _suggestedZinesProvider,
      _ => null,
    };
    if (zinesProvider != null) return _loadAndWaitZines(zinesProvider);

    // The follow/people row reads the global suggested-users fetch.
    if (contentId == profileFollowsCarouselContentId) {
      return _loadAndWaitFollows();
    }

    final provider = switch (contentId) {
      vibeSitiosContentId => _vibeVenuesProvider,
      vibeEventosContentId => _vibeEventsProvider,
      _ => null,
    };
    if (provider == null) return null;

    // PROD-4394 P0-2: the moment the vibe step's FIRST carousel starts
    // loading, kick the second carousel's fetch AND the zines poll in the
    // background. The reveal stays sequential (Places shows fully before the
    // Events beat), but the network time overlaps instead of serializing —
    // this was the vibe step's 118s median gap. Both are idempotent; the
    // zines controller revives its poll budget when the shelf later mounts.
    if (contentId == vibeSitiosContentId) {
      final events = _vibeEventsProvider;
      if (events != null) unawaited(_container?.read(events.notifier).load());
      final zines = _zinesProvider;
      if (zines != null) unawaited(_container?.read(zines.notifier).load());
    }
    return _loadAndWaitVibe(provider);
  }

  /// Follows twin of [_loadAndWaitZines]/[_loadAndWaitVibe]: resolves once the
  /// global suggested-users fetch (the same provider the follow carousel reads)
  /// has settled, so that row mounts with its cards rather than a spinner. An
  /// error/empty result resolves too — the carousel then renders nothing.
  Future<void> _loadAndWaitFollows() async {
    final container = _container;
    if (container == null) return;
    try {
      await container.read(orderedSuggestedUsersProvider.future);
    } catch (_) {
      // Swallowed: an error/empty pool collapses the row, the flow moves on.
    }
  }

  /// Zines twin of [_loadAndWaitVibe]: starts the shelf's fetch now (idempotent
  /// with the carousel's own initState load) and resolves once it reports
  /// `hasLoaded`, so the "most-followed" row mounts with its cards in hand.
  Future<void> _loadAndWaitZines(
    StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>
    provider,
  ) async {
    final container = _container;
    if (container == null) return;
    container.read(provider.notifier).load();
    final completer = Completer<void>();
    final sub = container.listen<OnboardingZinesState>(provider, (_, next) {
      if (next.hasLoaded && !completer.isCompleted) completer.complete();
    }, fireImmediately: true);
    try {
      // Defensive outer deadline (PROD-4394 F1): the controller's poll budget
      // (~125s) already bounds this, but the chat flow must NEVER hinge on an
      // optional shelf — a listener bug or an unforeseen state shape times out
      // here and the flow moves on without the row.
      await completer.future.timeout(const Duration(seconds: 150));
    } on TimeoutException {
      // Shelf never settled — continue without it.
    } finally {
      sub.close();
    }
  }

  /// Starts the shelf's fetch now (idempotent with the carousel's own initState
  /// load) and resolves once it reports `hasLoaded`, so the carousel mounts with
  /// its cards already in hand rather than showing a second spinner.
  Future<void> _loadAndWaitVibe(
    StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>
    provider,
  ) async {
    final container = _container;
    if (container == null) return;
    container.read(provider.notifier).load();
    final completer = Completer<void>();
    final sub = container.listen<OnboardingVibeState>(provider, (_, next) {
      if (next.hasLoaded && !completer.isCompleted) completer.complete();
    }, fireImmediately: true);
    try {
      // Defensive outer deadline (PROD-4394 F1) — the vibe GETs are bounded by
      // their HTTP timeouts, but the flow must never hinge on a shelf.
      await completer.future.timeout(const Duration(seconds: 90));
    } on TimeoutException {
      // Shelf never settled — continue without it.
    } finally {
      sub.close();
    }
  }

  @override
  void dispose() {
    final provider = _provider;
    if (provider != null) _container?.invalidate(provider);
    final venues = _vibeVenuesProvider;
    if (venues != null) _container?.invalidate(venues);
    final events = _vibeEventsProvider;
    if (events != null) _container?.invalidate(events);
    final zines = _zinesProvider;
    if (zines != null) _container?.invalidate(zines);
    final suggestedZines = _suggestedZinesProvider;
    if (suggestedZines != null) _container?.invalidate(suggestedZines);
    super.dispose();
  }

  /// Admin/QA restart: reset the durable onboarding state on the server (same
  /// endpoint as the settings "Replay onboarding" row), refresh the profile so
  /// `onboarding_complete=false` propagates, then rebuild the screen-local flow
  /// providers and bump [_flowGeneration] so the inner screen replays from the
  /// top (its rebuilt controller reads the freshly-cleared server envelope).
  Future<void> _restartOnboarding() async {
    try {
      await ref.read(onboardingStateApiProvider).resetState();
      await ref.read(authStateProvider.notifier).refreshUserProfile();
    } catch (_) {
      // The reset endpoint may not be deployed on this backend; still restart
      // the local flow so QA can walk it again.
    }
    if (!mounted) return;

    final container = _container;
    final provider = _provider;
    if (provider != null) container?.invalidate(provider);
    final venues = _vibeVenuesProvider;
    if (venues != null) container?.invalidate(venues);
    final events = _vibeEventsProvider;
    if (events != null) container?.invalidate(events);
    final zines = _zinesProvider;
    if (zines != null) container?.invalidate(zines);
    final suggestedZines = _suggestedZinesProvider;
    if (suggestedZines != null) container?.invalidate(suggestedZines);

    setState(() {
      _flowGeneration++;
      _buildFlowProviders();
    });
    _startedAt = DateTime.now();
    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(step: 'start', action: 'restarted');
  }

  /// Admin/QA skip: jump straight to the end of onboarding. `PUT step=complete`
  /// flips `onboarding_complete` server-side (the single completion path, spec
  /// PROD-3882), then we refresh the profile so the router gate releases and
  /// leave to the app. The fast-forward counterpart to [_restartOnboarding];
  /// carries forward whatever branch/city/path the current snapshot resolved so
  /// the idempotent completion PUT never blanks them.
  Future<void> _skipOnboarding() async {
    final provider = _provider;
    final snapshot = provider != null ? ref.read(provider).snapshot : null;
    try {
      await ref
          .read(onboardingStateApiProvider)
          .putState(
            OnboardingStatePutDto(
              version:
                  snapshot?.version ??
                  ApiOnboardingProgressStore.defaultVersion,
              step: OnboardingStepId.complete.wireId,
              branch: snapshot?.branch?.wireId,
              selectedCity: snapshot?.selectedCity,
              completionPath: snapshot?.completionPath?.wireId,
            ),
          );
      await ref.read(authStateProvider.notifier).refreshUserProfile();
    } catch (_) {
      // The state endpoint may not be deployed on this backend; fall through
      // and let the (still-forcing) gate keep the admin in onboarding rather
      // than stranding them on a half-left screen.
    }
    if (!context.mounted) return;
    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(step: 'complete', action: 'skipped');
    context.go(ref.read(onboardingExitDestinationProvider));
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    if (provider == null) return const SizedBox.shrink();

    // Completion unlocks the app immediately (server flips onboarding_complete;
    // the router gate re-runs and stops forcing). Navigate home explicitly so
    // the last onboarding frame doesn't linger.
    ref.listen(provider.select((s) => s.snapshot?.isComplete ?? false), (
      _,
      isComplete,
    ) async {
      if (!isComplete || !mounted) return;
      final analytics = ref.read(unifiedAnalyticsProvider);
      analytics.trackOnboardingStep(step: 'complete', action: 'completed');
      // Bottom-of-funnel event with the full completion shape: which subturns
      // were answered, the path taken (a `minimal` chat-handoff bails at the
      // not-local fork, skipping vibe→rituals), and best-effort session time.
      final snapshot = ref.read(provider).snapshot;
      final startedAt = _startedAt;
      analytics.trackOnboardingComplete(
        completedSteps: [
          for (final s in snapshot?.completedSubturns ?? const []) s.wireId,
        ],
        skippedAtStep:
            snapshot?.completionPath == OnboardingCompletionPath.minimal
            ? OnboardingSubturnId.notLocalChoice.wireId
            : null,
        totalTimeSeconds: startedAt != null
            ? DateTime.now().difference(startedAt).inSeconds
            : null,
      );
      // Refresh the profile so onboarding_complete=true propagates BEFORE we
      // leave — otherwise the still-true gate would bounce us straight back.
      //
      // PROD-4580: best-effort. This runs after an await, so a disposed screen
      // ("Cannot use \"ref\" after the widget was disposed", FLUTTER-1AC) or a
      // failed refresh used to throw straight out of the listener and skip the
      // `context.go` below — stranding the user on a finished onboarding screen
      // whose CTAs and composer are both gone, with no way out. Leaving is more
      // important than the refresh succeeding: the router gate re-reads the
      // profile on its own, and a stale gate only bounces us back here, where
      // `load()` now reconciles the state instead of deadlocking.
      try {
        await ref.read(authStateProvider.notifier).refreshUserProfile();
      } catch (_) {
        // Fall through and leave anyway.
      }
      if (mounted) context.go(ref.read(onboardingExitDestinationProvider));
    });

    // Surface the otherwise-invisible per-step persistence failures as a funnel
    // signal: fire an `error` action (keyed to the step being persisted) the
    // moment the retry card appears. Sentry carries the exception detail (see
    // the controller); this gives the per-step error RATE in PostHog.
    ref.listen(provider.select((s) => s.submissionError != null), (
      wasError,
      hasError,
    ) {
      if (!hasError || wasError == true || !mounted) return;
      final state = ref.read(provider);
      final step =
          state.pendingAnswer?.subturnId.wireId ??
          state.snapshot?.currentSubturnId.wireId ??
          'start';
      ref
          .read(unifiedAnalyticsProvider)
          .trackOnboardingStep(step: step, action: 'error');
    });

    return PopScope(
      // Non-dismissible: swallow system back inside onboarding.
      canPop: false,
      child: OnboardingIdentityNameScreen(
        // API-backed flow: `/onboarding/state` rejects guests outright, so hold
        // the load until a real session exists (PROD-4582).
        waitsForSession: true,
        // A fresh key on restart forces a new inner State so the transcript
        // replays from step 1 rather than resuming the old delivery.
        key: ValueKey(_flowGeneration),
        controllerProvider: provider,
        copy: _copy,
        vibeVenuesProvider: _vibeVenuesProvider,
        vibeEventsProvider: _vibeEventsProvider,
        zinesProvider: _zinesProvider,
        suggestedZinesProvider: _suggestedZinesProvider,
        onRestart: _restartOnboarding,
        onSkip: _skipOnboarding,
        // Best-effort: also feed the free text into the user's memory. Admin/
        // feature-flag gated server-side today (non-admins get status:disabled);
        // errors are swallowed so onboarding completion never depends on it.
        onExtraText: (text) =>
            ref.read(memoryTwinProvider.notifier).tellUs(text),
      ),
    );
  }
}
