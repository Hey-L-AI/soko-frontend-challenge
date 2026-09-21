import 'family_view.dart';
import 'memory_fact_view.dart';

class MemoryTwinResponse {
  final String userProfileId;
  final int schemaVersion;
  final int policyVersion;
  final int projectorVersion;
  final String taxonomyVersion;
  final List<String> personaTags;
  final List<FamilyView> families;

  /// Every action-sourced fact (saved venue/event, followed list, created
  /// list), independent of whether it materialized into a family dimension.
  /// "Your collection" and the narrative read this so label-less zines still
  /// appear. Carries entity image_url / subtitle enrichment.
  final List<MemoryFactView> actionFacts;
  final DateTime generatedAt;

  const MemoryTwinResponse({
    required this.userProfileId,
    required this.schemaVersion,
    required this.policyVersion,
    required this.projectorVersion,
    required this.taxonomyVersion,
    required this.personaTags,
    required this.families,
    required this.actionFacts,
    required this.generatedAt,
  });

  bool get isEmpty => families.isEmpty && actionFacts.isEmpty;

  // TODO: required-string casts retained pending the Phase 3 `requireString`
  // helper (see docs/platform/error-handling-discipline.md). Drop the
  // `gstack:allow` markers once it lands.
  factory MemoryTwinResponse.fromJson(Map<String, dynamic> json) {
    final userProfileId =
        json['user_profile_id']
            as String; // gstack:allow check-error-handling json-cast-string
    final taxonomyVersion =
        json['taxonomy_version']
            as String; // gstack:allow check-error-handling json-cast-string
    final generatedAtRaw =
        json['generated_at']
            as String; // gstack:allow check-error-handling json-cast-string
    return MemoryTwinResponse(
      userProfileId: userProfileId,
      schemaVersion: json['schema_version'] as int,
      policyVersion: json['policy_version'] as int,
      projectorVersion: json['projector_version'] as int,
      taxonomyVersion: taxonomyVersion,
      personaTags: (json['persona_tags'] as List? ?? const [])
          .map((t) => t as String)
          .toList(growable: false),
      families: (json['families'] as List? ?? const [])
          .map((f) => FamilyView.fromJson(f as Map<String, dynamic>))
          .toList(growable: false),
      actionFacts: (json['action_facts'] as List? ?? const [])
          .map((f) => MemoryFactView.fromJson(f as Map<String, dynamic>))
          .toList(growable: false),
      generatedAt: DateTime.parse(generatedAtRaw),
    );
  }
}
