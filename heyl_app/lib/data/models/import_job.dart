// Models for Google Maps list import job

/// Status of an import job
enum ImportJobStatus {
  queued,
  processing,
  completed,
  failed;

  static ImportJobStatus fromJson(String value) {
    return ImportJobStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ImportJobStatus.failed,
    );
  }

  String toJson() => name;
}

/// Progress phase of an import job
enum ImportPhase {
  scraping,
  enriching,
  creatingVenues,
  creatingList,
  done;

  static ImportPhase fromJson(String value) {
    switch (value) {
      case 'scraping':
        return ImportPhase.scraping;
      case 'enriching':
        return ImportPhase.enriching;
      case 'creating_venues':
        return ImportPhase.creatingVenues;
      case 'creating_list':
        return ImportPhase.creatingList;
      case 'done':
        return ImportPhase.done;
      default:
        return ImportPhase.scraping;
    }
  }

  String toJson() {
    switch (this) {
      case ImportPhase.scraping:
        return 'scraping';
      case ImportPhase.enriching:
        return 'enriching';
      case ImportPhase.creatingVenues:
        return 'creating_venues';
      case ImportPhase.creatingList:
        return 'creating_list';
      case ImportPhase.done:
        return 'done';
    }
  }

  /// Approximate progress fraction (0.0 to 1.0) for this phase
  double get baseFraction {
    switch (this) {
      case ImportPhase.scraping:
        return 0.0;
      case ImportPhase.enriching:
        return 0.25;
      case ImportPhase.creatingVenues:
        return 0.6;
      case ImportPhase.creatingList:
        return 0.85;
      case ImportPhase.done:
        return 1.0;
    }
  }

  /// The next phase's base fraction (for interpolation)
  double get nextBaseFraction {
    switch (this) {
      case ImportPhase.scraping:
        return 0.25;
      case ImportPhase.enriching:
        return 0.6;
      case ImportPhase.creatingVenues:
        return 0.85;
      case ImportPhase.creatingList:
        return 1.0;
      case ImportPhase.done:
        return 1.0;
    }
  }
}

/// Response when an import job is created (202 Accepted)
class ImportJobCreatedResponse {
  final String jobId;
  final String status;
  final String message;

  const ImportJobCreatedResponse({
    required this.jobId,
    required this.status,
    required this.message,
  });

  factory ImportJobCreatedResponse.fromJson(Map<String, dynamic> json) {
    return ImportJobCreatedResponse(
      jobId: json['job_id'] as String,
      status: json['status'] as String,
      message: json['message'] as String,
    );
  }
}

/// Progress information for an in-progress import
class ImportProgress {
  final ImportPhase phase;
  final String? message;
  final int? current;
  final int? total;

  const ImportProgress({
    required this.phase,
    this.message,
    this.current,
    this.total,
  });

  factory ImportProgress.fromJson(Map<String, dynamic> json) {
    return ImportProgress(
      phase: ImportPhase.fromJson(json['phase'] as String),
      message: json['message'] as String?,
      current: json['current'] as int?,
      total: json['total'] as int?,
    );
  }

  /// Calculate overall progress fraction (0.0 to 1.0)
  double get fraction {
    final base = phase.baseFraction;
    final next = phase.nextBaseFraction;
    final range = next - base;

    if (current != null && total != null && total! > 0) {
      return base + (range * current! / total!);
    }
    return base;
  }
}

/// A place that failed to import
class ImportFailedPlace {
  final String name;
  final String reason;

  const ImportFailedPlace({
    required this.name,
    required this.reason,
  });

  factory ImportFailedPlace.fromJson(Map<String, dynamic> json) {
    return ImportFailedPlace(
      name: json['name'] as String,
      reason: json['reason'] as String,
    );
  }
}

/// Result of a completed import job
class ImportJobResult {
  final bool success;
  final String? listId;
  final String? listName;
  final int total;
  final int imported;
  final int duplicatesSkipped;
  final int failed;

  /// Number of imported places that carried a user note from the source
  /// Maps list (e.g. _"best gelato in town"_). Added in BE PROD-1933 and
  /// piped into `UserListItem.tip` during import — surfaces via the
  /// existing tip-render UI and is used by the success notification
  /// copy to read _"N imported — K with your notes"_.
  final int withNotesCount;

  final List<ImportFailedPlace> failedPlaces;

  const ImportJobResult({
    required this.success,
    this.listId,
    this.listName,
    required this.total,
    required this.imported,
    required this.duplicatesSkipped,
    required this.failed,
    this.withNotesCount = 0,
    this.failedPlaces = const [],
  });

  factory ImportJobResult.fromJson(Map<String, dynamic> json) {
    return ImportJobResult(
      success: json['success'] as bool,
      listId: json['list_id'] as String?,
      listName: json['list_name'] as String?,
      total: json['total'] as int,
      imported: json['imported'] as int,
      duplicatesSkipped: json['duplicates_skipped'] as int,
      failed: json['failed'] as int,
      withNotesCount: (json['with_notes_count'] as int?) ?? 0,
      failedPlaces: (json['failed_places'] as List<dynamic>?)
              ?.map((e) => ImportFailedPlace.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

/// Full status response from import job polling endpoint
class ImportJobStatusResponse {
  final String jobId;
  final ImportJobStatus status;
  final DateTime? updatedAt;
  final ImportProgress? progress;
  final ImportJobResult? result;
  final String? error;

  const ImportJobStatusResponse({
    required this.jobId,
    required this.status,
    this.updatedAt,
    this.progress,
    this.result,
    this.error,
  });

  factory ImportJobStatusResponse.fromJson(Map<String, dynamic> json) {
    return ImportJobStatusResponse(
      jobId: json['job_id'] as String,
      status: ImportJobStatus.fromJson(json['status'] as String),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      progress: json['progress'] != null
          ? ImportProgress.fromJson(json['progress'] as Map<String, dynamic>)
          : null,
      result: json['result'] != null
          ? ImportJobResult.fromJson(json['result'] as Map<String, dynamic>)
          : null,
      error: json['error'] as String?,
    );
  }

  bool get isQueued => status == ImportJobStatus.queued;
  bool get isProcessing => status == ImportJobStatus.processing;
  bool get isCompleted => status == ImportJobStatus.completed;
  bool get isFailed => status == ImportJobStatus.failed;
  bool get isTerminal => isCompleted || isFailed;
}
