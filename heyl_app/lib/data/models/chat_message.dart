import 'event_occurrence.dart';
import 'location_snapshot.dart';
import 'map_pin.dart' show FacetPair;
import 'recurrence_phase.dart';
import 'rich_message.dart';
import 'social_proof.dart';

/// Message role enum
enum MessageRole {
  user,
  assistant;

  String toJson() => name;

  static MessageRole fromJson(String json) {
    return MessageRole.values.firstWhere(
      (e) => e.name == json,
      orElse: () => MessageRole.user,
    );
  }
}

/// User message type enum (for user-sent messages only)
enum UserMessageType {
  text,
  image,
  voice;

  String toJson() => name;

  static UserMessageType fromJson(String json) {
    return UserMessageType.values.firstWhere(
      (e) => e.name == json,
      orElse: () => UserMessageType.text,
    );
  }
}

/// Chat message model matching OpenAPI MessageOut schema
/// Supports both user messages (text/image/voice) and assistant messages (rich content)
class ChatMessage {
  final String messageId;
  final MessageRole role;
  final DateTime createdAt;

  /// For user messages: the type of content (text, image, voice)
  final UserMessageType? userMessageType;

  /// Text content for user messages or legacy assistant messages
  final String? text;

  /// Media URL for user image messages
  final String? mediaUrl;

  /// Rich content for assistant messages (new typed message format)
  final RichMessage? richContent;

  /// Legacy: place suggestions attached to assistant messages
  /// Use effectiveItemSuggestions getter instead
  final List<ItemSuggestion>? itemSuggestions;

  /// ISO 639-1 language code detected from assistant response (e.g. "pt", "en", "es")
  final String? language;

  /// The parent run's `run_number` (turn order; higher = newer). Only set for
  /// messages fetched from a session's runs; null for optimistic/streaming
  /// messages and the WhatsApp `listMessages` path. Used as the primary display
  /// ordering key so a turn never inverts on a coarse/tied `created_at`.
  final int? runNumber;

  /// The message's `sequence` within its run (OpenAPI `MessageOut.sequence`).
  /// Carried for debugging/round-trip only — NOT the sort key (nullable and may
  /// be unset on user messages; the backend `messages[]` array order is the
  /// authoritative within-run order, preserved via parse index instead).
  final int? sequence;

  const ChatMessage({
    required this.messageId,
    required this.role,
    required this.createdAt,
    this.userMessageType,
    this.text,
    this.mediaUrl,
    this.richContent,
    this.itemSuggestions,
    this.language,
    this.runNumber,
    this.sequence,
  });

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;

  /// Get display text for any message type
  String? get displayText {
    if (richContent != null) {
      return switch (richContent!) {
        TextRichMessage(:final content) => content,
        ButtonsMessage(:final text) => text,
        ImageRichMessage(:final caption) => caption,
        CardCarouselMessage() => null,
      };
    }
    return text;
  }

  /// Check if this is an acknowledgment message (quick response before main processing)
  bool get isAcknowledgment {
    if (richContent case TextRichMessage(:final isAcknowledgment)) {
      return isAcknowledgment;
    }
    return false;
  }

  /// Get place suggestions from rich content or legacy field
  List<ItemSuggestion> get effectiveItemSuggestions {
    if (richContent case CardCarouselMessage(:final items)) {
      return items.map((item) => item.toItemSuggestion()).toList();
    }
    return itemSuggestions ?? [];
  }

  /// Get card items from rich content or convert legacy place suggestions
  List<CardItem> get effectiveCardItems {
    if (richContent case CardCarouselMessage(:final items)) {
      return items;
    }
    // Convert legacy itemSuggestions to CardItems
    return (itemSuggestions ?? []).map((p) => p.toCardItem()).toList();
  }

  bool get hasItemSuggestions => effectiveItemSuggestions.isNotEmpty;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final role = MessageRole.fromJson(json['role'] as String? ?? 'user');

    // Parse rich content from flat structure (new API format)
    // or nested rich_content (legacy compatibility)
    RichMessage? richContent;
    final messageType = json['message_type'] as String?;

