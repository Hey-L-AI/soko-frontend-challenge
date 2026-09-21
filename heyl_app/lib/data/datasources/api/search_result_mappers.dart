import '../../../core/utils/datetime_parsing.dart';
import '../../models/models.dart';

/// Shared `/places/search` + `/events/search` result → [ItemSuggestion]
/// mappers.
///
/// The backend serializes a `PlaceSearchResult` / `EventSearchResult`
/// identically across `/places/search`, `/events/search`, and
/// `POST /map/hydrate` (one serializer, no drift — per the maps v0 contract),
/// so both `SearchApi` and `MapApi` map them through here.

/// Map one `PlaceSearchResult` JSON object to an [ItemSuggestion].
/// Returns null when the row lacks a usable `name`.
ItemSuggestion? itemSuggestionFromPlaceResult(Map<String, dynamic> place) {
  final name = place['name'] as String?;
  if (name == null) return null;

  // venue_id for local results, google_place_id for Google results.
  final venueId = place['venue_id'] as String?;
  final googlePlaceId = place['google_place_id'] as String?;
  final id = venueId ?? googlePlaceId ?? '';

  final address = place['address'] as String?;
  // Prefer the direct `city` field (PROD-1404 — postal prefix stripped in BE).
  // Fall back to the legacy address-parsing heuristic when omitted.
  String? city = place['city'] as String?;
  if (city == null && address != null) {
    final parts = address.split(', ');
    if (parts.length >= 2) {
      city = parts[parts.length - 2];
      city = city.replaceAll(RegExp(r'^\d+-\d+\s*'), '');
    }
  }

  return ItemSuggestion(
    id: id,
    name: name,
    type: 'place',
    venueId: venueId,
    googlePlaceId: googlePlaceId,
    googleMapsUrl: place['google_maps_url'] as String?,
    latitude: (place['latitude'] as num?)?.toDouble(),
    longitude: (place['longitude'] as num?)?.toDouble(),
    address: address,
    city: city,
    neighborhood: place['neighborhood'] as String?,
    rating: (place['rating'] as num?)?.toDouble(),
    ratingCount: place['rating_count'] as int?,
    types: (place['types'] as List<dynamic>?)?.cast<String>(),
    website: place['website'] as String?,
    imageUrl: place['image_url'] as String?,
    reason: place['recommended_reason'] as String?,
    description: place['explanation_long'] as String?,
    socialProof: place['social_proof'] != null
        ? SocialProof.fromJson(place['social_proof'] as Map<String, dynamic>)
        : null,
    relevanceScore: (place['relevance_score'] as num?)?.toDouble(),
  );
}

/// Map one `EventSearchResult` JSON object to an [ItemSuggestion].
/// Returns null when required fields (`event_id`, `name`) are missing.
ItemSuggestion? itemSuggestionFromEventResult(Map<String, dynamic> event) {
  if (event['event_id'] == null || event['name'] == null) return null;

  // Synthesize a single occurrence from `start_at`/`end_at` so the UI can
  // format the datetime in the active locale (the BE `date` string is
  // English-only).
  final startAtRaw = event['start_at'] as String?;
  final occurrences = <EventOccurrence>[];
  if (startAtRaw != null && startAtRaw.isNotEmpty) {
    final startAt = parseBackendDateTime(startAtRaw);
    if (startAt != null) {
      occurrences.add(
        EventOccurrence(
          id: event['event_id'] as String,
          startAt: startAt,
          endAt: parseBackendDateTime(event['end_at'] as String?),
          venueId: event['venue_id'] as String?,
          venueName: event['venue_name'] as String?,
          location: event['location'] as String?,
          timeKnown: event['time_known'] as bool? ?? true,
        ),
      );
    }
  }

  return ItemSuggestion(
    id: event['event_id'] as String,
    name: event['name'] as String,
    type: 'event',
    eventId: event['event_id'] as String,
    url: event['url'] as String?,
    imageUrl: event['image_url'] as String?,
    date: event['date'] as String?,
    description: event['description'] as String?,
    location: event['venue_name'] as String? ?? event['location'] as String?,
    city: event['city'] as String?,
    category: event['category'] as String?,
    categories:
        (event['categories'] as List<dynamic>?)?.cast<String>() ?? const [],
    latitude: (event['latitude'] as num?)?.toDouble(),
    longitude: (event['longitude'] as num?)?.toDouble(),
    occurrences: occurrences,
    socialProof: event['social_proof'] != null
        ? SocialProof.fromJson(event['social_proof'] as Map<String, dynamic>)
        : null,
    relevanceScore: (event['relevance_score'] as num?)?.toDouble(),
    // PROD-3412 (BE-7) — confident recurrence phase on hydrate event cards
    // (ungated). Absent/null/unknown ⇒ no chip.
    recurrencePhase: recurrencePhaseFromWire(event['recurrence_phase']),
  );
}
