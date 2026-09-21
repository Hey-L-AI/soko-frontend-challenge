import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/map_pin.dart';
import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import 'map_query_provider.dart';
import 'map_seed_provider.dart';
import 'map_selection_provider.dart';
import 'map_ui_state_provider.dart';

/// PROD-2736 / PROD-2807 — the results grid = **the shown pins** ("map = grid").
///
/// The grid hydrates ALL pins in view from the custom selection
/// ([mapSelectionProvider].visiblePins) — including those hidden inside
/// clusters, so the list is the complete result set, not just the
/// individually-plotted pins. Lazily windowed (24 at a time). Rebuilt (state
/// reset) whenever the selection changes (settle / zoom / pan / filter).
/// Hydration still runs in windows (the shown set is small — ≤ the selection
/// cap — so this is usually a single `/map/hydrate` call).

/// One pin reference (entity + id) in selection order, for windowed hydration.
/// For an event, [id] is the occurrence id (the `/map/pins` event pin id) —
/// round-tripped into `/map/hydrate` `event_occurrence_ids`.
class _PinRef {
  final bool isEvent;
  final String id;
  const _PinRef({required this.isEvent, required this.id});
}

class MapGridState {
  final List<ItemSuggestion> items;

  /// PROD-2989 — the map marker id (`"${entity}_${pin.id}"`) for each item in
  /// [items], index-aligned. Lets a grid open mark the exact pin "viewed" (the
  /// item itself only carries an event/venue id, but for events the pin is keyed
  /// by occurrence id). Empty string for any item the hydrate walk couldn't pair
  /// back to a source pin (rare stale-id drops).
  final List<String> markerIds;
  final bool isLoading;
  final bool hasMore;

  const MapGridState({
    this.items = const [],
    this.markerIds = const [],
    this.isLoading = false,
    this.hasMore = false,
  });

  MapGridState copyWith({
    List<ItemSuggestion>? items,
    List<String>? markerIds,
    bool? isLoading,
    bool? hasMore,
  }) => MapGridState(
    items: items ?? this.items,
    markerIds: markerIds ?? this.markerIds,
    isLoading: isLoading ?? this.isLoading,
    hasMore: hasMore ?? this.hasMore,
  );
}

class MapGridNotifier extends StateNotifier<MapGridState> {
  MapGridNotifier(this._ref, List<MapPin> shown)
    : _refs = [for (final p in shown) _PinRef(isEvent: p.isEvent, id: p.id)],
      super(MapGridState(hasMore: shown.isNotEmpty));

  /// Fixed grid for the seeded (chat) map: emits [items] + [markerIds] once and
  /// never hydrates. The empty ref list makes [loadMore] a no-op (it early-
  /// returns when `_cursor >= _refs.length`), and `hasMore` is false so the
  /// results sheet's lazy-hydration never fires.
  MapGridNotifier.fixed(
    this._ref, {
    required List<ItemSuggestion> items,
    required List<String> markerIds,
  }) : _refs = const [],
       super(MapGridState(items: items, markerIds: markerIds, hasMore: false));

  final Ref _ref;
  final List<_PinRef> _refs;
  int _cursor = 0;
  bool _busy = false;
  CancelToken? _token;
  static const int _windowSize = 24;

