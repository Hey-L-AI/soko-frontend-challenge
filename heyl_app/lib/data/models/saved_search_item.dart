import 'saved_item.dart';

/// One list-membership of a deduplicated saved-items entity row
/// (`SavedSearchItemListRef` on the wire, PROD-1936). `/saved-items`
/// returns one row per unique entity; each membership of that entity
/// across the caller's lists appears here so the FE can render
/// attribution conditionally — the list name when N=1, "Saved in N
/// zines" when N>1.
class SavedSearchItemListRef {
  /// `user_list_items.id` for this specific membership. One per
  /// membership; different memberships of the same entity have
  /// different `itemId` values.
  final String itemId;

  final String listId;
  final String listName;
  final String listSlug;

  /// Per-list user note. Different lists can hold different notes for
  /// the same entity, so this is per-membership rather than
  /// entity-scoped.
  final String? tip;

  const SavedSearchItemListRef({
    required this.itemId,
    required this.listId,
    required this.listName,
    required this.listSlug,
    this.tip,
  });

  factory SavedSearchItemListRef.fromJson(Map<String, dynamic> json) {
    return SavedSearchItemListRef(
      itemId: json['item_id'] as String,
      listId: json['list_id'] as String,
      listName: json['list_name'] as String,
      listSlug: json['list_slug'] as String,
      tip: json['tip'] as String?,
    );
  }
}

/// One row returned by `listMySavedItems` (PROD-1934/PROD-1936) —
/// `GET /api/v1/app/users/me/lists/saved-items`.
///
/// Each row is **one unique entity** (event or venue). When the same
/// entity is saved in N of the caller's lists, the N memberships
/// collapse into a single row and are exposed via [listRefs] (length
/// always ≥ 1, guaranteed by the BE).
///
/// Named `SavedSearchItem` (not `SavedItem`) to disambiguate from the
/// existing `SavedItem` model used elsewhere in the app. The wire shape
/// is `SavedSearchItemOut`.
class SavedSearchItem {
  final SavedItemType itemType;

  /// Set when [itemType] is `event`. The dedup key for events. Use as
  /// the path segment for `/events/<id>` deep links.
  final String? eventId;

  /// Set when [itemType] is `place`. The dedup key for places. Use as
  /// the path segment for `/venues/<id>` deep links.
  final String? venueId;

  /// `event.title` or `venue.name`. Drives the card name. Entity-scoped
  /// — identical regardless of which membership represented the entity.
  final String name;

  /// Proxied image URL (CORS-safe). Entity-scoped. Null when neither
  /// the event nor venue has an image.
  final String? imageUrl;

  /// Server-driven card subtitle. Entity-scoped. Events: first future
  /// occurrence's `venue.name` (fallback `venue.city`). Places:
  /// `venue.type` (fallback `venue.types[0]`, then `venue.city`).
  final String? subtitle;

  /// One entry per membership of this entity across the caller's
  /// lists. Always non-empty (BE guarantees `minItems: 1`). Ordered
  /// `added_at` DESC, then `list_name` ASC for ties — so
  /// `listRefs.first` is the most recently saved membership.
  final List<SavedSearchItemListRef> listRefs;

  const SavedSearchItem({
    required this.itemType,
    required this.name,
    required this.listRefs,
    this.eventId,
    this.venueId,
    this.imageUrl,
    this.subtitle,
  });

  /// Stable identifier for [Key] equality on the card. Uses the entity
  /// id (`event_id` for events, `venue_id` for places) so swap
  /// animations work across re-fetches. Pre-PROD-1936 used
  /// `user_list_items.id`, but that no longer makes sense at the row
  /// level — multiple memberships now collapse into one row, and the
  /// per-membership `itemId` lives on [listRefs] entries.
  String get rowKey {
    final id = eventId ?? venueId;
    return '${itemType.toJson()}-${id ?? listRefs.first.itemId}';
  }

  factory SavedSearchItem.fromJson(Map<String, dynamic> json) {
    return SavedSearchItem(
      itemType: SavedItemType.fromJson(json['item_type'] as String),
      eventId: json['event_id'] as String?,
      venueId: json['venue_id'] as String?,
      name: json['name'] as String,
      imageUrl: json['image_url'] as String?,
      subtitle: json['subtitle'] as String?,
      listRefs: (json['list_refs'] as List<dynamic>)
          .map((e) =>
              SavedSearchItemListRef.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Response envelope for `listMySavedItems`. `total` is the count of
/// **unique entities** matching the search filter (post-PROD-1936
/// dedupe), independent of pagination — useful for "+N more"
/// indicators without a second fetch.
class SavedSearchItemsResponse {
  final List<SavedSearchItem> items;
  final int total;

  const SavedSearchItemsResponse({required this.items, required this.total});

  factory SavedSearchItemsResponse.fromJson(Map<String, dynamic> json) {
    return SavedSearchItemsResponse(
      items: (json['items'] as List<dynamic>)
          .map((e) => SavedSearchItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
    );
  }
}
