import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/map_pin.dart';
import '../../../shared/utils/map_debug_overlay.dart' show MapDebugShape;

/// PROD-2671 — transient UI state for the Map page bottom drawer + cluster focus.

/// PROD-3043 — the results drawer's snap stops. The drawer is a
/// [DraggableScrollableSheet] that settles on exactly these three.
///
/// * [peek] — the resting, map-primary stop: drag handle + "Ver N resultados"
///   row + the pinned filter footer. No results grid. This is the **floor** —
///   the drawer never collapses below it, so the question buttons are always
///   reachable.
/// * [half] — exactly one row of result cards, with the map still framed above.
///   Its height is **derived from the real card height** at the current viewport
///   width (PROD-3090), not a fixed fraction of the box — so it reveals a card
///   and nothing more.
/// * [full] — the grid rises to just below the top chrome (back button +
///   shortcut chips / "Reset all filters"), which stay visible.
enum MapDrawerSnap { peek, half, full }

/// PROD-3043 — the **commanded** snap of the results drawer.
///
/// The sheet's `DraggableScrollableController` owns the live extent (the truth);
/// this provider is the *intent*. External actors drive it (a cluster tap →
/// [MapDrawerSnap.half]; a map pan out of cluster-focus → [MapDrawerSnap.peek];
/// the count row toggles it), and [MapResultsSheet] writes back to it once a
/// user drag settles, so consumers (e.g. the count row's chevron) reflect
/// reality. autoDispose so it resets to [MapDrawerSnap.peek] on leaving the map.
final mapDrawerSnapProvider = StateProvider.autoDispose<MapDrawerSnap>(
  (ref) => MapDrawerSnap.peek,
);

/// The live rendered height (logical px) of the drawer's **peek chrome** — the
/// drag handle + count row + the open filter's option row + the question
/// buttons. I.e. everything except the results grid. Published by
/// [MapResultsSheet] and read by the Map page to float the my-location button
/// 12 px above the drawer's top edge.
///
/// This tracks the drawer while filter options open/close (so the button stays
/// clear of up to 3 option rows) but is left behind — and covered — once the
/// grid expands over it. It is the **peek** height, NOT the live drag extent:
/// the button must not ride up and down with a drag (PROD-3043 decision #7).
///
/// Seeded with [kMapDrawerBasePeekPx] (not 0) so the very first frame reserves
/// the real chrome — a 0 seed would flash a fully-collapsed drawer. autoDispose
/// so it resets across map-page visits.
final mapDrawerChromeHeightProvider = StateProvider.autoDispose<double>(
  (ref) => kMapDrawerBasePeekPx,
);

/// The drawer's peek height **excluding any open filter's option row** — i.e.
/// the drag handle + count row + question buttons, and nothing else. Published
/// by [MapResultsSheet] from a live measurement.
///
/// This is what the **map camera's bottom inset** (and the `/map/pins` search
/// area) reserve. It deliberately ignores an open filter panel: a transient
/// option row must not re-frame the map (nor shift the searched area) just
/// because the user tapped "O quê" — that was the intent of the original
/// resting-height sampling, and it's preserved here.
///
/// It is **measured, not hard-coded**, so it stays correct if the resting drawer
/// UI ever changes (the count row is redesigned, a row wraps at a large text
/// scale, a new persistent element is added). Seeded with [kMapDrawerBasePeekPx],
/// which is exact for the default layout, so frame 1 needs no measurement.
final mapDrawerBasePeekHeightProvider = StateProvider.autoDispose<double>(
  (ref) => kMapDrawerBasePeekPx,
);

/// PROD-2993 — **is the user's finger currently on the drawer?**
///
/// The camera must not move while it is. Two reasons, and the second is the one
/// that bites:
///
///  1. Moving the map under a live finger is disorienting.
///  2. [mapDrawerOccludedHeightProvider] is only written on **settle**, so
///     mid-drag it still describes the *previous* snap. A fit computed then
///     would frame the pins against geometry that no longer exists.
///
/// This is the same trap the drawer itself already documents (see
/// `docs/learnings/embedded-draggable-scrollable-sheet-gotchas.md` #3: *a
/// debounce is not a settle — it cannot tell "the drag finished" from "the user
/// paused mid-drag"*). The drawer guards its own snap writes with this; the
/// camera has to be guarded too, because a 1-second scroll debounce comfortably
/// outlives a mid-drag pause.
///
/// Written by [MapResultsSheet] on scroll/drag start and end. autoDispose.
final mapDrawerDraggingProvider = StateProvider.autoDispose<bool>(
  (ref) => false,
);

