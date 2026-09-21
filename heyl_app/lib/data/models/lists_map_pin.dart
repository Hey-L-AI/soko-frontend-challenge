import 'map_pin.dart' show FacetPair;
import 'saved_item.dart' show SavedItemType;

/// One saved item (place or event) — slim payload returned by
/// `listMyMapPins` (`GET /api/v1/app/users/me/lists/map-pins`).
///
/// Replaces the place rows of the old `listMyListsItems` aggregate.
/// Carries the parent list's `listName` + `listSlug` so the hub can label
/// drawer cards and deep-link without a second fetch.
class ListsMapPin {
  final String itemId;

  /// PROD-1993: typed discriminator from the backend. Defaults to
  /// `place` when missing (older payloads / staged rollout) to
  /// preserve the previous behavior — hub historically returned
  /// places only.
  final SavedItemType itemType;
  final String listId;
  final String listName;
  final String listSlug;
  final String venueId;
  final String name;
  final double lat;
  final double lng;
  final String? imageUrl;
  final String? category;
  final String? tip;

  /// PROD-3829 — the item's primary discovery facet, when the backend sends
  /// one. Selects the map pin's teardrop art via `mapPinKey(primaryFacet:)`.
  ///
  /// **Forward-compatible parse: no payload carries this field yet.** Absent
  /// / null / `{}` all resolve to null, and a null facet renders the generic
  /// pink `pin-default`. The day the backend starts sending it, the category
  /// art appears on the next payload with **no app release** (PROD-3831/3832).
  ///
  /// ⚠️ NEVER synthesise this from `category` — on this model `category` is a
  /// loose string and is **not** a facet. The id↔category expansion is
  /// deliberately server-side (PROD-2369).
  final FacetPair? primaryFacet;

  const ListsMapPin({
    required this.itemId,
    required this.itemType,
    required this.listId,
    required this.listName,
    required this.listSlug,
    required this.venueId,
    required this.name,
    required this.lat,
    required this.lng,
    this.imageUrl,
    this.category,
    this.tip,
    this.primaryFacet,
  });

  factory ListsMapPin.fromJson(Map<String, dynamic> json) {
    final rawItemType = json['item_type'] as String?;
    return ListsMapPin(
      itemId: json['item_id'] as String,
      itemType: rawItemType != null
          ? SavedItemType.fromJson(rawItemType)
          : SavedItemType.place,
      listId: json['list_id'] as String,
      listName: json['list_name'] as String,
      listSlug: json['list_slug'] as String,
      venueId: json['venue_id'] as String,
      name: json['name'] as String,
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      imageUrl: json['image_url'] as String?,
      category: json['category'] as String?,
      tip: json['tip'] as String?,
      primaryFacet: FacetPair.readFrom(json),
    );
  }
}

/// Response envelope for `listMyMapPins`. `total` is the count of pins
/// matching the filter independent of pagination — useful for "+N more"
/// indicators without a second fetch. `hasMore` (PROD-2127) is true when
/// `total > offset + items.length`; the FE surfaces a truncation notice
/// rather than auto-paginating on first paint.
class ListsMapPinsResponse {
  final List<ListsMapPin> items;
  final int total;
  final bool hasMore;

  const ListsMapPinsResponse({
    required this.items,
    required this.total,
    this.hasMore = false,
  });

  factory ListsMapPinsResponse.fromJson(Map<String, dynamic> json) {
    return ListsMapPinsResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => ListsMapPin.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}
