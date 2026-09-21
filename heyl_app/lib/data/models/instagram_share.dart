import '../../core/ingest/ingest_job.dart';

/// Response from `POST /api/v1/app/instagram/share`.
///
/// Discriminated by [type]:
///   - `post` → [sharedPostId] populated
///   - `profile` → [subscriptionId] and [username] populated
class ShareSubmitResponse {
  final String type;
  final String status;
  final String? sharedPostId;
  final String? subscriptionId;
  final String? username;

  const ShareSubmitResponse({
    required this.type,
    required this.status,
    this.sharedPostId,
    this.subscriptionId,
    this.username,
  });

  factory ShareSubmitResponse.fromJson(Map<String, dynamic> json) {
    return ShareSubmitResponse(
      type: json['type'] as String,
      status: json['status'] as String,
      sharedPostId: json['shared_post_id'] as String?,
      subscriptionId: json['subscription_id'] as String?,
      username: json['username'] as String?,
    );
  }

  bool get isPost => type == 'post';
  bool get isProfile => type == 'profile';
}

/// An item from `GET /api/v1/app/instagram/shares`.
///
/// Status lifecycle: pending → processing → completed | pending_review |
/// irrelevant | past_event | failed.
class SharedPostOut implements IngestJob {
  final String id;
  final String userId;
  final String sourceChannel;
  final String postUrl;
  final String? postShortcode;
  final String status;
  final String? classification;
  final double? classificationConfidence;
  final String? eventId;
  final List<String> eventIds;
  final String? venueId;
  final String? listItemId;
  final String? errorMessage;
  final DateTime createdAt;

  const SharedPostOut({
    required this.id,
    required this.userId,
    required this.sourceChannel,
    required this.postUrl,
    this.postShortcode,
    required this.status,
    this.classification,
    this.classificationConfidence,
    this.eventId,
    this.eventIds = const [],
    this.venueId,
    this.listItemId,
    this.errorMessage,
    required this.createdAt,
  });

  factory SharedPostOut.fromJson(Map<String, dynamic> json) {
    return SharedPostOut(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      sourceChannel: json['source_channel'] as String,
      postUrl: json['post_url'] as String,
      postShortcode: json['post_shortcode'] as String?,
      status: json['status'] as String,
      classification: json['classification'] as String?,
      classificationConfidence: (json['classification_confidence'] as num?)
          ?.toDouble(),
      eventId: json['event_id'] as String?,
      eventIds: (json['event_ids'] as List?)?.cast<String>() ?? const [],
      venueId: json['venue_id'] as String?,
      listItemId: json['list_item_id'] as String?,
      errorMessage: json['error_message'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  @override
  String get jobId => id;

  @override
  bool get isPending => status == 'pending';
  @override
  bool get isProcessing => status == 'processing';
  bool get isCompleted => status == 'completed';
  @override
  bool get isFailed => isTerminal && !producedEntities;
  @override
  bool get isTerminal =>
      status == 'completed' ||
      status == 'pending_review' ||
      status == 'irrelevant' ||
      status == 'past_event' ||
      status == 'failed';

  /// Whether this share produced any entities the user should see in their
  /// list. True for `completed` (venue resolved + items added) AND for
  /// `pending_review` shares with non-empty `event_ids` (post-PROD-1728:
  /// events were created and added to "From Instagram" with
  /// `is_public=False, curation_status='pending_review'` — venue couldn't
  /// be resolved but the items still exist and must surface in the list).
  /// Empty `pending_review` (low-confidence extraction or garbage) and the
  /// other terminal failures (`irrelevant`, `past_event`, `failed`) all
  /// return false.
  @override
  bool get producedEntities =>
      isCompleted || (status == 'pending_review' && eventIds.isNotEmpty);
}
