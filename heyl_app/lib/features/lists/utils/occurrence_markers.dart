import 'package:flutter/material.dart';

import '../../../core/utils/datetime_parsing.dart';
import '../../../data/models/models.dart';
import '../../../shared/utils/map_pin_assets.dart';
import '../../../shared/widgets/map_marker_model.dart';

/// PROD-2205 — coord-rounded key used when an external occurrence /
/// venue has no `venue_id`. Five decimals = ~1.1 m precision, enough
/// to dedupe "same address" across the slim payload and the heavy
/// occurrence array without merging genuinely-distinct nearby venues.
String _coordKey(double lat, double lng) =>
    'extloc:${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';

/// Data attached to each occurrence-derived [MapMarker] so the tooltip
/// resolver and "View details" handler can read the venue context off
/// the marker without re-parsing the source `UserListItem` (PROD-2017).
///
/// `venueId` is nullable: external events scraped without a linked
/// venue still pin on the map but have no in-list venue route — the
/// tooltip omits the "View details" button when `venueId == null`.
class OccurrenceMarkerData {
  final String? venueId;
  final String venueName;
  final double lat;
  final double lng;

  const OccurrenceMarkerData({
    required this.venueId,
    required this.venueName,
    required this.lat,
    required this.lng,
  });
}

/// PROD-2017 — builds one [MapMarker] per unique venue location across
/// an event's occurrences for the zine item page's aux map.
///
/// Returns an empty list when the multi-pin path doesn't apply, so
/// callers can use `result.length >= 2` as the branching signal:
/// - `item.itemType != SavedItemType.event`
/// - the event has no occurrences with resolvable coordinates
/// - all occurrences collapse to a single location (caller renders
///   single-pin via the existing untouched path)
///
/// Dedup key: `venue_id` if non-null; otherwise
/// `extloc:<lat-rounded-5>,<lng-rounded-5>`. Stable across rebuilds so
/// the tooltip's "same-pin tap closes" rule works.
///
/// Letter ordering: groups sorted ascending by their earliest
/// `start_at`. A = earliest, B = next, … Capped at 'Z' for v1 — beyond
/// 26 unique venues the helper assigns a blank letter (tooltip still
/// works; pin renders as a plain unlabeled marker). Real touring data
/// has not hit this in practice.
List<MapMarker> buildOccurrenceMarkers(
  UserListItem item, {
  required Color color,
}) {
  if (item.itemType != SavedItemType.event) return const [];
  final event = item.event;
  if (event == null) return const [];
  final occs = event['occurrences'];
  if (occs is! List || occs.isEmpty) return const [];

  // Group occurrences by location (venue_id or rounded coords).
  // Within each group, track the earliest start_at so we can order
  // letters by tour chronology.
  final groups = <String, _LocationGroup>{};

  for (final raw in occs) {
    if (raw is! Map) continue;
    final lat = (raw['latitude'] as num?)?.toDouble();
    final lng = (raw['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) continue;

    final rawVenueId = raw['venue_id'] as String?;
    final venueId = (rawVenueId != null && rawVenueId.isNotEmpty)
        ? rawVenueId
        : null;

    final key = venueId ?? _coordKey(lat, lng);

    final startAt = parseBackendDateTime(raw['start_at'] as String?);

    final venueName = (raw['venue_name'] as String?) ?? '';

    final existing = groups[key];
    if (existing == null) {
      groups[key] = _LocationGroup(
        key: key,
        venueId: venueId,
        venueName: venueName,
        lat: lat,
        lng: lng,
        earliestStart: startAt,
      );
    } else {
      // Prefer a non-empty venue name; keep the earliest start_at.
      if (existing.venueName.isEmpty && venueName.isNotEmpty) {
        existing.venueName = venueName;
      }
      if (startAt != null &&
          (existing.earliestStart == null ||
              startAt.isBefore(existing.earliestStart!))) {
        existing.earliestStart = startAt;
      }
    }
  }

  if (groups.length < 2) return const [];

  // Sort by earliest start ascending. Groups missing a start_at sort
  // last (stable relative order amongst themselves).
  final ordered = groups.values.toList()
    ..sort((a, b) {
      final ax = a.earliestStart;
      final bx = b.earliestStart;
      if (ax == null && bx == null) return 0;
      if (ax == null) return 1;
      if (bx == null) return -1;
      return ax.compareTo(bx);
    });

  final markers = <MapMarker>[];
  for (var i = 0; i < ordered.length; i++) {
    final g = ordered[i];
    final letter = i < 26 ? String.fromCharCode('A'.codeUnitAt(0) + i) : '';
    markers.add(
      MapMarker.letter(
        id: g.key,
        lat: g.lat,
        lng: g.lng,
        letter: letter,
        color: color,
        category: MapMarkerCategory.venue,
        // PROD-3830: every occurrence of the same event shares the event's
        // facet, so they all draw the same teardrop. Null → pink default.
        // (This helper is currently unreferenced from lib/ — kept correct so
        // it behaves if the touring-event path is revived.)
        iconImage: mapPinKey(primaryFacet: item.primaryFacet),
        data: OccurrenceMarkerData(
          venueId: g.venueId,
          venueName: g.venueName,
          lat: g.lat,
          lng: g.lng,
        ),
      ),
    );
  }
  return markers;
}

/// PROD-2205 — given a `UserListItem` and the list's slim
/// `state.mapPins` set, return the subset of pin item-ids that
/// "belong to" the item.
///
/// Why this isn't `{item.id}`: `SlimMapPin.itemId` is "the earliest-
/// added `user_list_items.id` pointing at this venue" — when several
/// items in the list share a venue (a place added once and an event
/// at the same venue, for example), the pin's `itemId` may be a
/// different item's id. Matching by `venue_id` (with a rounded-coord
/// fallback for external events / legacy items without a venue row)
/// is robust against that aliasing.
///
/// **Symmetric matching.** Each side (item and pin) may contribute
/// EITHER a `venue_id` OR a coord-key — and those sides don't always
/// agree on which. The slim list-items endpoint, for example, omits
/// per-occurrence venue rows from `event['occurrences']` (only
/// `start_at` survives), so an event item falls back to its top-level
/// coords; meanwhile the matching slim pin carries the resolved
/// `venue_id`. To match those, we collect BOTH kinds of key on the
/// item side (when both are available) and check BOTH on the pin
/// side — a pin matches if `pin.venueId` OR `_coordKey(pin)` is in
/// the item key set.
///
/// Behaviour:
/// - Place item → matches pins whose `venueId` equals `item.venueId`
///   (or, when `item.venueId` is null, pins whose coords round to the
///   item's coords).
/// - Event item → walks `event['occurrences']` for per-venue keys;
///   also adds the event's top-level coords as a fallback key, since
///   the slim payload drops per-occurrence venue info and only the
///   primary lat/lng survives. Single-venue events match via the
///   coord-key against the pin's venue-resolved coords; multi-venue
///   events only fully light up when richer occurrence data is
///   present (heavy payload).
///
/// **Known limitation, tracked by [PROD-2219]:** with the current
/// slim payload, multi-venue events only highlight the *primary*
/// venue (next-occurrence). Lighting up every venue of a tour
/// requires a per-item venue set from the BE, which PROD-2219 adds
/// as `UserListItemSlim.occurrence_locations`. Once that field
/// lands, the event branch below should iterate it and contribute
/// every (venue_id, coord-key) pair to `keys` — the pin-side match
/// logic doesn't need to change.
///
/// Returns an empty set when nothing matches (defensive: the caller
/// falls back to no yellow highlight rather than crashing).
Set<String> selectedPinIdsForItem(UserListItem item, List<SlimMapPin> mapPins) {
  if (mapPins.isEmpty) return const <String>{};

  // 1. Collect every key this item could be referenced by. We collect
  //    BOTH venue IDs and coord-keys when both are knowable — see the
  //    "symmetric matching" note above.
  final keys = <String>{};
  void addVenue(String? id) {
    if (id != null && id.isNotEmpty) keys.add(id);
  }

  void addCoords(double? lat, double? lng) {
    if (lat != null && lng != null) keys.add(_coordKey(lat, lng));
  }

  if (item.itemType == SavedItemType.event) {
    final event = item.event;
    final occs = event?['occurrences'];
    if (occs is List) {
      for (final raw in occs) {
        if (raw is! Map) continue;
        addVenue(raw['venue_id'] as String?);
        addCoords(
          (raw['latitude'] as num?)?.toDouble(),
          (raw['longitude'] as num?)?.toDouble(),
        );
      }
    }
    // Slim event items lose per-occurrence venue rows (only `start_at`
    // survives `slimItemToHeavy`). The event's top-level coords stand
    // in for the primary venue.
    addVenue(item.venueId);
    addCoords(item.latitude, item.longitude);
  } else {
    addVenue(item.venueId);
    addCoords(item.latitude, item.longitude);
  }

  if (keys.isEmpty) return const <String>{};

  // 2. A pin matches if EITHER its venueId OR its coord-key is in
  //    the item's key set. This handles the asymmetric case (item
  //    contributes a coord-key but pin has a venueId, and vice
  //    versa) — without this, slim event items would never match
  //    any pin because their fallback key is coord-derived while the
  //    BE-resolved pin key is the venue UUID.
  final ids = <String>{};
  for (final pin in mapPins) {
    final venueId = pin.venueId;
    final venueMatches =
        venueId != null && venueId.isNotEmpty && keys.contains(venueId);
    final coordMatches = keys.contains(_coordKey(pin.latitude, pin.longitude));
    if (venueMatches || coordMatches) {
      ids.add(pin.itemId);
    }
  }
  return ids;
}

class _LocationGroup {
  final String key;
  final String? venueId;
  String venueName;
  final double lat;
  final double lng;
  DateTime? earliestStart;

  _LocationGroup({
    required this.key,
    required this.venueId,
    required this.venueName,
    required this.lat,
    required this.lng,
    required this.earliestStart,
  });
}
