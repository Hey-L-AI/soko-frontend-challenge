/// PROD-2671 / PROD-2993 — **the map's render list**: what actually gets drawn.
///
/// It sits at the end of a deliberately one-way chain, so nothing here can feed
/// back into what it reads:
///
/// ```
///   mapSelectionProvider   what the map would show for this camera
///            ↓
///   mapHighlightProvider   which of those the user is reading in the grid
///            ↓
///   mapMarkersProvider     the drawn markers  ← you are here
/// ```
///
/// It was extracted from `map_selection_provider.dart` when the highlight was
/// added: the highlight needs the *selection*, and the markers need the
/// *highlight*, so leaving the marker builder next to the selection would have
/// made the two files import each other. The layering above is the point — keep
/// it acyclic.
///
/// v0 keys pins by entity × primary facet (Decision #28); the slim [MapPin]
/// rides along as `data` for the pin-tap → detail path. Overflow bubbles carry
/// no `data` (their tap zooms to decluster, handled by `onOverflowTap`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/map_pin.dart';
import '../../../providers/location_provider.dart';
import '../../../shared/utils/user_location_marker.dart';
import '../../../shared/widgets/map_marker_model.dart';
import '../../../shared/utils/map_pin_assets.dart';
import 'map_focus_session_provider.dart';
import 'map_highlight_provider.dart';
import 'map_markers_provider.dart';
import 'map_selection_provider.dart';
import 'map_ui_state_provider.dart';

