// `characters` (grapheme-safe truncation) via the widgets re-export — a
// direct `package:characters` import trips `depend_on_referenced_packages`.
import 'package:flutter/widgets.dart' show StringCharacters;

import '../../../data/models/discovery_facets.dart';
import '../../../data/models/map_pin.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/map_marker_model.dart';
import '../../discovery/utils/facet_labels.dart';

/// PROD-2671 — resolves the Map page's inline pin / cluster labels.
///
/// Kept OUT of `mapMarkersProvider` (which is context-free) so localization can
/// use the `Lt` instance + the loaded facet catalog. `map_screen` runs
/// [withMapPinLabels] over the raw markers each build.

/// Placeholder title for a single pin, used only when `/map/pins` returns a
/// null/blank `name` (PROD-2868 makes `name` optional — a missing name must
/// never drop the pin).
String mapPinPlaceholderTitle(Lt l10n, {required bool isEvent}) =>
    isEvent ? l10n.mapPinEventPlaceholder : l10n.mapPinVenuePlaceholder;

/// Max length of a single pin's caption title. Long names (event titles can be
/// full headlines) wrap to 4-5 lines beside the pin and dominate the map; at
/// the caption layers' `text-max-width: 12` (ems) a 40-char title wraps to
/// ~2 lines. A character cap because Mapbox symbol text has no native
/// max-lines/ellipsis knob — `text-max-width` only sets the wrap width.
const int mapPinTitleMaxChars = 40;

/// Truncate a pin caption title to [mapPinTitleMaxChars] characters plus an
/// ellipsis. Counts GRAPHEMES (via `characters`) so an emoji or combining
/// accent is never split mid-cluster; trailing whitespace before the ellipsis
/// is trimmed ("Foo …" → "Foo…").
String truncateMapPinTitle(String title) {
  final graphemes = title.characters;
  if (graphemes.length <= mapPinTitleMaxChars) return title;
  return '${graphemes.take(mapPinTitleMaxChars).toString().trimRight()}…';
}

/// The **localized** subtitle for a pin caption — the item's category.
///
/// Sourced from the **primary facet's sub-category (child)** — e.g.
/// "Restaurantes", "Cafés", "Bares". The primary facet is populated for ~every
/// typed pin and its child is *more specific than the icon* (which conveys only
/// the parent). The backend `secondary_facets` field is the OVERLAP *beyond*
/// the primary — empty for most items (a restaurant maps to just one pair), so
/// it can't be the main source; it's a fallback only when the pin carries no
/// primary facet at all. Null only when the pin has no facet whatsoever.
String? mapPinFacetSubtitle(Lt l10n, DiscoveryFacets? catalog, MapPin pin) {
  final primary = pin.primaryFacet;
  if (primary != null) return _facetPairLabel(l10n, catalog, primary);
  if (pin.secondaryFacets.isNotEmpty) {
    return _facetPairLabel(l10n, catalog, pin.secondaryFacets.first);
  }
  return null;
}

/// Localize one [FacetPair] — the child chip (preferred) else the parent —
/// resolved within its OWN parent (child slugs repeat across parents, e.g.
/// `bars` under both `eat_drink` and `nightlife`) via [mapFacetLabel] (ARB →
/// backend English `label` + a one-time warn). Falls back to a prettified slug
/// when the loaded [catalog] doesn't know the facet (or hasn't loaded), so the
/// subtitle is never silently dropped.
String? _facetPairLabel(Lt l10n, DiscoveryFacets? catalog, FacetPair pair) {
  if (catalog != null) {
    for (final parent in catalog.parents) {
      if (parent.id != pair.parent) continue;
      if (pair.child == null) {
        return mapFacetLabel(
          l10n,
          labelKey: parent.labelKey,
          fallbackLabel: parent.label,
        );
      }
      for (final c in parent.childrenFor(wantVenue: true, wantEvent: true)) {
        if (c.slug == pair.child) {
          return mapFacetLabel(
            l10n,
            labelKey: c.labelKey,
            fallbackLabel: c.label,
          );
        }
      }
      break; // parent matched but no such child → prettify below
    }
  }
  return prettifyFacetSlug(pair.child ?? pair.parent);
}

/// The cluster title — "X venues" over "Y events" (only the present lines).
///
/// [countCapped] (PROD-2906 A6): when the v2 server marked the cell as
/// saturated, its counts are lower bounds — append "+" so the title reads
/// "X venues+ / Y events+". Never trips at launch (v1 selection is always
/// exact); the branch exists so a future dense-cell cap renders honestly.
String mapClusterTitle(
  Lt l10n, {
  required int venueCount,
  required int eventCount,
  bool countCapped = false,
}) {
  final suffix = countCapped ? '+' : '';
  final lines = <String>[];
  if (venueCount > 0) lines.add('${l10n.mapClusterVenues(venueCount)}$suffix');
  if (eventCount > 0) lines.add('${l10n.mapClusterEvents(eventCount)}$suffix');
  return lines.join('\n');
}

/// Attach the localized inline labels to the Map page markers produced by
/// (context-free) `mapMarkersProvider`. Single pins get a placeholder title +
/// their secondary-facet label; overflow bubbles get the "X venues / Y events"
/// count title (carried in [MapMarker.pinTitle], which the renderers stamp as
/// the `bubble_title` feature property).
List<MapMarker> withMapPinLabels({
  required Lt l10n,
  required DiscoveryFacets? catalog,
  required List<MapMarker> markers,
}) {
  return markers
      .map((m) {
        if (m.type == MapMarkerType.userLocation) return m;
        if (m.overflowCount != null) {
          return m.copyWith(
            pinTitle: mapClusterTitle(
              l10n,
              venueCount: m.venueCount ?? 0,
              eventCount: m.eventCount ?? 0,
              countCapped: m.overflowCountCapped,
            ),
          );
        }
        final pin = m.data is MapPin ? m.data as MapPin : null;
        final name = pin?.name?.trim();
        return m.copyWith(
          // PROD-2868: render the real venue name / event title; fall back to
          // the localized placeholder only when the backend sent no name.
          // Long names are capped at [mapPinTitleMaxChars] + ellipsis so a
          // headline-length title can't sprawl to 4-5 caption lines.
          pinTitle: (name != null && name.isNotEmpty)
              ? truncateMapPinTitle(name)
              : mapPinPlaceholderTitle(l10n, isEvent: pin?.isEvent ?? false),
          pinSubtitle: pin == null
              ? null
              : mapPinFacetSubtitle(l10n, catalog, pin),
        );
      })
      .toList(growable: false);
}
