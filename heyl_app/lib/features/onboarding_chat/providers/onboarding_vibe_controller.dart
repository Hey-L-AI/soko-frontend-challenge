import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/entity_signal.dart';
import '../../../data/models/vibe_candidate.dart';
import '../../../providers/api_provider.dart';
import '../data/onboarding_hydrate_source.dart';
import '../data/onboarding_vibe_source.dart';

/// Writes a thumb (👍/👎) and returns the reconciled server state. Injected so
/// the controller is testable without a live [SignalApi].
typedef PostSignalFn =
    Future<EntitySignal> Function(
      SignalEntityType type,
      String id,
      SignalAction action, {
      String? provenance,
    });

const _unset = Object();

/// One vibe shelf's state (venues *or* events — a single carousel).
@immutable
class OnboardingVibeState {
  const OnboardingVibeState({
    this.candidates = const [],
    this.sentiments = const {},
    this.isLoading = false,
    this.hasLoaded = false,
    this.error,
  });

  final List<VibeCandidate> candidates;

  /// Optimistic per-entity thumb state, keyed by [VibeCandidate.entityId].
  final Map<String, SignalTaste> sentiments;
  final bool isLoading;

  /// True once a fetch has finished (success *or* error) — lets the Continue
  /// gate tell "still loading" apart from "loaded, but the backend had nothing
  /// to show", so an empty result never traps the user at the vibe step.
  final bool hasLoaded;
  final Object? error;

  bool get isEmpty => candidates.isEmpty;

  SignalTaste tasteFor(String entityId) =>
      sentiments[entityId] ?? SignalTaste.none;

  /// The shown candidate ids, in display order — persisted on Continue so the
  /// same cards can be re-hydrated (in the same order) on resume.
  List<String> get candidateIds => [for (final c in candidates) c.entityId];

  /// The entity ids the user thumbed up / down on this shelf.
  List<String> get likedIds => _idsWith(SignalTaste.liked);
  List<String> get dislikedIds => _idsWith(SignalTaste.disliked);

  List<String> _idsWith(SignalTaste taste) => [
    for (final entry in sentiments.entries)
      if (entry.value == taste) entry.key,
  ];

  OnboardingVibeState copyWith({
    List<VibeCandidate>? candidates,
    Map<String, SignalTaste>? sentiments,
    bool? isLoading,
    bool? hasLoaded,
    Object? error = _unset,
  }) => OnboardingVibeState(
    candidates: candidates ?? this.candidates,
    sentiments: sentiments ?? this.sentiments,
    isLoading: isLoading ?? this.isLoading,
    hasLoaded: hasLoaded ?? this.hasLoaded,
    error: identical(error, _unset) ? this.error : error,
  );
}

/// Fetches one shelf (venues *or* events) via its own discovery call, and
/// records 👍/👎 through the entity-signal endpoints.
class OnboardingVibeController extends StateNotifier<OnboardingVibeState> {
  OnboardingVibeController({
    required VibeCandidateType type,
    required IOnboardingVibeApi api,
    required PostSignalFn postSignal,
    IOnboardingHydrateApi? hydrateApi,
  }) : _type = type,
       _api = api,
       _postSignal = postSignal,
       _hydrateApi = hydrateApi,
       super(const OnboardingVibeState());

  /// Cards fetched per shelf in a single call (the discovery endpoint isn't
  /// paginated). The carousel renders them all and reveals more as the user
  /// scrolls horizontally.
  static const _fetchLimit = 24;

  final VibeCandidateType _type;
  final IOnboardingVibeApi _api;
  final PostSignalFn _postSignal;
  final IOnboardingHydrateApi? _hydrateApi;

  bool _loadStarted = false;