    if (json['rich_content'] != null) {
      // Legacy nested format (keep for backwards compatibility)
      richContent = RichMessage.fromJson(
        json['rich_content'] as Map<String, dynamic>,
      );
    } else if (messageType != null && messageType != 'text') {
      // New flat format - message_type indicates rich content type
      // Pass the entire json to RichMessage.fromJson with 'type' field mapped
      richContent = RichMessage.fromJson({'type': messageType, ...json});
    } else if (json['items'] != null) {
      // Flat format without message_type - infer card_carousel from items
      richContent = RichMessage.fromJson({'type': 'card_carousel', ...json});
    }

    // Parse user message type
    UserMessageType? userMessageType;
    if (role == MessageRole.user) {
      final typeStr = json['type'] as String?;
      userMessageType = switch (typeStr) {
        'image' => UserMessageType.image,
        'voice' => UserMessageType.voice,
        _ => UserMessageType.text,
      };
    }

    // Parse content (API uses 'content', legacy uses 'text')
    var textContent = json['text'] as String? ?? json['content'] as String?;

    // Legacy: Infer type from content prefix for user messages
    if (json['type'] == null &&
        textContent != null &&
        role == MessageRole.user) {
      if (textContent.startsWith('[Image] ')) {
        userMessageType = UserMessageType.image;
        textContent = textContent.substring(8);
      } else if (textContent.startsWith('[Voice] ')) {
        userMessageType = UserMessageType.voice;
        textContent = textContent.substring(8);
      }
    }

    return ChatMessage(
      messageId: json['message_id'] as String,
      role: role,
      createdAt: DateTime.parse(json['created_at'] as String),
      userMessageType: userMessageType,
      text: textContent,
      mediaUrl: json['media_url'] as String?,
      richContent: richContent,
      itemSuggestions: (json['place_suggestions'] as List<dynamic>?)
          ?.map((e) => ItemSuggestion.fromJson(e as Map<String, dynamic>))
          .toList(),
      language: json['language'] as String?,
      // `run_number` is not part of MessageOut — it's injected from the parent
      // run in sessions_api. Parsed here only so a cached copy round-trips.
      runNumber: json['run_number'] as int?,
      sequence: json['sequence'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'message_id': messageId,
      'role': role.toJson(),
      if (userMessageType != null) 'type': userMessageType!.toJson(),
      if (text != null) 'text': text,
      if (mediaUrl != null) 'media_url': mediaUrl,
      'created_at': createdAt.toIso8601String(),
      if (richContent != null) 'rich_content': richContent!.toJson(),
      if (itemSuggestions != null)
        'place_suggestions': itemSuggestions!.map((e) => e.toJson()).toList(),
      if (language != null) 'language': language,
      if (runNumber != null) 'run_number': runNumber,
      if (sequence != null) 'sequence': sequence,
    };
  }

  ChatMessage copyWith({
    String? messageId,
    MessageRole? role,
    UserMessageType? userMessageType,
    String? text,
    String? mediaUrl,
    DateTime? createdAt,
    RichMessage? richContent,
    List<ItemSuggestion>? itemSuggestions,
    String? language,
    int? runNumber,
    int? sequence,
  }) {
    return ChatMessage(
      messageId: messageId ?? this.messageId,
      role: role ?? this.role,
      userMessageType: userMessageType ?? this.userMessageType,
      text: text ?? this.text,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      createdAt: createdAt ?? this.createdAt,
      richContent: richContent ?? this.richContent,
      itemSuggestions: itemSuggestions ?? this.itemSuggestions,
      language: language ?? this.language,
      runNumber: runNumber ?? this.runNumber,
      sequence: sequence ?? this.sequence,
    );
  }

  /// Factory for creating a user text message
  factory ChatMessage.userText(String text) {
    return ChatMessage(
      messageId: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      role: MessageRole.user,
      userMessageType: UserMessageType.text,
      text: text,
      createdAt: DateTime.now(),
    );
  }

  /// Factory for creating an assistant message with rich content
  factory ChatMessage.assistantRich(RichMessage content, {String? language}) {
    return ChatMessage(
      messageId: 'msg_${DateTime.now().millisecondsSinceEpoch}_assistant',
      role: MessageRole.assistant,
      richContent: content,
      createdAt: DateTime.now(),
      language: language,
    );
  }

