/// PROD-2991 — the **shared camera-reaction primitive**.
///
/// The Map page's default camera is deliberately *rock-stable* (PROD-2671): it
/// never re-frames itself. A "camera reaction" is a **temporary override** of
/// that rule in response to one specific user action, which must be handed back
/// cleanly when the action ends. The umbrella's shape, in one line:
///
///   **snapshot camera → enter a temporary state → restore on exit.**
///
/// Both children of PROD-2991 need exactly this:
///  * **PROD-2993** (built first) — results-scroll highlight at the drawer's
///    `half` snap.
///  * **PROD-2992** — pin-tap focus mode (freeze the pool, recentre on the pin,
///    dim + shrink the rest, restore on close).
///
/// So it lives here, once, rather than being invented twice and drifting.
///
/// ## The freeze is CAMERA-scoped, not a pool lock
///
/// This is the load-bearing subtlety. Moving the camera on the Map page kicks
/// off a chain that ends by **resetting the results grid**:
///
/// ```
/// camera moves → onCameraIdle → MapQueryNotifier.onCameraSettled
///              → /map/pins refetch → new mapSettledSelectionProvider
///              → mapGridProvider rebuilds EMPTY (it is keyed off it)
///              → MapResultsSheet._onSelectionChanged() → _rewindScroll()
/// ```
///
/// A feature that moves the camera *while the user is reading the grid* would
/// therefore yank the scroll back to the top, change which cards are in view,
/// and re-trigger itself. So while a session is active, the map screen skips
/// `onCameraSettled` — see [mapCameraFrozenProvider].
///
/// But it must skip **only that**. A **filter change** is a *query* change, not
/// a camera change, and it has to keep working: the filter row is deliberately
/// reachable at `half` (PROD-3043 decision #3), so a blanket "don't refetch"
/// would make the filters appear broken. Filter writes go straight to
/// [mapQueryProvider] and are never gated on this — the map page ends the
/// session and returns the drawer to `peek` instead (PROD-2993 D12).
///
/// **If you ever reach for this to suppress a refetch, ask whether the refetch
/// was caused by the camera. If it wasn't, this is the wrong tool.**
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'map_search_provider.dart';

/// The camera as it was when a session opened — enough to put it back exactly.
@immutable
class MapCameraSnapshot {
  final double lat;
  final double lng;
  final double zoom;

  const MapCameraSnapshot({
    required this.lat,
    required this.lng,
    required this.zoom,
  });

  @override
  bool operator ==(Object other) =>
      other is MapCameraSnapshot &&
      other.lat == lat &&
      other.lng == lng &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(lat, lng, zoom);
}

/// Which reaction owns the current session. One at a time, by construction —
/// they all commandeer the same camera.
enum MapFocusSessionKind {
  /// PROD-2993 — **narrow** `half`: the results drawer shows the one-card
  /// carousel; the centred card's pin is highlighted (and every pin enlarges),
  /// and the camera follows the carousel.
  resultsHighlight,

  /// PROD-2993 — **wide** `half`: the drawer shows the full grid; hovering a card
  /// highlights only that pin (no whole-map enlargement) and the camera follows
  /// the hover. A distinct kind from [resultsHighlight] so `mapHighlightProvider`
  /// can pick the hover source — but it drives the SAME camera machinery
  /// (recenter, freeze + "Search this area" on pan, restore on close).
  resultsHoverHighlight,

  /// PROD-2992 — a pin was tapped; the camera recentres on it and the rest of
  /// the map recedes. (Not built yet — this enum case is the seam.)
  pinFocus,
}

/// An active camera reaction.
@immutable
class MapFocusSession {
  final MapFocusSessionKind kind;

  /// Where the camera was when the session opened. Null only if the camera
  /// hadn't reported a position yet (no fix / first frame) — then there is
  /// nothing to restore to and exit leaves the camera alone.
  final MapCameraSnapshot? snapshot;

  /// **The user has moved the camera themselves during this session.**
  ///
  /// Two consequences, and they're the whole reason this flag exists:
  ///  1. Camera-following stops. A programmatic camera that keeps fighting a
  ///     user's pan is the single most-reported bug in this UI pattern.
  ///  2. The pool is frozen, so the pins on screen are now **stale** — they
  ///     describe the area we searched, not the area being looked at. The map
  ///     page surfaces a "Search this area" affordance rather than quietly
  ///     showing wrong data.
  ///
  /// Cleared when a deliberate grid scroll re-arms following (PROD-2993 D10),
  /// which also pulls the camera back over the searched area — so "dirty" and
  /// "showing stale pins" stay the same condition.
  final bool cameraDirty;

