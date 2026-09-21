import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/experiment_service.dart';
import '../../../data/models/map_pin.dart';
import '../models/map_query.dart';
import 'map_seed_provider.dart';
import '../utils/map_dot_hints.dart' show dotHintExclusionIds, withPromotedPin;
import '../utils/map_feature_gates.dart';
import '../utils/map_grid_selection.dart';
import '../utils/map_pin_promotion.dart';
import 'map_markers_provider.dart';
import 'map_query_provider.dart';
import 'map_ui_state_provider.dart';

/// PROD-2807 (#4) — the **live** camera viewport, updated on every (throttled)
/// camera move AND on settle. Instant mid-gesture re-selection reads this, so
/// panning/zooming re-selects off the last-good pool without waiting for the
/// settle — while the pool itself still refetches only on settle (via
/// [mapQueryProvider]). Null until the first camera event, when the selection
/// falls back to the settled [MapQuery] viewport.
final mapLiveViewportProvider = StateProvider.autoDispose<MapViewport?>(
  (ref) => null,
);

/// PROD-2992 — while pin-focus is active, the viewport [mapSelectionProvider]
/// selects against is **pinned** to this value (captured on focus entry) instead
/// of the live viewport, so panning/zooming inside focus does not re-slice the
/// pool ("freeze the pool — no live re-selection"). Null the rest of the time,
/// when live re-selection is normal. Set/cleared by `MapScreen._onPinTap`.
///
/// This is the reselection half of the pin-focus freeze; the fetch half is
/// [mapCameraFrozenProvider] (skips the settle refetch). Only pin-focus sets
/// this — the results-highlight sessions leave it null and re-select live (they
/// want "Search this area" on a pan, which pin-focus does not).
final mapFrozenViewportProvider = StateProvider.autoDispose<MapViewport?>(
  (ref) => null,
);

/// PROD-3656 — the pins auto-promoted out of the pool to spend the marker-cap
/// slots a zoom-in freed. Two faces, because the map and the grid are gated
/// differently:
///
///  • [live] feeds [mapSelectionProvider] — the map. It grows **mid-gesture**,
///    which is the whole point: the promotion lands in the same frame as the
///    zoom, before any `/map/pins` response.
///  • [settled] feeds [mapSettledSelectionProvider] — the results grid and the
///    "Ver N resultados" count. It only ever changes when a response lands, so
///    a promotion can't rebuild `mapGridProvider` mid-gesture (which would
///    rewind the scroll and re-fire `/map/hydrate`). Post-settle the two faces
///    are identical, so map = grid = count holds again.
@immutable
class MapAutoPromotions {
  final List<MapPin> live;
  final List<MapPin> settled;

  const MapAutoPromotions({this.live = const [], this.settled = const []});

  bool get isEmpty => live.isEmpty && settled.isEmpty;
}