  /// Factory for creating an assistant text message (legacy, wraps in TextRichMessage)
  factory ChatMessage.assistantText(
    String text, {
    List<ItemSuggestion>? places,
    String? language,
  }) {
    return ChatMessage(
      messageId: 'msg_${DateTime.now().millisecondsSinceEpoch}_assistant',
      role: MessageRole.assistant,
      richContent: TextRichMessage(content: text),
      text: text, // Keep for backward compatibility
      createdAt: DateTime.now(),
      itemSuggestions: places,
      language: language,
    );
  }

  /// Factory for creating a user voice message (optimistic)
  factory ChatMessage.userVoice({String? displayText}) {
    return ChatMessage(
      messageId: 'msg_${DateTime.now().millisecondsSinceEpoch}_voice',
      role: MessageRole.user,
      userMessageType: UserMessageType.voice,
      text: displayText ?? '[Voice message]',
      createdAt: DateTime.now(),
    );
  }

  /// Factory for creating a user image message (optimistic)
  factory ChatMessage.userImage(String imagePath, {String? caption}) {
    return ChatMessage(
      messageId: 'msg_${DateTime.now().millisecondsSinceEpoch}_image',
      role: MessageRole.user,
      userMessageType: UserMessageType.image,
      text: caption,
      mediaUrl: imagePath,
      createdAt: DateTime.now(),
    );
  }
}

/// Item suggestion (event or place) shown in chat
class ItemSuggestion {
  final String id;
  final String name;
  final String? imageUrl;
  final List<String> tags;
  final String? type; // 'event' or 'place'
  final String? eventId;
  final String? venueId;
  final String?
  url; // URL to the event/place (for opening in browser or saving)

  // Event-specific fields for external save (Mode 2)
  final String? date;

  /// Precision of [date]: `"datetime"`, `"date"`, or `"unknown"`.
  /// `null` for cached payloads predating the field — renderers fall back to
  /// the previous behaviour.
  final String? datePrecision;
  final String? description;
  final String? location; // Venue name for events
  final String? city;
  final String? neighborhood;
  final String? category;
  final List<String> categories;

  // Place-specific fields for external save (Mode 2)
  final double? latitude;
  final double? longitude;
  final String? address;
  final double? rating;
  final int? ratingCount;
  final List<String>? types; // Google Maps types
  final String? googlePlaceId;
  final String? googleMapsUrl;
  final String? website; // Place website URL
  final String? phone; // Place phone number
  final Map<String, dynamic>? openingHours; // Place opening hours

  // UI state fields
  final bool hasRealTime;

  // Personalization field
  final String? reason;

  // Event occurrence fields (for events with multiple dates)
  final List<EventOccurrence> occurrences;
  final int? occurrenceCount;
  final bool hasMoreOccurrences;

  // Social proof data (from detail or search endpoints)
  final SocialProof? socialProof;

  /// Meilisearch ranking score (0-1) from `places.search` / `events.search`
  /// responses. Null for items that don't come from a scored search path
  /// (chat-rendered cards, list items, Google-fallback place results).
  /// Used by the discovery typeahead to sort + filter by relevance.
  final double? relevanceScore;

  /// PROD-2993 — the two-layer discovery facet this item pins to (PROD-2735).
  ///
  /// Present on every `PlaceSearchResult` / `EventSearchResult` — and therefore
  /// on every card `/map/hydrate` returns — but it went unparsed until the map
  /// needed it, so **don't assume it's populated on cards from other paths**.
  ///
  /// PROD-3829 update: the *parsing* is no longer the limit. `UserListItem`,
  /// `SlimMapPin`, `ListsMapPin`, `ListsCalendarEvent` and the venue/event
  /// detail responses all read `primary_facet` now, forward-compatibly. What
  /// they lack is a backend that **sends** it — only `/map/hydrate` does today.
  /// So a card from any other path still arrives with a null facet (→ the
  /// generic pink pin), but the day PROD-3831/3832 add the field server-side
  /// it lights up with no app release. Chat suggestions specifically are
  /// PROD-3832.
  ///
  /// The Map page reads it to draw the **facet-coloured teardrop** for a card
  /// whose item is buried inside a stack. It can't get that from the map data:
  /// a v2 server stack sends its members as `{id, entity}` only
  /// (`MapMember` — no facet, no coordinates), and only the top ≤5
  /// `stack_members` carry a facet at all. The hydrated card is the one place
  /// the facet is always available for *every* result in view.
  final FacetPair? primaryFacet;

