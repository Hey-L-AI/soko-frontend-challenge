import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/lists_provider.dart';
import 'yours_following_mode_provider.dart';

/// Calendar month currently visible on the `/lists` hub. Drives the
/// `from_date` / `to_date` window the calendar-events endpoint sends to the
/// BE.
///
/// Defaults to the first of the current month (`DateTime.now()` rounded
/// down). The calendar widget pushes new values when the user clicks the
/// chevron buttons.
final listsHubVisibleMonthProvider = StateProvider<DateTime>((_) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, 1);
});

/// Hub payload: separate map + calendar item lists, both as synthetic
/// `UserListItem`s so the existing `ListMapView` / `ListCalendarView`
/// widgets render them unchanged.
///
/// Synthesized by the adapter helpers in this file from the slim
/// `/map-pins` and `/calendar-events` BE responses. The widgets touch
/// only `latitude`/`longitude`/`title`/`imageUrl`/`category`/`occurrenceDates`
/// / `eventId` / `venueId`, all of which are populated below.
class ListsHubData {
  /// Synthetic place items derived from `/map-pins`. Each carries a sparse
  /// `venue` map populated only with the fields the map widget reads.
  final List<UserListItem> mapItems;

  /// Synthetic event items derived from `/calendar-events`. Each carries
  /// a sparse `event` map with `occurrences` populated for calendar dots
  /// and a single `latitude`/`longitude` at the first occurrence (so the
  /// map can also pin event venues alongside place pins).
  final List<UserListItem> calendarItems;

  /// PROD-2127 — BE signaled the map-pins page is truncated (`total >
  /// offset + items.length`). The FE surfaces a non-blocking notice rather
  /// than auto-paginating on first paint.
  final bool mapHasMore;

  /// PROD-2127 — same for calendar-events.
  final bool calendarHasMore;

  const ListsHubData({
    required this.mapItems,
    required this.calendarItems,
    this.mapHasMore = false,
    this.calendarHasMore = false,
  });
}

/// `/lists` hub state, keyed by [YoursFollowingMode] (PROD-2128). Fetches
/// `/map-pins` and `/calendar-events` in parallel across all of the
/// caller's items (no city filter — PROD-2145), passing `scope=following`
/// when the user is on the "A seguir" tab. The owned mode omits `scope`
/// so the BE defaults to `owned` (back-compat with pre-PROD-2127 callers).
///
/// Re-fetches when [listsHubVisibleMonthProvider] changes. The map
/// response is constant with respect to the month, so a month change
/// technically re-fetches both endpoints — accepted in v1 for simplicity.
/// Splitting into two providers (one per endpoint) is the "out of scope"
/// optimization called out in PROD-1928.
///
/// Tombstones (FE-side):
///   * `recentlyDeletedListIds` (PROD-2084) — applied in both modes.
///   * `recentlyUnfollowedListIds` (PROD-2128) — applied only in
///     [YoursFollowingMode.following] so a freshly-unfollowed list drops
///     from the map+calendar immediately rather than waiting for the BE
///     `/following` carousel to catch up.
final listsHubItemsProvider =
    FutureProvider.family<ListsHubData, YoursFollowingMode>((ref, mode) async {
      final visibleMonth = ref.watch(listsHubVisibleMonthProvider);
      final fromDate = DateTime(visibleMonth.year, visibleMonth.month, 1);
      final toDate = DateTime(visibleMonth.year, visibleMonth.month + 1, 1);

      final listsApi = ref.read(listsApiProvider);

      // PROD-2127 — pass `scope=following` only on the "A seguir" tab. Omit
      // entirely for owned so the BE keeps the existing default (`owned`) —
      // any FE callsite that pre-dates PROD-2127 sees zero behavior change.
      final scope = mode == YoursFollowingMode.following ? 'following' : null;

      // Fire both slim endpoints in parallel. BE caps `limit` at 1000 (pins)
      // and 500 (events). A power-user with many cross-city items can
      // exceed these caps; the response's `has_more` flag drives the FE
      // truncation notice.
      final results = await Future.wait([
        listsApi.getListsMapPins(scope: scope, limit: 1000),
        listsApi.getListsCalendarEvents(
          fromDate: fromDate,
          toDate: toDate,
          scope: scope,
          limit: 500,
        ),
      ]);

      final pinsResponse = results[0] as ListsMapPinsResponse;
      final eventsResponse = results[1] as ListsCalendarEventsResponse;

      // PROD-2084 — read-after-write defense. The caller `_handleDelete`
      // invalidates this provider after a successful DELETE, but `/map-pins`
      // and `/calendar-events` may briefly return items belonging to the
      // just-deleted list under BE write lag. Drop them locally against the
      // central tombstone set; the next refetch will catch up server-side.
      // PROD-2128 — under `scope=following`, also drop items belonging to a
      // just-unfollowed list (the carousel's `visibility` filter doesn't
      // help if the BE write hasn't propagated yet).
      final tombstones = ref.watch(
        listsProvider.select((s) {
          if (mode == YoursFollowingMode.following) {
            return <String>{
              ...s.recentlyDeletedListIds,
              ...s.recentlyUnfollowedListIds,
            };
          }
          return s.recentlyDeletedListIds;
        }),
      );

      final mapItems = pinsResponse.items.map(_pinToSyntheticItem);
      final calendarItems = eventsResponse.items.map(
        calendarEventToSyntheticItem,
      );

      return ListsHubData(
        mapItems: tombstones.isEmpty
            ? mapItems.toList()
            : mapItems.where((i) => !tombstones.contains(i.listId)).toList(),
        calendarItems: tombstones.isEmpty
            ? calendarItems.toList()
            : calendarItems
                  .where((i) => !tombstones.contains(i.listId))
                  .toList(),
        mapHasMore: pinsResponse.hasMore,
        calendarHasMore: eventsResponse.hasMore,
      );
    });