/// PROD-3656 — owns the auto-promotion lifecycle.
///
/// The defect it fixes: on the v2 path a live camera move re-slices by
/// *trimming* the server's chosen set ([selectionFromServer]), so zooming in
/// drops representatives out of view and frees capacity under
/// [selectionCapForSource] that is never re-spent — the map draws fewer pins
/// than it is allowed to while the spare slots sit there as dots.
///
/// The rules (Zé, 2026-08-05 — PROD-3690, replacing the PROD-3656 originals):
///
///  • **Only once the camera has settled** — never mid-gesture. Promotion is a
///    top-up for the window between the settle and the `/map/pins` response,
///    not gesture feedback.
///  • **Only when a whole zoom level was crossed** since the last pass, and
///    only upward. A pinch that stays inside one level does nothing.
///  • **Only while fewer than [kMaxAutoPromotedTotal] pins are displayed**, and
///    never past that total. Gate and ceiling are one rule.
///  • **Zoom out** → nothing promoted; it just re-arms the level it lands on,
///    so returning to a deeper level promotes again.
///  • **When a response lands** → it *merges*. For the same-or-deeper view it
///    is additive and never demotes a pin the user just watched appear; for a
///    materially wider view ([kPromotionReleaseZoomDelta]) the promotions are
///    released and the fresh server selection governs.
///  • **A new search** (different [MapQuery.filterSignature]) drops everything.
///
/// Why settle-gating matters beyond calmness: both renderers skip arming the
/// per-pin reveal while `_cameraMoving`, so a mid-gesture promotion would be
/// baselined and never animate. Promoting at settle gets the animation for
/// free.
class MapAutoPromotionsNotifier extends StateNotifier<MapAutoPromotions> {
  MapAutoPromotionsNotifier(this._ref) : super(const MapAutoPromotions()) {
    _signature = _ref.read(mapQueryProvider).filterSignature;
    // PROD-3690: the ONE trigger. `mapQueryProvider` changes on
    // `onCameraSettled`, which is exactly "the user's fingers left the screen".
    // There is deliberately no `mapLiveViewportProvider` listener any more —
    // promotion must not run mid-gesture.
    _ref.listen<MapQuery>(mapQueryProvider, (_, next) => _onQuery(next));
    _ref.listen<MapPinsState>(
      mapPinsProvider,
      (prev, next) => _onPins(prev, next),
    );
    // PROD-2906's rule — the flag is authoritative in BOTH directions. With it
    // off the selection falls back to `selectPins`, which never draws these, so
    // holding them would hide results from the pins AND (via the dot exclusion)
    // from the dots (codex review).
    //
    // The PROD-3656 kill-switch rides the same listener for the same reason: a
    // flip to off must not leave already-promoted pins on the map, and the dot
    // exclusion is gated on the promotions being non-empty, so releasing them
    // is what hands those results back to the dot layer.
    _ref.listen<bool>(
      experimentServiceProvider.select(
        (s) => s.enableMapPinsV2 && mapPinAutoPromotionEnabled(s),
      ),
      (_, next) {
        if (!next && !state.isEmpty) {
          _promotedAtZoom = null;
          state = const MapAutoPromotions();
        }
      },
    );
    // This provider is created LAZILY — nothing watches it until a v2 response
    // exists, by which time the listener above has already missed that
    // response. Without priming, `_poolSignature` would stay null and the
    // stale-pool guard would block the first zoom-in (the primary path) until
    // some later response landed. `isLoading` is the discriminator: a pool
    // published for the current query is never mid-fetch.
    final pins = _ref.read(mapPinsProvider);
    if (pins.data != null && !pins.isLoading) _poolSignature = _signature;
  }

  final Ref _ref;

  /// PROD-3690 — the whole zoom level (`zoom.floor()`) of the last **settle**,
  /// or null before the first one. A pass runs only when a settle lands on a
  /// strictly deeper level than this.
  ///
  /// Updated on EVERY settle, including zoom-outs — so zooming out to z14 and
  /// back in to z16 promotes again, which is what "per zoom level" means to a
  /// user. The first settle only establishes the baseline (opening the map is
  /// not a zoom-in, and the server's wide-zoom band is its own decision).
  int? _lastPassZoomLevel;

  /// The zoom the current promotions were made at, or null when there are
  /// none. A response for a settled view materially below this releases them.
  double? _promotedAtZoom;

  /// The filter signature the current promotions belong to.
  String _signature = '';

  /// The filter signature the **pool in memory** was fetched for, or null
  /// before the first response.
  ///
  /// `MapPinsState.data` deliberately survives loading, so right after a filter
  /// change the last-good pool is still the OLD search's. Promoting off it would
  /// put results the user just filtered out back on the map — and the additive
  /// merge would then keep them when the new response lands. Promotion waits for
  /// the pool to catch up (codex review).
  String? _poolSignature;

  /// PROD-3690 — decide whether this settle earns a promotion pass.
  ///
  /// Pure bookkeeping plus the zoom-level test; the "how many" half lives in
  /// [_promote].
  void _onSettle(MapQuery q) {
    // PROD-2992 — pin-focus freezes re-selection entirely; a zoom inside focus
    // must not promote either (the plotted set is meant to stay put). Defensive:
    // pin-focus also freezes the settle itself, so this should be unreachable.
    if (_ref.read(mapFrozenViewportProvider) != null) return;
    final level = q.zoom.floor();
    final previous = _lastPassZoomLevel;
    // Recorded before the early returns, so a zoom-out (or a settle that
    // promotes nothing) still re-arms the level it landed on.
    _lastPassZoomLevel = level;
    if (previous == null || level <= previous) return;
    final vp = viewportForMapQuery(q);
    if (vp == null) return;
    _promote(vp);
  }

