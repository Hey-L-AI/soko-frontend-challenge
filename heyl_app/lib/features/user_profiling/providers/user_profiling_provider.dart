import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/datasources/interfaces/api_interfaces.dart';
import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';

/// In-memory state for the user-profiling (V6 vibe) flow.
///
/// Flow: Location (Step 0) → 4 vibe steps (1-2 selections each) → 1 interests
/// step (1-4 selections) → submit → result.
///
/// Selections per vibe step are stored as a list of option IDs.
/// `interests` is a flat list of 1-4 interest IDs.
@immutable
class UserProfilingState {
  /// 0 = location, 1..4 = vibe steps, 5 = interests, 6 = result.
  final int currentStep;

  // Step 0 — structured location. cityId/cityName/iso2 come from the
  // shared Country+City picker or from the GPS/IP fallback path, so they
  // always reference a real `GeoCity` (or a synthetic `gps:lat,lon` id
  // when `/geo/cities` couldn't match the GPS-reverse-geocoded name).
  // Free-text city entry is gone — "Bananas" is unreachable.
  final String? cityId;
  final String? cityName;
  final String? iso2;
  final String? countryName;
  final double? latitude;
  final double? longitude;
  final String neighbourhood;

  // Steps 1-4: keyed by step id ("morning"|"activity"|"food"|"night")
  // → 1-2 selected option IDs (e.g. ["S1_A", "S1_C"]).
  final Map<String, List<String>> selections;

  // Step 5: 1-4 interest IDs.
  final List<String> interests;

  /// True while [submit] is in flight.
  final bool submitting;

  /// Set once the backend returns a successful submit response.
  final UserProfilingSubmitResponse? result;

  /// Last submit error.
  final Object? error;

  const UserProfilingState({
    this.currentStep = 0,
    this.cityId,
    this.cityName,
    this.iso2,
    this.countryName,
    this.latitude,
    this.longitude,
    this.neighbourhood = '',
    this.selections = const {},
    this.interests = const [],
    this.submitting = false,
    this.result,
    this.error,
  });

  /// True iff the user has picked (or auto-resolved) a real city.
  bool get hasLocation =>
      (cityName?.trim().isNotEmpty ?? false) && (iso2?.isNotEmpty ?? false);

  /// True iff location is set AND every step in [catalog] has at least its
  /// declared `min` selections (vibe steps read from `selections[step.id]`;
  /// the interests step reads from the flat `interests` list).
  ///
  /// Derives from the catalog rather than a hardcoded vibe-id list so the
  /// gate doesn't silently break when the BE catalog drifts (PROD-2436 — the
  /// old getter hardcoded `morning|activity|food|night`, which would return
  /// false even with all visible-step selections set if the catalog ever
  /// renamed an id).
  bool isComplete(UserProfilingQuestions catalog) {
    if (!hasLocation) return false;
    for (final step in catalog.steps) {
      final count = step.kind == UserProfilingStepKind.interests
          ? interests.length
          : (selections[step.id]?.length ?? 0);
      if (count < step.min) return false;
    }
    return true;
  }

