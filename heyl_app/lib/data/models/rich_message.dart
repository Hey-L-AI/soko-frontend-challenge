import 'chat_message.dart';
import 'event_occurrence.dart';
import 'map_pin.dart' show FacetPair;

/// Button action types for interactive messages
enum ButtonActionType {
  url,
  postback;

  String toJson() => name;

  static ButtonActionType fromJson(String json) {
    return ButtonActionType.values.firstWhere(
      (e) => e.name == json,
      orElse: () => ButtonActionType.postback,
    );
  }
}

/// Action button for messages (used in ButtonsMessage and CardItem)
class ButtonAction {
  final ButtonActionType type;
  final String label;
  final String? url; // For 'url' type - opens externally
  final String? text; // For 'postback' type - sends as message

  const ButtonAction({
    required this.type,
    required this.label,
    this.url,
    this.text,
  });

  factory ButtonAction.fromJson(Map<String, dynamic> json) {
    return ButtonAction(
      type: ButtonActionType.fromJson(json['type'] as String? ?? 'postback'),
      label: json['label'] as String,
      url: json['url'] as String?,
      text: json['text'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type.toJson(),
    'label': label,
    if (url != null) 'url': url,
    if (text != null) 'text': text,
  };
}

/// Card item type (event, place, or generic)
enum CardItemType {
  event,
  place,
  generic;

  String toJson() => name;

  static CardItemType? fromJson(String? json) {
    if (json == null) return null;
    return CardItemType.values.firstWhere(
      (e) => e.name == json,
      orElse: () => CardItemType.generic,
    );
  }
}

/// Single card in a carousel message
class CardItem {
  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final String? url;
  final List<ButtonAction> buttons;
  final CardItemType? type;
  final String? eventId;
  final String? venueId;

  // Place-specific fields
  final double? latitude;
  final double? longitude;
  final double? rating;
  final int? ratingCount;
  final String? googleMapsUrl;
  final String? googlePlaceId;
  final String? address;
  final String? website;
  final List<String> types;

  // Event-specific fields
  final String? date;

  /// Precision of [date]: `"datetime"`, `"date"`, or `"unknown"`.
  /// Drives time rendering in event cards — `date`-only must not show `00:00`.
  final String? datePrecision;

  /// PROD-3829 — the card's primary discovery facet, when the backend sends
  /// one. Parsed forward-compatibly: no chat payload carries it yet
  /// (PROD-3832 adds it), so this is null today and the pin falls back to the
  /// generic pink art. Structured chat carousels flow through this model on
  /// their way to [ItemSuggestion], so dropping it here would silently defeat
  /// the facet for every card path.
  final FacetPair? primaryFacet;
  final String? location;
  final String? category;
  final String? description;

  // Shared fields
  final String? city;
  final String? neighborhood;
  final List<String> tags;

  // UI state fields
  final bool hasRealTime;

  // Personalization field
  final String? reason;

  // Event occurrence fields (for events with multiple dates)
  final List<EventOccurrence> occurrences;
  final int? occurrenceCount;
  final bool hasMoreOccurrences;

  const CardItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.url,
    this.buttons = const [],
    this.type,
    this.eventId,
    this.venueId,
    this.latitude,
    this.longitude,
    this.rating,
    this.ratingCount,
    this.googleMapsUrl,
    this.googlePlaceId,
    this.address,
    this.website,
    this.types = const [],
    this.date,
    this.datePrecision,
    this.location,
    this.category,
    this.description,
    this.city,
    this.neighborhood,
    this.tags = const [],
    this.hasRealTime = false,
    this.reason,
    this.occurrences = const [],
    this.occurrenceCount,
    this.hasMoreOccurrences = false,
    this.primaryFacet,
  });