  void _promote(MapViewport vp) {
    // PROD-3656 kill-switch. Checked here, at the one place a promotion is
    // created, so an off flag leaves `state` permanently empty — every
    // downstream consumer (`withAutoPromotions`, the dot exclusion) is already
    // a no-op on an empty promotion set, which is what makes "off" mean
    // exactly the pre-PROD-3656 map rather than a second code path.
    if (!mapPinAutoPromotionEnabled(_ref.read(experimentServiceProvider))) {
      return;
    }
    final pins = _ref.read(mapPinsProvider);
    // PROD-3657: while a cached pool is pre-painting, the map is on the
    // client-side `selectPins` path, which already spends every slot — the same
    // reason the v1 fallback is excluded below. Promoting here would compute
    // against a server selection the map isn't drawing from.
    if (pins.prepaint != null) return;
    final resp = pins.data;
    if (resp == null) return;
    // The pool still belongs to the previous search — see [_poolSignature].
    if (_poolSignature != _signature) return;
    // v2 only. The v1 fallback runs `selectPins` over the pool, which already
    // spends every slot — promoting there would double-promote.
    final v2 = _ref.read(experimentServiceProvider).enableMapPinsV2;
    final server = v2 ? resp.selection : null;
    if (server == null) return;

    // Promotions that left the (shrinking) viewport stop counting against the
    // cap and stop being drawn. Pruning here — inside the zoom-in pass, where
    // the viewport only ever gets smaller — keeps the live path purely
    // additive for everything still on screen.
    final kept = _withoutAbsorbed(pinsInViewport(state.live, vp), server);
    final base = selectionFromServer(server, vp);
    // PROD-3690 — the gate and the ceiling are one expression: promote only
    // while fewer than kMaxAutoPromotedTotal pins are displayed, and never past
    // that total. `free <= 0` is the ">= 4 already displayed → promote nothing"
    // rule.
    //
    // Was `selectionCapForSource(source)` (25 for `all`, 50 bounded) — a number
    // the server never had anything to do with. The applied v2 cap comes from
    // the backend's `MAP_PINS_SELECTION_BANDS` (8 below z16 for `all`, 20
    // above), and the `selection_cap` the client used to send was read on no
    // code path at all; PROD-3731 stopped sending it. See
    // [kMaxAutoPromotedTotal]. `selectionCapForSource` is still correct for the
    // client-side `selectPins` fallback below — just not for this arithmetic.
    final displayed = base.shown.length + base.bubbles.length + kept.length;
    final free = kMaxAutoPromotedTotal - displayed;

    final dotTapped = _ref.read(mapPromotedPinProvider);
    // PROD-3657 widens what "the pool" means: pins from EARLIER viewports in
    // the same search are promotable too. That matters because `/map/pins`
    // responses are routinely `capped: true` (the 5 km Lisbon default is) — the
    // pool is the N-nearest to *its* centre, so a differently-centred fetch a
    // moment ago can hold results inside this viewport that this response
    // dropped. Appended AFTER the response's own pins so those keep priority in
    // the nearest-first tie-break; deduped by id, and the cache filters by
    // signature + TTL + rect intersection, so this scans one or two entries.
    final pool = [
      ...interleaveMapPool(resp),
      ..._ref
          .read(mapPinsProvider.notifier)
          .cache
          .extraPoolFor(
            _ref.read(mapQueryProvider),
            vp,
            DateTime.now(),
            exclude: {
              for (final p in resp.venues) p.id,
              for (final p in resp.events) p.id,
            },
          ),
    ];
    final added = free <= 0
        ? const <MapPin>[]
        : selectPromotedPins(
            pool: pool,
            // Never double-represent something the map already draws: the RAW
            // server selection (representatives + every stack member,
            // viewport-independent), the live promotions, and PROD-3124's
            // dot-tap promotion.
            excludedIds: <String>{
              ...dotHintExclusionIds(serverSelection: server),
              for (final p in kept) p.id,
              if (dotTapped != null) dotTapped.id,
            },
            occupied: [
              ...promotionAnchorsOf(base),
              ...promotionAnchorsOfPins(kept),
              if (dotTapped != null) ...promotionAnchorsOfPins([dotTapped]),
            ],
            viewport: vp,
            limit: free,
          );

    // Nothing to promote and nothing pruned → don't churn the provider (every
    // write rebuilds the map's marker list).
    if (added.isEmpty && kept.length == state.live.length) return;
    state = MapAutoPromotions(
      live: [...kept, ...added],
      settled: state.settled,
    );
    if (added.isNotEmpty) _promotedAtZoom = vp.zoom;
  }

