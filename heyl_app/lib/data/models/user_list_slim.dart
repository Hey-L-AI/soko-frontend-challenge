/// Slim payloads for the list-page endpoints introduced in PROD-1966/1967.
///
/// `UserListItemSlim` mirrors `UserListItemOut` but drops the embedded
/// `venue` / `event` blobs in favour of pre-resolved flat fields — see
/// PROD-1966 for the contract. `SlimMapPin` is the server-deduped pin
/// shape returned alongside the items (one pin per unique venue across
/// the response, used by the cover map).
///
/// These models are the canonical shape of the list-page item set; the
/// older heavy [UserListItem] in `user_list.dart` is retained for code
/// paths that still hit `/items` (single-list detail flows, hub).
library;

import '../../core/utils/datetime_parsing.dart';
import 'map_pin.dart' show FacetPair;
import 'saved_item.dart' show SavedItemType;
import 'user_list.dart' show UserListItem;

class UserListItemSlim {
  final String id;
  final String listId;
  final SavedItemType itemType;
  final String? eventId;
  final String? venueId;
  final int sortOrder;
  final String? tip;
  final DateTime addedAt;
  final bool isCover;

  final String title;
  final String? descriptionShort;
  final String? imageUrl;
  final String? category;

  /// Second taxonomy level (`sub_categories[0]`), localized — the specific
  /// type shown beneath [category] (e.g. "Festival" under "Culture"). For
  /// place items this is the venue subcategory label. Null when the entity
  /// has no sub-category. Added by PROD-4115.
  final String? subcategory;

  /// Already-formatted, already-localized price string for event items
  /// (e.g. "Grátis", "10–20 €"). Render verbatim; never re-derive. Null for
  /// place items and unpriced events. Added by PROD-4115.
  final String? priceLabel;

  final double? latitude;
  final double? longitude;
  final String? address;
  final String? city;

  /// Neighbourhood (finer than [city]), free-text — same source as the
  /// discovery feed. For places it is the venue's neighbourhood; for events it
  /// comes from the next occurrence's linked venue (null for external events).
  /// The location row renders venue_name → neighbourhood → city for events,
  /// and neighbourhood → city for places. Added by PROD-4115.
  final String? neighborhood;

  /// Venue display name for event items: the next occurrence's linked venue
  /// name, falling back to the occurrence `location_label` for external
  /// events. Lets the list surface the venue instead of the city. Null when
  /// the occurrence has neither a linked venue nor a label, and null for
  /// place items ([title] is already the venue name). Added by PROD-4115.
  final String? venueName;

  /// Earliest *future* `start_at` for event items (falls back to the
  /// earliest past `start_at` when the event has no future occurrences).
  /// Null for venue items.
  final DateTime? nextOccurrenceAt;

  /// Count of future occurrences strictly after [nextOccurrenceAt]. `0`
  /// for a single-future event; `N-1` for an event with `N` future
  /// occurrences; `0` for a past-only event. Null for venue items.
  final int? futureOccurrencesCount;

  /// Every `start_at` (future + past), sorted ASC. Used by the calendar
  /// to mark dates. Null for venue items.
  final List<DateTime>? occurrenceDates;

  /// Note author — the user who added this item (and so authored its [tip]),
  /// as `{id, full_name, avatar_url}`. Mirrors `UserListItemOut.added_by`.
  /// Threaded into the heavy [UserListItem] by [slimItemToHeavy] so the
  /// list-page note callout can render the author's `PersonDot`. Null when
  /// the backend didn't expand it (legacy / unattributed rows).
  final Map<String, dynamic>? addedBy;

  /// Author id / display name / photo, read off [addedBy] — mirror the
  /// getters on the heavy [UserListItem] so slim callers have the same API.
  String? get addedById => (addedBy?['id'] as String?)?.trim();
  String? get addedByName => (addedBy?['full_name'] as String?)?.trim();
  String? get addedByAvatarUrl => (addedBy?['avatar_url'] as String?)?.trim();

