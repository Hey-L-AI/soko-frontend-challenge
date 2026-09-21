import 'highlighted_feed.dart' show DiscoveryFeedCity;

/// Venue card returned by `/api/v1/app/feed/venues-with-events` (PROD-1553).
///
/// City-scoped — `distance_km` from the broader `FeedItemBase` schema is
/// intentionally omitted on this card type; proximity is `Perto de ti`'s
/// job. `event_count_15d` and `next_event_start_at` power an optional
/// "5 events this week"-style badge on the FE.
class VenueWithEventsItem {
  final String id;
  final String title;
  final String? imageUrl;

  /// The **localized** venue-type display label ("Restaurante chinês" in
  /// pt-PT, "Chinese restaurant" in en) — NOT a slug. Backend-resolved per
  /// request from the venue's primary type; localized since PROD-2142, and
  /// owned by the backend under ADR-048.
  ///
  /// **Render it exactly as received** — no humanize, no title-case, no
  /// slug→label mapping. The prettifiers that used to wrap this value were
  /// removed in PROD-3978: they were dead slug-handling that would have
  /// masked a raw-slug regression. Same field and same value as
  /// [VenueDetailResponse.primaryTag].
  final String? primaryTag;
  final double? rating;
  final int eventCount15d;
  final DateTime? nextEventStartAt;

  const VenueWithEventsItem({
    required this.id,
    required this.title,
    required this.eventCount15d,
    this.imageUrl,
    this.primaryTag,
    this.rating,
    this.nextEventStartAt,
  });

  factory VenueWithEventsItem.fromJson(Map<String, dynamic> json) {
    return VenueWithEventsItem(
      id: json['id'] as String,
      title: json['title'] as String,
      imageUrl: json['image_url'] as String?,
      primaryTag: json['primary_tag'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      eventCount15d: (json['event_count_15d'] as num?)?.toInt() ?? 0,
      nextEventStartAt: json['next_event_start_at'] != null
          ? DateTime.parse(json['next_event_start_at'] as String)
          : null,
    );
  }
}

/// `/api/v1/app/feed/venues-with-events` response (PROD-1553).
///
/// `total` is qualifying venues for the (city, day) — useful for the
/// "Ver mais" affordance. The FE paginates by passing increasing `offset`.
class VenuesWithEventsFeedResponse {
  final List<VenueWithEventsItem> items;
  final int total;
  final DiscoveryFeedCity city;

  const VenuesWithEventsFeedResponse({
    required this.items,
    required this.total,
    required this.city,
  });

  factory VenuesWithEventsFeedResponse.fromJson(Map<String, dynamic> json) {
    return VenuesWithEventsFeedResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => VenueWithEventsItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: (json['total'] as num?)?.toInt() ?? 0,
      city: DiscoveryFeedCity.fromJson(json['city'] as Map<String, dynamic>),
    );
  }
}
