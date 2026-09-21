import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/exceptions/api_exceptions.dart';
import '../data/onboarding_zine.dart';
import '../data/onboarding_zines_source.dart';

/// The onboarding zines step's state — the generated preliminary zines (one per
/// picked interest) plus their load/save status. The step shows a row of themed
/// zine cover cards; each is saved independently (a one-way whole-zine copy).
@immutable
class OnboardingZinesState {
  const OnboardingZinesState({
    this.zines = const [],
    this.isLoading = false,
    this.hasSettled = false,
    this.gaveUpGenerating = false,
    this.error,
    this.savingIds = const {},
    this.savedIds = const {},
    this.savedRefs = const {},
  });

  final List<OnboardingPreliminaryZine> zines;
  final bool isLoading;

  /// PROD-4394 F1: explicit settled tri-state (content / empty / error). The
  /// old derived getter (`zines.isNotEmpty || error != null`) could never
  /// become true on a SUCCESSFUL EMPTY response, so the chat controller's
  /// content-await hung the flow forever on an empty shelf. Set on every
  /// terminal outcome of [OnboardingZinesController.load] — zines in hand,
  /// legitimately empty, error, or a generating-budget give-up.
  final bool hasSettled;

  /// The generating-poll budget was exhausted without a terminal answer
  /// (PROD-4394 P0-4). Settled as EMPTY so the flow continues — the zines land
  /// on the user's feed once generation finishes; the next
  /// [OnboardingZinesController.load] call revives polling with a fresh budget
  /// (a prefetch that gave up must not hide zines that became ready by the
  /// time the shelf actually mounts).
  final bool gaveUpGenerating;

  final Object? error;

  /// List ids with a save/unsave in flight.
  final Set<String> savingIds;

  /// List ids currently saved (copied to an owned list, or followed).
  final Set<String> savedIds;

  /// Preliminary list id → the reference needed to reverse its save (the copied
  /// owned list's id, or the followed list's id). Populated by [save]; absent
  /// for a save that predates this session (resume), where the follow batch can
  /// still unsave from the list id alone but the copy batch cannot.
  final Map<String, String> savedRefs;

  bool get isEmpty => zines.isEmpty;
  bool get anySaved => savedIds.isNotEmpty;

  /// True once the initial [OnboardingZinesController.load] has settled — with
  /// zines in hand, a legitimately EMPTY result (thin-supply `no_supply`), a
  /// terminal error, or a generating-budget give-up. Lets the screen hold a
  /// carousel's "searching…" beat until its real fetch resolves (see
  /// `_loadAndWaitZines`) without an empty success stalling the flow forever
  /// (PROD-4394 F1).
  bool get hasLoaded => !isLoading && hasSettled;

  bool isSaving(String listId) => savingIds.contains(listId);
  bool isSaved(String listId) => savedIds.contains(listId);

  OnboardingZinesState copyWith({
    List<OnboardingPreliminaryZine>? zines,
    bool? isLoading,
    bool? hasSettled,
    bool? gaveUpGenerating,
    Object? error = _unset,
    Set<String>? savingIds,
    Set<String>? savedIds,
    Map<String, String>? savedRefs,
  }) => OnboardingZinesState(
    zines: zines ?? this.zines,
    isLoading: isLoading ?? this.isLoading,
    hasSettled: hasSettled ?? this.hasSettled,
    gaveUpGenerating: gaveUpGenerating ?? this.gaveUpGenerating,
    error: identical(error, _unset) ? this.error : error,
    savingIds: savingIds ?? this.savingIds,
    savedIds: savedIds ?? this.savedIds,
    savedRefs: savedRefs ?? this.savedRefs,
  );

  static const _unset = Object();
}

/// Fetches the generated preliminary zines and saves them on request.
class OnboardingZinesController extends StateNotifier<OnboardingZinesState> {
  OnboardingZinesController({
    required IOnboardingZinesApi api,
    List<Duration>? notReadyBackoff,
    List<Duration>? generatingBackoff,
  }) : _api = api,
       _notReadyBackoff = notReadyBackoff ?? _defaultNotReadyBackoff,
       _generatingBackoff = generatingBackoff ?? _defaultGeneratingBackoff,
       super(const OnboardingZinesState());