  const UserListItemSlim({
    required this.id,
    required this.listId,
    required this.itemType,
    this.eventId,
    this.venueId,
    this.sortOrder = 0,
    this.tip,
    required this.addedAt,
    this.isCover = false,
    required this.title,
    this.descriptionShort,
    this.imageUrl,
    this.category,
    this.subcategory,
    this.priceLabel,
    this.latitude,
    this.longitude,
    this.address,
    this.city,
    this.neighborhood,
    this.venueName,
    this.nextOccurrenceAt,
    this.futureOccurrencesCount,
    this.occurrenceDates,
    this.addedBy,
  });

  /// Convenience: a single date for calendar callers that only need the
  /// earliest occurrence (mirrors `UserListItem.eventDate`). Null on
  /// venue items.
  DateTime? get eventDate => nextOccurrenceAt;

  /// Numeric target id for navigation (event_id for events, venue_id for
  /// places). Empty string when the underlying entity hasn't resolved
  /// (shouldn't happen in BE-sourced data but keeps callers null-safe).
  String get targetId =>
      itemType == SavedItemType.event ? (eventId ?? '') : (venueId ?? '');

  /// Google Place ID lookup — slim payload doesn't carry it (the standalone
  /// detail page fetches the full venue). Returns null so callers fall
  /// through to id-based matching.
  String? get googlePlaceId => null;

