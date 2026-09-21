/// UGC moderation models (PROD-2264).
///
/// Mirrors the `Moderation` tag in `open-api/heyl-webapp-v1.openapi.yaml`:
/// `POST /reports`, `POST /blocks`, `GET /blocks`, `DELETE /blocks/{id}`.
library;

/// What is being reported. Backend enum
/// `[list, list_item, event, user, venue]`.
///
/// **The wire value for a place is `venue`, not `place`** — PROD-3254.
/// PROD-2264 shipped `place` here on the assumption the backend would
/// follow; it never did, so every report submitted from a venue detail
/// screen 422'd at enum parse, whatever reason the user picked. Note the
/// app's *other* vocabulary is unrelated: map pins and the daily drop use
/// `item_type: 'place' | 'event'`, and that stays `place`. Only moderation
/// says `venue`.
///
/// `venue` is legal on both report channels backend-side. This client only
/// speaks the content-safety channel (the default), which is what the
/// report sheet's reason picker offers; the availability channel (closed /
/// duplicate / wrong_place) is not wired up here.
enum ReportTargetType {
  list,
  listItem,
  event,
  user,
  venue;

  String toJson() => switch (this) {
    ReportTargetType.list => 'list',
    ReportTargetType.listItem => 'list_item',
    ReportTargetType.event => 'event',
    ReportTargetType.user => 'user',
    ReportTargetType.venue => 'venue',
  };

  static ReportTargetType fromJson(String json) => switch (json) {
    'list' => ReportTargetType.list,
    'list_item' => ReportTargetType.listItem,
    'event' => ReportTargetType.event,
    'user' => ReportTargetType.user,
    'venue' => ReportTargetType.venue,
    _ => ReportTargetType.user,
  };
}

/// User-facing report reasons. Backend additionally has the
/// `blocked_by_user` and `auto_escalation_block_count` reasons it writes
/// itself — those are not valid client input and intentionally absent
/// from this enum. `spam` and `repeated_content` are two distinct reasons,
/// stored separately. The legacy `misinformation` value was renamed to
/// `incorrect_information`, and `hate_speech`/`violence_threats` were
/// retired; the backend normalizes those legacy wire values server-side
/// (so old clients never 422), and [fromJson] maps any unknown/legacy
/// value to [other] so unexpected payloads degrade safely.
enum ReportReason {
  incorrectInformation,
  repeatedContent,
  spam,
  harassment,
  sexuallyExplicit,
  other;

  String toJson() => switch (this) {
    ReportReason.incorrectInformation => 'incorrect_information',
    ReportReason.repeatedContent => 'repeated_content',
    ReportReason.spam => 'spam',
    ReportReason.harassment => 'harassment',
    ReportReason.sexuallyExplicit => 'sexually_explicit',
    ReportReason.other => 'other',
  };

  static ReportReason fromJson(String json) => switch (json) {
    'incorrect_information' => ReportReason.incorrectInformation,
    'repeated_content' => ReportReason.repeatedContent,
    'spam' => ReportReason.spam,
    'harassment' => ReportReason.harassment,
    'sexually_explicit' => ReportReason.sexuallyExplicit,
    'other' => ReportReason.other,
    _ => ReportReason.other,
  };
}

enum ReportStatus {
  pending,
  actioned,
  dismissed;

  static ReportStatus fromJson(String json) => switch (json) {
    'pending' => ReportStatus.pending,
    'actioned' => ReportStatus.actioned,
    'dismissed' => ReportStatus.dismissed,
    _ => ReportStatus.pending,
  };
}

class ReportCreateRequest {
  final ReportTargetType targetType;
  final String targetId;
  final ReportReason reason;
  final String? details;

  const ReportCreateRequest({
    required this.targetType,
    required this.targetId,
    required this.reason,
    this.details,
  });

  Map<String, dynamic> toJson() => {
    'target_type': targetType.toJson(),
    'target_id': targetId,
    'reason': reason.toJson(),
    if (details != null && details!.isNotEmpty) 'details': details,
  };
}

class ReportCreated {
  final String reportId;
  final ReportStatus status;
  final DateTime createdAt;
  final bool idempotentHit;

  const ReportCreated({
    required this.reportId,
    required this.status,
    required this.createdAt,
    required this.idempotentHit,
  });

