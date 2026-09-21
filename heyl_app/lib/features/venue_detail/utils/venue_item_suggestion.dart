import '../../../data/models/chat_message.dart';
import '../../../data/models/social_proof.dart';

/// Build a [ItemSuggestion] view-model from a freshly-fetched
/// [VenueDetailResponse]. The add-to-list and detail-sheet APIs key off
/// this shape, so we mirror it whenever the redesigned page hands data to
/// those flows.
ItemSuggestion venueAsItemSuggestion(VenueDetailResponse venue) {
  return ItemSuggestion(
    id: venue.id,
    name: venue.name,
    type: 'place',
    venueId: venue.id,
    imageUrl: venue.imageUrl,
    description: venue.descriptionLong,
    address: venue.address,
    city: venue.city,
    latitude: venue.latitude,
    longitude: venue.longitude,
    rating: venue.rating,
    ratingCount: venue.ratingCount,
    tags: venue.tags ?? const [],
    website: venue.website,
    googleMapsUrl: venue.googleMapsUrl,
    googlePlaceId: venue.googlePlaceId,
    phone: venue.phone,
    openingHours: venue.openingHours,
    socialProof: venue.socialProof,
    // PROD-3829: forward the facet so a save started from the venue detail
    // page carries it into the optimistic list item.
    primaryFacet: venue.primaryFacet,
  );
}