/// Adapter — `ListsMapPin` → sparse synthetic `UserListItem`.
///
/// Populates only the fields `ListMapView` and the item-card widgets
/// actually read: `id`, `listId`, `itemType`, `venueId`, `tip`, and the
/// `venue` / `event` map. `addedAt` is unused for hub rendering — set
/// to epoch to make tests deterministic.
///
/// PROD-1993: `itemType` is read directly from the typed pin field.
/// Falls back to `place` inside `ListsMapPin.fromJson` when the backend
/// payload predates the discriminator.
@visibleForTesting
UserListItem pinToSyntheticItem(ListsMapPin p) => _pinToSyntheticItem(p);

UserListItem _pinToSyntheticItem(ListsMapPin p) {
  final isEvent = p.itemType == SavedItemType.event;
  return UserListItem(
    id: p.itemId,
    listId: p.listId,
    addedById: '',
    itemType: p.itemType,
    venueId: p.venueId,
    tip: p.tip,
    addedAt: _epoch,
    // PROD-3829: carry the facet onto the synthetic item, top-level —
    // deliberately NOT inside the `venue`/`event` map below, which mirrors a
    // wire shape. Null today (no payload sends it); the pin falls back to the
    // generic pink art until PROD-3831 ships it.
    primaryFacet: p.primaryFacet,
    venue: isEvent
        ? null
        : <String, dynamic>{
            'id': p.venueId,
            'name': p.name,
            'latitude': p.lat,
            'longitude': p.lng,
            if (p.imageUrl != null) 'image_url': p.imageUrl,
            if (p.category != null) 'tags': [p.category],
          },
    event: isEvent
        ? <String, dynamic>{
            'title': p.name,
            'latitude': p.lat,
            'longitude': p.lng,
            if (p.imageUrl != null) 'image_url': p.imageUrl,
            if (p.category != null) 'tags': [p.category],
          }
        : null,
  );
}

/// Adapter — `ListsCalendarEvent` → sparse synthetic `UserListItem` (event).
///
/// Populates the `event` map with everything `ListCalendarView` and the
/// map (when calendar items are merged into the map for event-venue pins)
/// need:
///   - `title`, `image_url` for cards
///   - `latitude` / `longitude` at the FIRST occurrence — drives the single
///     map pin per event in v1. Multi-venue pinning for touring events is
///     a deferred follow-up.
///   - `start_datetime` for the legacy `eventDate` getter
///   - `occurrences[]` carrying every `start_at` + per-occurrence venue
///     fields, consumed by `UserListItem.occurrenceDates` to draw every
///     calendar dot.
///
/// Events with empty occurrences fall through with null lat/lng, so
/// `_itemsWithCoordinates` filters them out of the map and they yield no
/// calendar dots.
///
/// Public (not test-only): the /library calendar body reuses it to render
/// the caller's whole saved-event set through the same `ListCalendarView`.
UserListItem calendarEventToSyntheticItem(ListsCalendarEvent e) {
  final first = e.occurrences.isNotEmpty ? e.occurrences.first : null;
  return UserListItem(
    id: e.itemId,
    listId: e.listId,
    addedById: '',
    itemType: SavedItemType.event,
    eventId: e.eventId,
    tip: e.tip,
    addedAt: _epoch,
    // PROD-3829: same as the pin adapter — without this the hub's EVENT pins
    // could never show category art, since they come from `/calendar-events`
    // rather than `/map-pins`.
    primaryFacet: e.primaryFacet,
    event: <String, dynamic>{
      'title': e.title,
      if (e.imageUrl != null) 'image_url': e.imageUrl,
      if (first != null) ...{
        'latitude': first.lat,
        'longitude': first.lng,
        'start_datetime': first.startAt.toIso8601String(),
      },
      'occurrences': e.occurrences
          .map(
            (o) => <String, dynamic>{
              'start_at': o.startAt.toIso8601String(),
              'lat': o.lat,
              'lng': o.lng,
              if (o.venueId != null) 'venue_id': o.venueId,
              if (o.venueName != null) 'venue_name': o.venueName,
              if (o.venueCity != null) 'venue_city': o.venueCity,
            },
          )
          .toList(),
    },
  );
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
