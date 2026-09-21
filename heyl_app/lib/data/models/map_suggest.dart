/// PROD-3497 — models for `POST /map/suggest` (v2 map search-bar typed
/// suggestions, PROD-3434 umbrella). Contract: PROD-3494.
///
/// Domain-specific fields are RAW DATA (null for other domains) — all
/// user-facing copy (subtitles, labels) is composed and localized
/// client-side per umbrella Decision #42.
library;

import '../../core/utils/datetime_parsing.dart';

/// The three server-suggested domains. Locations are NOT served by
/// `/map/suggest` — the client composes them via `GET /geo/areas`.
enum MapSuggestDomain {
  venues('venues'),
  events('events'),
  lists('lists');

  const MapSuggestDomain(this.wire);

  /// Wire name — also the value used in `failed_domains`.
  final String wire;
}

/// One typed suggestion (venue / event / list — one shape, unused fields
/// null).
class MapSuggestItem {
  const MapSuggestItem({
    required this.type,
    required this.id,
    required this.name,
    required this.score,
    required this.isTopHit,
    this.imageUrl,
    this.latitude,
    this.longitude,
    this.category,
    this.neighborhood,
    this.city,
    this.venueName,
    this.startAt,
    this.timeKnown,
    this.occurrenceId,
    this.ownerHandle,
    this.ownerName,
    this.itemCount,
    this.isOwn,
  });

  /// 'venue' | 'event' | 'list'.
  final String type;

  /// Canonical entity UUID (venue / EVENT / list — events also carry
  /// [occurrenceId], the `/map/pins` pin id).
  final String id;

  final String name;

  /// Proxied thumbnail. Venues: cached image only — null is common, render
  /// a placeholder. Events: event image. Lists: cover.
  final String? imageUrl;

  /// Fly-to coordinates (venues/events; may be null → detail sheet per
  /// Decision #18 — FE‑3 concern).
  final double? latitude;
  final double? longitude;

  /// Venues — lead type SLUG (e.g. `portuguese_restaurant`), localized
  /// client-side the same way card tags are.
  final String? category;
  final String? neighborhood;
  final String? city;

  /// Events — raw fields for the client-composed "when · venue" subtitle.
  /// [timeKnown] false = crawler-defaulted-midnight (app-wide convention).
  final String? venueName;
  final DateTime? startAt;
  final bool? timeKnown;

  /// Events — matched occurrence id (= the `/map/pins` event pin id).
  final String? occurrenceId;

  /// Lists — raw handle (no @ prefix), owner full name, item count.
  final String? ownerHandle;
  final String? ownerName;
  final int? itemCount;

  /// Lists — PROD-3647: true when the viewer OWNS the list, a **strict**
  /// `owner_id` match decided server-side. A COLLABORATIVE list is `false`,
  /// deliberately: the history path resolves the list and compares owner ids,
  /// so both producers of `map_list_opened.ownership` mean exactly the same
  /// thing and the metric stays comparable across `source`. Guests get
  /// `false`. Null for venues and events — the field is lists-only, like
  /// [ownerHandle] / [itemCount].
  final bool? isOwn;

  /// Name-similarity 0-1 from the shared scorer — comparable across
  /// domains. Array order is proximity-biased; never re-sort by score
  /// within a domain (use it only for cross-domain block ordering).
  final double score;

  /// At most one item across the whole response (Decision #38); also kept
  /// first inside its domain block (Decision #39 — render it twice).
  final bool isTopHit;

  // TODO(PROD-3497): identity-field casts retained pending Phase 3
  // `requireString` helper (see docs/platform/error-handling-discipline.md).
  // Drop the `gstack:allow` markers once the helper lands.
  factory MapSuggestItem.fromJson(Map<String, dynamic> json) {
    return MapSuggestItem(
      type:
          json['type']
              as String, // gstack:allow check-error-handling json-cast-string
      id:
          json['id']
              as String, // gstack:allow check-error-handling json-cast-string
      name: (json['name'] as String?) ?? '',
      imageUrl: json['image_url'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      category: json['category'] as String?,
      neighborhood: json['neighborhood'] as String?,
      city: json['city'] as String?,
      venueName: json['venue_name'] as String?,
      startAt: parseBackendDateTime(json['start_at'] as String?),
      timeKnown: json['time_known'] as bool?,
      occurrenceId: json['occurrence_id'] as String?,
      ownerHandle: json['owner_handle'] as String?,
      ownerName: json['owner_name'] as String?,
      itemCount: json['item_count'] as int?,
      isOwn: json['is_own'] as bool?,
      score: (json['score'] as num).toDouble(),
      isTopHit: json['is_top_hit'] as bool? ?? false,
    );
  }
}

/// One domain's bucket: up to 10 admitted matches + whether more exist.
class MapSuggestBucket {
  const MapSuggestBucket({required this.items, required this.hasMore});

  static const empty = MapSuggestBucket(items: [], hasMore: false);

  final List<MapSuggestItem> items;
  final bool hasMore;

  factory MapSuggestBucket.fromJson(Map<String, dynamic>? json) {
    if (json == null) return empty;
    return MapSuggestBucket(
      items: ((json['items'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MapSuggestItem.fromJson)
          .toList(growable: false),
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}

/// `POST /map/suggest` response — three domain buckets + per-domain
/// degradation. Engine trouble never 500s; the affected domain(s) appear
/// in [failedDomains] with empty items (render the quiet retry row).
class MapSuggestResponse {
  const MapSuggestResponse({
    required this.venues,
    required this.events,
    required this.lists,
    required this.failedDomains,
  });

  final MapSuggestBucket venues;
  final MapSuggestBucket events;
  final MapSuggestBucket lists;
  final List<String> failedDomains;

  MapSuggestBucket bucketFor(MapSuggestDomain domain) => switch (domain) {
    MapSuggestDomain.venues => venues,
    MapSuggestDomain.events => events,
    MapSuggestDomain.lists => lists,
  };

  bool domainFailed(MapSuggestDomain domain) =>
      failedDomains.contains(domain.wire);

  factory MapSuggestResponse.fromJson(Map<String, dynamic> json) {
    return MapSuggestResponse(
      venues: MapSuggestBucket.fromJson(
        json['venues'] as Map<String, dynamic>?,
      ),
      events: MapSuggestBucket.fromJson(
        json['events'] as Map<String, dynamic>?,
      ),
      lists: MapSuggestBucket.fromJson(json['lists'] as Map<String, dynamic>?),
      failedDomains: ((json['failed_domains'] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }
}