  void _onQuery(MapQuery q) {
    final signature = q.filterSignature;
    if (signature != _signature) {
      // A new search — different scope, keyword, facets, date or list. The pool
      // is about to be replaced wholesale; nothing promoted from the old one
      // should survive it.
      _signature = signature;
      _promotedAtZoom = null;
      if (!state.isEmpty) state = const MapAutoPromotions();
      // The pool for this search hasn't landed yet, so there is nothing to
      // promote off. `_lastPassZoomLevel` is deliberately left alone: the
      // camera did not move, so the next genuine zoom-in should still count as
      // a level crossing.
      return;
    }
    // Same search, new camera — this is a settle. PROD-3690's trigger.
    _onSettle(q);
  }

  void _onPins(MapPinsState? prev, MapPinsState next) {
    final data = next.data;
    // Loading flips and cancellations keep the same last-good response — only a
    // genuinely new one is a merge point.
    if (data == null || identical(prev?.data, data)) return;

    final q = _ref.read(mapQueryProvider);
    // A published response is never a superseded one (`_fetch` cancels the old
    // token and drops cancelled results), so the pool now belongs to whatever
    // the query says right now. Recorded before the early return below, so an
    // empty promotion set still unblocks the next zoom-in.
    _poolSignature = q.filterSignature;
    if (state.isEmpty) return;

    final promotedAt = _promotedAtZoom;
    if (promotedAt != null &&
        q.zoom < promotedAt - kPromotionReleaseZoomDelta) {
      // Materially wider view: the fresh server selection governs, and the
      // extras demote back to dots.
      _promotedAtZoom = null;
      state = const MapAutoPromotions();
      return;
    }
    // Same-or-deeper view: merge additively and let the settled face catch up,
    // so the grid and the count agree with the map again.
    final viewport = viewportForMapQuery(q);
    var kept = viewport == null
        ? state.live
        : pinsInViewport(state.live, viewport);
    final v2 = _ref.read(experimentServiceProvider).enableMapPinsV2;
    final server = v2 ? data.selection : null;
    if (server != null) kept = _withoutAbsorbed(kept, server);

    // PROD-3657 — the settled face takes only promotions THIS response
    // returned. A promotion drawn from the cache (`extraPoolFor`) is allowed on
    // the map, which is what "pins from earlier viewports become promotable"
    // means; letting it into the settled face would put it in the results grid
    // and the "Ver N resultados" count with no live response behind it, and
    // sticky promotions would keep it there indefinitely (codex review).
    //
    // Stateless on purpose: nothing tracks *where* a promotion came from. If
    // this response happens to contain it, it is simply no longer cache-derived
    // and settles like any other promotion.
    final returned = <String>{
      for (final p in data.venues) p.id,
      for (final p in data.events) p.id,
    };
    final settled = [
      for (final p in kept)
        if (returned.contains(p.id)) p,
    ];
    state = MapAutoPromotions(live: kept, settled: settled);
  }

  /// [pins] minus the ones [server] now represents itself.
  ///
  /// Not a demotion — the server plots them, so the user sees no change. But
  /// leaving them in would charge the cap twice for one marker (once via
  /// `base.shown`, once via the promotion list), and later zoom-ins would then
  /// leave genuinely free slots unfilled (codex review).
  List<MapPin> _withoutAbsorbed(List<MapPin> pins, MapServerSelection server) {
    if (pins.isEmpty) return pins;
    final represented = dotHintExclusionIds(serverSelection: server);
    if (represented.isEmpty) return pins;
    return [
      for (final p in pins)
        if (!represented.contains(p.id)) p,
    ];
  }
}

final mapAutoPromotionsProvider =
    StateNotifierProvider.autoDispose<
      MapAutoPromotionsNotifier,
      MapAutoPromotions
    >((ref) => MapAutoPromotionsNotifier(ref));

