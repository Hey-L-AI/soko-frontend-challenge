// Wire DTOs for the resumable chat-onboarding state endpoint (PROD-3882 / BE-1):
//   GET  /api/v1/app/onboarding/state -> OnboardingStateDto
//   PUT  /api/v1/app/onboarding/state <- OnboardingStatePutDto -> OnboardingStateDto
//
// The backend persists at STEP granularity (identity, vibe, …) with a free-form
// answer object per step; the webapp's subturn-level mapping lives in the
// `ApiOnboardingProgressStore` adapter, not here. These DTOs stay a thin,
// loss-free mirror of the wire shape.

import 'package:flutter/foundation.dart';

/// Raw stored onboarding state (the `state` envelope on the response). `null`
/// on the response until the user's first PUT.
@immutable
class OnboardingStateInnerDto {
  const OnboardingStateInnerDto({
    this.step,
    this.branch,
    this.selectedCity,
    this.completionPath,
    this.answers = const {},
  });

  /// Canonical step id wire string (`identity`, `vibe`, `not_local`, `zines`,
  /// `profile`, `rituals`, `complete`).
  final String? step;
  final String? branch;
  final String? selectedCity;
  final String? completionPath;

  /// Sub-answers keyed by canonical step id. Free-form object per step.
  final Map<String, dynamic> answers;

  factory OnboardingStateInnerDto.fromJson(Map<String, dynamic> json) {
    final rawAnswers = json['answers'];
    return OnboardingStateInnerDto(
      step: json['step'] as String?,
      branch: json['branch'] as String?,
      selectedCity: json['selected_city'] as String?,
      completionPath: json['completion_path'] as String?,
      answers: rawAnswers is Map
          ? Map<String, dynamic>.from(rawAnswers)
          : const {},
    );
  }
}

/// `GET`/`PUT /onboarding/state` response envelope.
@immutable
class OnboardingStateDto {
  const OnboardingStateDto({
    required this.complete,
    this.version,
    this.state,
    this.branch,
    this.selectedCity,
  });

  final bool complete;
  final String? version;

  /// `null` until the first PUT (a user who never advanced onboarding).
  final OnboardingStateInnerDto? state;

  /// Projected out of `state` for convenience by the backend.
  final String? branch;
  final String? selectedCity;

  factory OnboardingStateDto.fromJson(Map<String, dynamic> json) {
    final rawState = json['state'];
    return OnboardingStateDto(
      complete: json['complete'] as bool? ?? false,
      version: json['version'] as String?,
      state: rawState is Map<String, dynamic>
          ? OnboardingStateInnerDto.fromJson(rawState)
          : null,
      branch: json['branch'] as String?,
      selectedCity: json['selected_city'] as String?,
    );
  }
}

/// `PUT /onboarding/state` request body. Idempotent per `(user, step)`.
@immutable
class OnboardingStatePutDto {
  const OnboardingStatePutDto({
    required this.version,
    required this.step,
    this.branch,
    this.selectedCity,
    this.completionPath,
    this.answers,
    this.selectedCityId,
    this.selectedLatitude,
    this.selectedLongitude,
  });

  final String version;
  final String step;
  final String? branch;
  final String? selectedCity;
  final String? completionPath;

  /// The PICKED location, sent on the city step so the server resolves coverage
  /// authoritatively (against `discovery_enabled`) and sets `branch` itself.
  /// `selectedCityId` is a seeded-city UUID from the picker (GPS/area send only
  /// coords). Omitted on every non-city PUT so later steps don't re-resolve.
  final String? selectedCityId;
  final double? selectedLatitude;
  final double? selectedLongitude;

  /// Sub-answers for THIS step. `null` OMITS the field (advances the pointer /
  /// sets branch/city/path only, preserving prior answers); a provided object
  /// (even `{}`) overwrites `answers[step]`.
  final Map<String, dynamic>? answers;

  Map<String, dynamic> toJson() => {
    'version': version,
    'step': step,
    if (branch != null) 'branch': branch,
    if (selectedCity != null) 'selected_city': selectedCity,
    if (completionPath != null) 'completion_path': completionPath,
    if (selectedCityId != null) 'selected_city_id': selectedCityId,
    if (selectedLatitude != null) 'selected_latitude': selectedLatitude,
    if (selectedLongitude != null) 'selected_longitude': selectedLongitude,
    if (answers != null) 'answers': answers,
  };
}