  /// PROD-3379 / PROD-3412 — confident recurrence phase for the chips
  /// ("Primeiros dias" / "Últimos dias"). Present (ungated) on `/map/hydrate` **event**
  /// cards (`EventSearchResult.recurrence_phase`); null/absent for venues, chat
  /// suggestions, and list items. Drives [RecurrencePhaseChip] on the map drawer
  /// cards. Parsed forward-compatibly (unknown ⇒ null — see
  /// [recurrencePhaseFromWire]).
  final RecurrencePhase? recurrencePhase;

  const ItemSuggestion({
    required this.id,
    required this.name,
    this.imageUrl,
    this.tags = const [],
    this.type,
    this.eventId,
    this.venueId,
    this.url,
    // Event fields
    this.date,
    this.datePrecision,
    this.description,
    this.location,
    this.city,
    this.neighborhood,
    this.category,
    this.categories = const [],
    // Place fields
    this.latitude,
    this.longitude,
    this.address,
    this.rating,
    this.ratingCount,
    this.types,
    this.googlePlaceId,
    this.googleMapsUrl,
    this.website,
    this.phone,
    this.openingHours,
    this.hasRealTime = false,
    this.reason,
    this.occurrences = const [],
    this.occurrenceCount,
    this.hasMoreOccurrences = false,
    this.socialProof,
    this.relevanceScore,
    this.primaryFacet,
    this.recurrencePhase,
  });

  /// Returns a copy with the given fields replaced. Used by the chat map
  /// flow to enrich coordinate-less event suggestions with `latitude` /
  /// `longitude` fetched from `GET /events/{event_id}` before plotting them
  /// (external/Gemini event cards arrive without coordinates).
  ItemSuggestion copyWith({
    String? id,
    String? name,
    String? imageUrl,
    List<String>? tags,
    String? type,
    String? eventId,
    String? venueId,
    String? url,
    String? date,
    String? datePrecision,
    String? description,
    String? location,
    String? city,
    String? neighborhood,
    String? category,
    List<String>? categories,
    double? latitude,
    double? longitude,
    String? address,
    double? rating,
    int? ratingCount,
    List<String>? types,
    String? googlePlaceId,
    String? googleMapsUrl,
    String? website,
    String? phone,
    Map<String, dynamic>? openingHours,
    bool? hasRealTime,
    String? reason,
    List<EventOccurrence>? occurrences,
    int? occurrenceCount,
    bool? hasMoreOccurrences,
    SocialProof? socialProof,
    double? relevanceScore,
    FacetPair? primaryFacet,
    RecurrencePhase? recurrencePhase,
  }) {
    return ItemSuggestion(
      id: id ?? this.id,
      name: name ?? this.name,
      imageUrl: imageUrl ?? this.imageUrl,
      tags: tags ?? this.tags,
      type: type ?? this.type,
      eventId: eventId ?? this.eventId,
      venueId: venueId ?? this.venueId,
      url: url ?? this.url,
      date: date ?? this.date,
      datePrecision: datePrecision ?? this.datePrecision,
      description: description ?? this.description,
      location: location ?? this.location,
      city: city ?? this.city,
      neighborhood: neighborhood ?? this.neighborhood,
      category: category ?? this.category,
      categories: categories ?? this.categories,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      address: address ?? this.address,
      rating: rating ?? this.rating,
      ratingCount: ratingCount ?? this.ratingCount,
      types: types ?? this.types,
      googlePlaceId: googlePlaceId ?? this.googlePlaceId,
      googleMapsUrl: googleMapsUrl ?? this.googleMapsUrl,
      website: website ?? this.website,
      phone: phone ?? this.phone,
      openingHours: openingHours ?? this.openingHours,
      hasRealTime: hasRealTime ?? this.hasRealTime,
      reason: reason ?? this.reason,
      occurrences: occurrences ?? this.occurrences,
      occurrenceCount: occurrenceCount ?? this.occurrenceCount,
      hasMoreOccurrences: hasMoreOccurrences ?? this.hasMoreOccurrences,
      socialProof: socialProof ?? this.socialProof,
      relevanceScore: relevanceScore ?? this.relevanceScore,
      primaryFacet: primaryFacet ?? this.primaryFacet,
      recurrencePhase: recurrencePhase ?? this.recurrencePhase,
    );
  }

