/// Translation status for memory content
enum TranslationStatus {
  ready,
  refreshing,
  pending,
  notAvailable;

  factory TranslationStatus.fromString(String? value) {
    switch (value) {
      case 'refreshing':
        return TranslationStatus.refreshing;
      case 'pending':
        return TranslationStatus.pending;
      case 'not_available':
        return TranslationStatus.notAvailable;
      default:
        return TranslationStatus.ready;
    }
  }
}

/// Memory category for display grouping
enum MemoryCategory {
  location,
  preferences,
  feedback;

  String get displayName {
    switch (this) {
      case MemoryCategory.location:
        return 'Location';
      case MemoryCategory.preferences:
        return 'Preferences';
      case MemoryCategory.feedback:
        return 'Feedback';
    }
  }
}

/// User memory model matching OpenAPI UserMemoryOut schema
class UserMemory {
  final String? id;
  final String? userId; // Now a UUID (same as profile id)
  final String? displayIdentifier; // Phone or email for display
  final String? fullName;
  final String? memoryText;
  final List<String>? memoryKeyFacts;
  final int memoryConversationCount;
  final DateTime? memoryLastUpdated;
  final String? memoryConfidenceNotes;
  final String? memorySummary;
  final String? city;
  final DateTime? createdAt;
  final TranslationStatus translationStatus;

  // Classification fields
  final String? classificationName;
  final String? classificationHomeLocation;
  final String? classificationCurrentLocation;
  final String? classificationPrimaryLanguage;
  final String? classificationSecondaryLanguage;
  final List<String>? classificationInterestTags;
  final List<String>? classificationPersonaTags;
  final String? classificationCommunicationStyle;
  final String? classificationEngagementTier;
  final String? classificationChurnRisk;
  final String? classificationReEngagementNotes;
  final double? classificationConfidence;
  final String? classificationNotes;
  final DateTime? classificationLastUpdated;

  const UserMemory({
    this.id,
    this.userId,
    this.displayIdentifier,
    this.fullName,
    this.memoryText,
    this.memoryKeyFacts,
    this.memoryConversationCount = 0,
    this.memoryLastUpdated,
    this.memoryConfidenceNotes,
    this.memorySummary,
    this.city,
    this.createdAt,
    this.translationStatus = TranslationStatus.ready,
    this.classificationName,
    this.classificationHomeLocation,
    this.classificationCurrentLocation,
    this.classificationPrimaryLanguage,
    this.classificationSecondaryLanguage,
    this.classificationInterestTags,
    this.classificationPersonaTags,
    this.classificationCommunicationStyle,
    this.classificationEngagementTier,
    this.classificationChurnRisk,
    this.classificationReEngagementNotes,
    this.classificationConfidence,
    this.classificationNotes,
    this.classificationLastUpdated,
  });

  /// Get memory items for display (key facts only)
  List<MemoryItem> get memoryItems {
    final items = <MemoryItem>[];

    // Only show key facts - they're already well-formatted from the API
    if (memoryKeyFacts != null) {
      for (var i = 0; i < memoryKeyFacts!.length; i++) {
        items.add(MemoryItem(
          text: memoryKeyFacts![i],
          category: MemoryCategory.preferences,
          timestamp: memoryLastUpdated,
          index: i, // Track index for deletion
        ));
      }
    }

    return items;
  }

