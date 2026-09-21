import '../../core/ingest/ingest_job.dart';

/// Failure bucket reported by the backend when `status == 'failed'`.
/// Mirrors the OpenAPI enum (PROD-2147); unknown values from forward-
/// compatible backends bucket into [unhandled].
enum EventContributionFailureCategory {
  moderationBlocked,
  classificationError,
  extractionError,
  persistenceError,
  unhandled;

  static EventContributionFailureCategory? fromJson(String? raw) {
    if (raw == null) return null;
    switch (raw) {
      case 'moderation_blocked':
        return moderationBlocked;
      case 'classification_error':
        return classificationError;
      case 'extraction_error':
        return extractionError;
      case 'persistence_error':
        return persistenceError;
      case 'unhandled':
        return unhandled;
      default:
        return unhandled;
    }
  }
}

/// One user event-contribution row.
///
/// Returned by `POST /api/v1/app/contributions/events` (with
/// `status='pending'`), `GET /api/v1/app/contributions/events/{id}`,
/// and inside the list items array of `GET /api/v1/app/contributions/events`.
///
/// Status lifecycle: `pending → processing → extracted | failed`.
/// `extracted` with empty [eventIds] is a legacy state and is reported as
/// [isFailed] for UI purposes (per the ticket spec: "extracted with empty
/// event_ids → only possible on legacy rows; treat the same as failure").
class EventContributionOut implements IngestJob {
  final String id;
  final String status;
  final String imageUrl;
  final String? classification;
  final List<String> eventIds;
  final List<String> listItemIds;
  final String? errorMessage;
  final EventContributionFailureCategory? failureCategory;
  final String? note;
  final String? city;
  final String? venueId;
  final DateTime createdAt;
  final DateTime? processedAt;

  const EventContributionOut({
    required this.id,
    required this.status,
    required this.imageUrl,
    this.classification,
    this.eventIds = const [],
    this.listItemIds = const [],
    this.errorMessage,
    this.failureCategory,
    this.note,
    this.city,
    this.venueId,
    required this.createdAt,
    this.processedAt,
  });

  // TODO(PROD-2264): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  factory EventContributionOut.fromJson(Map<String, dynamic> json) {
    final id =
        json['id']
            as String; // gstack:allow check-error-handling json-cast-string
    final status =
        json['status']
            as String; // gstack:allow check-error-handling json-cast-string
    final imageUrl =
        json['image_url']
            as String; // gstack:allow check-error-handling json-cast-string
    final createdAtRaw =
        json['created_at']
            as String; // gstack:allow check-error-handling json-cast-string
    final processedAtRaw = json['processed_at'] as String?;
    return EventContributionOut(
      id: id,
      status: status,
      imageUrl: imageUrl,
      classification: json['classification'] as String?,
      eventIds: (json['event_ids'] as List?)?.cast<String>() ?? const [],
      listItemIds: (json['list_item_ids'] as List?)?.cast<String>() ?? const [],
      errorMessage: json['error_message'] as String?,
      failureCategory: EventContributionFailureCategory.fromJson(
        json['failure_category'] as String?,
      ),
      note: json['note'] as String?,
      city: json['city'] as String?,
      venueId: json['venue_id'] as String?,
      createdAt: DateTime.parse(createdAtRaw),
      processedAt: processedAtRaw != null
          ? DateTime.parse(processedAtRaw)
          : null,
    );
  }

  @override
  String get jobId => id;

  @override
  bool get isPending => status == 'pending';

  @override
  bool get isProcessing => status == 'processing';

  bool get isExtracted => status == 'extracted';

  @override
  bool get isTerminal => status == 'extracted' || status == 'failed';

  /// True when the row reached `extracted` AND produced at least one event.
  /// Empty extractions (legacy rows only — current backend marks them
  /// `failed/extraction_error` instead) report `false`.
  @override
  bool get producedEntities => isExtracted && eventIds.isNotEmpty;

  /// True for any terminal-but-not-produced row: literal `failed` AND
  /// `extracted-with-empty-event_ids` (legacy).
  @override
  bool get isFailed => isTerminal && !producedEntities;
}

/// Cursor-paginated wrapper for `GET /api/v1/app/contributions/events`.
class PaginatedEventContributionOut {
  final List<EventContributionOut> items;

  /// ISO-8601 `created_at` of the oldest row in [items] when the page is
  /// full. `null` indicates this is the tail. Pass back as the `cursor`
  /// query param.
  final String? nextCursor;

  const PaginatedEventContributionOut({required this.items, this.nextCursor});

  factory PaginatedEventContributionOut.fromJson(Map<String, dynamic> json) {
    return PaginatedEventContributionOut(
      items: ((json['items'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(EventContributionOut.fromJson)
          .toList(),
      nextCursor: json['next_cursor'] as String?,
    );
  }
}