  factory UserListItemSlim.fromJson(Map<String, dynamic> json) {
    return UserListItemSlim(
      id: json['id'] as String,
      listId: json['list_id'] as String,
      itemType: SavedItemType.fromJson(json['item_type'] as String? ?? 'event'),
      eventId: json['event_id'] as String?,
      venueId: json['venue_id'] as String?,
      sortOrder: json['sort_order'] as int? ?? 0,
      tip: json['tip'] as String?,
      addedAt: DateTime.parse(json['added_at'] as String),
      isCover: json['is_cover'] as bool? ?? false,
      title: json['title'] as String? ?? '',
      descriptionShort: json['description_short'] as String?,
      imageUrl: json['image_url'] as String?,
      category: json['category'] as String?,
      subcategory: json['subcategory'] as String?,
      priceLabel: json['price_label'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      address: json['address'] as String?,
      city: json['city'] as String?,
      neighborhood: json['neighborhood'] as String?,
      venueName: json['venue_name'] as String?,
      nextOccurrenceAt: _parseDate(json['next_occurrence_at']),
      futureOccurrencesCount: json['future_occurrences_count'] as int?,
      occurrenceDates: _parseDateList(json['occurrence_dates']),
      addedBy: json['added_by'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'list_id': listId,
      'item_type': itemType.toJson(),
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      'sort_order': sortOrder,
      if (tip != null) 'tip': tip,
      'added_at': addedAt.toIso8601String(),
      'is_cover': isCover,
      'title': title,
      if (descriptionShort != null) 'description_short': descriptionShort,
      if (imageUrl != null) 'image_url': imageUrl,
      if (category != null) 'category': category,
      if (subcategory != null) 'subcategory': subcategory,
      if (priceLabel != null) 'price_label': priceLabel,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (address != null) 'address': address,
      if (city != null) 'city': city,
      if (neighborhood != null) 'neighborhood': neighborhood,
      if (venueName != null) 'venue_name': venueName,
      if (nextOccurrenceAt != null)
        'next_occurrence_at': nextOccurrenceAt!.toIso8601String(),
      if (futureOccurrencesCount != null)
        'future_occurrences_count': futureOccurrencesCount,
      if (occurrenceDates != null)
        'occurrence_dates': occurrenceDates!
            .map((d) => d.toIso8601String())
            .toList(),
      if (addedBy != null) 'added_by': addedBy,
    };
  }

  UserListItemSlim copyWith({
    String? id,
    String? listId,
    SavedItemType? itemType,
    String? eventId,
    String? venueId,
    int? sortOrder,
    String? tip,
    bool clearTip = false,
    DateTime? addedAt,
    bool? isCover,
    String? title,
    String? descriptionShort,
    String? imageUrl,
    String? category,
    String? subcategory,
    String? priceLabel,
    double? latitude,
    double? longitude,
    String? address,
    String? city,
    String? neighborhood,
    String? venueName,
    DateTime? nextOccurrenceAt,
    int? futureOccurrencesCount,
    List<DateTime>? occurrenceDates,
    Map<String, dynamic>? addedBy,
  }) {
    return UserListItemSlim(
      id: id ?? this.id,
      listId: listId ?? this.listId,
      itemType: itemType ?? this.itemType,
      eventId: eventId ?? this.eventId,
      venueId: venueId ?? this.venueId,
      sortOrder: sortOrder ?? this.sortOrder,
      tip: clearTip ? null : (tip ?? this.tip),
      addedAt: addedAt ?? this.addedAt,
      isCover: isCover ?? this.isCover,
      title: title ?? this.title,
      descriptionShort: descriptionShort ?? this.descriptionShort,
      imageUrl: imageUrl ?? this.imageUrl,
      category: category ?? this.category,
      subcategory: subcategory ?? this.subcategory,
      priceLabel: priceLabel ?? this.priceLabel,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      address: address ?? this.address,
      city: city ?? this.city,
      neighborhood: neighborhood ?? this.neighborhood,
      venueName: venueName ?? this.venueName,
      nextOccurrenceAt: nextOccurrenceAt ?? this.nextOccurrenceAt,
      futureOccurrencesCount:
          futureOccurrencesCount ?? this.futureOccurrencesCount,
      occurrenceDates: occurrenceDates ?? this.occurrenceDates,
      addedBy: addedBy ?? this.addedBy,
    );
  }
}

/// Server-deduped map pin. One per unique venue across the items of a
/// single list (computed over the full filtered set, not the current
/// page). [itemId] is the earliest-added `user_list_items.id` pointing at
/// this venue — used to jump the zine pager to the matching item page on
/// tap. [venueId] is null for external events that resolve to coordinates
/// without a venue row.
class SlimMapPin {
  final String itemId;

  /// PROD-1993: typed discriminator returned by the backend. When
  /// missing (older payloads, or new payload still propagating to
  /// staging), we fall back to the `venueId == null` heuristic in
  /// `fromJson` so the cover map stays correct during the rollout.
  final SavedItemType itemType;
  final String? venueId;
  final double latitude;
  final double longitude;
  final String name;
  final String? imageUrl;
  final String? category;

  /// PROD-3829 — the item's primary discovery facet, when the backend sends
  /// one. Selects the map pin's teardrop art via `mapPinKey(primaryFacet:)`.
  ///
  /// **Forward-compatible parse: no payload carries this field yet.** Absent
  /// / null / `{}` all resolve to null (`FacetPair.fromJson` returns null for
  /// a missing or parentless object), and a null facet renders the generic
  /// pink `pin-default`. The day an endpoint starts sending it, the category
  /// art appears on the next payload with **no app release** — which is the
  /// whole point of parsing it before it exists (PROD-3831/3832 ship it
  /// server-side).
  ///
  /// ⚠️ NEVER synthesise this from `category`, `tags` or `place_types`. The
  /// id↔category expansion is deliberately server-side (PROD-2369) so a
  /// stale client can't drift from it. A null facet stays null.
  final FacetPair? primaryFacet;

  const SlimMapPin({
    required this.itemId,
    required this.itemType,
    this.venueId,
    required this.latitude,
    required this.longitude,
    required this.name,
    this.imageUrl,
    this.category,
    this.primaryFacet,
  });

  factory SlimMapPin.fromJson(Map<String, dynamic> json) {
    final rawItemType = json['item_type'] as String?;
    final venueIdRaw = json['venue_id'] as String?;
    final itemType = rawItemType != null
        ? SavedItemType.fromJson(rawItemType)
        : (venueIdRaw == null ? SavedItemType.event : SavedItemType.place);
    return SlimMapPin(
      itemId: json['item_id'] as String,
      itemType: itemType,
      venueId: venueIdRaw,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      name: json['name'] as String? ?? '',
      imageUrl: json['image_url'] as String?,
      category: json['category'] as String?,
      primaryFacet: FacetPair.readFrom(json),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'item_id': itemId,
      'item_type': itemType.toJson(),
      if (venueId != null) 'venue_id': venueId,
      'latitude': latitude,
      'longitude': longitude,
      'name': name,
      if (imageUrl != null) 'image_url': imageUrl,
      if (category != null) 'category': category,
      if (primaryFacet != null) 'primary_facet': primaryFacet!.toJson(),
    };
  }
}

/// Response envelope for `listItemsSlim` / `listPublicListItemsSlim`.
/// [mapPins] is the full whole-list deduped pin set on every response
/// (pagination shape A per PROD-1966); [items] paginates via limit/offset
/// and [total] reflects the count of items matching the filter.
class UserListItemsSlimOut {
  final List<UserListItemSlim> items;
  final List<SlimMapPin> mapPins;
  final int total;

  const UserListItemsSlimOut({
    required this.items,
    required this.mapPins,
    required this.total,
  });

  factory UserListItemsSlimOut.fromJson(Map<String, dynamic> json) {
    return UserListItemsSlimOut(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => UserListItemSlim.fromJson(e as Map<String, dynamic>))
          .toList(),
      mapPins: (json['map_pins'] as List<dynamic>? ?? const [])
          .map((e) => SlimMapPin.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
    );
  }
}

/// Adapter — slim list item → sparse synthetic `UserListItem`.
///
/// Populates only the fields the existing list-page widgets read off
/// [UserListItem] (title/image/category, geo, addresses, event date(s),
/// `description_short`, `tip`, `is_cover`). The richer fields the heavy
/// payload carried (`opening_hours`, full `description`, ratings, phone,
/// per-occurrence venue rows, ...) are intentionally absent — they were
/// only needed by code paths that have moved to the standalone in-list
/// detail page, which fetches its own data.
///
/// The note author is threaded through from the slim [UserListItemSlim.addedBy]
/// blob (`{id, full_name, avatar_url}`) so the list-page note callout can
/// render the author's `PersonDot`. When the slim payload carries no
/// `added_by` (legacy / unattributed rows), [addedBy] stays null and the
/// explicit [addedById] override (default empty) is used — downstream list
/// filters key off ownership of the *list*, not the individual item, so an
/// empty id is safe there.
UserListItem slimItemToHeavy(UserListItemSlim s, {String addedById = ''}) {
  final isEvent = s.itemType == SavedItemType.event;
  Map<String, dynamic>? event;
  Map<String, dynamic>? venue;

  if (isEvent) {
    event = <String, dynamic>{
      'title': s.title,
      if (s.descriptionShort != null) 'description_short': s.descriptionShort,
      if (s.imageUrl != null) 'image_url': s.imageUrl,
      if (s.category != null) 'category': s.category,
      // PROD-4115 — read by _DetailsGrid via UserListItem.subcategory /
      // .priceLabel / event['venue_name'].
      if (s.subcategory != null) 'subcategory': s.subcategory,
      if (s.priceLabel != null) 'price_label': s.priceLabel,
      if (s.venueName != null) 'venue_name': s.venueName,
      if (s.neighborhood != null) 'neighborhood': s.neighborhood,
      if (s.latitude != null) 'latitude': s.latitude,
      if (s.longitude != null) 'longitude': s.longitude,
      if (s.address != null) 'venue_address': s.address,
      if (s.city != null) 'venue_city': s.city,
      if (s.nextOccurrenceAt != null)
        'start_datetime': s.nextOccurrenceAt!.toIso8601String(),
      if (s.occurrenceDates != null && s.occurrenceDates!.isNotEmpty)
        'occurrences': [
          for (final d in s.occurrenceDates!)
            <String, dynamic>{'start_at': d.toIso8601String()},
        ],
    };
  } else {
    venue = <String, dynamic>{
      'name': s.title,
      if (s.descriptionShort != null) 'description_short': s.descriptionShort,
      if (s.imageUrl != null) 'image_url': s.imageUrl,
      if (s.category != null) 'tags': <String>[s.category!],
      // PROD-4115 — UserListItem.subcategory / .neighbourhood fall back to the
      // venue map for place items.
      if (s.subcategory != null) 'subcategory': s.subcategory,
      if (s.neighborhood != null) 'neighborhood': s.neighborhood,
      if (s.latitude != null) 'latitude': s.latitude,
      if (s.longitude != null) 'longitude': s.longitude,
      if (s.address != null) 'address': s.address,
      if (s.city != null) 'city': s.city,
    };
  }

  return UserListItem(
    id: s.id,
    // Prefer the id carried in the slim `added_by` blob; fall back to the
    // explicit override (empty by default) for unattributed rows.
    addedById: s.addedById ?? addedById,
    listId: s.listId,
    itemType: s.itemType,
    eventId: s.eventId,
    venueId: s.venueId,
    tip: s.tip,
    sortOrder: s.sortOrder,
    addedAt: s.addedAt,
    isCover: s.isCover,
    event: event,
    venue: venue,
    addedBy: s.addedBy,
  );
}

/// Adapter — slim map pin → sparse synthetic `UserListItem`.
///
/// Mirrors `pinToSyntheticItem` in `lists_hub_items_provider.dart`, but
/// uses the slim pin's `latitude`/`longitude` field names instead of the
/// hub's `lat`/`lng`. Used to feed [SlimMapPin]s into [ListMapView],
/// which accepts heavy `UserListItem`s.
///
/// PROD-1993: `itemType` is read directly from the typed pin field. The
/// previous `venueId == null` heuristic mis-coloured venue-backed events
/// (events whose next occurrence had a linked venue). `SlimMapPin.fromJson`
/// still falls back to that heuristic when the backend payload predates
/// PROD-1993 — kept for safe staged rollout.
UserListItem slimMapPinToHeavy(SlimMapPin pin, String listId) {
  final isEvent = pin.itemType == SavedItemType.event;
  return UserListItem(
    id: pin.itemId,
    listId: listId,
    addedById: '',
    itemType: pin.itemType,
    venueId: pin.venueId,
    addedAt: _epoch,
    // PROD-3829: carry the facet onto the synthetic item, top-level. Without
    // this the parse would be dead weight — every list map is fed by these
    // synthetic items, never by a real `UserListItemOut`.
    primaryFacet: pin.primaryFacet,
    venue: isEvent
        ? null
        : <String, dynamic>{
            if (pin.venueId != null) 'id': pin.venueId,
            'name': pin.name,
            'latitude': pin.latitude,
            'longitude': pin.longitude,
            if (pin.imageUrl != null) 'image_url': pin.imageUrl,
            if (pin.category != null) 'tags': <String>[pin.category!],
          },
    event: isEvent
        ? <String, dynamic>{
            'title': pin.name,
            'latitude': pin.latitude,
            'longitude': pin.longitude,
            if (pin.imageUrl != null) 'image_url': pin.imageUrl,
            if (pin.category != null) 'tags': <String>[pin.category!],
          }
        : null,
  );
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

DateTime? _parseDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return parseBackendDateTime(raw);
}

List<DateTime>? _parseDateList(Object? raw) {
  if (raw is! List) return null;
  final out = <DateTime>[];
  for (final entry in raw) {
    final parsed = _parseDate(entry);
    if (parsed != null) out.add(parsed);
  }
  return out;
}
