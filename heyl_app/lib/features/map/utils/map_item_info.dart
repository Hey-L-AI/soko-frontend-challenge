import '../../../data/models/chat_message.dart';
import '../../../data/models/lists_calendar_event.dart';
import '../../../data/models/lists_map_pin.dart';
import '../../../shared/widgets/map_marker_model.dart';

/// PROD-2671 — display info extracted from a [MapMarker]'s payload, shared
/// by the pin tooltip and the results sheet. The map mixes three payload
/// types (global search `ItemSuggestion`, list-scope `ListsMapPin` /
/// `ListsCalendarEvent`), so this is the one place that normalises them.
typedef MapItemInfo = ({
  String title,
  String subtitle,
  String? imageUrl,
  String? route,
});

MapItemInfo? mapMarkerItemInfo(MapMarker marker) =>
    mapItemInfoForData(marker.data);

MapItemInfo? mapItemInfoForData(Object? data) {
  if (data is ItemSuggestion) {
    final isEvent = data.type == 'event';
    return (
      title: data.name,
      subtitle: isEvent ? 'Evento' : 'Lugar',
      imageUrl: data.imageUrl,
      route: mapDetailRouteForData(data),
    );
  }
  if (data is ListsMapPin) {
    return (
      title: data.name,
      subtitle: 'Lugar',
      imageUrl: data.imageUrl,
      route: mapDetailRouteForData(data),
    );
  }
  if (data is ListsCalendarEvent) {
    return (
      title: data.title,
      subtitle: 'Evento',
      imageUrl: data.imageUrl,
      route: mapDetailRouteForData(data),
    );
  }
  return null;
}

/// Detail route for a marker's payload, or null when no id is available
/// (e.g. a Google-only place result with no local `venue_id`).
String? mapDetailRouteForData(Object? data) {
  if (data is ItemSuggestion) {
    if (data.type == 'event') {
      final id = data.eventId ?? data.id;
      return id.isNotEmpty ? '/events/$id' : null;
    }
    final id = data.venueId ?? data.id;
    return id.isNotEmpty ? '/venues/$id' : null;
  }
  if (data is ListsMapPin) {
    return data.venueId.isNotEmpty ? '/venues/${data.venueId}' : null;
  }
  if (data is ListsCalendarEvent) {
    return data.eventId.isNotEmpty ? '/events/${data.eventId}' : null;
  }
  return null;
}
