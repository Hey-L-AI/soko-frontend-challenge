import 'chat_message.dart';
import '../../core/utils/city_resolver.dart';

/// Saved item type enum
enum SavedItemType {
  event,
  place;

  String toJson() => name;

  static SavedItemType fromJson(String json) {
    return SavedItemType.values.firstWhere(
      (e) => e.name == json,
      orElse: () => SavedItemType.event,
    );
  }
}

/// Saved item model matching OpenAPI SavedItem schema
class SavedItem {
  final String savedId;
  final SavedItemType type;
  final String? eventId;
  final String? venueId;
  final DateTime createdAt;

  /// Optional related data for display
  final String? title;
  final String? imageUrl;
  final String? category;

  /// Venue-specific fields
  final String? address;
  final String? city;
  final double? latitude;
  final double? longitude;
  final String? website;
  final String? googleMapsUrl;
  final String? phone;
  final Map<String, dynamic>? openingHours;

  /// Event-specific fields
  final String? description;
  final String? url;
  final String? date;
  final String? venueName;

  const SavedItem({
    required this.savedId,
    required this.type,
    this.eventId,
    this.venueId,
    required this.createdAt,
    this.title,
    this.imageUrl,
    this.category,
    this.address,
    this.city,
    this.latitude,
    this.longitude,
    this.website,
    this.googleMapsUrl,
    this.phone,
    this.openingHours,
    this.description,
    this.url,
    this.date,
    this.venueName,
  });

  /// The actual target ID (either event or venue)
  String get targetId =>
      type == SavedItemType.event ? (eventId ?? '') : (venueId ?? '');

  factory SavedItem.fromJson(Map<String, dynamic> json) {
    // Extract nested event/venue data for display
    final event = json['event'] as Map<String, dynamic>?;
    final venue = json['venue'] as Map<String, dynamic>?;

    // Get title from nested event.title or venue.name, or fall back to top-level
    String? title = json['title'] as String?;
    if (title == null || title.isEmpty) {
      if (event != null) {
        title = event['title'] as String?;
      } else if (venue != null) {
        title = venue['name'] as String?;
      }
    }

    // Get category from event or venue types
    String? category = json['category'] as String?;
    if (category == null && event != null) {
      category = event['category'] as String?;
    }

    // Get image URL - try top-level first, then nested event/venue
    String? imageUrl = json['image_url'] as String?;
    if (imageUrl == null || imageUrl.isEmpty) {
      if (event != null) {
        imageUrl = event['image_url'] as String?;
      } else if (venue != null) {
        imageUrl = venue['image_url'] as String?;
      }
    }

    // Extract venue-specific fields
    String? address;
    String? city;
    double? latitude;
    double? longitude;
    String? website;
    String? googleMapsUrl;
    String? phone;
    Map<String, dynamic>? openingHours;
    if (venue != null) {
      address = venue['address'] as String?;
      city = venue['city'] as String?;
      latitude = (venue['latitude'] as num?)?.toDouble();
      longitude = (venue['longitude'] as num?)?.toDouble();
      website = venue['website'] as String?;
      googleMapsUrl = venue['google_maps_url'] as String?;
      phone = venue['phone'] as String?;
      openingHours = venue['opening_hours'] as Map<String, dynamic>?;
    }

    // Extract event-specific fields
    String? description;
    String? url;
    String? date;
    String? venueName;
    if (event != null) {
      description = event['description'] as String?;
      url = event['url'] as String?;
      // Handle both start_datetime and date fields
      date = (event['start_datetime'] ?? event['date']) as String?;
      venueName = event['venue_name'] as String?;
      // Get venue details for events (coordinates + address for map display)
      latitude ??= (event['latitude'] as num?)?.toDouble();
      longitude ??= (event['longitude'] as num?)?.toDouble();
      address ??= event['venue_address'] as String?;
      city ??= event['venue_city'] as String?;
    }

    return SavedItem(
      // API returns 'id', but we also support 'saved_id' for consistency
      savedId: (json['saved_id'] ?? json['id']).toString(),
      // API returns 'item_type', but we also support 'type'
      type: SavedItemType.fromJson(
        (json['type'] ?? json['item_type']) as String? ?? 'event',
      ),
      eventId: json['event_id']?.toString(),
      venueId: json['venue_id']?.toString(),
      createdAt: DateTime.parse(json['created_at'] as String),
      title: title,
      imageUrl: imageUrl,
      category: category,
      address: address,
      city: city,
      latitude: latitude,
      longitude: longitude,
      website: website,
      googleMapsUrl: googleMapsUrl,
      phone: phone,
      openingHours: openingHours,
      description: description,
      url: url,
      date: date,
      venueName: venueName,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'saved_id': savedId,
      'type': type.toJson(),
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      'created_at': createdAt.toIso8601String(),
      if (title != null) 'title': title,
      if (imageUrl != null) 'image_url': imageUrl,
      if (category != null) 'category': category,
      if (address != null) 'address': address,
      if (city != null) 'city': city,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (description != null) 'description': description,
      if (url != null) 'url': url,
      if (date != null) 'date': date,
      if (venueName != null) 'venue_name': venueName,
    };
  }
}

