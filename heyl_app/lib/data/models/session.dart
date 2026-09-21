import 'location_snapshot.dart';

/// Channel enum for session source
enum SessionChannel {
  web,
  webapp, // Backend uses 'webapp' for web app sessions
  mobile,
  whatsapp,
  voice;

  String toJson() => name;

  static SessionChannel fromJson(String json) {
    // Handle 'webapp' as an alias for 'web' if needed
    if (json == 'webapp') return SessionChannel.webapp;
    return SessionChannel.values.firstWhere(
      (e) => e.name == json,
      orElse: () => SessionChannel.web,
    );
  }
}

/// The conversation's persisted search center (C), read projection of the
/// backend `SessionSearchCenter` (PROD-3129). Deliberately NOT a
/// [LocationSnapshot]: once the resolver moves the center to a named place its
/// source is not a device source. Exposes just what the webapp needs to
/// restore a reopened conversation's map/scope (coordinates) and label it.
class SessionSearchCenter {
  final double latitude;
  final double longitude;

  /// City name when the backend knows it; null otherwise.
  final String? label;

  const SessionSearchCenter({
    required this.latitude,
    required this.longitude,
    this.label,
  });

  factory SessionSearchCenter.fromJson(Map<String, dynamic> json) {
    return SessionSearchCenter(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      label: json['label'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    if (label != null) 'label': label,
  };
}

/// Session model matching actual backend response
class Session {
  final String sessionId;
  final String? sessionUuid;
  final String? userId;
  final DateTime? createdAt;
  final DateTime? lastMessageAt;
  final SessionChannel channel;
  final String? title;
  final int? totalMessages;
  final int? totalRuns;
  final String? firstMessagePreview;

  /// True for archived WhatsApp sessions (not the most recent)
  final bool isReadOnly;

  /// False for all WhatsApp sessions (users must continue on WhatsApp)
  final bool canSendMessages;

  /// wa.me deep link for the most recent WhatsApp session only
  final String? whatsappContinueUrl;

  /// The conversation's persisted chat search center (C), when the backend
  /// has one (PROD-3129). Used to restore/display a reopened conversation's
  /// scope without re-seeding from the current picker.
  final SessionSearchCenter? searchCenter;

  const Session({
    required this.sessionId,
    this.sessionUuid,
    this.userId,
    this.createdAt,
    this.lastMessageAt,
    required this.channel,
    this.title,
    this.totalMessages,
    this.totalRuns,
    this.firstMessagePreview,
    this.isReadOnly = false,
    this.canSendMessages = true,
    this.whatsappContinueUrl,
    this.searchCenter,
  });

  /// Whether this is a WhatsApp session
  bool get isWhatsApp => channel == SessionChannel.whatsapp;

  /// Display title - returns title or formatted date
  String get displayTitle {
    if (title != null && title!.isNotEmpty) {
      return title!;
    }
    return formattedDate;
  }

  /// Formatted date for display (Today, Yesterday, Dec 23, etc.)
  String get formattedDate {
    final date = createdAt ?? lastMessageAt ?? DateTime.now();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final sessionDate = DateTime(date.year, date.month, date.day);

    if (sessionDate == today) {
      return 'Today';
    } else if (sessionDate == yesterday) {
      return 'Yesterday';
    } else if (date.year == now.year) {
      // Same year: "Dec 23"
      return '${_monthName(date.month)} ${date.day}';
    } else {
      // Different year: "Dec 23, 2024"
      return '${_monthName(date.month)} ${date.day}, ${date.year}';
    }
  }

  static String _monthName(int month) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[month - 1];
  }

  /// Preview text (can be set from last message)
  String get preview => firstMessagePreview ?? 'No messages yet';

  factory Session.fromJson(Map<String, dynamic> json) {
    // Handle date parsing with fallbacks
    DateTime? createdAt;
    if (json['created_at'] != null) {
      createdAt = DateTime.parse(json['created_at'] as String);
    } else if (json['first_message_at'] != null) {
      createdAt = DateTime.parse(json['first_message_at'] as String);
    }

    DateTime? lastMessageAt;
    if (json['last_message_at'] != null) {
      lastMessageAt = DateTime.parse(json['last_message_at'] as String);
    }

    return Session(
      sessionId: json['session_id'] as String,
      sessionUuid: json['session_uuid'] as String?,
      userId: json['user_id'] as String?,
      createdAt: createdAt,
      lastMessageAt: lastMessageAt,
      channel: SessionChannel.fromJson(json['channel'] as String? ?? 'web'),
      title: json['title'] as String?,
      totalMessages: json['total_messages'] as int?,
      totalRuns: json['total_runs'] as int?,
      firstMessagePreview: json['first_message_preview'] as String?,
      isReadOnly: json['is_read_only'] as bool? ?? false,
      canSendMessages: json['can_send_messages'] as bool? ?? true,
      whatsappContinueUrl: json['whatsapp_continue_url'] as String?,
      searchCenter: json['search_center'] is Map<String, dynamic>
          ? SessionSearchCenter.fromJson(
              json['search_center'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'session_id': sessionId,
      if (sessionUuid != null) 'session_uuid': sessionUuid,
      if (userId != null) 'user_id': userId,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      if (lastMessageAt != null)
        'last_message_at': lastMessageAt!.toIso8601String(),
      'channel': channel.toJson(),
      if (title != null) 'title': title,
      if (totalMessages != null) 'total_messages': totalMessages,
      if (totalRuns != null) 'total_runs': totalRuns,
      if (firstMessagePreview != null)
        'first_message_preview': firstMessagePreview,
      'is_read_only': isReadOnly,
      'can_send_messages': canSendMessages,
      if (whatsappContinueUrl != null)
        'whatsapp_continue_url': whatsappContinueUrl,
      if (searchCenter != null) 'search_center': searchCenter!.toJson(),
    };
  }

  Session copyWith({
    String? sessionId,
    String? sessionUuid,
    String? userId,
    DateTime? createdAt,
    DateTime? lastMessageAt,
    SessionChannel? channel,
    String? title,
    int? totalMessages,
    int? totalRuns,
    String? firstMessagePreview,
    bool? isReadOnly,
    bool? canSendMessages,
    String? whatsappContinueUrl,
    SessionSearchCenter? searchCenter,
  }) {
    return Session(
      sessionId: sessionId ?? this.sessionId,
      sessionUuid: sessionUuid ?? this.sessionUuid,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      channel: channel ?? this.channel,
      title: title ?? this.title,
      totalMessages: totalMessages ?? this.totalMessages,
      totalRuns: totalRuns ?? this.totalRuns,
      firstMessagePreview: firstMessagePreview ?? this.firstMessagePreview,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      canSendMessages: canSendMessages ?? this.canSendMessages,
      whatsappContinueUrl: whatsappContinueUrl ?? this.whatsappContinueUrl,
      searchCenter: searchCenter ?? this.searchCenter,
    );
  }
}

/// Request model for creating a session
/// Note: Channel is always 'webapp' for the Flutter app, so it's not included
class SessionCreateRequest {
  final String? title;
  final String? visitorId;

  /// Seeds the session's chat search center (C) at creation from the shared
  /// `ResolvedSearchLocation`. Null when there is no usable signal — the
  /// backend then applies its own default.
  final LocationSnapshot? initialLocation;

  const SessionCreateRequest({
    this.title,
    this.visitorId,
    this.initialLocation,
  });

  Map<String, dynamic> toJson() {
    return {
      if (title != null) 'title': title,
      if (visitorId != null) 'visitor_id': visitorId,
      if (initialLocation != null)
        'initial_location': initialLocation!.toJson(),
    };
  }
}

/// Response model for paginated sessions list
class SessionsListResponse {
  final List<Session> items;
  final int total;
  final String? cursor;
  final bool hasMore;

  const SessionsListResponse({
    required this.items,
    required this.total,
    this.cursor,
    required this.hasMore,
  });

  factory SessionsListResponse.fromJson(Map<String, dynamic> json) {
    final items =
        (json['items'] as List<dynamic>?)
            ?.map((e) => Session.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return SessionsListResponse(
      items: items,
      total: json['total'] as int? ?? items.length,
      cursor: json['cursor'] as String?,
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}