  /// Check if this is an external item (no DB IDs)
  bool get isExternal => eventId == null && venueId == null;

  /// Check if this has enough data for external save
  bool get canSaveExternally {
    if (type == 'event') {
      return name.isNotEmpty && url != null && url!.isNotEmpty;
    } else if (type == 'place') {
      return name.isNotEmpty && city != null && city!.isNotEmpty;
    }
    return false;
  }

  /// Human-readable type label for subtitle rendering.
  ///
  /// Prefers `tags.first` (already human-formatted by the backend — e.g.
  /// `"Ice Cream Shop"`), falls back to `types.first` title-cased
  /// (e.g. `"ice_cream_shop"` → `"Ice Cream Shop"`). Returns null if no
  /// usable label is available.
  String? get typeLabel {
    if (tags.isNotEmpty && tags.first.isNotEmpty) {
      return tags.first;
    }
    final t = types;
    if (t != null && t.isNotEmpty && t.first.isNotEmpty) {
      return t.first
          .replaceAll('_', ' ')
          .split(' ')
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
    }
    return null;
  }

  /// Builds the card subtitle shown on chat `VenueCard` and add-to-list
  /// `SearchResultCard`: `[type] • [neighborhood] • [city]`.
  ///
  /// Null/empty parts are skipped (graceful fallback) so a place with
  /// only `neighborhood` still renders meaningfully. Returns empty string
  /// if nothing is available.
  String locationSubtitle() {
    final parts = <String>[];
    final label = typeLabel;
    if (label != null) parts.add(label);
    if (neighborhood != null && neighborhood!.isNotEmpty) {
      parts.add(neighborhood!);
    }
    if (city != null && city!.isNotEmpty) parts.add(city!);
    return parts.join(' \u2022 ');
  }

  /// Comma-joined location summary for event cards: `"[location], [city]"`.
  ///
  /// For events, `location` holds the venue name (per the backend contract).
  /// Backend data sometimes has `location == city` (e.g. when the venue is
  /// unknown and the backend falls back to the city as the location label) —
  /// drop the city in that case so we don't render `"Lisboa, Lisboa"`.
  /// Case-insensitive trim comparison.
  ///
  /// Returns empty string if neither is set.
  String eventLocationSummary() {
    final loc = location?.trim() ?? '';
    final cty = city?.trim() ?? '';
    if (loc.isEmpty) return cty;
    if (cty.isEmpty) return loc;
    if (loc.toLowerCase() == cty.toLowerCase()) return loc;
    return '$loc, $cty';
  }