/// PROD-2807 — the on-screen selection derived from the last-good `/map/pins`
/// pool + the current camera.
///
/// This is the **single source of truth for both the map and the grid**:
/// [MapSelection.shown] are the individually plotted pins — which are *exactly*
/// the results grid ("map = grid") and the "Ver N resultados" count
/// ("count = shown") — and [MapSelection.bubbles] are the `+k` overflow
/// markers. Recomputes on every **live** camera move (#4: instant re-select),
/// every [MapQuery] change (settle / zoom / filter), and whenever the pool
/// refetches; the pool itself is only refetched on settle.
final mapSelectionProvider = Provider.autoDispose<MapSelection>((ref) {
  // Seeded (chat) map: return the fixed selection, bypassing the live pipeline.
  // A root read (not a scope override) so `mapMarkersProvider` etc. pick it up
  // with no `dependencies` marking. Null on `/map` → falls through, unchanged.
  final seed = ref.watch(mapSeedProvider);
  if (seed != null) return seed.selection;
  final q = ref.watch(mapQueryProvider);
  if (!q.hasCenter) return const MapSelection();

  // PROD-3657: the MAP draws the pre-paint when a cached pool covers this
  // viewport and the response is still in flight, else the last-good response.
  // The grid + count face below stays on `data` so they don't reset twice per
  // settle. A pre-paint carries no `selection`, so the branch below falls
  // through to `selectPins` — the right answer for the camera we're on.
  final resp = ref.watch(mapPinsProvider).displayData;
  if (resp == null) return const MapSelection();

  // The live viewport (updated mid-gesture) drives instant re-selection; before
  // the first camera event it's null → fall back to the settled MapQuery box.
  //
  // PROD-2992: while pin-focus has pinned a viewport, select against THAT and do
  // not watch the live viewport — so panning/zooming inside focus leaves the
  // plotted set frozen (AC: "no live re-selection"). `ref.watch` is conditional
  // on purpose: skipping it in this branch drops the live-viewport dependency,
  // so live changes can't rebuild this provider while frozen.
  final frozen = ref.watch(mapFrozenViewportProvider);
  final viewport =
      frozen ?? ref.watch(mapLiveViewportProvider) ?? viewportForMapQuery(q);
  if (viewport == null) return const MapSelection();

  // PROD-2906 (A6): when the server computed the selection (v2), re-slice it to
  // the live viewport instead of running selectPins; when absent (v1 / server
  // flag off), fall back to the client-side selection over the pool.
  // Only honour a server selection while the FE opt-in is ON — if the flag is
  // flipped off, a still-cached v2 `selection` (superseding v1 refetch in
  // flight / cancelled / failed) must NOT keep the map server-side; ignore it
  // and fall back immediately, so the flag is authoritative in both directions.
  // PROD-3124 dot tap: a dot-promoted item joins the shown set (captioned
  // pin) even when the relevance selection didn't pick it. Applied on BOTH
  // selection providers so map + grid + count stay in agreement.
  final promoted = ref.watch(mapPromotedPinProvider);

  final selection = _serverSelectionIfEnabled(ref, resp);
  if (selection != null) {
    // PROD-3656: the pins auto-promoted into the cap slots this zoom freed —
    // the LIVE face, so they land in the same frame as the gesture. Applied
    // only here (the v2 path): `selectPins` below already spends every slot.
    return withAutoPromotions(
      withPromotedPin(
        selectionFromServer(selection, viewport),
        promoted,
        viewport,
      ),
      ref.watch(mapAutoPromotionsProvider.select((s) => s.live)),
      viewport,
    );
  }
  // PROD-2947 (FE-1): bounded scopes (yours/following) surface up to 50 pins.
  return withPromotedPin(
    selectPins(
      pool: interleaveMapPool(resp),
      viewport: viewport,
      cap: selectionCapForSource(q.source),
    ),
    promoted,
    viewport,
  );
});

/// The server-side `selection` to consume, or null — null unless the FE opt-in
/// flag `map-pins-v2` is on (so an off flag falls back to `selectPins` even if a
/// v2 response is still cached; PROD-2906, codex review).
MapServerSelection? _serverSelectionIfEnabled(Ref ref, MapPinsResponse resp) {
  final enabled = ref.watch(
    experimentServiceProvider.select((s) => s.enableMapPinsV2),
  );
  return enabled ? resp.selection : null;
}

