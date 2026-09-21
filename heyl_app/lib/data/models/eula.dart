/// EULA acceptance models (PROD-2264).
///
/// Mirrors `EulaAcceptRequest` / `EulaAcceptanceOut` / `EulaStatusOut` in
/// `open-api/heyl-webapp-v1.openapi.yaml`.
library;

/// Source that recorded the EULA acceptance.
enum EulaAcceptanceSource {
  signup,
  forcedReaccept,
  preferences,
  backfill;

  String toJson() => switch (this) {
    EulaAcceptanceSource.signup => 'signup',
    EulaAcceptanceSource.forcedReaccept => 'forced_reaccept',
    EulaAcceptanceSource.preferences => 'preferences',
    EulaAcceptanceSource.backfill => 'backfill',
  };

  static EulaAcceptanceSource fromJson(String json) => switch (json) {
    'signup' => EulaAcceptanceSource.signup,
    'forced_reaccept' => EulaAcceptanceSource.forcedReaccept,
    'preferences' => EulaAcceptanceSource.preferences,
    'backfill' => EulaAcceptanceSource.backfill,
    _ => EulaAcceptanceSource.signup,
  };
}

class EulaAcceptRequest {
  final String eulaVersion;
  final String? locale;

  const EulaAcceptRequest({required this.eulaVersion, this.locale});

  Map<String, dynamic> toJson() => {
    'eula_version': eulaVersion,
    if (locale != null) 'locale': locale,
  };
}

class EulaAcceptance {
  final String id;
  final String userId;
  final String eulaVersion;
  final DateTime acceptedAt;
  final String? locale;
  final EulaAcceptanceSource source;

  const EulaAcceptance({
    required this.id,
    required this.userId,
    required this.eulaVersion,
    required this.acceptedAt,
    required this.source,
    this.locale,
  });

  // TODO(PROD-2264): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  // Drop the `gstack:allow` markers once the helper lands.
  factory EulaAcceptance.fromJson(Map<String, dynamic> json) {
    final id =
        json['id']
            as String; // gstack:allow check-error-handling json-cast-string
    final userId =
        json['user_id']
            as String; // gstack:allow check-error-handling json-cast-string
    final eulaVersion =
        json['eula_version']
            as String; // gstack:allow check-error-handling json-cast-string
    final acceptedAtRaw =
        json['accepted_at']
            as String; // gstack:allow check-error-handling json-cast-string
    final sourceRaw =
        json['source']
            as String; // gstack:allow check-error-handling json-cast-string
    return EulaAcceptance(
      id: id,
      userId: userId,
      eulaVersion: eulaVersion,
      acceptedAt: DateTime.parse(acceptedAtRaw),
      locale: json['locale'] as String?,
      source: EulaAcceptanceSource.fromJson(sourceRaw),
    );
  }
}

class EulaStatus {
  final String currentVersion;
  final String? acceptedVersion;
  final DateTime? acceptedAt;
  final bool needsAcceptance;

  const EulaStatus({
    required this.currentVersion,
    required this.needsAcceptance,
    this.acceptedVersion,
    this.acceptedAt,
  });

  // TODO(PROD-2264): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  factory EulaStatus.fromJson(Map<String, dynamic> json) {
    final currentVersion =
        json['current_version']
            as String; // gstack:allow check-error-handling json-cast-string
    final acceptedAtRaw = json['accepted_at'] as String?;
    return EulaStatus(
      currentVersion: currentVersion,
      acceptedVersion: json['accepted_version'] as String?,
      acceptedAt: acceptedAtRaw != null ? DateTime.parse(acceptedAtRaw) : null,
      needsAcceptance: json['needs_acceptance'] as bool,
    );
  }
}