  final IOnboardingZinesApi _api;

  bool _loadStarted = false;

  /// Backoff for the not-ready (409) race — the zines request can beat the
  /// identity-step commit that persists the user's interests (or the city). This
  /// resolves in well under a second, so a short window is right: give up to the
  /// error + manual retry once it's exhausted, rather than polling a genuine
  /// "you skipped a step" precondition forever. Injectable for tests.
  final List<Duration> _notReadyBackoff;

  static const _defaultNotReadyBackoff = <Duration>[
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
  ];

  /// Backoff for the "generating" (409) case — zine generation runs in a
  /// background Celery task (PROD-3882) enqueued a few steps earlier. It takes
  /// ~15-35s (measured ~35s for 4 interests) and backend p95 engine time is
  /// ~70s — the old ~60s budget regularly expired on HEALTHY generations
  /// (PROD-4394 P0-4). Now ≥120s across ~41 polls at a ≥2s cadence; the
  /// backend re-enqueues on each 409 (idempotent, advisory-locked, deduped by
  /// a Redis in-flight marker), so don't poll faster. Exhausting THIS budget
  /// is not an error: the load settles EMPTY with [gaveUpGenerating] so the
  /// flow continues (zines land on the feed once ready) and a later [load]
  /// revives polling with a fresh budget.
  final List<Duration> _generatingBackoff;

  static final List<Duration> _defaultGeneratingBackoff = <Duration>[
    const Duration(seconds: 1),
    const Duration(seconds: 2),
    ...List<Duration>.filled(39, const Duration(seconds: 3)),
  ];

  /// The backend's `409` detail for the background-generation case
  /// (`"Preliminary zines are being generated, retry shortly."`). The
  /// city/interests-race 409s carry a different `detail`, so this string check
  /// routes each to the right backoff. Matched loosely (substring, lower-cased)
  /// to survive minor copy tweaks.
  static bool _isGenerating(NotReadyException error) =>
      error.message.toLowerCase().contains('generat');

  /// Generate the preliminary zines. Idempotent — safe to call from the shelf's
  /// initState.
  ///
  /// [seedSavedIds] re-paints the "Saved" state on resume: zine content is
  /// stable server-side, but the saved set resets each mount, so a returning
  /// user who kept some zines needs them seeded from the persisted answer.
  /// One-way (never un-saves), matching [save].
  Future<void> load({Set<String> seedSavedIds = const {}}) async {
    if (seedSavedIds.isNotEmpty) {
      state = state.copyWith(savedIds: {...state.savedIds, ...seedSavedIds});
    }
    // PROD-4394 P0-4: a load that previously gave up on the generating budget
    // (e.g. an eager prefetch fired steps earlier) revives with a fresh budget
    // when called again — otherwise a stale give-up would hide zines that
    // became ready between the prefetch and the shelf actually mounting.
    if (_loadStarted && state.gaveUpGenerating && !state.isLoading) {
      _loadStarted = false;
    }
    if (_loadStarted) return;
    _loadStarted = true;
    state = state.copyWith(
      isLoading: true,
      error: null,
      hasSettled: false,
      gaveUpGenerating: false,
    );
    // Separate counters: a "generating" 409 (background task in flight) polls a
    // long window; a city/interests-race 409 polls a short one. Tracking them
    // independently means an early race 409 never eats into the generating
    // budget, and vice versa.
    var raceAttempt = 0;
    var generatingAttempt = 0;
    for (;;) {
      try {
        final zines = await _api.fetch();
        if (!mounted) return;
        // PROD-4394 F1: settle EXPLICITLY — an empty success (the backend's
        // terminal thin-supply `no_supply` answer) is a settled outcome, not
        // a keep-waiting state. The shelf collapses; the flow continues.
        state = state.copyWith(
          zines: zines,
          isLoading: false,
          hasSettled: true,
        );
        return;
      } on NotReadyException catch (error) {
        // Precondition not met yet — keep the spinner up and retry within the
        // matching backoff window.
        if (!mounted) return;
        final generating = _isGenerating(error);
        final backoff = generating ? _generatingBackoff : _notReadyBackoff;
        final attempt = generating ? generatingAttempt++ : raceAttempt++;
        if (attempt >= backoff.length) {
          if (generating) {
            // Budget exhausted on a HEALTHY-but-slow generation: not an
            // error. Settle empty + gaveUpGenerating so the chat continues
            // ("we'll have them on your feed"); a later load() revives.
            state = state.copyWith(
              isLoading: false,
              hasSettled: true,
              gaveUpGenerating: true,
            );
            return;
          }
          // The city/interests race window expired — a genuine precondition
          // problem. Surface the error + manual retry.
          _loadStarted = false;
          state = state.copyWith(
            isLoading: false,
            hasSettled: true,
            error: error,
          );
          return;
        }
        await Future<void>.delayed(backoff[attempt]);
      } catch (error) {
        if (!mounted) return;
        _loadStarted = false; // allow retry
        state = state.copyWith(
          isLoading: false,
          hasSettled: true,
          error: error,
        );
        return;
      }
    }
  }

