import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/experiment_service.dart';
import '../utils/map_dot_hints.dart';
import 'map_markers_provider.dart';
import 'map_query_provider.dart';
import 'map_selection_provider.dart';
import 'map_ui_state_provider.dart';

/// PROD-3124 — the dot hints for the current settled viewport.
///
/// Thin glue over the pure engine (`map_dot_hints.dart`, unit-tested there):
/// pool + settled query in, `List<MapDotHint>` out. The **viewport** is
/// deliberately **settle-gated** — it comes from the settled [mapQueryProvider],
/// not the throttled [mapLiveViewportProvider], so panning doesn't re-select
/// dots. Pins re-slice live above them; dots are hints and don't need
/// mid-gesture work.
///
/// The one exception (PROD-3656) is the *exclusion* set: an auto-promoted dot
/// becomes a pin mid-gesture, and it must stop being a dot in that same frame.
///
/// Exclusion (never dot a rendered result): on the v2 path the RAW server
/// `selection` (all representatives + full stack members — viewport-
/// independent, so it stays exact while the live re-slice pans the buffered
/// ring); on the v1 fallback the settled client-side selection. Mirrors the
/// flag-authoritative rule of `_serverSelectionIfEnabled` — an off flag must
/// not let a cached v2 selection drive the exclusion while the pins fell back.
final mapDotHintsProvider = Provider.autoDispose<List<MapDotHint>>((ref) {
  final q = ref.watch(mapQueryProvider);
  if (!q.hasCenter) return const [];

  // PROD-3657: no dots while a cached pool is pre-painting. The pre-paint runs
  // the map through the client-side `selectPins`, which spends the WHOLE pool
  // (shown or inside a `+k`), so by construction there is nothing left over to
  // hint about — and dotting the away-area pool's leftovers would put hints
  // where the map isn't drawing from. Lasts only until the response lands.
  final pins = ref.watch(mapPinsProvider);
  if (pins.prepaint != null) return const [];
  final resp = pins.data;
  if (resp == null) return const [];

  final viewport = viewportForMapQuery(q);
  if (viewport == null) return const [];

  final v2Enabled = ref.watch(
    experimentServiceProvider.select((s) => s.enableMapPinsV2),
  );
  final serverSelection = v2Enabled ? resp.selection : null;
  // PROD-3124 dot tap: a promoted item renders as a pin (withPromotedPin) —
  // never double-represent it as a dot.
  final promoted = ref.watch(mapPromotedPinProvider);
  // PROD-3656: same rule for the auto-promotions — "never a pin and its own dot
  // on screen at once". This is the ONE place the dot layer is deliberately not
  // settle-gated: the promotion lands mid-gesture, so its dot has to go in the
  // same frame. Cheap (a pure pass over the cached pool, no network), and it
  // only fires on discrete zoom-in steps, not on every camera frame.
  final auto = ref.watch(mapAutoPromotionsProvider);
  final excluded = <String>{
    ...dotHintExclusionIds(
      serverSelection: serverSelection,
      settledSelection: serverSelection == null
          ? ref.watch(mapSettledSelectionProvider)
          : null,
    ),
    if (promoted != null) promoted.id,
    // Gated on the SAME condition `mapSelectionProvider` uses to apply them —
    // a live server selection, which also covers the flag being off and the
    // backend's own kill-switch (flag on, no `selection` in the response).
    // Without the gate, a fallback to `selectPins` (which never draws these)
    // would leave a promoted result excluded from the dots too, erasing it from
    // both layers. The notifier releases them on a flag flip as well — this just
    // doesn't depend on which listener runs first.
    if (serverSelection != null) ...[
      for (final p in auto.live) p.id,
      for (final p in auto.settled) p.id,
    ],
  };

  return selectDotHints(
    venues: resp.venues,
    events: resp.events,
    excludedIds: excluded,
    viewport: viewport,
    source: q.source,
    entity: q.entityWire,
    // PROD-3124 debug knobs — null/default outside the debug panel. Watching
    // them makes slider drags re-select instantly over the cached pool.
    capOverride: ref.watch(mapDotAllowanceOverrideProvider),
    eventShare: ref.watch(mapDotEventShareOverrideProvider) ?? kDotEventShare,
  );
});

/// The dots as a ready-to-render GeoJSON FeatureCollection — null when there
/// are none. Derived here (not in the screen's build) so its IDENTITY is
/// stable between settles: the map widgets re-sync + re-run the fade on
/// `!identical(...)`, and a per-frame rebuild in the screen would re-trigger
/// the fade on every unrelated rebuild.
final mapDotHintsGeoJsonProvider = Provider.autoDispose<Map<String, dynamic>?>((
  ref,
) {
  final dots = ref.watch(mapDotHintsProvider);
  if (dots.isEmpty) return null;
  return buildDotHintsFeatureCollection(dots);
});
