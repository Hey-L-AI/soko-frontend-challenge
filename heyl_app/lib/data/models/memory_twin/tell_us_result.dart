/// Outcome of a "conta-nos sobre ti" self-description submission
/// (`POST /api/v1/app/users/me/memory/tell-us`, backend Phase 5).
class TellUsResult {
  /// `applied` (facts written), `disabled` (feature flag off), `empty_input`,
  /// `no_facts` (nothing durable found), or `no_client` / `error` (a soft
  /// upstream failure — treated as a no-op, never surfaced as an error).
  final String status;

  /// How many memory facts were written this submission.
  final int factsWritten;

  /// The contents of the facts written (for an optional confirmation preview).
  final List<String> facts;

  const TellUsResult({
    required this.status,
    this.factsWritten = 0,
    this.facts = const [],
  });

  /// Whether facts were actually written (the profile/memory should refresh).
  bool get applied => status == 'applied' && factsWritten > 0;

  factory TellUsResult.fromJson(Map<String, dynamic> json) {
    return TellUsResult(
      status: json['status'] as String? ?? 'error',
      factsWritten: json['facts_written'] as int? ?? 0,
      facts:
          (json['facts'] as List<dynamic>?)?.map((e) => e as String).toList() ??
          const [],
    );
  }
}