/// The map's markers — individual pins from [MapSelection.shown], the `+k`
/// overflow bubbles from [MapSelection.bubbles], any pins **pulled out of a
/// stack** because the user is reading their card (PROD-2993), and the
/// user-location dot.
final mapMarkersProvider = Provider.autoDispose<List<MapMarker>>((ref) {
  final selection = ref.watch(mapSelectionProvider);

  // Focus fade: when a terminal cluster is focused OR an individual pin's
  // detail sheet is open, every OTHER marker dims (only the focused
  // cluster/pin stays lit). A focused cluster is a bubble id; a focused pin is
  // an individual marker id — both flow through the same `focusId`.
  final focusId =
      ref.watch(mapFocusedClusterProvider)?.id ??
      ref.watch(mapFocusedPinProvider);
  final anyFocus = focusId != null;

  // PROD-2992 — pin-focus: the ONE tapped pin grows by [kMapPinFocusSizeMul] and
  // wins z-order, while its detail sheet is open and the rest recedes. Gated on
  // an ACTIVE pin-focus session (not bare `mapFocusedPinProvider`, which the
  // debug-inspect path also sets) so inspecting a pin in the debug panel doesn't
  // enlarge it.
  final pinFocusActive =
      ref.watch(mapFocusSessionProvider)?.kind == MapFocusSessionKind.pinFocus;
  final focusedPinId = ref.watch(mapFocusedPinProvider);
  bool isPinFocused(String markerId) =>
      pinFocusActive && markerId == focusedPinId;

  // PROD-2993 — the results highlight (drawer at `half`). Two effects, now
  // decoupled so the WIDE hover-highlight can use the second without the first:
  //
  //  • **Whole-map enlargement** ([MapHighlightState.enlargeAll]) — the narrow
  //    carousel grows EVERY pin by [kMapHighlightSizeMul], because its short
  //    `half` strip needs the pins to read at size (D14). Wide hover does NOT;
  //    it lifts only the hovered pin.
  //  • The lit cards' pins stay lit; everything else dims, through the SAME
  //    `dimmed` channel cluster-focus already uses. Applies to both.
  //
  // The two focus systems compose rather than fight: a cluster tap opens the
  // drawer to `half` (so both are live at once), and an explicit focus — a
  // tapped pin, a focused cluster — is the more specific intent, so it wins.
  final highlight = ref.watch(mapHighlightProvider);
  final highlighted = highlight.markerIds;
  // Dim the rest whenever something is lit (a centred carousel card OR a hovered
  // grid card).
  final dimActive = highlighted.isNotEmpty;
  // The baseline enlargement every pin gets: the narrow whole-map bump, or 1.0
  // on wide (where only the hovered pin lifts, below).
  final globalSizeMul = highlight.enlargeAll ? kMapHighlightSizeMul : 1.0;

  /// Should [markerId] be dimmed? An explicit focus (pin / cluster) always wins;
  /// otherwise the highlight dims everything it isn't lighting.
  bool dimmedFor(String markerId) {
    if (anyFocus) return markerId != focusId;
    if (dimActive) return !highlighted.contains(markerId);
    return false;
  }

  /// The size multiplier for [markerId]: a lit pin always gets the highlight
  /// bump ([kMapHighlightSizeMul]); everything else gets [globalSizeMul] (the
  /// narrow whole-map bump, or 1.0 on wide). So on wide hover only the hovered
  /// pin grows; on narrow every pin grows and the lit one matches.
  double highlightSizeMul(String markerId) =>
      highlighted.contains(markerId) ? kMapHighlightSizeMul : globalSizeMul;

  /// PROD-2993 — is this pin currently **lit by the results highlight**? True
  /// when the pin is one of the highlighted cards AND it isn't being dimmed by an
  /// explicit focus. A highlighted-but-dimmed pin (a rarer `half` + open-detail
  /// overlap) is not "lit", so it keeps its fades.
  bool litByHighlight(String markerId) =>
      highlighted.contains(markerId) && !dimmedFor(markerId);

  // PROD-2989: marker ids whose detail sheet has been opened this visit — their
  // individual pins render faded (`MapPinIconTokens.viewedIconOpacity`). Only
  // individual pins carry this flag; bubbles keep `viewed:false`.
  //
  // PROD-2993: the results highlight OVERRIDES that fade for the pin it's lighting
  // ([litByHighlight]) — while you browse the carousel at `half`, the card you're
  // on reads at full opacity even if you'd already opened its detail this visit.
  // Every other viewed pin still fades.
  final viewedIds = ref.watch(mapViewedItemIdsProvider);
  bool viewedFor(String markerId) =>
      viewedIds.contains(markerId) && !litByHighlight(markerId);
  final out = <MapMarker>[];

  // PROD-2947 (FE-1): score-driven pin SIZE. We rank each pin's score against the
  // fetched candidate POOL (`/map/pins` venues/events), per entity, and map that
  // rank to size, rather than mapping the absolute score. The pool only refetches
  // on camera-settle, so a pin's size is STABLE while the user pans (the map
  // re-slices the same pool). A flat / null-score pool → a no-op normalizer →
  // baseline `1.0×` ("graceful when flat"). Venues and events are normalized
  // SEPARATELY (their scores are different axes — list/quality vs time-relevance
  // — so they aren't cross-comparable).
  //
  // ⚠️ This used to say "real backend scores are tightly clustered (venues ≈ 0.25,
  // events ≈ 0)", which justified normalizing as *rescuing* an imperceptible
  // gradient. Measured on staging 2026-07-13, that is no longer true: venues span
  // 0.0–0.61 with ~97 distinct values across 150 pins, events up to 0.997 with
  // ~117 distinct. Pool-relative normalization is still the right call (it keeps
  // the full 0.85×–1.15× size range in use regardless of how the backend's
  // absolute scale drifts, and the two entities aren't cross-comparable anyway) —
  // but don't rely on the old "scores are all ≈0.25" claim when reasoning about
  // this code. See PROD-3004.
  // PROD-3657: normalize against the pool the map is actually DRAWING — during
  // a cache pre-paint that's the cached pool, not the away area's response.
  // Ranking a drawn pin against a pool it isn't in would size it off a
  // distribution it never belonged to.
  final pool = ref.watch(mapPinsProvider).displayData;
  final venueNorm = ScoreNormalizer.fromScores(
    (pool?.venues ?? const <MapPin>[]).map((p) => p.score),
  );
  final eventNorm = ScoreNormalizer.fromScores(
    (pool?.events ?? const <MapPin>[]).map((p) => p.score),
  );

  for (final pin in selection.shown) {
    final lat = pin.lat;
    final lng = pin.lng;
    if (lat == null || lng == null) continue;
    final markerId = '${pin.entity}_${pin.id}';
    final normalized = (pin.isEvent ? eventNorm : venueNorm).normalize(
      pin.score,
    );
    out.add(
      MapMarker(
        id: markerId,
        lat: lat,
        lng: lng,
        type: MapMarkerType.place,
        data: pin,
        category: pin.isEvent
            ? MapMarkerCategory.event
            : MapMarkerCategory.venue,
        // PROD-2671: facet-coloured teardrop keyed by primary facet × entity
        // (generic event/venue pin when the facet has no dedicated art).
        iconImage: mapPinKey(primaryFacet: pin.primaryFacet),
        dimmed: dimmedFor(markerId),
        // PROD-2989: faded once this item's detail sheet has been opened —
        // unless the results highlight is lighting it (PROD-2993, [viewedFor]).
        viewed: viewedFor(markerId),
        // PROD-2947 (FE-1): pool-relevance rank → 0.85×–1.15× size (baseline
        // 1.0× when the pool is flat / this pin has no score), then PROD-2993's
        // whole-map enlargement on top of it. Both are multipliers on the same
        // `icon_scale` feature property, so they simply compose.
        // PROD-2947 (FE-1) score size × PROD-2993 highlight bump × PROD-2992
        // pin-focus bump — all three ride the same `icon_scale`, so they compose.
        scoreSizeMul:
            MapPinIconTokens.scoreSizeMultiplier(normalized) *
            highlightSizeMul(markerId) *
            (isPinFocused(markerId) ? kMapPinFocusSizeMul : 1.0),
        // PROD-2947 (FE-1): caption priority from the RAW score — a
        // higher-scored pin's caption wins a collision with a lower-scored
        // neighbour (`symbol-sort-key`, lower = higher priority).
        // PROD-2992: the focused pin gets `sort_key = 0.0` — the minimum — which
        // both raises its icon draw-order (icons key off `1 − sort_key`, so it
        // paints on top) and wins its caption collision, lifting the enlarged
        // teardrop above the dimmed rest.
        captionSortKey: isPinFocused(markerId)
            ? 0.0
            : MapPinIconTokens.captionSortKey(pin.score),
      ),
    );
  }

  for (final b in selection.bubbles) {
    out.add(
      MapMarker(
        id: b.id,
        lat: b.centerLat,
        lng: b.centerLng,
        type: MapMarkerType.place,
        // The bubble carries its full member set so a tap can scope the drawer.
        data: b,
        overflowCount: b.count,
        // A6: saturated-cell counts render "N+" (never trips at launch).
        overflowCountCapped: b.countCapped,
        // venue-only → blue, event-only → green, mixed → null (pink), mirroring
        // the old cluster colouring via the feature's event_count/place_count.
        category: (b.hasEvents && b.hasVenues)
            ? null
            : (b.hasEvents ? MapMarkerCategory.event : MapMarkerCategory.venue),
        // PROD-2671: stack-of-5 — up to 5 member pin-keys (front-first) + the
        // venue/event counts that drive the "X venues / Y events" title.
        stackIcons: b.stackMembers
            .map((p) => mapPinKey(primaryFacet: p.primaryFacet))
            .toList(growable: false),
        venueCount: b.venueCount,
        eventCount: b.eventCount,
        // Terminal (co-located) → tapping opens the focus flow, not a zoom.
        overflowTerminal: b.unsplittable,
        dimmed: dimmedFor(b.id),
        // PROD-2993 (D14): stacks grow with everything else. Bubbles used to
        // omit `icon_scale` entirely (the renderers coalesce a missing value to
        // 1.0), so this is the first thing that ever sets it on them — which is
        // why the stack layers' `icon-size` had to learn to read it. Bubbles are
        // never individually highlighted, so they only get the global bump.
        scoreSizeMul: globalSizeMul,
      ),
    );
  }

  // PROD-2993 — pins **pulled out of a stack** because their card is on screen.
  //
  // A stacked item has no individual pin, so scrolling to its card would
  // otherwise highlight nothing. We add one, at the item's TRUE coordinates
  // (from the hydrated card — see `map_highlight_provider.dart` for why the map
  // data can't supply them), and let it overlap the stack it came from. That
  // overlap is intentional: by construction a stack's members sit within one
  // grid cell of each other, so they were always going to be on top of it.
  //
  // Appended last so they draw above the stack's own teardrops.
  for (final e in highlight.pulledFromStack) {
    out.add(
      MapMarker(
        id: e.markerId,
        lat: e.lat,
        lng: e.lng,
        type: MapMarkerType.place,
        category: e.isEvent ? MapMarkerCategory.event : MapMarkerCategory.venue,
        iconImage: mapPinKey(primaryFacet: e.primaryFacet),
        // It is by definition one of the cards in view, so it is never dimmed —
        // and the highlight lighting it also overrides the "viewed" fade
        // ([viewedFor], PROD-2993), so the card you're on always reads full.
        dimmed: false,
        viewed: viewedFor(e.markerId),
        // Pulled out because its card is in view → it's a lit pin, so it gets
        // the highlight bump (on wide hover this is the one pin that grows).
        scoreSizeMul: highlightSizeMul(e.markerId),
        // No `data`: a tap on it must not open a detail sheet from a pin the
        // selection doesn't own. The card underneath it is the tap target, and
        // it disappears again the moment the card scrolls out of view.
      ),
    );
  }

  // The user-location **blue dot** — reuses the shared, tested helper that the
  // chat/list/detail maps use. It appends a `MapMarker.userLocation` (carrying
  // `accuracyM`) only for a real GPS fix (skipped on IP-fallback), and the dot
  // is excluded from cluster/fit paths on both platforms. Watching
  // `locationProvider` re-renders the dot as the fix updates.
  appendUserLocationMarker(out, ref.watch(locationProvider));

  return out;
});
