/// PROD-2993 — the results cards the user is currently looking at, resolved onto
/// the map.
///
/// ## Where a card's position actually comes from (this is the trap)
///
/// The ticket assumed a visible card's location could be read off the `MapPin`
/// the client already holds. **On the v2 server path — which is the live path
/// for every user — that is false.** A stack's members arrive as
/// `MapMember {id, entity}`: no coordinates, and (past the top 5) no facet
/// either. `MapStackMember.toPin()` says so in as many words — *"lat/lng/name
/// null — the teardrop is drawn at the stack centre"*. So for a card buried in a
/// stack, the pin we hold literally does not know where it is.
///
/// The rescue is the **hydrated card itself**. `/map/hydrate` returns
/// `PlaceSearchResult` / `EventSearchResult`, and both carry `latitude` /
/// `longitude` — and the grid is holding exactly one per card already. That is
/// strictly better than the plan: it is the item's **true position**, not a
/// stack centroid.
///
/// Hence [_resolvePoint]'s order, and hence why the grid — not the selection —
/// is the source of truth here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/map_pin.dart';
import '../utils/map_highlight_geometry.dart';
import 'map_focus_session_provider.dart';
import 'map_grid_provider.dart';
import 'map_selection_provider.dart';
import 'map_ui_state_provider.dart';

/// The item index in [mapGridProvider] whose card is centred in the carousel
/// right now (a single-element list). Published by `MapResultsCarousel` as the
/// centred card changes — it owns the horizontal scroll position, so nothing
/// else can see it.
///
/// Empty is a real, meaningful value — the drawer just closed (`_endSession`
/// clears it) — and means "highlight nothing". Never treat it as "keep the last
/// set": the highlight would then be lying about what's on screen.
final mapVisibleCardIndicesProvider = StateProvider.autoDispose<List<int>>(
  (ref) => const [],
);

/// PROD-2993 — the grid card the mouse is **hovering**, on WIDE viewports at
/// `half`. Null when nothing is hovered.
///
/// The wide `half` is a full grid (no carousel), so there's no "centred" card to
/// highlight — instead hovering a card lights its pin. Published by
/// `MapResultsGrid` through a `MouseRegion`, which fires ONLY for a real mouse,
/// so **touch devices never set it and get no highlight, by construction**
/// (which is exactly the "no hover → no highlight" the design asks for).
final mapHoveredCardIndexProvider = StateProvider.autoDispose<int?>(
  (ref) => null,
);

/// PROD-2993 — a **one-shot command** to scroll the carousel to a card, driven
/// from OUTSIDE it (a tap on a faded map pin at narrow `half`: select it in the
/// carousel instead of opening its detail). `MapResultsCarousel` listens, animates
/// to the index, then clears this back to null (so the same index can be
/// requested again after a manual scroll). Null = no pending request.
///
/// The reverse of [mapVisibleCardIndicesProvider] (which the carousel *writes* as
/// it scrolls): this is how the rest of the page *drives* the carousel.
final mapCarouselFocusRequestProvider = StateProvider.autoDispose<int?>(
  (ref) => null,
);

/// One highlighted card, resolved onto the map.
@immutable
class MapHighlightEntry {
  /// `"${entity}_${id}"` — the same key the map's markers use.
  final String markerId;
  final double lat;
  final double lng;
  final bool isEvent;
  final FacetPair? primaryFacet;

  /// True when this card's item is **inside a stack**, so the map isn't drawing
  /// an individual pin for it. PROD-2993 pulls one out and draws it on top of
  /// the stack (the ticket's "accept overlap") — at its true coordinates.
  final bool pulledFromStack;

  const MapHighlightEntry({
    required this.markerId,
    required this.lat,
    required this.lng,
    required this.isEvent,
    this.primaryFacet,
    this.pulledFromStack = false,
  });
}

@immutable
class MapHighlightState {
  /// Enlarge EVERY plotted pin — the narrow carousel's whole-map bump (D14),
  /// because the short `half` strip needs the pins to read at size. True even
  /// when [entries] is empty (pins stay enlarged while browsing). The WIDE
  /// hover-highlight leaves the map at normal scale and lifts only the hovered
  /// pin, so it sets this false.
  final bool enlargeAll;

  final List<MapHighlightEntry> entries;

  const MapHighlightState({this.enlargeAll = false, this.entries = const []});

  /// The lit marker ids. Everything else on the map dims (PROD-2993 D2 — the
  /// same focus-fade cluster-focus and pin-tap focus already use).
  Set<String> get markerIds => {for (final e in entries) e.markerId};

  /// The points the camera would have to frame, if it turns out it must move.
  List<HighlightPoint> get points => [
    for (final e in entries) HighlightPoint(e.lat, e.lng),
  ];

  /// Cards whose pins the map isn't drawing individually — they need one added.
  List<MapHighlightEntry> get pulledFromStack => [
    for (final e in entries)
      if (e.pulledFromStack) e,
  ];
}