  factory CardItem.fromJson(Map<String, dynamic> json) {
    return CardItem(
      id: json['id'] as String,
      title: json['title'] as String,
      subtitle: json['subtitle'] as String?,
      imageUrl: json['image_url'] as String?,
      url: json['url'] as String?,
      buttons:
          (json['buttons'] as List<dynamic>?)
              ?.map((e) => ButtonAction.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      type: CardItemType.fromJson(json['type'] as String?),
      eventId: json['event_id'] as String?,
      venueId: json['venue_id'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      rating: (json['rating'] as num?)?.toDouble(),
      ratingCount: json['rating_count'] as int?,
      googleMapsUrl: json['google_maps_url'] as String?,
      googlePlaceId: json['google_place_id'] as String?,
      address: json['address'] as String?,
      website: json['website'] as String?,
      types: (json['types'] as List<dynamic>?)?.cast<String>() ?? [],
      date: json['date'] as String?,
      datePrecision: json['date_precision'] as String?,
      primaryFacet: FacetPair.readFrom(json),
      location: json['location'] as String?,
      category: json['category'] as String?,
      description: json['description'] as String?,
      city: json['city'] as String?,
      neighborhood: json['neighborhood'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
      hasRealTime: json['has_real_time'] as bool? ?? false,
      reason: json['reason'] as String?,
      occurrences:
          (json['occurrences'] as List<dynamic>?)
              ?.map((e) => EventOccurrence.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      occurrenceCount: json['occurrence_count'] as int?,
      hasMoreOccurrences: json['has_more_occurrences'] as bool? ?? false,
    );
  }

  /// Create from ItemSuggestion for compatibility with legacy data
  factory CardItem.fromItemSuggestion(ItemSuggestion place) {
    return CardItem(
      id: place.id,
      // PROD-3829: see the note on `ItemSuggestion.toCardItem()` — the round
      // trip is only closed if both directions carry the facet.
      primaryFacet: place.primaryFacet,
      title: place.name,
      subtitle: place.description,
      imageUrl: place.imageUrl,
      url: place.url,
      type: place.type == 'event'
          ? CardItemType.event
          : place.type == 'place'
          ? CardItemType.place
          : CardItemType.generic,
      eventId: place.eventId,
      venueId: place.venueId,
      latitude: place.latitude,
      longitude: place.longitude,
      rating: place.rating,
      ratingCount: place.ratingCount,
      googleMapsUrl: place.googleMapsUrl,
      googlePlaceId: place.googlePlaceId,
      address: place.address,
      website: place.website,
      types: place.types ?? [],
      date: place.date,
      datePrecision: place.datePrecision,
      location: place.location,
      category: place.category,
      city: place.city,
      neighborhood: place.neighborhood,
      tags: place.tags,
      hasRealTime: place.hasRealTime,
      reason: place.reason,
      occurrences: place.occurrences,
      occurrenceCount: place.occurrenceCount,
      hasMoreOccurrences: place.hasMoreOccurrences,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (imageUrl != null) 'image_url': imageUrl,
    if (url != null) 'url': url,
    if (buttons.isNotEmpty) 'buttons': buttons.map((e) => e.toJson()).toList(),
    if (type != null) 'type': type!.toJson(),
    if (eventId != null) 'event_id': eventId,
    if (venueId != null) 'venue_id': venueId,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
    if (rating != null) 'rating': rating,
    if (ratingCount != null) 'rating_count': ratingCount,
    if (googleMapsUrl != null) 'google_maps_url': googleMapsUrl,
    if (googlePlaceId != null) 'google_place_id': googlePlaceId,
    if (address != null) 'address': address,
    if (website != null) 'website': website,
    if (types.isNotEmpty) 'types': types,
    if (date != null) 'date': date,
    if (datePrecision != null) 'date_precision': datePrecision,
    if (location != null) 'location': location,
    if (category != null) 'category': category,
    if (description != null) 'description': description,
    if (city != null) 'city': city,
    if (neighborhood != null) 'neighborhood': neighborhood,
    if (tags.isNotEmpty) 'tags': tags,
    if (hasRealTime) 'has_real_time': hasRealTime,
    if (reason != null) 'reason': reason,
    if (occurrences.isNotEmpty)
      'occurrences': occurrences.map((e) => e.toJson()).toList(),
    if (occurrenceCount != null) 'occurrence_count': occurrenceCount,
    if (hasMoreOccurrences) 'has_more_occurrences': hasMoreOccurrences,
    if (primaryFacet != null) 'primary_facet': primaryFacet!.toJson(),
  };

  /// Convert to ItemSuggestion for compatibility with existing UI widgets
  ItemSuggestion toItemSuggestion() {
    return ItemSuggestion(
      id: id,
      name: title,
      imageUrl: imageUrl,
      tags: tags.isNotEmpty ? tags : (category != null ? [category!] : []),
      type: type == CardItemType.event
          ? 'event'
          : type == CardItemType.place
          ? 'place'
          : type == CardItemType.generic
          ? 'generic'
          : null,
      eventId: eventId,
      venueId: venueId,
      url: url,
      // PROD-3829: carry the facet across the CardItem -> ItemSuggestion
      // conversion; otherwise chat carousels lose it before it ever reaches
      // a map marker.
      primaryFacet: primaryFacet,
      // Event fields
      date: date,
      datePrecision: datePrecision,
      // Prefer the short `subtitle` (LLM-shaped one-liner) as the card
      // description; fall back to the longer `description` (truncated by
      // the card's maxLines clamp) when no subtitle is present.
      description: subtitle ?? description,
      location: location,
      city: city,
      neighborhood: neighborhood,
      category: category,
      // Place fields
      latitude: latitude,
      longitude: longitude,
      address: address,
      rating: rating,
      ratingCount: ratingCount,
      types: types.isNotEmpty ? types : null,
      googlePlaceId: googlePlaceId,
      googleMapsUrl: googleMapsUrl,
      website: website,
      hasRealTime: hasRealTime,
      reason: reason,
      occurrences: occurrences,
      occurrenceCount: occurrenceCount,
      hasMoreOccurrences: hasMoreOccurrences,
    );
  }
}

/// Rich message type discriminator
enum RichMessageType {
  text,
  cardCarousel,
  buttons,
  image;

  String toJson() {
    return switch (this) {
      RichMessageType.text => 'text',
      RichMessageType.cardCarousel => 'card_carousel',
      RichMessageType.buttons => 'buttons',
      RichMessageType.image => 'image',
    };
  }

  static RichMessageType fromJson(String json) {
    return switch (json) {
      'text' => RichMessageType.text,
      'card_carousel' => RichMessageType.cardCarousel,
      'buttons' => RichMessageType.buttons,
      'image' => RichMessageType.image,
      _ => RichMessageType.text,
    };
  }
}

/// Sealed class for structured message types (discriminated union)
sealed class RichMessage {
  final RichMessageType type;

  const RichMessage(this.type);

  /// Factory to parse RichMessage from JSON using type discriminator
  factory RichMessage.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'text';
    return switch (typeStr) {
      'text' => TextRichMessage.fromJson(json),
      'card_carousel' => CardCarouselMessage.fromJson(json),
      'buttons' => ButtonsMessage.fromJson(json),
      'image' => ImageRichMessage.fromJson(json),
      _ => TextRichMessage(content: json['content'] as String? ?? ''),
    };
  }

  Map<String, dynamic> toJson();
}

/// Text-only message
final class TextRichMessage extends RichMessage {
  final String content;
  final bool isAcknowledgment;

  const TextRichMessage({required this.content, this.isAcknowledgment = false})
    : super(RichMessageType.text);

  factory TextRichMessage.fromJson(Map<String, dynamic> json) {
    return TextRichMessage(
      content: json['content'] as String? ?? '',
      isAcknowledgment: json['is_acknowledgment'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'content': content,
    'is_acknowledgment': isAcknowledgment,
  };
}

/// Carousel of cards (events/places)
final class CardCarouselMessage extends RichMessage {
  final List<CardItem> items;

  const CardCarouselMessage({required this.items})
    : super(RichMessageType.cardCarousel);

  factory CardCarouselMessage.fromJson(Map<String, dynamic> json) {
    return CardCarouselMessage(
      items:
          (json['items'] as List<dynamic>?)
              ?.map((e) => CardItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'card_carousel',
    'items': items.map((e) => e.toJson()).toList(),
  };

  /// Convert to ItemSuggestion list for compatibility with existing UI
  List<ItemSuggestion> toItemSuggestions() {
    return items.map((item) => item.toItemSuggestion()).toList();
  }
}

/// Message with action buttons (quick replies)
final class ButtonsMessage extends RichMessage {
  final String text;
  final List<ButtonAction> buttons;

  const ButtonsMessage({required this.text, required this.buttons})
    : super(RichMessageType.buttons);

  factory ButtonsMessage.fromJson(Map<String, dynamic> json) {
    return ButtonsMessage(
      text: json['text'] as String? ?? '',
      buttons:
          (json['buttons'] as List<dynamic>?)
              ?.map((e) => ButtonAction.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'buttons',
    'text': text,
    'buttons': buttons.map((e) => e.toJson()).toList(),
  };
}

/// Image message with optional caption
final class ImageRichMessage extends RichMessage {
  final String url;
  final String? caption;

  const ImageRichMessage({required this.url, this.caption})
    : super(RichMessageType.image);

  factory ImageRichMessage.fromJson(Map<String, dynamic> json) {
    return ImageRichMessage(
      url: json['url'] as String? ?? '',
      caption: json['caption'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'url': url,
    if (caption != null) 'caption': caption,
  };
}
