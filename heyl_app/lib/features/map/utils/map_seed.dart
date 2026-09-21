import 'dart:math' as math;

import '../../../data/models/chat_message.dart';
import '../../../data/models/map_pin.dart';
import 'map_camera.dart' show MapCameraTarget, kDefaultMapRadiusMeters;
import 'map_grid_selection.dart' show MapSelection;

/// Turns a fixed, already-hydrated list of [ItemSuggestion]s (e.g. a chat's
/// places) into the exact shapes the shared `/map` widgets consume — so the
/// chat map can render through the SAME `MapScreen` pipeline instead of a
/// bespoke modal, just fed statically instead of from `/map/pins` + hydrate.
///
/// Everything here is index-aligned by construction:
///   [pins][i] ↔ [markerIds][i] ↔ [items][i]
/// which is the invariant the live grid guarantees (`MapGridState.markerIds`
/// is index-aligned with `items`, and `MapGridState.eventIdForMarker` relies on
/// it). Items without coordinates are dropped — a pin needs a lat/lng to plot,
/// and a card with no pin has nothing to correlate to.
///
/// **Marker id / pin id convention (must match the live path).** The screen
/// builds each marker id as `'${pin.entity}_${pin.id}'` (see
/// `map_render_provider`), and the pin-tap handler resolves an event via
/// `MapGridState.eventIdForMarker(markerId)`. So:
///   - venue → `pin.id = venueId`, entity `'venue'`, marker `'venue_<venueId>'`.
///   - event → `pin.id = eventId`, entity `'event'`, marker `'event_<eventId>'`.
/// Keying seeded event pins by the **event id** (never a fabricated occurrence
/// id) is deliberate: the tap handler reads back `items[i].eventId` and opens
/// `showEventDetailSheet(eventId: …)` with no occurrence round-trip.
class SeededMapData {
  /// The coordinate-bearing items, in input order (the ones that plot).
  final List<ItemSuggestion> items;

  /// Slim pins for the map render layer, index-aligned with [items].
  final List<MapPin> pins;

  /// `'${entity}_${id}'` per item, index-aligned with [items] — what the grid
  /// hands the pin-tap handler.
  final List<String> markerIds;

  const SeededMapData({
    required this.items,
    required this.pins,
    required this.markerIds,
  });

  /// A settled [MapSelection] holding every seeded pin as both `shown` and
  /// `visiblePins` (no clustering, no overflow bubbles). `totalInView` is exact
  /// because we hold the whole fixed set. Overriding the selection providers
  /// with this makes the map show exactly this list, unaffected by the viewport.
  MapSelection get selection =>
      MapSelection(shown: pins, visiblePins: pins, totalInView: pins.length);

  bool get isEmpty => items.isEmpty;

  /// A [MapCameraTarget] framing every seeded pin — the opening camera for the
  /// seeded [MapScreen] (which, with a non-null `initialCamera`, skips the
  /// location/city opening path entirely). Falls back to [fallback] (e.g. the
  /// chat's search centre) when there are no coordinate-bearing items.
  MapCameraTarget seededCamera({MapCameraTarget? fallback}) {
    if (pins.isEmpty) {
      return fallback ?? const MapCameraTarget(lat: 0, lng: 0);
    }
    var minLat = pins.first.lat!, maxLat = minLat;
    var minLng = pins.first.lng!, maxLng = minLng;
    for (final p in pins) {
      minLat = math.min(minLat, p.lat!);
      maxLat = math.max(maxLat, p.lat!);
      minLng = math.min(minLng, p.lng!);
      maxLng = math.max(maxLng, p.lng!);
    }
    final centerLat = (minLat + maxLat) / 2;
    final centerLng = (minLng + maxLng) / 2;
    // Rough metres-per-degree; the lng span shrinks with latitude. Half the
    // larger span is the radius the opening zoom frames (a single point → 0
    // span → the default radius floor).
    const metresPerDegLat = 111320.0;
    final latSpanM = (maxLat - minLat) * metresPerDegLat;
    final lngSpanM =
        (maxLng - minLng) *
        metresPerDegLat *
        math.cos(centerLat * math.pi / 180).abs();
    final radius = math.max(
      math.max(latSpanM, lngSpanM) / 2,
      kDefaultMapRadiusMeters,
    );
    return MapCameraTarget(
      lat: centerLat,
      lng: centerLng,
      radiusMeters: radius,
    );
  }

  static bool _isEvent(ItemSuggestion s) => s.type == 'event';

  /// The id the map/detail sheet loads by: venue id for venues, event id for
  /// events, falling back to the suggestion's own id.
  static String _entityId(ItemSuggestion s) =>
      _isEvent(s) ? (s.eventId ?? s.id) : (s.venueId ?? s.id);

  static String _entity(ItemSuggestion s) => _isEvent(s) ? 'event' : 'venue';

  /// Build the aligned pin/marker/item triplet from a fixed list, dropping any
  /// item without coordinates.
  factory SeededMapData.fromItems(List<ItemSuggestion> source) {
    final items = <ItemSuggestion>[];
    final pins = <MapPin>[];
    final markerIds = <String>[];
    for (final s in source) {
      final lat = s.latitude;
      final lng = s.longitude;
      if (lat == null || lng == null) continue;
      final entity = _entity(s);
      final id = _entityId(s);
      items.add(s);
      pins.add(
        MapPin(
          id: id,
          entity: entity,
          lat: lat,
          lng: lng,
          name: s.name,
          primaryFacet: s.primaryFacet,
        ),
      );
      markerIds.add('${entity}_$id');
    }
    return SeededMapData(items: items, pins: pins, markerIds: markerIds);
  }
}