  factory ItemSuggestion.fromJson(Map<String, dynamic> json) {
    return ItemSuggestion(
      id: json['id'] as String,
      name: json['name'] as String,
      imageUrl: json['image_url'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
      type: json['type'] as String?,
      eventId: json['event_id'] as String?,
      venueId: json['venue_id'] as String?,
      url: json['url'] as String?,
      // Event fields
      date: json['date'] as String?,
      datePrecision: json['date_precision'] as String?,
      // For places, description is in subtitle (per BaseCardProperties)
      description:
          json['description'] as String? ?? json['subtitle'] as String?,
      location: json['location'] as String?,
      city: json['city'] as String?,
      neighborhood: json['neighborhood'] as String?,
      category: json['category'] as String?,
      categories:
          (json['categories'] as List<dynamic>?)?.cast<String>() ?? const [],
      // Place fields
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      address: json['address'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      ratingCount: json['rating_count'] as int?,
      types: (json['types'] as List<dynamic>?)?.cast<String>(),
      googlePlaceId: json['google_place_id'] as String?,
      googleMapsUrl: json['google_maps_url'] as String?,
      website: json['website'] as String?,
      phone: json['phone'] as String?,
      openingHours: json['opening_hours'] as Map<String, dynamic>?,
      hasRealTime: json['has_real_time'] as bool? ?? false,
      reason: json['reason'] as String?,
      occurrences:
          (json['occurrences'] as List<dynamic>?)
              ?.map((e) => EventOccurrence.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      occurrenceCount: json['occurrence_count'] as int?,
      hasMoreOccurrences: json['has_more_occurrences'] as bool? ?? false,
      socialProof: json['social_proof'] != null
          ? SocialProof.fromJson(json['social_proof'] as Map<String, dynamic>)
          : null,
      // PROD-2993 — present on search/hydrate cards, absent everywhere else
      // (chat suggestions, list items); `FacetPair.fromJson` returns null for
      // a null map, so those simply keep a null facet.
      primaryFacet: FacetPair.fromJson(
        json['primary_facet'] as Map<String, dynamic>?,
      ),
      recurrencePhase: recurrencePhaseFromWire(json['recurrence_phase']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (imageUrl != null) 'image_url': imageUrl,
      'tags': tags,
      if (type != null) 'type': type,
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (url != null) 'url': url,
      // Event fields
      if (date != null) 'date': date,
      if (datePrecision != null) 'date_precision': datePrecision,
      if (description != null) 'description': description,
      if (location != null) 'location': location,
      if (city != null) 'city': city,
      if (neighborhood != null) 'neighborhood': neighborhood,
      if (category != null) 'category': category,
      if (categories.isNotEmpty) 'categories': categories,
      // Place fields
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (address != null) 'address': address,
      if (rating != null) 'rating': rating,
      if (ratingCount != null) 'rating_count': ratingCount,
      if (types != null) 'types': types,
      if (googlePlaceId != null) 'google_place_id': googlePlaceId,
      if (googleMapsUrl != null) 'google_maps_url': googleMapsUrl,
      if (website != null) 'website': website,
      if (phone != null) 'phone': phone,
      if (openingHours != null) 'opening_hours': openingHours,
      if (hasRealTime) 'has_real_time': hasRealTime,
      if (reason != null) 'reason': reason,
      if (occurrences.isNotEmpty)
        'occurrences': occurrences.map((e) => e.toJson()).toList(),
      if (occurrenceCount != null) 'occurrence_count': occurrenceCount,
      if (hasMoreOccurrences) 'has_more_occurrences': hasMoreOccurrences,
      if (primaryFacet != null) 'primary_facet': primaryFacet!.toJson(),
      if (recurrencePhase != null)
        'recurrence_phase': recurrencePhase!.wireValue,
    };
  }

  /// Convert to CardItem for use with PlaceCardsRow
  CardItem toCardItem() {
    return CardItem(
      id: id,
      // PROD-3829: the facet must survive BOTH directions of this conversion.
      // `ChatMessage.effectiveCardItems` sends legacy suggestions through
      // `toCardItem()`, and `PlaceCardsRow` converts the card straight back to
      // an `ItemSuggestion` for tap/save — so a drop in either direction loses
      // the facet on a full round trip while every individual model still
      // looks correct.
      primaryFacet: primaryFacet,
      title: name,
      subtitle: description,
      imageUrl: imageUrl,
      url: url,
      type: type == 'event'
          ? CardItemType.event
          : type == 'place'
          ? CardItemType.place
          : type == 'generic'
          ? CardItemType.generic
          : null,
      eventId: eventId,
      venueId: venueId,
      // Event fields
      date: date,
      datePrecision: datePrecision,
      location: location,
      city: city,
      neighborhood: neighborhood,
      category: category,
      description: description,
      tags: tags,
      // Place fields
      latitude: latitude,
      longitude: longitude,
      address: address,
      rating: rating,
      ratingCount: ratingCount,
      types: types ?? [],
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

/// Request model for sending a text message
class TextMessageSendRequest {
  final String text;
  final LocationSnapshot? location;
  final String? locale;
  final String? visitorId;

  const TextMessageSendRequest({
    required this.text,
    this.location,
    this.locale,
    this.visitorId,
  });

  /// Backend expects 'content' field, not 'text'
  Map<String, dynamic> toJson() => {
    'content': text,
    if (location != null) 'location': location!.toJson(),
    if (locale != null) 'locale': locale,
    if (visitorId != null) 'visitor_id': visitorId,
  };
}

/// Response for message accepted
class MessageAcceptedResponse {
  final String messageId;
  final String status;
  final String sessionId;

  const MessageAcceptedResponse({
    required this.messageId,
    required this.status,
    required this.sessionId,
  });

  factory MessageAcceptedResponse.fromJson(Map<String, dynamic> json) {
    return MessageAcceptedResponse(
      messageId: json['message_id'] as String,
      status: json['status'] as String,
      sessionId: json['session_id'] as String,
    );
  }
}
