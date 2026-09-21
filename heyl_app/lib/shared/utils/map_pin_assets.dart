/// PROD-2671 — map pin assets + facet→pin resolution, shared by every map
/// surface (PROD-3828 lifted this out of `features/map/` so the chat, list,
/// zine and detail maps can import it too — PROD-3830 rolls them over).
///
/// Pins are **teardrop glyphs keyed by primary facet** — one pin per category,
/// a single colour (a decorative Soko-palette accent; events and venues share
/// the same category pin, so colour no longer encodes the entity type). Each pin
/// is registered with Mapbox under a **key** and a `MapMarker.iconImage` carries
/// that key; [kMapPinAssets] maps key → bundled asset path (passed to
/// `MapboxMapWidget.categoryIconAssets`, which `addImage`s each on web + native).
///
/// A pin whose facet has no dedicated art (or a null facet) falls back to the
/// single generic pin — [kDefaultPinKey] (pink), shared by events and venues.
library;

import '../../data/models/map_pin.dart';

/// The generic pin key — the pink fallback shared by events and venues when
/// a facet has no mapped pin (or the facet is null).
const String kDefaultPinKey = 'pin-default';

/// Primary-facet slug → pin key (`pin-<key>.png`). One pin per category
/// (single colour, shared by events + venues). Designer refresh (2026-07-09).
///
/// Keys are **parent** facet slugs — [mapPinKey] resolves on
/// `FacetPair.parent`, so nothing that isn't a parent can ever match.
///
/// **Six** of the ten entries are live. The backend taxonomy
/// (`heyl/core/taxonomy/discovery_facets.py`) defines exactly six parent
/// facets in `DISCOVERY_PARENTS` — `eat_drink`, `art`, `music`, `nightlife`,
/// `outdoors`, `shopping` — and only those can appear as a `FacetPair.parent`.
///
/// ⚠️ The other four entries are **inert**, for two different reasons. Both
/// are easy to misread, so before "fixing" either, read this:
///
/// * `family`, `date_worthy`, `free` are **lenses, not parents**. They live in
///   `DISCOVERY_LENSES` as a *different dataclass* (`Lens`, not `ParentFacet`)
///   whose docstring reads "A composable attribute filter (not a type).
///   Filter-only: NOT emitted as a result tag." A lens is a predicate over an
///   attribute (`free` is `price_type == "free"`), not a category an item *is*.
///   The reverse-projection maps that build every `FacetPair` iterate
///   `DISCOVERY_PARENTS` only, so no lens id can ever reach one. They are NOT
///   "waiting to be added to the taxonomy" — they are already in it, as a kind
///   of thing that is deliberately never emitted. PROD-2736 wires lens
///   *filtering* into search and still won't emit them as `primary_facet`.
/// * `sports` is a **child** slug (under `outdoors` for venues, and under
///   other parents for events), not a parent. A sports venue therefore draws
///   the `outdoors` teardrop.
///
/// The art for all four ships and stays — keeping an unused PNG is harmless,
/// and dropping it is a call about the design set rather than a code cleanup.
///
/// Separately, a parent existing in the taxonomy still doesn't guarantee the
/// backend selects it as an item's `primary_facet` on any given payload; which
/// endpoints start sending it is PROD-3831/3832. An absent or unmapped parent
/// already falls back to [kDefaultPinKey].
///
/// (Verified against the taxonomy 2026-08-09. An earlier revision of this
/// comment claimed nine live parents — that came from grepping `id="`, which
/// cannot tell `ParentFacet` from `Lens`, since both dataclasses have an `id`.)
const Map<String, String> kFacetPinKey = {
  // The six live parent facets (`DISCOVERY_PARENTS`).
  'eat_drink': 'pin-eat_drink',
  'art': 'pin-art',
  'music': 'pin-music',
  'nightlife': 'pin-nightlife',
  'outdoors': 'pin-outdoors',
  'shopping': 'pin-shopping',
  // Inert — lenses (`DISCOVERY_LENSES`), never emitted as a result tag.
  'family': 'pin-family',
  'date_worthy': 'pin-date_worthy',
  'free': 'pin-free',
  // Inert — a CHILD slug, not a parent; sports venues draw `pin-outdoors`.
  'sports': 'pin-sports',
};

/// Every pin key → its bundled asset path. Passed to
/// `MapboxMapWidget.categoryIconAssets` so the map widgets register each image
/// with Mapbox (`addImage`): the generic pin + each category pin.
final Map<String, String> kMapPinAssets = {
  kDefaultPinKey: 'assets/pins/$kDefaultPinKey.png',
  for (final key in kFacetPinKey.values) key: 'assets/pins/$key.png',
};

/// The pin key resolved from its [primaryFacet] (parent slug). One pin per
/// category regardless of entity; falls back to [kDefaultPinKey] when the
/// facet is null or isn't in [kFacetPinKey].
String mapPinKey({FacetPair? primaryFacet}) {
  final key = primaryFacet == null ? null : kFacetPinKey[primaryFacet.parent];
  return key ?? kDefaultPinKey;
}