/// PROD-2993 — how much of the map the drawer is **actually covering**, in
/// logical px, at its last settled snap.
///
/// Deliberately NOT the same thing as [mapDrawerBasePeekHeightProvider]. That
/// one is what the camera *reserves* — always the peek chrome, never the live
/// extent, so the map is rock-stable while the drawer is dragged (PROD-3043
/// decision #7). This one is what the drawer *hides*, which at `half` is a great
/// deal more. The gap between the two is precisely why the results highlight
/// needs a camera at all: pins can sit inside it, on screen as far as the camera
/// is concerned and invisible as far as the user is concerned.
///
/// Written on **settle** only — a per-pixel value would rebuild the map page on
/// every frame of a drag. Seeded with the peek height so the first frame is
/// already right. autoDispose.
final mapDrawerOccludedHeightProvider = StateProvider.autoDispose<double>(
  (ref) => kMapDrawerBasePeekPx,
);

/// The drawer's header once it is **open** (at `half` or `full`) — the drag
/// handle alone (`SheetDragHandle` is 12 top + 4 bar + 8 bottom = 24).
///
/// The handle stays pinned at every snap, so there is always a grabbable strip
/// at the top of the drawer.
const double kMapDrawerOpenHeaderPx = 24;

/// The "Ver N resultados" row: a [BtSqIco] (40) + 8 bottom padding.
const double kMapDrawerCountRowPx = 48;

/// PROD-3090 — what the header gives back to the map when the drawer opens.
///
/// The count row is the affordance to *open* the drawer; once open, the results
/// are right there and the row is redundant, so it sheds. The collapse is driven
/// continuously off the live sheet extent (see `MapResultsSheet`), not off the
/// settled snap — collapsing at settle would jump the grid by this much in one
/// frame.
const double kMapDrawerHeaderCollapsePx = kMapDrawerCountRowPx;

/// The drawer's **pinned header at `peek`** — drag handle + the "Ver N
/// resultados" row. The count row's slot is reserved even at `count == 0`
/// (`Visibility(maintainSize:)`), so the header — and with it the peek height —
/// never shifts as results arrive.
const double kMapDrawerHeaderPx = kMapDrawerOpenHeaderPx + kMapDrawerCountRowPx;

/// The gap between the header and the first row of result cards — the results
/// grid's own top padding (`MapResultsGrid`).
///
/// It lives here, beside the other drawer-chrome constants, rather than only in
/// the grid, because [MapDrawerSnap.half] is **composed** from it: half = open
/// header + this + one card row + the footer. Keeping one constant is what stops
/// the snap and the grid from drifting apart.
const double kMapDrawerGridTopPadPx = 4;

/// Breathing room at the **top of the footer**, above the filter option row and
/// the question buttons.
///
/// The footer is an opaque band and the results grid scrolls **underneath** it,
/// so without this the grid is cut flush against the question buttons — a card's
/// image ends exactly where "O quê" begins, with no separation. Padding the
/// *grid* can't fix that: grid padding only adds scroll extent at the end of the
/// list, so mid-scroll the card still meets the footer edge. The gap has to live
/// inside the footer, where it renders as a strip of [AppColors.sokoPaper] that
/// content disappears behind.
const double kMapDrawerFooterTopGapPx = 12;

/// The drawer's **footer** with no filter panel open — the top gap
/// ([kMapDrawerFooterTopGapPx]) + the question buttons (`_QuestionButton`, 48) +
/// 12 bottom padding. Grows when a filter's option row opens; that growth is
/// measured, not assumed.
const double kMapDrawerBaseFooterPx = kMapDrawerFooterTopGapPx + 48 + 12;

/// The drawer's peek height with **no filter panel open** — a compile-time
/// constant, because every piece of the peek chrome is fixed-height (see the two
/// constants above). The Map page's Scaffold already supplies the bottom nav
/// (and with it the bottom safe area), so there is no `SafeArea` term.
///
/// Two uses:
/// * the **first-frame** peek extent — exact, so the drawer never flashes
///   collapsed and then jumps;
/// * the **map camera's bottom inset**, which deliberately tracks this constant
///   and never re-frames for an open filter or a drag (PROD-3043 decision #7).
const double kMapDrawerBasePeekPx = kMapDrawerHeaderPx + kMapDrawerBaseFooterPx;

/// PROD-2971 — the master "map debug mode" switch (admin-only tool). When on
/// AND the current user is admin, `/map/pins` is requested with `debug=true` so
/// the server returns its diagnostics block, the searched-area overlay is drawn,
/// and the debug panel shows the server rows. Off by default so admins don't pay
/// the debug query cost unless they open the tool; NEVER sent for non-admins
/// (the backend 422s a non-admin `debug=true`). Toggled from the debug dialog.
/// autoDispose so it resets to off when the map page is left.
final mapDebugEnabledProvider = StateProvider.autoDispose<bool>((ref) => false);

/// PROD-2971 — sub-toggle for exact per-cell counts in the debug grid
/// (`debug_cell_counts`). Costly (~+50–100 ms) so off by default; only
/// meaningful while [mapDebugEnabledProvider] is on. autoDispose.
final mapDebugCellCountsProvider = StateProvider.autoDispose<bool>(
  (ref) => false,
);

