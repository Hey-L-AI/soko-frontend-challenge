/// Status contract for a long-running async ingest job.
///
/// Implemented by feature-specific DTOs (e.g. `SharedPostOut` for Instagram
/// share, `EventContributionOut` for photo→event contributions) so the
/// shared [IngestPollingController] can drive any of them. Pure status
/// surface — feature data lives on the concrete subclass.
abstract class IngestJob {
  /// Stable identifier the controller polls against.
  String get jobId;

  /// Job is queued, not yet processed.
  bool get isPending;

  /// Job is actively being processed.
  bool get isProcessing;

  /// Job reached any terminal state (success or failure).
  bool get isTerminal;

  /// Terminal AND produced at least one entity the user should see in their
  /// list / event detail. Distinct from [isTerminal] so terminal-but-empty
  /// states (extracted-with-no-events, irrelevant, past_event) can be handled
  /// as soft failures.
  bool get producedEntities;

  /// Terminal AND did not produce entities.
  bool get isFailed;
}