  /// Save (copy/follow) one zine. No-op once saved or while a save/unsave is in
  /// flight. Optimistic: the bookmark fills on the tap and only rolls back if
  /// the request fails, so it never waits out the (occasionally slow) copy POST.
  Future<void> save(String listId) async {
    if (state.isSaved(listId) || state.isSaving(listId)) return;
    state = state.copyWith(
      savingIds: {...state.savingIds, listId},
      savedIds: {...state.savedIds, listId},
    );
    try {
      final savedRef = await _api.save(listId);
      if (!mounted) return;
      state = state.copyWith(
        savingIds: {...state.savingIds}..remove(listId),
        savedRefs: {...state.savedRefs, listId: savedRef},
      );
    } catch (_) {
      if (!mounted) return;
      // Roll the optimistic flip back off.
      state = state.copyWith(
        savingIds: {...state.savingIds}..remove(listId),
        savedIds: {...state.savedIds}..remove(listId),
      );
    }
  }

  /// Reverse a [save]. No-op unless currently saved and idle. Optimistic like
  /// [save] — the bookmark empties on the tap and only rolls back on failure.
  Future<void> unsave(String listId) async {
    if (!state.isSaved(listId) || state.isSaving(listId)) return;
    final savedRef = state.savedRefs[listId];
    state = state.copyWith(
      savingIds: {...state.savingIds, listId},
      savedIds: {...state.savedIds}..remove(listId),
    );
    try {
      await _api.unsave(listId, savedListId: savedRef);
      if (!mounted) return;
      state = state.copyWith(
        savingIds: {...state.savingIds}..remove(listId),
        savedRefs: {...state.savedRefs}..remove(listId),
      );
    } catch (_) {
      if (!mounted) return;
      // Couldn't unsave (e.g. a copied zine from a prior session with no stored
      // ref) — put the saved flip back so the UI stays honest.
      state = state.copyWith(
        savingIds: {...state.savingIds}..remove(listId),
        savedIds: {...state.savedIds, listId},
      );
    }
  }
}

/// Screen-local provider factory — wired at the call site with the real API,
/// invalidated when the onboarding screen disposes.
StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>
createOnboardingZinesProvider({
  required IOnboardingZinesApi api,
  List<Duration>? notReadyBackoff,
  List<Duration>? generatingBackoff,
}) => StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>(
  (ref) => OnboardingZinesController(
    api: api,
    notReadyBackoff: notReadyBackoff,
    generatingBackoff: generatingBackoff,
  ),
);

/// A live provider whose dependency resolves lazily inside the body, so nothing
/// hits the network until the zines shelf first reads it. The onboarding screen
/// builds one and invalidates it on dispose.
StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>
buildLiveOnboardingZinesProvider() =>
    StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>(
      (ref) =>
          OnboardingZinesController(api: ref.watch(onboardingZinesApiProvider)),
    );

/// Live provider for the "most-followed" second batch on step 3. Same
/// controller, different source: [onboardingSuggestedZinesApiProvider] fetches
/// popular PUBLIC zines and saves by following. Built + invalidated alongside
/// [buildLiveOnboardingZinesProvider] by the onboarding screen.
StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>
buildLiveOnboardingSuggestedZinesProvider() =>
    StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>(
      (ref) => OnboardingZinesController(
        api: ref.watch(onboardingSuggestedZinesApiProvider),
      ),
    );