  /// Populate this shelf. Idempotent — safe to call from the carousel's
  /// initState.
  ///
  /// - **Resume** (`candidateIds` non-empty + a hydrate API is wired): re-hydrate
  ///   exactly those cards, in order, and seed the 👍/👎 from each card's own
  ///   persisted sentiment — the user sees the same shelf they left.
  /// - **First visit** (`candidateIds` empty): fetch a fresh discovery batch.
  Future<void> load({List<String> candidateIds = const []}) async {
    if (_loadStarted) return;
    _loadStarted = true;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final hydrateApi = _hydrateApi;
      if (candidateIds.isNotEmpty && hydrateApi != null) {
        final hydrated = await hydrateApi.hydrate([
          for (final id in candidateIds)
            OnboardingEntityRef(
              type: _type == VibeCandidateType.event ? 'event' : 'place',
              id: id,
            ),
        ]);
        if (!mounted) return;
        state = state.copyWith(
          candidates: [for (final h in hydrated) h.candidate],
          sentiments: {
            for (final h in hydrated)
              if (h.sentiment != SignalTaste.none)
                h.candidate.entityId: h.sentiment,
          },
          isLoading: false,
          hasLoaded: true,
        );
        return;
      }

      final candidates = await _api.fetch(type: _type, limit: _fetchLimit);
      if (!mounted) return;
      state = state.copyWith(
        candidates: candidates,
        isLoading: false,
        hasLoaded: true,
      );
      // Overlay the caller's already-held 👍/👎 for these entities. The signal
      // endpoint is a server-side TOGGLE, so a card for something the user liked
      // in an EARLIER session must render selected — otherwise the next tap
      // silently toggles that like back to `none` and the vibe gate never opens
      // (PROD-3888). Discovery items carry no sentiment, so hydrate the ids.
      // Runs AFTER first paint (cards are already shown) and never fatally.
      await _seedSentiments(candidates);
    } catch (error) {
      if (!mounted) return;
      _loadStarted = false; // allow retry
      state = state.copyWith(isLoading: false, error: error, hasLoaded: true);
    }
  }

  /// Apply a thumb. Optimistically toggles, POSTs, then reconciles to the
  /// server's returned sentiment; reverts on failure.
  ///
  /// Returns the reconciled server sentiment (the NET result — `none` when a tap
  /// cleared a held sentiment, since the endpoint is a toggle), or `null` when
  /// the write failed and the optimistic state was reverted. Callers use this to
  /// report the funnel event for what actually persisted, not the tap intent.
  Future<SignalTaste?> toggle(
    VibeCandidate candidate,
    SignalAction action,
  ) async {
    final id = candidate.entityId;
    final previous = state.tasteFor(id);
    final target = action == SignalAction.like
        ? SignalTaste.liked
        : SignalTaste.disliked;
    final predicted = previous == target ? SignalTaste.none : target;

    state = state.copyWith(sentiments: _withSentiment(id, predicted));

    try {
      final signal = await _postSignal(
        candidate.type.signalType,
        id,
        action,
        provenance: SignalProvenance.onboardingDiscovery,
      );
      if (!mounted) return signal.taste;
      state = state.copyWith(sentiments: _withSentiment(id, signal.taste));
      return signal.taste;
    } catch (_) {
      if (!mounted) return null;
      state = state.copyWith(sentiments: _withSentiment(id, previous));
      return null;
    }
  }

  /// Fetch the caller's persisted sentiment for freshly-discovered [candidates]
  /// and merge it into state, WITHOUT clobbering any thumb the user tapped
  /// during the round-trip (existing keys win). No-op without a hydrate API
  /// (test wiring) or on any hydrate error — the shelf is usable regardless.
  Future<void> _seedSentiments(List<VibeCandidate> candidates) async {
    final hydrateApi = _hydrateApi;
    if (hydrateApi == null || candidates.isEmpty) return;
    try {
      final hydrated = await hydrateApi.hydrate([
        for (final c in candidates)
          OnboardingEntityRef(
            type: c.type == VibeCandidateType.event ? 'event' : 'place',
            id: c.entityId,
          ),
      ]);
      if (!mounted) return;
      final seeded = <String, SignalTaste>{
        for (final h in hydrated)
          if (h.sentiment != SignalTaste.none)
            h.candidate.entityId: h.sentiment,
      };
      if (seeded.isEmpty) return;
      state = state.copyWith(sentiments: {...seeded, ...state.sentiments});
    } catch (_) {
      // Non-fatal: cards are already shown; seeding is best-effort.
    }
  }

  /// Overwrite the held taste for [id] from an authoritative external source —
  /// the shared [signalControllerProvider], re-read when a pushed detail page
  /// returns. The detail's 👍/👎 write to that shared controller, NOT this
  /// shelf's local [OnboardingVibeState.sentiments], so without this re-sync a
  /// like made inside a card's detail would leave the shelf card (and the
  /// Continue gate's [OnboardingVibeState.likedIds]) stale. No-op when the taste
  /// is unchanged so we don't churn state. Mirrors the picks-row re-sync in
  /// `onboarding_identity_name_screen.dart` `_openSearchItemDetail`.
  void syncTaste(String id, SignalTaste taste) {
    if (!mounted || state.tasteFor(id) == taste) return;
    state = state.copyWith(sentiments: _withSentiment(id, taste));
  }

  Map<String, SignalTaste> _withSentiment(String id, SignalTaste taste) => {
    ...state.sentiments,
    id: taste,
  };
}

/// Screen-local provider factory — wired at the call site with the real API and
/// signal writer, invalidated when the onboarding screen disposes.
StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>
createOnboardingVibeProvider({
  required VibeCandidateType type,
  required IOnboardingVibeApi api,
  required PostSignalFn postSignal,
  IOnboardingHydrateApi? hydrateApi,
}) => StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>(
  (ref) => OnboardingVibeController(
    type: type,
    api: api,
    postSignal: postSignal,
    hydrateApi: hydrateApi,
  ),
);

/// A live shelf provider (one per [VibeCandidateType]) whose dependencies
/// resolve lazily inside the body, so nothing hits the network until the
/// carousel first reads it. The onboarding screen builds one per shelf and
/// invalidates them on dispose.
StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>
buildLiveOnboardingVibeProvider(VibeCandidateType type) =>
    StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>(
      (ref) => OnboardingVibeController(
        type: type,
        api: ref.watch(onboardingVibeApiProvider),
        postSignal: ref.read(signalApiProvider).postSignal,
        hydrateApi: ref.watch(onboardingHydrateApiProvider),
      ),
    );