  const MapFocusSession({
    required this.kind,
    this.snapshot,
    this.cameraDirty = false,
  });

  MapFocusSession copyWith({bool? cameraDirty}) => MapFocusSession(
    kind: kind,
    snapshot: snapshot,
    cameraDirty: cameraDirty ?? this.cameraDirty,
  );

  @override
  bool operator ==(Object other) =>
      other is MapFocusSession &&
      other.kind == kind &&
      other.snapshot == snapshot &&
      other.cameraDirty == cameraDirty;

  @override
  int get hashCode => Object.hash(kind, snapshot, cameraDirty);
}

class MapFocusSessionNotifier extends StateNotifier<MapFocusSession?> {
  MapFocusSessionNotifier() : super(null);

  /// Open a session of [kind], snapshotting the camera at [snapshot].
  ///
  /// **Re-entrant by design: entering a kind that is already running is a
  /// no-op, and in particular does NOT re-snapshot.** PROD-2993 leans on this.
  /// Its drawer can travel `half → full → half`, and `full` is a pass-through
  /// (the session stays open across it). If the second arrival at `half`
  /// re-snapshotted, it would capture the camera *our own highlighting had
  /// already moved* — quietly overwriting the anchor with a position the user
  /// never chose, so "restore" would put them somewhere they'd never been.
  void enter(MapFocusSessionKind kind, {MapCameraSnapshot? snapshot}) {
    if (state?.kind == kind) return;
    state = MapFocusSession(kind: kind, snapshot: snapshot);
  }

  /// The user drove the camera. See [MapFocusSession.cameraDirty].
  void markCameraDirty() {
    final s = state;
    if (s == null || s.cameraDirty) return;
    state = s.copyWith(cameraDirty: true);
  }

  /// The grid is driving again — the camera is back over the searched area, so
  /// the pins are no longer stale (PROD-2993 D10).
  void clearCameraDirty() {
    final s = state;
    if (s == null || !s.cameraDirty) return;
    state = s.copyWith(cameraDirty: false);
  }

  /// Close the session and hand back what it was holding, so the caller can
  /// decide what to do with the snapshot.
  ///
  /// It deliberately does **not** restore the camera itself: the three exits
  /// want three different things from it (PROD-2993 D11) — restore it, keep the
  /// user's new position, or re-frame for a bigger viewport. A primitive that
  /// restored unconditionally would be wrong two times out of three.
  MapFocusSession? exit() {
    final s = state;
    state = null;
    return s;
  }
}

/// The active camera reaction, or null. autoDispose so it can never leak across
/// Map-page visits.
final mapFocusSessionProvider =
    StateNotifierProvider.autoDispose<
      MapFocusSessionNotifier,
      MapFocusSession?
    >((ref) => MapFocusSessionNotifier());

/// **Is the camera→search chain suppressed right now?**
///
/// Read by `MapScreen.onCameraIdle`, which skips `onCameraSettled` when true.
/// That — and only that — is the freeze. Read the library doc above before
/// widening it.
///
/// Two sources, both camera-caused (the library-doc test):
///
///  1. An active camera-reaction **session** (PROD-2991).
///  2. The **focused search mode** (PROD-3496). Opening the soft keyboard
///     shrinks the Scaffold body → the Mapbox canvas resizes → `moveend`
///     settles with a smaller viewport radius → without this freeze that
///     committed a new query and refetched `/map/pins` on every bar tap.
///     The mode needs no session (the map is inert behind the scrim — the
///     camera can't be commandeered, so there's nothing to snapshot or
///     restore): on exit the canvas resizes back, the settle reports the
///     exact camera already committed, and `onCameraSettled`'s sub-threshold
///     `moved` guard drops it — enter + exit produce zero requests and the
///     map returns to the same view, pins and grid. (The grid is safe by
///     construction: it watches [mapSettledSelectionProvider], which slices
///     against the QUERY viewport, not the live one.)
final mapCameraFrozenProvider = Provider.autoDispose<bool>(
  (ref) =>
      ref.watch(mapFocusSessionProvider) != null ||
      ref.watch(mapSearchProvider.select((s) => s.focused)),
);
