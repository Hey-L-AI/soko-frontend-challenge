import 'chat_message.dart';
import 'event_occurrence.dart';

/// Event model matching OpenAPI Event schema
class Event {
  final String id;
  final String title;
  final String? category;
  final bool isActive;
  final bool isPublic;

  /// Additional fields for display (not in base schema but useful)
  final String? description;
  final String? imageUrl;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? venueName;
  final String? city;

  const Event({
    required this.id,
    required this.title,
    this.category,
    required this.isActive,
    required this.isPublic,
    this.description,
    this.imageUrl,
    this.startDate,
    this.endDate,
    this.venueName,
    this.city,
  });

  factory Event.fromJson(Map<String, dynamic> json) {
    return Event(
      id: json['id'] as String,
      title: json['title'] as String,
      category: json['category'] as String?,
      isActive: json['is_active'] as bool? ?? true,
      isPublic: json['is_public'] as bool? ?? true,
      description: json['description'] as String?,
      imageUrl: json['image_url'] as String?,
      startDate: json['start_date'] != null
          ? DateTime.parse(json['start_date'] as String)
          : null,
      endDate: json['end_date'] != null
          ? DateTime.parse(json['end_date'] as String)
          : null,
      venueName: json['venue_name'] as String?,
      city: json['city'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      if (category != null) 'category': category,
      'is_active': isActive,
      'is_public': isPublic,
      if (description != null) 'description': description,
      if (imageUrl != null) 'image_url': imageUrl,
      if (startDate != null) 'start_date': startDate!.toIso8601String(),
      if (endDate != null) 'end_date': endDate!.toIso8601String(),
      if (venueName != null) 'venue_name': venueName,
      if (city != null) 'city': city,
    };
  }

  Event copyWith({
    String? id,
    String? title,
    String? category,
    bool? isActive,
    bool? isPublic,
    String? description,
    String? imageUrl,
    DateTime? startDate,
    DateTime? endDate,
    String? venueName,
    String? city,
  }) {
    return Event(
      id: id ?? this.id,
      title: title ?? this.title,
      category: category ?? this.category,
      isActive: isActive ?? this.isActive,
      isPublic: isPublic ?? this.isPublic,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      venueName: venueName ?? this.venueName,
      city: city ?? this.city,
    );
  }
}

/// Response model for event list
class EventListResponse {
  final List<Event> items;
  final String? nextCursor;

  const EventListResponse({
    required this.items,
    this.nextCursor,
  });

  factory EventListResponse.fromJson(Map<String, dynamic> json) {
    return EventListResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => Event.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['next_cursor'] as String?,
    );
  }

  bool get hasMore => nextCursor != null;
}

/// Detailed event response from GET /events/{event_id}
/// Includes occurrence data for multi-date events
class EventDetailResponse {
  final String id;
  final String title;
  final String? category;
  final String? description;
  final String? imageUrl;
  final String? url;
  final String? venueName;
  final String? venueAddress;
  final String? city;
  final double? latitude;
  final double? longitude;
  final int? totalOccurrences;
  final List<EventOccurrence> occurrences;

  const EventDetailResponse({
    required this.id,
    required this.title,
    this.category,
    this.description,
    this.imageUrl,
    this.url,
    this.venueName,
    this.venueAddress,
    this.city,
    this.latitude,
    this.longitude,
    this.totalOccurrences,
    this.occurrences = const [],
  });

  factory EventDetailResponse.fromJson(Map<String, dynamic> json) {
    return EventDetailResponse(
      id: json['id'] as String,
      title: json['title'] as String,
      category: json['category'] as String?,
      description: json['description'] as String?,
      imageUrl: json['image_url'] as String?,
      url: json['url'] as String?,
      venueName: json['venue_name'] as String?,
      venueAddress: json['venue_address'] as String?,
      city: json['city'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      totalOccurrences: json['total_occurrences'] as int?,
      occurrences: (json['occurrences'] as List<dynamic>?)
              ?.map((e) => EventOccurrence.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// Convert to ItemSuggestion for routed detail navigation and add-to-list flows.
  ItemSuggestion toItemSuggestion() {
    // Extract venueId from first occurrence if available
    final occVenueId = occurrences.isNotEmpty ? occurrences.first.venueId : null;
    return ItemSuggestion(
      id: id,
      name: title,
      type: 'event',
      eventId: id,
      venueId: occVenueId,
      imageUrl: imageUrl,
      url: url,
      description: description,
      location: venueName,
      city: city,
      category: category,
      latitude: latitude,
      longitude: longitude,
      address: venueAddress,
      occurrences: occurrences,
      occurrenceCount: totalOccurrences ?? occurrences.length,
      hasMoreOccurrences: totalOccurrences != null &&
          totalOccurrences! > occurrences.length,
    );
  }
}
