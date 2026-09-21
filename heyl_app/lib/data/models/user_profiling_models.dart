// Models for the post-signup vibe onboarding flow (V6 spec).
//
// Wire shape mirrors `GET /api/v1/app/user_profiling/questions` and
// `POST /api/v1/app/user_profiling/submit`. See full spec at:
//   docs/features/onboarding-vibe-flow.md
//   /Users/joaograca/Downloads/onboarding_survey_routing_V6.txt

// =============================================================================
// QUESTION CATALOG (from GET /user_profiling/questions)
// =============================================================================

/// The full onboarding question catalog returned by the backend.
class UserProfilingQuestions {
  /// Backend-side version of the catalog (e.g. "V6-2026.04.28"). The client
  /// caches by this value and invalidates when editorial ships new copy.
  final String version;
  final List<UserProfilingStep> steps;

  const UserProfilingQuestions({required this.version, required this.steps});

  factory UserProfilingQuestions.fromJson(Map<String, dynamic> json) {
    return UserProfilingQuestions(
      version: json['version'] as String,
      steps: (json['steps'] as List<dynamic>)
          .map((s) => UserProfilingStep.fromJson(s as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

enum UserProfilingStepKind { vibe, interests }

UserProfilingStepKind _stepKindFromWire(String raw) {
  switch (raw) {
    case 'vibe':
      return UserProfilingStepKind.vibe;
    case 'interests':
      return UserProfilingStepKind.interests;
    default:
      throw FormatException('Unknown onboarding step kind: $raw');
  }
}

/// A single step in the vibe survey. Vibe steps (1-4) allow 1-2 selections;
/// the interests step (5) allows 1-4. Per V6 spec, all steps are
/// multi-select.
class UserProfilingStep {
  /// Stable enum string used for analytics + the submit payload key.
  /// One of: `morning`, `activity`, `food`, `night`, `interests`.
  final String id;
  final UserProfilingStepKind kind;

  /// Localization key for the step's question heading.
  final String titleKey;

  /// Localization key for the secondary subtitle (may be empty for some
  /// steps).
  final String? subtitleKey;

  /// Minimum selections required (typically 1).
  final int min;

  /// Maximum selections allowed (2 for vibe steps, 4 for interests).
  final int max;

  final List<UserProfilingOption> options;

  const UserProfilingStep({
    required this.id,
    required this.kind,
    required this.titleKey,
    required this.min,
    required this.max,
    required this.options,
    this.subtitleKey,
  });

  factory UserProfilingStep.fromJson(Map<String, dynamic> json) {
    return UserProfilingStep(
      id: json['id'] as String,
      kind: _stepKindFromWire(json['kind'] as String),
      titleKey: json['title_key'] as String,
      subtitleKey: json['subtitle_key'] as String?,
      min: (json['min'] as int?) ?? 1,
      max: (json['max'] as int?) ?? 2,
      options: (json['options'] as List<dynamic>)
          .map((o) => UserProfilingOption.fromJson(o as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

/// An option within a step. For vibe options the `vibeLabelKey` and
/// `imageUrl` are populated; for interest chips the `icon` (emoji) is set
/// and the other two are null.
class UserProfilingOption {
  /// Stable enum string. For vibes this matches the V6 spec IDs
  /// (`S1_A`..`S4_C`); for interests it's the kebab-case interest id
  /// (`hikes-nature`, `sports-fitness`, ...).
  final String id;

  /// Localization key for the primary option label.
  final String labelKey;

  /// Localization key for the secondary all-lowercase vibe tag (e.g.
  /// "classic & cozy"). Null for interest chips.
  final String? vibeLabelKey;

  /// Hero image URL for vibe cards. Null for interest chips. Supports the
  /// `asset:` scheme for bundled images.
  final String? imageUrl;

  /// Emoji glyph for interest chips (e.g. "🥾"). Null for vibe cards.
  final String? icon;

  const UserProfilingOption({
    required this.id,
    required this.labelKey,
    this.vibeLabelKey,
    this.imageUrl,
    this.icon,
  });

  factory UserProfilingOption.fromJson(Map<String, dynamic> json) {
    return UserProfilingOption(
      id: json['id'] as String,
      labelKey: json['label_key'] as String,
      vibeLabelKey: json['vibe_label_key'] as String?,
      imageUrl: json['image_url'] as String?,
      icon: json['icon'] as String?,
    );
  }
}

// =============================================================================
// SUBMIT REQUEST (POST /user_profiling/submit body)
// =============================================================================

/// User-provided location captured in Step 0. City is required; everything
/// else is optional.
class UserProfilingLocation {
  final String city;
  final String? neighbourhood;
  final double? latitude;
  final double? longitude;

  const UserProfilingLocation({
    required this.city,
    this.neighbourhood,
    this.latitude,
    this.longitude,
  });

  Map<String, dynamic> toJson() => {
    'city': city,
    if (neighbourhood != null && neighbourhood!.isNotEmpty)
      'neighbourhood': neighbourhood,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
  };
}

/// Payload for `POST /api/v1/app/user_profiling/submit`.
///
/// `selections` is keyed by step id (`morning`, `activity`, `food`, `night`)
/// with a list of 1-2 option IDs each (e.g. `["S1_A", "S1_C"]`).
/// `interests` is the flat list of 1-4 interest IDs.
class UserProfilingSubmitRequest {
  final UserProfilingLocation location;
  final Map<String, List<String>> selections;
  final List<String> interests;

  const UserProfilingSubmitRequest({
    required this.location,
    required this.selections,
    required this.interests,
  });

  Map<String, dynamic> toJson() => {
    'location': location.toJson(),
    'selections': selections,
    'interests': interests,
  };
}

// =============================================================================
// SUBMIT RESPONSE
// =============================================================================

/// Atomic response from /user_profiling/submit: assigned persona + the smart
/// lists the backend created for the user.
class UserProfilingSubmitResponse {
  final Persona persona;

  /// Confidence in the assigned persona (0.0-1.0). Derived from
  /// `top_score / (top_score + second_score)`. Useful for downstream UI
  /// that wants to flag low-confidence assignments.
  final double confidence;

  /// Profile-level booleans derived from interest selections:
  /// * `user_is_active` — true if "sports-fitness" was selected
  /// * `user_has_kids` — true if "family" was selected
  final ProfileSignals profileSignals;

  /// 2-4 smart lists generated from the user's interests + location +
  /// persona. The backend has already saved these as Soko lists.
  final List<SmartList> smartLists;

  const UserProfilingSubmitResponse({
    required this.persona,
    required this.confidence,
    required this.profileSignals,
    required this.smartLists,
  });

  factory UserProfilingSubmitResponse.fromJson(Map<String, dynamic> json) {
    return UserProfilingSubmitResponse(
      persona: Persona.fromJson(json['persona'] as Map<String, dynamic>),
      confidence: (json['confidence'] as num).toDouble(),
      profileSignals: ProfileSignals.fromJson(
        json['profile_signals'] as Map<String, dynamic>,
      ),
      smartLists: (json['smart_lists'] as List<dynamic>)
          .map((l) => SmartList.fromJson(l as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

/// V6 personas. Stable enum strings — used end-to-end (DB, API, app,
/// analytics).
class Persona {
  /// One of: `conscious_outdoors`, `local_at_heart`, `curious_cosmopolitan`,
  /// `golden_age`, `quality_seeker`.
  final String id;
  final String nameKey;
  final String descriptionKey;

  /// Optional emoji decoration shown in the result screen.
  final String? emoji;

  const Persona({
    required this.id,
    required this.nameKey,
    required this.descriptionKey,
    this.emoji,
  });

  factory Persona.fromJson(Map<String, dynamic> json) {
    return Persona(
      id: json['id'] as String,
      nameKey: json['name_key'] as String,
      descriptionKey: json['description_key'] as String,
      emoji: json['emoji'] as String?,
    );
  }
}

class ProfileSignals {
  final bool userIsActive;
  final bool userHasKids;

  const ProfileSignals({required this.userIsActive, required this.userHasKids});

  factory ProfileSignals.fromJson(Map<String, dynamic> json) => ProfileSignals(
    userIsActive: (json['user_is_active'] as bool?) ?? false,
    userHasKids: (json['user_has_kids'] as bool?) ?? false,
  );
}

/// One smart list — a saved Soko list seeded by the backend during
/// onboarding. The full list is queryable via the existing
/// `/users/me/lists/{id}` endpoint.
///
/// Cover slots mirror `ListIdentityOut` so the "Just for you" screen can
/// render the curated `Zine-Profiling-*.jpg` covers via the canonical
/// `ZineCoverRecipe.fromFields` resolver without an extra fetch.
class SmartList {
  /// UUID of the saved Soko list.
  final String id;

  /// Display name of the list (already localized + interpolated by the
  /// backend). Example: "Cozy Coffee Spots".
  final String name;

  /// Optional list description.
  final String? description;

  /// Number of items in the seeded list.
  final int itemCount;

  final String coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverImageUrl;
  final String? coverItemId;
  final String? coverItemImageUrl;

  /// PROD-2297 per-list curator chrome toggles. The submit response
  /// returns these as `false` for every smart list (all are
  /// `is_from_profiling=TRUE`), matching the BE backfill for the
  /// same rows on `user_lists`. Default `true` on parse keeps older
  /// API responses safe — though smart-lists callers expect them set.
  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;

  const SmartList({
    required this.id,
    required this.name,
    required this.itemCount,
    required this.coverType,
    this.description,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverImageUrl,
    this.coverItemId,
    this.coverItemImageUrl,
    this.coverShowTitle = true,
    this.coverShowTexture = true,
    this.coverShowLogo = true,
  });

  factory SmartList.fromJson(Map<String, dynamic> json) => SmartList(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    itemCount: (json['item_count'] as num?)?.toInt() ?? 0,
    coverType: (json['cover_type'] as String?) ?? 'background_color',
    coverColor: json['cover_color'] as String?,
    coverTexture: json['cover_texture'] as String?,
    coverTextColor: json['cover_text_color'] as String?,
    coverImageUrl: json['cover_image_url'] as String?,
    coverItemId: json['cover_item_id'] as String?,
    coverItemImageUrl: json['cover_item_image_url'] as String?,
    coverShowTitle: json['cover_show_title'] as bool? ?? true,
    coverShowTexture: json['cover_show_texture'] as bool? ?? true,
    coverShowLogo: json['cover_show_logo'] as bool? ?? true,
  );
}