/// External event data for Mode 2 saving
class ExternalEventData {
  final String title;
  final String url;
  final String? date;
  final String? description;
  final String? location;
  final String? city;
  final String? category;
  final String? imageUrl;
  final double? latitude;
  final double? longitude;

  const ExternalEventData({
    required this.title,
    required this.url,
    this.date,
    this.description,
    this.location,
    this.city,
    this.category,
    this.imageUrl,
    this.latitude,
    this.longitude,
  });

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'url': url,
      if (date != null) 'date': date,
      if (description != null) 'description': description,
      if (location != null) 'location': location,
      if (city != null) 'city': city,
      if (category != null) 'category': category,
      if (imageUrl != null) 'image_url': imageUrl,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
    };
  }
}

/// External place data for Mode 2 saving
class ExternalPlaceData {
  final String name;
  final String? city;
  final double? latitude;
  final double? longitude;
  final String? address;
  final double? rating;
  final int? ratingCount;
  final List<String>? types;
  final String? googlePlaceId;
  final String? googleMapsUrl;
  final String? imageUrl;
  final String? description;

  const ExternalPlaceData({
    required this.name,
    this.city,
    this.latitude,
    this.longitude,
    this.address,
    this.rating,
    this.ratingCount,
    this.types,
    this.googlePlaceId,
    this.googleMapsUrl,
    this.imageUrl,
    this.description,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (city != null) 'city': city,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (address != null) 'address': address,
      if (rating != null) 'rating': rating,
      if (ratingCount != null) 'rating_count': ratingCount,
      if (types != null && types!.isNotEmpty) 'types': types,
      if (googlePlaceId != null) 'google_place_id': googlePlaceId,
      if (googleMapsUrl != null) 'google_maps_url': googleMapsUrl,
      if (imageUrl != null) 'image_url': imageUrl,
      if (description != null) 'description': description,
    };
  }
}

/// Request model for creating a saved item (supports Mode 1 and Mode 2)
class SavedCreateRequest {
  final SavedItemType type;
  final String? eventId;
  final String? venueId;
  // External data for Mode 2 saving
  final ExternalEventData? eventData;
  final ExternalPlaceData? placeData;

  const SavedCreateRequest({
    required this.type,
    this.eventId,
    this.venueId,
    this.eventData,
    this.placeData,
  });

  // Mode 1: Save by existing DB ID
  factory SavedCreateRequest.event(String eventId) {
    return SavedCreateRequest(type: SavedItemType.event, eventId: eventId);
  }

  factory SavedCreateRequest.place(String venueId) {
    return SavedCreateRequest(type: SavedItemType.place, venueId: venueId);
  }

  // Mode 2: Save with external data
  factory SavedCreateRequest.externalEvent(ExternalEventData data) {
    return SavedCreateRequest(type: SavedItemType.event, eventData: data);
  }

  factory SavedCreateRequest.externalPlace(ExternalPlaceData data) {
    return SavedCreateRequest(type: SavedItemType.place, placeData: data);
  }

  /// Create from ItemSuggestion
  /// Always includes display data (eventData/placeData) for proper rendering,
  /// plus the DB ID if available for linking to existing records.
  /// Async because city resolution may require reverse geocoding.
  static Future<SavedCreateRequest> fromItemSuggestion(
    ItemSuggestion place,
  ) async {
    if (place.type == 'event') {
      // Always include event data for display (name, imageUrl, etc.)
      // Include coordinates for map display
      final eventData = ExternalEventData(
        title: place.name,
        url: place.url ?? '',
        date: place.date,
        description: place.description,
        location: place.location,
        city: place.city,
        category: place.category,
        imageUrl: place.imageUrl,
        latitude: place.latitude,
        longitude: place.longitude,
      );

      return SavedCreateRequest(
        type: SavedItemType.event,
        eventId: place.eventId, // May be null for external events
        eventData: eventData,
      );
    } else if (place.type == 'place') {
      // Resolve city: backend value → reverse geocoding → address parsing → null
      final city = await CityResolver.resolveCity(
        city: place.city,
        lat: place.latitude,
        lng: place.longitude,
        address: place.address,
      );

      final placeData = ExternalPlaceData(
        name: place.name,
        city: city,
        latitude: place.latitude,
        longitude: place.longitude,
        address: place.address,
        rating: place.rating,
        ratingCount: place.ratingCount,
        types: place.types,
        googlePlaceId: place.googlePlaceId,
        googleMapsUrl: place.googleMapsUrl,
        imageUrl: place.imageUrl,
        description: place.description,
      );

      return SavedCreateRequest(
        type: SavedItemType.place,
        venueId: place.venueId, // May be null for external places
        placeData: placeData,
      );
    }
    throw ArgumentError(
      'Cannot create SavedCreateRequest: missing required data',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'item_type': type.toJson(), // Backend expects 'item_type', not 'type'
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (eventData != null) 'event_data': eventData!.toJson(),
      if (placeData != null) 'place_data': placeData!.toJson(),
    };
  }
}

/// Response model for saved items list
class SavedListResponse {
  final List<SavedItem> items;
  final String? nextCursor;

  const SavedListResponse({required this.items, this.nextCursor});

  factory SavedListResponse.fromJson(Map<String, dynamic> json) {
    return SavedListResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => SavedItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['next_cursor'] as String?,
    );
  }

  bool get hasMore => nextCursor != null;
}
