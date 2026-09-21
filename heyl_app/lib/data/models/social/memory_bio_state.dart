/// The owner's memory-bio ownership state (accepted / pending / hidden),
/// returned by the accept + hide endpoints (backend Phase 4/5).
class MemoryBioState {
  /// The current public bio text (null when none is accepted).
  final String? memoryBio;

  /// A freshly-regenerated bio awaiting the owner's acceptance
  /// (propose-not-overwrite). Null when there is nothing to accept.
  final String? memoryBioPending;

  /// Whether the owner has hidden their memory bio from the public profile.
  final bool memoryBioHidden;

  const MemoryBioState({
    this.memoryBio,
    this.memoryBioPending,
    this.memoryBioHidden = false,
  });

  factory MemoryBioState.fromJson(Map<String, dynamic> json) {
    return MemoryBioState(
      memoryBio: json['memory_bio'] as String?,
      memoryBioPending: json['memory_bio_pending'] as String?,
      memoryBioHidden: json['memory_bio_hidden'] as bool? ?? false,
    );
  }
}