  /// Hydrate the next window of pin ids. No-op when already loading or
  /// exhausted. Errors / cancellation leave the accumulated items intact.
  Future<void> loadMore() async {
    if (_busy || _cursor >= _refs.length) return;
    _busy = true;
    state = state.copyWith(isLoading: true);

    final end = math.min(_cursor + _windowSize, _refs.length);
    final window = _refs.sublist(_cursor, end);
    final venueIds = [
      for (final r in window)
        if (!r.isEvent) r.id,
    ];
    final eventIds = [
      for (final r in window)
        if (r.isEvent) r.id,
    ];
    final token = _token = CancelToken();

    try {
      final res = await _ref
          .read(mapApiProvider)
          .getMapHydrate(
            venueIds: venueIds,
            eventOccurrenceIds: eventIds,
            // Same filters the pins used, so the hydrated cards match.
            facetFilters: _ref.read(mapQueryProvider).facetFilters.toList(),
            cancelToken: token,
          );
      if (!mounted) return;
      if (token.isCancelled) {
        state = state.copyWith(isLoading: false);
        return;
      }
      // Re-order the hydrated cards back into the window's (selection /
      // relevance) order. `/map/hydrate` returns venues + events as two lists,
      // each preserving request order (minus any dropped-stale ids), so a naive
      // `[...venues, ...events]` would render all venues then all events and
      // lose the shown-pin order. Walk the window refs and pop per-type in
      // order — the grid then mirrors exactly the shown-pin order ("map = grid").
      final ordered = <ItemSuggestion>[];
      // PROD-2989: the source pin's marker id for each ordered item, built in
      // lockstep so a grid open can fade the exact pin (see [MapGridState]).
      final orderedMarkerIds = <String>[];
      var vi = 0, ei = 0;
      for (final ref in window) {
        if (ref.isEvent) {
          if (ei < res.events.length) {
            ordered.add(res.events[ei++]);
            orderedMarkerIds.add('event_${ref.id}');
          }
        } else {
          if (vi < res.venues.length) {
            ordered.add(res.venues[vi++]);
            orderedMarkerIds.add('venue_${ref.id}');
          }
        }
      }
      // Defensive: append anything the walk didn't consume (id drops / extras).
      // These can't be paired back to a source pin, so their marker id is empty.
      if (vi < res.venues.length) {
        final extra = res.venues.sublist(vi);
        ordered.addAll(extra);
        orderedMarkerIds.addAll(List<String>.filled(extra.length, ''));
      }
      if (ei < res.events.length) {
        final extra = res.events.sublist(ei);
        ordered.addAll(extra);
        orderedMarkerIds.addAll(List<String>.filled(extra.length, ''));
      }
      _cursor = end;
      state = MapGridState(
        items: [...state.items, ...ordered],
        markerIds: [...state.markerIds, ...orderedMarkerIds],
        isLoading: false,
        hasMore: _cursor < _refs.length,
      );
    } catch (_) {
      if (mounted) state = state.copyWith(isLoading: false);
    } finally {
      _busy = false;
    }
  }

  /// Abandon any in-flight hydration (e.g. the user started panning the map).
  void cancelInFlight() => _token?.cancel();

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }
}

/// PROD-2981 — read the grid as a **cache for pin taps**.
extension MapGridPinLookup on MapGridState {
  /// The event id for the pin [markerId], if this grid has already hydrated it.
  ///
  /// A `/map/pins` event pin is keyed by OCCURRENCE, but the detail contract
  /// wants the event id — so a pin tap has to resolve one into the other. When
  /// the grid has already hydrated that pin, the mapping is right here: [items]
  /// carries the real `eventId` and is index-aligned with [markerIds], so
  /// reading it costs nothing and skips the round-trip.
  ///
  /// **This is an accelerator, not the latency fix.** It only hits while the
  /// results drawer is OPEN: `MapResultsSheet._ensureHydrated` fires only above
  /// the `peek` snap and re-arms on every selection change, so with the drawer
  /// closed (the default) this grid is empty and every tap misses. What actually
  /// makes the tap feel instant is that the sheet now opens FIRST and resolves
  /// the occurrence id itself on a miss (`eventIdForOccurrenceProvider`) — never
  /// behind a network call. Don't let this method's existence imply otherwise.
  ///
  /// Null when the grid hasn't reached the pin (its hydrate window is lazy, 24
  /// at a time) or the item carries no event id — the caller falls back to the
  /// sheet-resolves path.
  String? eventIdForMarker(String markerId) {
    final i = markerIds.indexOf(markerId);
    if (i < 0 || i >= items.length) return null;
    final id = items[i].eventId;
    return (id == null || id.isEmpty) ? null : id;
  }
}

/// Resets the grid whenever the **settled** selection changes (watches
/// [mapSettledSelectionProvider]) — the grid mirrors the pins on the map at the
/// last settle. It deliberately does NOT follow the live mid-gesture selection:
/// hydrating cards via `/map/hydrate` is settle-gated (like the pool refetch),
/// so the grid doesn't thrash while the user pans/zooms (PROD-2807 #4).
final mapGridProvider =
    StateNotifierProvider.autoDispose<MapGridNotifier, MapGridState>((ref) {
      // Seeded (chat) map: the grid IS the fixed list — already hydrated, so no
      // `/map/hydrate`. A plain notifier with empty `shown` (its `loadMore`
      // early-returns on an empty ref list) carrying the fixed state.
      final seed = ref.watch(mapSeedProvider);
      if (seed != null) {
        return MapGridNotifier.fixed(
          ref,
          items: seed.items,
          markerIds: seed.markerIds,
        );
      }
      // Cluster-focus scopes the drawer to just the tapped cluster's members;
      // otherwise the drawer lists ALL pins in view (including those hidden
      // inside clusters), not just the individually-plotted ones.
      final focused = ref.watch(mapFocusedClusterProvider);
      final pins =
          focused?.members ??
          ref.watch(mapSettledSelectionProvider).visiblePins;
      return MapGridNotifier(ref, pins);
    });
