/// Models for the admin-only "Discovery (for you)" shelf (PROD-3927).
///
/// Decodes the `DiscoveryResult` returned by `POST /api/v1/app/discovery`
/// (the PROD-3912 Discovery API). Each `DiscoveryItem` carries a raw `entity`
/// payload (the retrieval result); we pull only the few fields the shelf card
/// renders. Venue and event payloads differ, so field extraction branches on
/// `entity_type`.
library;

/// One ranked card in the "Discovery (for you)" shelf.
class DiscoveryForYouItem {
  /// venue_id / event_id — the tap route needs it.
  final String id;

  /// `'venues'` or `'events'` — selects the card kind + detail route.
  final String entityType;

  /// Display title.
  final String title;

  /// Cover URL. Often null for venues → the card falls back to seeded artwork.
  final String? imageUrl;

  /// Category line: the venue's primary type or the event's category.
  final String? category;

  /// Distance from the search center, km. Null when absent.
  final double? distanceKm;

  /// Event start (events only); null for venues.
  final DateTime? startAt;

  /// Zero-based rank of this item within the served slate (PROD-4257). Set by
  /// the backend on the flat `POST /discovery` result, where wire order ==
  /// ranked order; null when the backend omits it. Rides on the engagement
  /// event so the offline join can attribute conversion per slate position.
  final int? position;

  const DiscoveryForYouItem({
    required this.id,
    required this.entityType,
    required this.title,
    this.imageUrl,
    this.category,
    this.distanceKm,
    this.startAt,
    this.position,
  });

  bool get isEvent => entityType == 'events';

  factory DiscoveryForYouItem.fromJson(Map<String, dynamic> json) {
    final entity =
        (json['entity'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final entityType = (json['entity_type'] as String?) ?? 'venues';

    // Category: events carry a scalar `category`; venues carry `types[0]`
    // (the primary type, per ADR-043).
    String? category;
    if (entityType == 'events') {
      category = entity['category'] as String?;
    } else {
      final types = entity['types'];
      if (types is List && types.isNotEmpty) {
        category = types.first?.toString();
      }
    }

    final rawStart = entity['start_at'];

    return DiscoveryForYouItem(
      id: (json['id'] ?? entity['id'] ?? entity['venue_id'] ?? '').toString(),
      entityType: entityType,
      title: (json['title'] ?? entity['title'] ?? entity['name'] ?? '')
          .toString(),
      imageUrl: entity['image_url'] as String?,
      category: category,
      distanceKm: (entity['distance_km'] as num?)?.toDouble(),
      startAt: rawStart is String ? DateTime.tryParse(rawStart) : null,
      position: (json['position'] as num?)?.toInt(),
    );
  }
}

/// Response wrapper for `POST /api/v1/app/discovery`. The debug block (present
/// only with `debug=true`, which the shelf never sends) is ignored.
class DiscoveryForYouResponse {
  final List<DiscoveryForYouItem> items;

  /// True when ranked candidates exist beyond `offset + num_results`, i.e. a
  /// further page can be fetched by increasing `offset` (added with discovery
  /// offset pagination). Defaults to `false` so a backend that predates the
  /// pagination change degrades to a single, non-paging page.
  final bool hasMore;

  /// The served slate's `discovery_runs` id (PROD-4257). Reliable on this flat
  /// `POST /discovery` result (unlike the block-composed home feed). Null when
  /// run logging is off; forward only when present.
  final String? runId;

  const DiscoveryForYouResponse({
    required this.items,
    this.hasMore = false,
    this.runId,
  });

  factory DiscoveryForYouResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return DiscoveryForYouResponse(
      items: rawItems
          .map(
            (e) => DiscoveryForYouItem.fromJson(
              (e as Map).cast<String, dynamic>(),
            ),
          )
          // Drop id-less items — the card tap needs a real id.
          .where((item) => item.id.isNotEmpty)
          .toList(),
      hasMore: json['has_more'] as bool? ?? false,
      runId: json['run_id'] as String?,
    );
  }
}
