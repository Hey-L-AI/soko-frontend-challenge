import '../../../data/models/chat_message.dart';
import '../../../data/models/event_occurrence.dart';
import '../../../data/models/social_proof.dart';

/// Build an [ItemSuggestion] view-model from a freshly-fetched
/// [EventDetailResponse2] + the legacy occurrence list. The add-to-list
/// and detail-sheet APIs key off this shape, so we mirror it whenever the
/// redesigned page hands data to those flows.
ItemSuggestion eventAsItemSuggestion(
  EventDetailResponse2 event, {
  List<EventOccurrence> occurrences = const [],
}) {
  // Earliest future occurrence start (already sorted upstream); fall back to
  // the modern detail's `startDatetime` when occurrences are empty.
  final firstOccurrenceStart = occurrences.isNotEmpty
      ? occurrences.first.startAt.toIso8601String()
      : event.startDatetime;

  return ItemSuggestion(
    id: event.id,
    name: event.title,
    type: 'event',
    eventId: event.id,
    venueId: event.venueId,
    imageUrl: event.imageUrl,
    description: event.descriptionLong,
    url: event.url,
    location: event.venueName,
    city: event.venueCity,
    category: event.category,
    latitude: event.latitude,
    longitude: event.longitude,
    address: event.venueAddress,
    date: firstOccurrenceStart,
    occurrences: occurrences,
    occurrenceCount: occurrences.length,
    socialProof: event.socialProof,
    // PROD-3829: forward the facet so a save started from the event detail
    // page carries it into the optimistic list item.
    primaryFacet: event.primaryFacet,
  );
}
