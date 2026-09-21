/// Venues-only Near-You feed models (PROD-1963). Decodes
/// `NearYouPlacesFeedOut` from `GET /api/v1/app/feed/near-you/places`.
/// Powers the "Near you" / "Perto de ti" shelf on the Discovery Page.
library;

/// One venue card in the Near-you (places) shelf. Mirrors `FeedItemVenue`
/// in the OpenAPI spec.
class NearYouVenueItem {
  /// Venue UUID.
  final String id;

  /// Display title.
  final String title;

  /// Cover/thumbnail URL. May be null for sparse data; callers fall back
  /// to a placeholder asset.
  final String? imageUrl;

  /// Distance from the requested coordinate, in kilometres.
  final double distanceKm;

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

  /// Aggregated rating, 0–5. Null when the venue has no rating yet.
  final double? rating;

  const NearYouVenueItem({
    required this.id,
    required this.title,
    required this.distanceKm,
    this.imageUrl,
    this.primaryTag,
    this.rating,
  });

  factory NearYouVenueItem.fromJson(Map<String, dynamic> json) {
    return NearYouVenueItem(
      id: json['id'] as String,
      title: json['title'] as String,
      imageUrl: json['image_url'] as String?,
      distanceKm: (json['distance_km'] as num).toDouble(),
      primaryTag: json['primary_tag'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
    );
  }
}

/// Counts of venues seen-suppression hard-dropped from a feed load. Mirrors
/// `PlacesDropStats`. Absent / zeroed when the caller asked for the raw feed
/// (`personalize=false`). The Near-you places shelf's "show hidden" button
/// reads [within250m].
class PlacesDropStats {
  /// All venues suppression dropped this load, any distance.
  final int total;

  /// Dropped venues within 250 m of the requested coordinate — the salient
  /// count.
  final int within250m;

  const PlacesDropStats({this.total = 0, this.within250m = 0});

  factory PlacesDropStats.fromJson(Map<String, dynamic> json) {
    return PlacesDropStats(
      total: json['total'] as int? ?? 0,
      within250m: json['within_250m'] as int? ?? 0,
    );
  }
}

/// Response wrapper for `/feed/near-you/places`. `total` is the count of
/// candidates within the hard radius cap across all pages; the shelf
/// computes `hasMore` as `loaded.length < total`.
class NearYouPlacesFeedResponse {
  final List<NearYouVenueItem> items;
  final int total;

  /// Seen-suppression drop counts for this load. Null when the BE omitted
  /// the block (older BE, or `personalize=false`).
  final PlacesDropStats? dropped;

  const NearYouPlacesFeedResponse({
    required this.items,
    required this.total,
    this.dropped,
  });

  factory NearYouPlacesFeedResponse.fromJson(Map<String, dynamic> json) {
    return NearYouPlacesFeedResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => NearYouVenueItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      dropped: json['dropped'] == null
          ? null
          : PlacesDropStats.fromJson(json['dropped'] as Map<String, dynamic>),
    );
  }
}
