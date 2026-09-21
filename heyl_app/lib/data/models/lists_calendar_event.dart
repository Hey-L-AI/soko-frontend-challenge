import '../../core/utils/datetime_parsing.dart';
import 'map_pin.dart' show FacetPair;

/// One qualifying occurrence inside the requested date window. Future-only
/// and within ~25 km of the resolved city centroid. Coordinates fall back to
/// the occurrence's own `lat`/`lng` when no linked venue exists (external
/// events), so the FE can pin every distinct `(lat, lng)` on the map.
class ListsCalendarOccurrence {
  final DateTime startAt;
  final String? venueId;
  final String? venueName;
  final String? venueCity;
  final double lat;
  final double lng;

  const ListsCalendarOccurrence({
    required this.startAt,
    required this.lat,
    required this.lng,
    this.venueId,
    this.venueName,
    this.venueCity,
  });

  factory ListsCalendarOccurrence.fromJson(Map<String, dynamic> json) {
    return ListsCalendarOccurrence(
      startAt: parseBackendDateTimeRequired(json['start_at'] as String),
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      venueId: json['venue_id'] as String?,
      venueName: json['venue_name'] as String?,
      venueCity: json['venue_city'] as String?,
    );
  }
}

/// One saved event — slim payload returned by `listMyCalendarEvents`
/// (`GET /api/v1/app/users/me/lists/calendar-events`). Replaces the event
/// rows of the old `listMyListsItems` aggregate.
///
/// `occurrences` is sorted ASC by `startAt` and capped at 50 per event
/// server-side (far-future tail dropped first).
class ListsCalendarEvent {
  final String itemId;
  final String listId;
  final String listName;
  final String listSlug;
  final String eventId;
  final String title;
  final String? imageUrl;
  final String? tip;
  final List<ListsCalendarOccurrence> occurrences;

  /// PROD-3829 — the item's primary discovery facet, when the backend sends
  /// one. Selects the map pin's teardrop art via `mapPinKey(primaryFacet:)`.
  ///
  /// **Forward-compatible parse: no payload carries this field yet.** Absent
  /// / null / `{}` all resolve to null, and a null facet renders the generic
  /// pink `pin-default`. The day the backend starts sending it, the category
  /// art appears on the next payload with **no app release** (PROD-3831/3832).
  ///
  /// ⚠️ NEVER synthesise this from tags or categories — that expansion is
  /// deliberately server-side (PROD-2369).
  final FacetPair? primaryFacet;

  const ListsCalendarEvent({
    required this.itemId,
    required this.listId,
    required this.listName,
    required this.listSlug,
    required this.eventId,
    required this.title,
    required this.occurrences,
    this.imageUrl,
    this.tip,
    this.primaryFacet,
  });

  factory ListsCalendarEvent.fromJson(Map<String, dynamic> json) {
    return ListsCalendarEvent(
      itemId: json['item_id'] as String,
      listId: json['list_id'] as String,
      listName: json['list_name'] as String,
      listSlug: json['list_slug'] as String,
      eventId: json['event_id'] as String,
      title: json['title'] as String,
      imageUrl: json['image_url'] as String?,
      tip: json['tip'] as String?,
      primaryFacet: FacetPair.readFrom(json),
      occurrences: (json['occurrences'] as List<dynamic>)
          .map(
            (e) => ListsCalendarOccurrence.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

/// Response envelope for `listMyCalendarEvents`. `hasMore` (PROD-2127) is
/// true when `total > offset + items.length`; the FE surfaces a truncation
/// notice rather than auto-paginating on first paint.
class ListsCalendarEventsResponse {
  final List<ListsCalendarEvent> items;
  final int total;
  final bool hasMore;

  const ListsCalendarEventsResponse({
    required this.items,
    required this.total,
    this.hasMore = false,
  });

  factory ListsCalendarEventsResponse.fromJson(Map<String, dynamic> json) {
    return ListsCalendarEventsResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => ListsCalendarEvent.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}
