import 'package:flutter/foundation.dart';

/// PROD-3498 — what kind of thing the active map search is.
///
/// Mirrors the dropdown's row types (and the past-searches history types), so
/// the bar can show the same leading icon the suggestion row had.
enum MapSearchTargetType { keyword, venue, event, location, list }

/// PROD-3498 — the **one** search currently applied to the map (Decision #30:
/// one active search at a time; a new selection replaces the previous).
///
/// Purely presentational + identity: it drives the bar's active chrome (type
/// icon + label + clear-X, D8) and lets the map resolve a promoted pin back to
/// its canonical entity. The actual map effects live where they always have —
/// `mapQueryProvider.keyword` for a keyword search, `mapPromotedPinProvider`
/// for a flown-to venue/event, the camera for a location.
@immutable
class MapActiveSearch {
  const MapActiveSearch({
    required this.type,
    required this.label,
    this.targetId,
    this.eventId,
  });

  final MapSearchTargetType type;

  /// What the bar shows: the keyword itself, or the entity/area name.
  final String label;

  /// The executed entity's id — venue id, canonical event id, `/geo/areas`
  /// prediction id, or list id. Null for a keyword search.
  final String? targetId;

  /// Events only — the **canonical** event id, kept even when the promoted pin
  /// carries an occurrence id (or, for a past-search re-execution, no
  /// occurrence id at all). `_onPinTap` needs it to open the detail sheet by
  /// event id instead of mistaking a canonical id for an occurrence id
  /// (`MapPin.id` for an event is the occurrence id — see `map_pin.dart`).
  final String? eventId;

  @override
  bool operator ==(Object other) =>
      other is MapActiveSearch &&
      other.type == type &&
      other.label == label &&
      other.targetId == targetId &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(type, label, targetId, eventId);
}