/// PROD-2807 (#4) — the selection computed from the **settled** viewport
/// ([MapQuery]), used by the results GRID.
///
/// The map pins + the count line re-select live off [mapSelectionProvider]
/// (cheap client-side work), but the grid hydrates cards via `/map/hydrate`,
/// which — like the pool refetch — must be **settle-gated**, not fired on every
/// throttled mid-gesture move. This changes only when the camera settles (a
/// [MapQuery] change) or the pool refetches, so the grid doesn't thrash /
/// re-hydrate while the user is dragging.
final mapSettledSelectionProvider = Provider.autoDispose<MapSelection>((ref) {
  // Seeded (chat) map: the settled selection IS the fixed set (nothing settles).
  final seed = ref.watch(mapSeedProvider);
  if (seed != null) return seed.selection;
  final q = ref.watch(mapQueryProvider);
  if (!q.hasCenter) return const MapSelection();

  final resp = ref.watch(mapPinsProvider).data;
  if (resp == null) return const MapSelection();

  final viewport = viewportForMapQuery(q);
  if (viewport == null) return const MapSelection();

  // PROD-2906 (A6): prefer the server selection (v2), trimmed to the settled
  // viewport rect (drops the server's 1-cell ring buffer so the grid lists
  // exactly what's on screen); fall back to selectPins when absent (v1) or when
  // the FE opt-in flag is off (ignore a stale cached v2 selection — codex).
  // PROD-3124 dot tap: the promoted pin joins here too, so the grid + count
  // agree with the map.
  final promoted = ref.watch(mapPromotedPinProvider);
  final selection = _serverSelectionIfEnabled(ref, resp);
  if (selection != null) {
    // PROD-3656: the SETTLED face of the auto-promotions — it only moves when a
    // response lands, so the grid never rebuilds (and never re-hydrates)
    // mid-gesture, yet post-settle the grid + count list exactly what the map
    // plots.
    return withAutoPromotions(
      withPromotedPin(
        selectionFromServer(selection, viewport),
        promoted,
        viewport,
      ),
      // `select` is load-bearing, not a micro-optimisation: a zoom-in emits a
      // new MapAutoPromotions with the SAME `settled` list, and watching the
      // whole provider would rebuild this one anyway — which recreates
      // `mapGridProvider`, rewinds the drawer's scroll and re-fires
      // `/map/hydrate` mid-gesture, exactly what the split exists to prevent
      // (codex review). Identity comparison is what makes it work: the settled
      // face is only ever REPLACED, never mutated.
      ref.watch(mapAutoPromotionsProvider.select((s) => s.settled)),
      viewport,
    );
  }
  // PROD-2947 (FE-1): bounded scopes (yours/following) surface up to 50 pins.
  return withPromotedPin(
    selectPins(
      pool: interleaveMapPool(resp),
      viewport: viewport,
      cap: selectionCapForSource(q.source),
    ),
    promoted,
    viewport,
  );
});

/// The camera viewport for selection — the settled rectangle when we have it,
/// else an approximate centre+radius box (before the first settle, on a seeded
/// centre) so the initial fetch's pins still get selected. Public so the dot
/// hints provider (PROD-3124) derives its settled viewport identically.
MapViewport? viewportForMapQuery(MapQuery q) {
  if (q.hasBounds) {
    return MapViewport(
      swLat: q.swLat!,
      swLng: q.swLng!,
      neLat: q.neLat!,
      neLng: q.neLng!,
      zoom: q.zoom,
    );
  }
  if (!q.hasCenter) return null;
  final lat = q.centerLat!;
  final lng = q.centerLng!;
  final dLat = q.radiusMeters / 111320.0;
  final cos = math.cos(lat * math.pi / 180.0).abs();
  final dLng = q.radiusMeters / (111320.0 * (cos < 1e-6 ? 1e-6 : cos));
  return MapViewport(
    swLat: lat - dLat,
    swLng: lng - dLng,
    neLat: lat + dLat,
    neLng: lng + dLng,
    zoom: q.zoom,
  );
}