  factory UserMemory.fromJson(Map<String, dynamic> json) {
    return UserMemory(
      id: json['id'] as String?,
      userId: json['id'] as String?,
      displayIdentifier: json['display_identifier'] as String?,
      fullName: json['full_name'] as String?,
      memoryText: json['memory_text'] as String?,
      memoryKeyFacts: (json['memory_key_facts'] as List<dynamic>?)?.cast<String>(),
      memoryConversationCount: json['memory_conversation_count'] as int? ?? 0,
      memoryLastUpdated: json['memory_last_updated'] != null
          ? DateTime.parse(json['memory_last_updated'] as String)
          : null,
      memoryConfidenceNotes: json['memory_confidence_notes'] as String?,
      memorySummary: json['memory_summary'] as String?,
      city: json['city'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      translationStatus:
          TranslationStatus.fromString(json['translation_status'] as String?),
      classificationName: json['classification_name'] as String?,
      classificationHomeLocation: json['classification_home_location'] as String?,
      classificationCurrentLocation: json['classification_current_location'] as String?,
      classificationPrimaryLanguage: json['classification_primary_language'] as String?,
      classificationSecondaryLanguage: json['classification_secondary_language'] as String?,
      classificationInterestTags:
          (json['classification_interest_tags'] as List<dynamic>?)?.cast<String>(),
      classificationPersonaTags:
          (json['classification_persona_tags'] as List<dynamic>?)?.cast<String>(),
      classificationCommunicationStyle:
          json['classification_communication_style'] as String?,
      classificationEngagementTier: json['classification_engagement_tier'] as String?,
      classificationChurnRisk: json['classification_churn_risk'] as String?,
      classificationReEngagementNotes:
          json['classification_re_engagement_notes'] as String?,
      classificationConfidence:
          (json['classification_confidence'] as num?)?.toDouble(),
      classificationNotes: json['classification_notes'] as String?,
      classificationLastUpdated: json['classification_last_updated'] != null
          ? DateTime.parse(json['classification_last_updated'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      if (displayIdentifier != null) 'display_identifier': displayIdentifier,
      if (fullName != null) 'full_name': fullName,
      if (memoryText != null) 'memory_text': memoryText,
      if (memoryKeyFacts != null) 'memory_key_facts': memoryKeyFacts,
      'memory_conversation_count': memoryConversationCount,
      if (memoryLastUpdated != null)
        'memory_last_updated': memoryLastUpdated!.toIso8601String(),
      if (memoryConfidenceNotes != null)
        'memory_confidence_notes': memoryConfidenceNotes,
      if (memorySummary != null) 'memory_summary': memorySummary,
      if (city != null) 'city': city,
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      if (classificationName != null) 'classification_name': classificationName,
      if (classificationHomeLocation != null)
        'classification_home_location': classificationHomeLocation,
      if (classificationCurrentLocation != null)
        'classification_current_location': classificationCurrentLocation,
      if (classificationPrimaryLanguage != null)
        'classification_primary_language': classificationPrimaryLanguage,
      if (classificationSecondaryLanguage != null)
        'classification_secondary_language': classificationSecondaryLanguage,
      if (classificationInterestTags != null)
        'classification_interest_tags': classificationInterestTags,
      if (classificationPersonaTags != null)
        'classification_persona_tags': classificationPersonaTags,
      if (classificationCommunicationStyle != null)
        'classification_communication_style': classificationCommunicationStyle,
      if (classificationEngagementTier != null)
        'classification_engagement_tier': classificationEngagementTier,
      if (classificationChurnRisk != null)
        'classification_churn_risk': classificationChurnRisk,
      if (classificationReEngagementNotes != null)
        'classification_re_engagement_notes': classificationReEngagementNotes,
      if (classificationConfidence != null)
        'classification_confidence': classificationConfidence,
      if (classificationNotes != null) 'classification_notes': classificationNotes,
      if (classificationLastUpdated != null)
        'classification_last_updated': classificationLastUpdated!.toIso8601String(),
    };
  }

  UserMemory copyWith({
    String? id,
    String? userId,
    String? displayIdentifier,
    String? fullName,
    String? memoryText,
    List<String>? memoryKeyFacts,
    int? memoryConversationCount,
    DateTime? memoryLastUpdated,
    String? memoryConfidenceNotes,
    String? memorySummary,
    String? city,
    DateTime? createdAt,
    TranslationStatus? translationStatus,
    String? classificationName,
    String? classificationHomeLocation,
    String? classificationCurrentLocation,
    String? classificationPrimaryLanguage,
    String? classificationSecondaryLanguage,
    List<String>? classificationInterestTags,
    List<String>? classificationPersonaTags,
    String? classificationCommunicationStyle,
    String? classificationEngagementTier,
    String? classificationChurnRisk,
    String? classificationReEngagementNotes,
    double? classificationConfidence,
    String? classificationNotes,
    DateTime? classificationLastUpdated,
  }) {
    return UserMemory(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      displayIdentifier: displayIdentifier ?? this.displayIdentifier,
      fullName: fullName ?? this.fullName,
      memoryText: memoryText ?? this.memoryText,
      memoryKeyFacts: memoryKeyFacts ?? this.memoryKeyFacts,
      memoryConversationCount:
          memoryConversationCount ?? this.memoryConversationCount,
      memoryLastUpdated: memoryLastUpdated ?? this.memoryLastUpdated,
      memoryConfidenceNotes:
          memoryConfidenceNotes ?? this.memoryConfidenceNotes,
      memorySummary: memorySummary ?? this.memorySummary,
      city: city ?? this.city,
      createdAt: createdAt ?? this.createdAt,
      translationStatus: translationStatus ?? this.translationStatus,
      classificationName: classificationName ?? this.classificationName,
      classificationHomeLocation:
          classificationHomeLocation ?? this.classificationHomeLocation,
      classificationCurrentLocation:
          classificationCurrentLocation ?? this.classificationCurrentLocation,
      classificationPrimaryLanguage:
          classificationPrimaryLanguage ?? this.classificationPrimaryLanguage,
      classificationSecondaryLanguage: classificationSecondaryLanguage ??
          this.classificationSecondaryLanguage,
      classificationInterestTags:
          classificationInterestTags ?? this.classificationInterestTags,
      classificationPersonaTags:
          classificationPersonaTags ?? this.classificationPersonaTags,
      classificationCommunicationStyle: classificationCommunicationStyle ??
          this.classificationCommunicationStyle,
      classificationEngagementTier:
          classificationEngagementTier ?? this.classificationEngagementTier,
      classificationChurnRisk:
          classificationChurnRisk ?? this.classificationChurnRisk,
      classificationReEngagementNotes: classificationReEngagementNotes ??
          this.classificationReEngagementNotes,
      classificationConfidence:
          classificationConfidence ?? this.classificationConfidence,
      classificationNotes: classificationNotes ?? this.classificationNotes,
      classificationLastUpdated:
          classificationLastUpdated ?? this.classificationLastUpdated,
    );
  }
}

/// Individual memory item for UI display
class MemoryItem {
  final String text;
  final MemoryCategory category;
  final DateTime? timestamp;
  final int? index; // Index in the key facts list (for deletion)

  const MemoryItem({
    required this.text,
    required this.category,
    this.timestamp,
    this.index,
  });

  /// Relative time string (e.g., "2 weeks ago")
  String get relativeTime {
    if (timestamp == null) return '';

    final now = DateTime.now();
    final diff = now.difference(timestamp!);

    if (diff.inDays > 30) {
      final months = (diff.inDays / 30).floor();
      return '$months month${months > 1 ? 's' : ''} ago';
    } else if (diff.inDays > 7) {
      final weeks = (diff.inDays / 7).floor();
      return '$weeks week${weeks > 1 ? 's' : ''} ago';
    } else if (diff.inDays > 0) {
      return '${diff.inDays} day${diff.inDays > 1 ? 's' : ''} ago';
    } else if (diff.inHours > 0) {
      return '${diff.inHours} hour${diff.inHours > 1 ? 's' : ''} ago';
    } else {
      return 'Just now';
    }
  }
}

/// Memory item delete request
/// Backend expects: item_type ('fact', 'all_facts', 'text', 'all') and fact_index (0-based)
class MemoryItemDeleteRequest {
  final String itemType; // 'fact', 'all_facts', 'text', or 'all'
  final int? factIndex; // 0-based index when itemType='fact'

  const MemoryItemDeleteRequest({
    required this.itemType,
    this.factIndex,
  });

  /// Delete a specific key fact by index
  factory MemoryItemDeleteRequest.fact(int index) {
    return MemoryItemDeleteRequest(itemType: 'fact', factIndex: index);
  }

  /// Clear all key facts
  factory MemoryItemDeleteRequest.allFacts() {
    return const MemoryItemDeleteRequest(itemType: 'all_facts');
  }

  /// Clear memory text only
  factory MemoryItemDeleteRequest.memoryText() {
    return const MemoryItemDeleteRequest(itemType: 'text');
  }

  /// Clear all memory data
  factory MemoryItemDeleteRequest.all() {
    return const MemoryItemDeleteRequest(itemType: 'all');
  }

  Map<String, dynamic> toJson() {
    return {
      'item_type': itemType,
      if (factIndex != null) 'fact_index': factIndex,
    };
  }
}

/// Memory ingest request
class MemoryIngestRequest {
  final String sessionId;
  final List<ConversationExcerpt> conversationExcerpt;

  const MemoryIngestRequest({
    required this.sessionId,
    required this.conversationExcerpt,
  });

  Map<String, dynamic> toJson() {
    return {
      'session_id': sessionId,
      'conversation_excerpt': conversationExcerpt.map((e) => e.toJson()).toList(),
    };
  }
}

/// Conversation excerpt for memory ingest
class ConversationExcerpt {
  final String role; // 'user' or 'assistant'
  final String content;

  const ConversationExcerpt({
    required this.role,
    required this.content,
  });

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'content': content,
    };
  }
}