/// PROD-2971 — whether the docked map-debug panel is open. The `MapDebugTab`
/// side-tab toggles it; the panel is non-modal (a `Positioned` in the map
/// Stack), so the map stays tappable underneath — a pin tap while it's open
/// inspects that pin in the panel instead of opening the detail sheet.
/// autoDispose so it resets when the map page is left.
final mapDebugPanelOpenProvider = StateProvider.autoDispose<bool>(
  (ref) => false,
);

/// PROD-2971 — which overlay shapes are currently drawn. The panel's legend
/// toggles individual shapes; defaults to all on. autoDispose.
final mapDebugShapesProvider = StateProvider.autoDispose<Set<MapDebugShape>>(
  (ref) => MapDebugShape.values.toSet(),
);

/// A co-located cluster the user has focused by tapping it (one that can't be
/// split by more zoom).
class FocusedCluster {
  /// The tapped bubble marker's id (so the map can fade everything else).
  final String id;

  /// The cluster's members — the results drawer is scoped to exactly these.
  final List<MapPin> members;

  const FocusedCluster({required this.id, required this.members});
}

/// The currently focused cluster, or null. When set: the map fades every other
/// pin + caption and highlights this cluster, and the results drawer is scoped
/// to [FocusedCluster.members] and snapped open to [MapDrawerSnap.half]. Cleared
/// by a map tap / pan / zoom, which also returns the drawer to
/// [MapDrawerSnap.peek] — note that collapse is scoped to *this* auto-expansion:
/// a drawer the user dragged open themselves is left where they put it
/// (PROD-3043 decision #10). autoDispose so it never leaks across map-page visits.
final mapFocusedClusterProvider = StateProvider.autoDispose<FocusedCluster?>(
  (ref) => null,
);

/// DEBUG-ONLY — whether the "search area" overlay is on (a translucent soko-red
/// circle + viewport rectangle showing exactly what the FE sends to `/map/pins`).
/// Toggled from the debug tab's popup ([MapDebugTab]); read by [MapScreen] to
/// build the [MapSearchAreaOverlay] passed to the map. autoDispose so it resets
/// (off) across map-page visits. Only wired under `kDebugMode`.
final mapDebugSearchAreaProvider = StateProvider.autoDispose<bool>(
  (ref) => false,
);

/// PROD-3124 dot tap — the item a tapped dot promoted to a full pin. The map
/// flies to it at `kDotHintFocusZoom` and the selection layer injects it into
/// the shown set (`withPromotedPin`) so it renders with a caption even when
/// the relevance selection wouldn't pick it. Replaced by the next dot tap;
/// autoDispose so it clears when the map page is left.
final mapPromotedPinProvider = StateProvider.autoDispose<MapPin?>(
  (ref) => null,
);

/// PROD-3124 — DEBUG KNOB — live override for the dot-hint total allowance
/// (the zoom-band cap, 200/100 by default). Set from the debug panel's "Max
/// dots" slider (30–200); null → band defaults. Purely client-side: changing
/// it re-runs dot selection over the cached pool, no refetch. autoDispose so
/// it resets when the map page is left.
final mapDotAllowanceOverrideProvider = StateProvider.autoDispose<int?>(
  (ref) => null,
);

/// PROD-3124 — DEBUG KNOB — live override for the events' share of the dot
/// allowance (`kDotEventShare`, 0.8 by default; venues get the remainder).
/// Set from the debug panel's split slider; null → default. Client-side only.
/// autoDispose so it resets when the map page is left.
final mapDotEventShareOverrideProvider = StateProvider.autoDispose<double?>(
  (ref) => null,
);

/// PROD-2671 — the marker id of the individual pin whose detail sheet is
/// currently open, or null. When set, the map applies the *same* fade as
/// cluster-focus (every other pin + caption dims; this pin stays lit) so the
/// tapped item is highlighted behind its detail sheet. Unlike cluster-focus it
/// does NOT touch the results drawer — the detail sheet is the surface here.
/// Set right before the sheet is shown in [_onPinTap] and cleared when the
/// sheet is dismissed. autoDispose so it never leaks across map-page visits.
final mapFocusedPinProvider = StateProvider.autoDispose<String?>((ref) => null);

/// PROD-2989 — the set of marker ids (`"${entity}_${pin.id}"`) whose single-item
/// detail sheet has been opened this map-page visit. A viewed item's pin renders
/// slightly faded (icon-opacity `MapPinIconTokens.viewedIconOpacity`) as a
/// "seen" hint — see the fade expression
/// in the web/native renderers. Recorded on sheet-CLOSE (alongside the focus
/// clear in [_onPinTap], and after the grid open) so the fade never fights the
/// focus highlight. Local-only, in-memory, no backend/persistence; autoDispose
/// clears it when the user leaves the Map page. Filter changes never touch it —
/// "viewed" is a property of the item, not the filter.
final mapViewedItemIdsProvider = StateProvider.autoDispose<Set<String>>(
  (ref) => <String>{},
);
