import 'memory_fact_view.dart';

class ObservationView {
  final String id;
  final String value;
  final double certainty;
  final String polarity;
  final String strength;
  final String
  sourceClass; // 'explicit_fact' | 'positive_event' | 'persona_prior'
  final List<String> uses;
  final DateTime? observedAt;
  final String? sourceFactId;
  final String? sourceSessionId;
  final String? factSource;
  final String? evidenceText;

  /// Where this memory came from, as classified by the backend (PROD-2331):
  /// `message` | `onboarding` | `location` | `action` | `inferred`. Drives how
  /// the provenance card renders — only `message` is shown as a literal quote.
  /// Null for legacy payloads predating the field; callers must fall back to
  /// the old (`evidence_text` / `isUserStated`) behavior when it's null.
  final String? provenanceKind;
  // The full set of provenance kinds for this chip's value — populated when
  // observations of the same value are deduped (a chip can come from onboarding
  // AND a save AND activity). Null on a fresh observation; callers use
  // [allProvenanceKinds] which falls back to the single [provenanceKind].
  final Set<String>? provenanceKinds;
  final bool canDelete;
  final List<MemoryFactView> backingFacts;

  /// PROD-2799 #1b: the venue-type category group (e.g. "Sports & Fitness",
  /// "Culture & Arts") sent by the backend for venue_type chips, so the Memory
  /// page routes each venue_type to the right parent section instead of putting
  /// them all under Tastes. Null for non-venue_type values and legacy payloads.
  final String? group;
  // PROD-3766: display tier from the backend — 'primary' renders by default,
  // 'secondary' (1 tick) folds behind "show more". Missing = primary.
  final String tier;
  bool get isSecondary => tier == 'secondary';

  bool get isUserMessage => provenanceKind == 'message';

  /// All sources behind this chip, deduped. Falls back to the single
  /// [provenanceKind] when the merged set wasn't supplied.
  Set<String> get allProvenanceKinds =>
      provenanceKinds ??
      (provenanceKind != null ? {provenanceKind!} : <String>{});

  const ObservationView({
    required this.id,
    required this.value,
    required this.certainty,
    required this.polarity,
    required this.strength,
    required this.sourceClass,
    required this.uses,
    required this.canDelete,
    required this.backingFacts,
    this.provenanceKind,
    this.provenanceKinds,
    this.observedAt,
    this.sourceFactId,
    this.sourceSessionId,
    this.factSource,
    this.evidenceText,
    this.group,
    this.tier = 'primary',
  });

  bool get isUserStated =>
      sourceClass == 'explicit_fact' || backingFacts.any((f) => f.isUserStated);

  bool get isPersonaPrior => sourceClass == 'persona_prior';

  // TODO: required-string casts retained pending the Phase 3 `requireString`
  // helper (see docs/platform/error-handling-discipline.md). Drop the
  // `gstack:allow` markers once it lands.
  factory ObservationView.fromJson(Map<String, dynamic> json) {
    final id =
        json['id']
            as String; // gstack:allow check-error-handling json-cast-string
    final value =
        json['value']
            as String; // gstack:allow check-error-handling json-cast-string
    final polarity =
        json['polarity']
            as String; // gstack:allow check-error-handling json-cast-string
    final strength =
        json['strength']
            as String; // gstack:allow check-error-handling json-cast-string
    final sourceClass =
        json['source_class']
            as String; // gstack:allow check-error-handling json-cast-string
    final observedAtRaw = json['observed_at'] as String?;
    return ObservationView(
      id: id,
      value: value,
      certainty: (json['certainty'] as num).toDouble(),
      polarity: polarity,
      strength: strength,
      sourceClass: sourceClass,
      uses: (json['uses'] as List? ?? const [])
          .map((u) => u as String)
          .toList(growable: false),
      observedAt: observedAtRaw == null ? null : DateTime.parse(observedAtRaw),
      sourceFactId: json['source_fact_id'] as String?,
      sourceSessionId: json['source_session_id'] as String?,
      factSource: json['fact_source'] as String?,
      evidenceText: json['evidence_text'] as String?,
      provenanceKind: json['provenance_kind'] as String?,
      group: json['group'] as String?,
      tier: (json['tier'] as String?) ?? 'primary',
      canDelete: json['can_delete'] as bool,
      backingFacts: (json['backing_facts'] as List? ?? const [])
          .map((f) => MemoryFactView.fromJson(f as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}