  // TODO(PROD-2264): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  factory ReportCreated.fromJson(Map<String, dynamic> json) {
    final reportId =
        json['report_id']
            as String; // gstack:allow check-error-handling json-cast-string
    final statusRaw =
        json['status']
            as String; // gstack:allow check-error-handling json-cast-string
    final createdAtRaw =
        json['created_at']
            as String; // gstack:allow check-error-handling json-cast-string
    return ReportCreated(
      reportId: reportId,
      status: ReportStatus.fromJson(statusRaw),
      createdAt: DateTime.parse(createdAtRaw),
      idempotentHit: json['idempotent_hit'] as bool,
    );
  }
}

class BlockCreateRequest {
  final String blockedUserId;
  final ReportTargetType? contextTargetType;
  final String? contextTargetId;
  final ReportReason? reason;

  const BlockCreateRequest({
    required this.blockedUserId,
    this.contextTargetType,
    this.contextTargetId,
    this.reason,
  });

  Map<String, dynamic> toJson() => {
    'blocked_user_id': blockedUserId,
    if (contextTargetType != null)
      'context_target_type': contextTargetType!.toJson(),
    if (contextTargetId != null) 'context_target_id': contextTargetId,
    if (reason != null) 'reason': reason!.toJson(),
  };
}

class BlockCreated {
  final String blockId;
  final String reportId;
  final String blockedUserId;
  final DateTime createdAt;

  const BlockCreated({
    required this.blockId,
    required this.reportId,
    required this.blockedUserId,
    required this.createdAt,
  });

  // TODO(PROD-2264): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  factory BlockCreated.fromJson(Map<String, dynamic> json) {
    final blockId =
        json['block_id']
            as String; // gstack:allow check-error-handling json-cast-string
    final reportId =
        json['report_id']
            as String; // gstack:allow check-error-handling json-cast-string
    final blockedUserId =
        json['blocked_user_id']
            as String; // gstack:allow check-error-handling json-cast-string
    final createdAtRaw =
        json['created_at']
            as String; // gstack:allow check-error-handling json-cast-string
    return BlockCreated(
      blockId: blockId,
      reportId: reportId,
      blockedUserId: blockedUserId,
      createdAt: DateTime.parse(createdAtRaw),
    );
  }
}

class BlockedUser {
  final String blockId;
  final String blockedUserId;
  final String? blockedUserDisplayName;
  final DateTime createdAt;

  const BlockedUser({
    required this.blockId,
    required this.blockedUserId,
    required this.createdAt,
    this.blockedUserDisplayName,
  });

  // TODO(PROD-2264): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  factory BlockedUser.fromJson(Map<String, dynamic> json) {
    final blockId =
        json['block_id']
            as String; // gstack:allow check-error-handling json-cast-string
    final blockedUserId =
        json['blocked_user_id']
            as String; // gstack:allow check-error-handling json-cast-string
    final createdAtRaw =
        json['created_at']
            as String; // gstack:allow check-error-handling json-cast-string
    return BlockedUser(
      blockId: blockId,
      blockedUserId: blockedUserId,
      blockedUserDisplayName: json['blocked_user_display_name'] as String?,
      createdAt: DateTime.parse(createdAtRaw),
    );
  }
}

/// 403 body returned when the caller is suspended or banned (PROD-2264).
/// Distinct from the 401 `AuthErrorResponse` family so the iOS client
/// doesn't treat these as token problems and loop on refresh.
enum ModerationErrorCode {
  userSuspended,
  userBanned;

  static ModerationErrorCode? fromJson(String? json) => switch (json) {
    'USER_SUSPENDED' => ModerationErrorCode.userSuspended,
    'USER_BANNED' => ModerationErrorCode.userBanned,
    _ => null,
  };
}

class ModerationError implements Exception {
  final String error;
  final ModerationErrorCode code;
  final String message;
  final int? retryAfter;

  const ModerationError({
    required this.error,
    required this.code,
    required this.message,
    this.retryAfter,
  });

  static ModerationError? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final code = ModerationErrorCode.fromJson(json['error_code'] as String?);
    if (code == null) return null;
    return ModerationError(
      error: (json['error'] as String?) ?? 'user_suspended',
      code: code,
      message: (json['message'] as String?) ?? '',
      retryAfter: json['retry_after'] as int?,
    );
  }

  @override
  String toString() => 'ModerationError(${code.name}: $message)';
}