  UserProfilingState copyWith({
    int? currentStep,
    String? cityId,
    String? cityName,
    String? iso2,
    String? countryName,
    double? latitude,
    double? longitude,
    String? neighbourhood,
    Map<String, List<String>>? selections,
    List<String>? interests,
    bool? submitting,
    UserProfilingSubmitResponse? result,
    Object? error,
    bool clearError = false,
    bool clearResult = false,
    bool clearLocation = false,
  }) {
    return UserProfilingState(
      currentStep: currentStep ?? this.currentStep,
      cityId: clearLocation ? null : (cityId ?? this.cityId),
      cityName: clearLocation ? null : (cityName ?? this.cityName),
      iso2: clearLocation ? null : (iso2 ?? this.iso2),
      countryName: clearLocation ? null : (countryName ?? this.countryName),
      latitude: clearLocation ? null : (latitude ?? this.latitude),
      longitude: clearLocation ? null : (longitude ?? this.longitude),
      neighbourhood: neighbourhood ?? this.neighbourhood,
      selections: selections ?? this.selections,
      interests: interests ?? this.interests,
      submitting: submitting ?? this.submitting,
      result: clearResult ? null : (result ?? this.result),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class UserProfilingNotifier extends StateNotifier<UserProfilingState> {
  final IUserProfilingApi _api;

  UserProfilingNotifier(this._api) : super(const UserProfilingState());

  // ---- Step 0: location ----

  /// Apply a structured location pick (from the picker or the GPS/IP
  /// fallback path). Whitespace-only [cityName] is rejected so the
  /// `isComplete` invariant can't be poisoned.
  void setLocation({
    required String cityId,
    required String cityName,
    required String iso2,
    required String countryName,
    double? latitude,
    double? longitude,
  }) {
    if (cityName.trim().isEmpty || iso2.isEmpty) return;
    state = state.copyWith(
      cityId: cityId,
      cityName: cityName,
      iso2: iso2,
      countryName: countryName,
      latitude: latitude,
      longitude: longitude,
      clearError: true,
    );
  }

  void clearLocation() {
    state = state.copyWith(clearLocation: true, clearError: true);
  }

  void setNeighbourhood(String value) {
    state = state.copyWith(neighbourhood: value, clearError: true);
  }

  // ---- Steps 1-4: single-select ----

  /// Replace this step's selection with a single option. Used by the
  /// auto-advancing vibe pages — each vibe step is a 1-of-N pick and
  /// advances the moment the user taps. Re-tapping the same option is
  /// a noop. Tapping a different option swaps it in.
  void selectVibeOption(String stepId, String optionId) {
    final current = state.selections[stepId] ?? const [];
    if (current.length == 1 && current.first == optionId) return;
    final next = Map<String, List<String>>.from(state.selections);
    next[stepId] = [optionId];
    state = state.copyWith(selections: next, clearError: true);
  }

  /// Toggle an option in/out of the given vibe step's selection.
  /// Honors [max] (typically 2 for vibe steps): un-toggling always works,
  /// adding when at max is a no-op. Retained for any future multi-select
  /// vibe step; the live flow uses [selectVibeOption] for vibes.
  void toggleVibeOption(String stepId, String optionId, {int max = 2}) {
    final current = List<String>.from(state.selections[stepId] ?? const []);
    if (current.contains(optionId)) {
      current.remove(optionId);
    } else {
      if (current.length >= max) return;
      current.add(optionId);
    }
    final next = Map<String, List<String>>.from(state.selections);
    next[stepId] = current;
    state = state.copyWith(selections: next, clearError: true);
  }

  // ---- Step 5: interests multi-select (max 4) ----

  void toggleInterest(String id, {int max = 4}) {
    final current = List<String>.from(state.interests);
    if (current.contains(id)) {
      current.remove(id);
    } else {
      if (current.length >= max) return;
      current.add(id);
    }
    state = state.copyWith(interests: current, clearError: true);
  }

  // ---- Step navigation ----

  void goToStep(int step) {
    state = state.copyWith(currentStep: step);
  }

  void nextStep() {
    state = state.copyWith(currentStep: state.currentStep + 1);
  }

  void previousStep() {
    if (state.currentStep == 0) return;
    state = state.copyWith(currentStep: state.currentStep - 1);
  }

  // ---- Submit ----

  /// POST `/user_profiling/submit`. On success, [state.result] is populated.
  ///
  /// Takes [catalog] so the completeness gate validates against the actual
  /// BE-served step list (see `UserProfilingState.isComplete`).
  Future<void> submit(UserProfilingQuestions catalog) async {
    if (!state.isComplete(catalog)) {
      throw StateError('Cannot submit onboarding: state is incomplete');
    }
    state = state.copyWith(submitting: true, clearError: true);
    try {
      final response = await _api.submit(
        UserProfilingSubmitRequest(
          location: UserProfilingLocation(
            city: state.cityName!.trim(),
            neighbourhood: state.neighbourhood.trim().isEmpty
                ? null
                : state.neighbourhood.trim(),
            latitude: state.latitude,
            longitude: state.longitude,
          ),
          selections: state.selections,
          interests: state.interests,
        ),
      );
      state = state.copyWith(submitting: false, result: response);
    } catch (e) {
      state = state.copyWith(submitting: false, error: e);
      rethrow;
    }
  }

  /// Reset the whole flow.
  void reset() {
    state = const UserProfilingState();
  }
}

final userProfilingProvider =
    StateNotifierProvider<UserProfilingNotifier, UserProfilingState>((ref) {
      final api = ref.watch(userProfilingApiProvider);
      return UserProfilingNotifier(api);
    });

/// The current user's already-scored persona, for the "you've already done
/// this" landing an already-profiled user reaches via the `/user-profiling/flow`
/// deep link (PROD-2566).
///
/// **Pending backend (PROD-2698).** There is currently no read endpoint that
/// returns an existing user's composed persona — the persona is returned ONLY by
/// `POST /user_profiling/submit`, which also re-writes memory + smart lists, so
/// it can't be used as a read. Per the project constraint we do NOT call a
/// non-existent endpoint, so this provider falls back to the in-memory result if
/// the user happened to finish profiling earlier in this session, and otherwise
/// returns `null`. The landing renders gracefully without a persona card while
/// this is null.
///
/// TODO(PROD-2698): once the backend `GET` persona endpoint ships and is added
/// to the OpenAPI spec, replace the body with `ref.watch(userProfilingApi
/// Provider).getPersona()` and surface load/error states on the landing.
final alreadyProfiledPersonaProvider = FutureProvider<Persona?>((ref) async {
  return ref.watch(userProfilingProvider.select((s) => s.result?.persona));
});