/// The live highlight. Null-safe and cheap: it recomputes when the focused
/// carousel card changes (published live to [mapVisibleCardIndicesProvider] as
/// the centred card changes — one index at a time), when the grid hydrates, or
/// when the map re-selects.
final mapHighlightProvider = Provider.autoDispose<MapHighlightState>((ref) {
  // Highlight is a `half`-only effect — for BOTH the narrow carousel and the
  // wide hover. At `full` the grid covers the map, so enlarging/dimming pins
  // nobody can see would be pure churn; at `peek` there's nothing to read. (The
  // narrow *session* still spans half AND full for camera-snapshot continuity —
  // D4 — but the highlight itself is gated here, on the snap.)
  if (ref.watch(mapDrawerSnapProvider) != MapDrawerSnap.half) {
    return const MapHighlightState();
  }

  // Two `half` sources, told apart by the session KIND — `map_screen` opens a
  // different one per viewport (narrow carousel vs wide grid). Both kinds drive
  // the same camera machinery; only the highlight SOURCE and the enlargement
  // differ here.
  final kind = ref.watch(mapFocusSessionProvider)?.kind;

  final List<int> indices;
  final bool enlargeAll;
  if (kind == MapFocusSessionKind.resultsHighlight) {
    // Narrow carousel: the centred card + the whole-map enlargement (D14).
    indices = ref.watch(mapVisibleCardIndicesProvider);
    enlargeAll = true;
  } else if (kind == MapFocusSessionKind.resultsHoverHighlight) {
    // Wide grid: the HOVERED card (mouse only — touch never hovers). Only this
    // pin lifts and the rest dim; no whole-map enlargement.
    final hovered = ref.watch(mapHoveredCardIndexProvider);
    if (hovered == null) return const MapHighlightState();
    indices = <int>[hovered];
    enlargeAll = false;
  } else {
    // No session, or a non-results one (pin-focus) → no results highlight.
    return const MapHighlightState();
  }

  final grid = ref.watch(mapGridProvider);
  if (indices.isEmpty || grid.items.isEmpty) {
    // Nothing qualifies yet (e.g. the grid hasn't hydrated) — narrow keeps its
    // pins enlarged; wide shows nothing.
    return MapHighlightState(enlargeAll: enlargeAll);
  }

  final selection = ref.watch(mapSelectionProvider);

  // Which markers is the map drawing individually right now? Anything NOT in
  // here that a card points at is inside a stack, and needs a pin pulled out.
  final shown = <String, MapPin>{
    for (final p in selection.shown) '${p.entity}_${p.id}': p,
  };

  // Fallback positions + facets for stacked members. A stack's centre is the
  // only location the v2 wire gives us for a member; `stackMembers` (top ≤5) is
  // the only place a member's facet appears.
  final stackCentre = <String, ({double lat, double lng})>{};
  final stackFacet = <String, FacetPair?>{};
  for (final b in selection.bubbles) {
    for (final p in b.members) {
      stackCentre['${p.entity}_${p.id}'] = (lat: b.centerLat, lng: b.centerLng);
    }
    for (final p in b.stackMembers) {
      stackFacet['${p.entity}_${p.id}'] = p.primaryFacet;
    }
  }

  final entries = <MapHighlightEntry>[];
  for (final i in indices) {
    if (i < 0 || i >= grid.items.length || i >= grid.markerIds.length) continue;
    final markerId = grid.markerIds[i];
    // The hydrate walk couldn't pair this card back to a source pin (a rare
    // stale-id drop) — there is no pin to highlight.
    if (markerId.isEmpty) continue;

    final item = grid.items[i];
    final pin = shown[markerId];

    final point = _resolvePoint(
      item.latitude,
      item.longitude,
      pin,
      stackCentre[markerId],
    );
    // PROD-2993 D15 — no coordinates from any source. Quietly drop it: it can't
    // be highlighted and it must not drag the camera to (0, 0).
    if (point == null) continue;

    entries.add(
      MapHighlightEntry(
        markerId: markerId,
        lat: point.lat,
        lng: point.lng,
        isEvent: markerId.startsWith('event_'),
        // The hydrated card is the ONLY source that has a facet for every
        // result in view; the stack's top-5 is a fallback for a card that
        // predates the field, and `shown` pins carry their own.
        primaryFacet:
            item.primaryFacet ?? pin?.primaryFacet ?? stackFacet[markerId],
        pulledFromStack: pin == null,
      ),
    );
  }

  return MapHighlightState(enlargeAll: enlargeAll, entries: entries);
});

/// PROD-2993 D15 — the fallback chain for "where is this card?", best first:
///
/// 1. **The hydrated card's own coordinates.** The item's true position. Always
///    present for venues (`PlaceSearchResult` requires them) and usually for
///    events.
/// 2. **Its individually-plotted `MapPin`.** Only exists when the map is already
///    drawing it — i.e. never for the stacked cards that need this most.
/// 3. **Its stack's centre.** Accurate to within one grid cell, which is the
///    definition of a stack. Good enough to frame; wrong to claim as exact.
/// 4. **Nothing** → the card is excluded from the highlight and from the camera
///    fit entirely. `EventSearchResult.latitude` is nullable, so this is
///    reachable, and silently framing (0, 0) would be far worse than skipping.
({double lat, double lng})? _resolvePoint(
  double? cardLat,
  double? cardLng,
  MapPin? pin,
  ({double lat, double lng})? stack,
) {
  if (cardLat != null && cardLng != null) return (lat: cardLat, lng: cardLng);
  final pLat = pin?.lat;
  final pLng = pin?.lng;
  if (pLat != null && pLng != null) return (lat: pLat, lng: pLng);
  return stack;
}
