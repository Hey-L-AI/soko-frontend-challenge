import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../data/models/category_facet.dart';
import '../../../data/models/place_type_facet.dart';
import '../../../l10n/generated/l10n.dart';

// PROD-2671 — single source of truth for facet chip labels.
//
// The backend owns the facet taxonomy and ships each facet with a stable
// `label_key` plus an English-only `label`; the app localizes client-side
// by mapping `label_key` → ARB (PROD-2369). This logic used to be
// duplicated in three widgets (the event + place filter bars and the Map
// page); it now lives here.
//
// Event and place are separate catalogs — the same `label_key` (e.g.
// `facet.arts_culture`) maps to different ARB strings per catalog — so
// resolution is keyed on both the catalog and the label key.
//
// When a *visible* facet has no client translation (a backend taxonomy
// addition the app hasn't caught up to), the label falls back to the
// backend's English `label` AND a one-time Sentry warning fires, so we're
// alerted and can add the ARB entry + a case below quickly.

/// Which facet catalog a label belongs to (each has distinct ARB keys).
///
/// [event]/[place] are the FLAT per-entity catalogs (discovery filter chips).
/// [map] is the two-layer discovery catalog (`GET /discovery/facets`) the Map
/// page renders — a SEPARATE namespace whose keys are `facet.{parent}` (parent)
/// and `facet.{parent}.{slug}` (curated child), so it resolves independently.
enum FacetCatalog { event, place, map }

/// Localized label for an **event** category facet.
String eventFacetLabel(Lt l10n, CategoryFacet facet) => _facetLabel(
  l10n,
  catalog: FacetCatalog.event,
  labelKey: facet.labelKey,
  fallbackLabel: facet.label,
);

/// Localized label for a **place** type facet.
String placeFacetLabel(Lt l10n, PlaceTypeFacet facet) => _facetLabel(
  l10n,
  catalog: FacetCatalog.place,
  labelKey: facet.labelKey,
  fallbackLabel: facet.label,
);

/// Localized label for a **map** two-layer discovery facet (parent OR curated
/// child), resolved by its `label_key` from `GET /discovery/facets`. Used for
/// the Map page pin caption's secondary facet (and, later, the Tema sheet).
///
/// Fallback chain — this is the "FE/BE disconnection" contract:
///   1. localized ARB (when we ship a translation for this `label_key`),
///   2. else the backend English [fallbackLabel] (always present on the
///      catalog) + a one-time Sentry warning so a taxonomy drift surfaces.
/// When the pin references a facet **not in the loaded catalog at all** (a
/// harder disconnect), the caller ([mapPinFacetSubtitle]) prettifies the raw
/// slug via [prettifyFacetSlug] instead — this function only runs once we have
/// a catalog entry (hence a real [fallbackLabel]).
String mapFacetLabel(
  Lt l10n, {
  required String labelKey,
  required String fallbackLabel,
}) => _facetLabel(
  l10n,
  catalog: FacetCatalog.map,
  labelKey: labelKey,
  fallbackLabel: fallbackLabel,
);

/// Human-readable fallback for a facet **slug** when the catalog has no entry
/// for it — the hard FE/BE disconnect (a pin references a facet the loaded
/// `/discovery/facets` doesn't know, e.g. a new backend taxonomy addition or a
/// failed/stale catalog fetch). `live_music` → "Live Music". Keeps the pin's
/// subtitle non-empty instead of dropping it.
String prettifyFacetSlug(String slug) => slug
    .split(RegExp(r'[_\-\s]+'))
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');

String _facetLabel(
  Lt l10n, {
  required FacetCatalog catalog,
  required String labelKey,
  required String fallbackLabel,
}) {
  final localized = switch (catalog) {
    FacetCatalog.event => _eventLabel(l10n, labelKey),
    FacetCatalog.place => _placeLabel(l10n, labelKey),
    FacetCatalog.map => _mapLabel(l10n, labelKey),
  };
  if (localized != null) return localized;
  _warnMissingTranslation(catalog, labelKey, fallbackLabel);
  return fallbackLabel;
}

String? _eventLabel(Lt l10n, String labelKey) => switch (labelKey) {
  'facet.music' => l10n.discoveryEventFacetMusic,
  'facet.arts_culture' => l10n.discoveryEventFacetArtsCulture,
  'facet.food_drink' => l10n.discoveryEventFacetFoodDrink,
  'facet.nightlife' => l10n.discoveryEventFacetNightlife,
  'facet.learning' => l10n.discoveryEventFacetLearning,
  'facet.family' => l10n.discoveryEventFacetFamily,
  'facet.outdoors_wellbeing' => l10n.discoveryEventFacetOutdoorsWellbeing,
  'facet.sports' => l10n.discoveryEventFacetSports,
  'facet.community' => l10n.discoveryEventFacetCommunity,
  'facet.networking' => l10n.discoveryEventFacetNetworking,
  'facet.markets_shopping' => l10n.discoveryEventFacetMarketsShopping,
  _ => null,
};

/// Localized ARB for a **map** two-layer facet `label_key`. Keys follow
/// `facet.{parent}` (6 parents) and `facet.{parent}.{slug}` (curated children)
/// from `heyl/core/taxonomy/discovery_facets.py`. Child slugs that repeat across
/// parents with the same label (`bars`, `markets`) share one ARB key. Any key
/// NOT here falls through to the backend English `label` via [mapFacetLabel].
String? _mapLabel(Lt l10n, String labelKey) => switch (labelKey) {
  // Parents.
  'facet.eat_drink' => l10n.mapFacetEatDrink,
  'facet.art' => l10n.mapFacetArt,
  'facet.music' => l10n.mapFacetMusic,
  'facet.nightlife' => l10n.mapFacetNightlife,
  'facet.outdoors' => l10n.mapFacetOutdoors,
  'facet.shopping' => l10n.mapFacetShopping,
  // eat_drink children.
  'facet.eat_drink.restaurants' => l10n.mapFacetRestaurants,
  'facet.eat_drink.cafes' => l10n.mapFacetCafes,
  'facet.eat_drink.pastry' => l10n.mapFacetPastry,
  'facet.eat_drink.bars' || 'facet.nightlife.bars' => l10n.mapFacetBars,
  'facet.eat_drink.markets' || 'facet.shopping.markets' => l10n.mapFacetMarkets,
  'facet.eat_drink.events' => l10n.mapFacetEvents,
  // art children.
  'facet.art.museums' => l10n.mapFacetMuseums,
  'facet.art.cinema' => l10n.mapFacetCinema,
  'facet.art.cultural_centres' => l10n.mapFacetCulturalCentres,
  'facet.art.landmarks' => l10n.mapFacetLandmarks,
  'facet.art.exhibitions' => l10n.mapFacetExhibitions,
  'facet.art.performative_arts' => l10n.mapFacetPerformativeArts,
  'facet.art.literature' => l10n.mapFacetLiterature,
  'facet.art.comedy' => l10n.mapFacetComedy,
  'facet.art.festivals' => l10n.mapFacetFestivals,
  'facet.art.workshops' => l10n.mapFacetWorkshops,
  // music children.
  'facet.music.venues' => l10n.mapFacetVenues,
  'facet.music.live_music' => l10n.mapFacetLiveMusic,
  'facet.music.electronic' => l10n.mapFacetElectronic,
  // nightlife children (bars shared above).
  'facet.nightlife.clubs' => l10n.mapFacetClubs,
  'facet.nightlife.wineries' => l10n.mapFacetWineries,
  'facet.nightlife.parties' => l10n.mapFacetParties,
  // outdoors children.
  'facet.outdoors.parks' => l10n.mapFacetParks,
  'facet.outdoors.beaches' => l10n.mapFacetBeaches,
  'facet.outdoors.trails' => l10n.mapFacetTrails,
  'facet.outdoors.sports' => l10n.mapFacetSports,
  'facet.outdoors.activities' => l10n.mapFacetActivities,
  'facet.outdoors.games' => l10n.mapFacetGames,
  // shopping children (markets shared above).
  'facet.shopping.shops' => l10n.mapFacetShops,
  'facet.shopping.specialty' => l10n.mapFacetSpecialty,
  _ => null,
};

String? _placeLabel(Lt l10n, String labelKey) => switch (labelKey) {
  'facet.eat_drink' => l10n.discoveryPlaceFacetEatDrink,
  'facet.bars_nightlife' => l10n.discoveryPlaceFacetBarsNightlife,
  'facet.shops_markets' => l10n.discoveryPlaceFacetShopsMarkets,
  'facet.arts_culture' => l10n.discoveryPlaceFacetArtsCulture,
  'facet.music_events' => l10n.discoveryPlaceFacetMusicEvents,
  'facet.entertainment' => l10n.discoveryPlaceFacetEntertainment,
  'facet.sights_heritage' => l10n.discoveryPlaceFacetSightsHeritage,
  'facet.outdoors_nature' => l10n.discoveryPlaceFacetOutdoorsNature,
  'facet.sports_fitness' => l10n.discoveryPlaceFacetSportsFitness,
  'facet.learning_community' => l10n.discoveryPlaceFacetLearningCommunity,
  _ => null,
};

/// One warning per `(catalog, label_key)` per app session — enough to
/// alert us in Sentry without flooding on every rebuild.
final Set<String> _warnedFacetKeys = <String>{};

void _warnMissingTranslation(
  FacetCatalog catalog,
  String labelKey,
  String fallbackLabel,
) {
  if (!_warnedFacetKeys.add('${catalog.name}:$labelKey')) return;

  if (kDebugMode) {
    debugPrint(
      '[facet] No client translation for ${catalog.name} facet "$labelKey" '
      '— falling back to backend label "$fallbackLabel". Add an ARB entry '
      '+ a case in facet_labels.dart.',
    );
  }

  try {
    Sentry.captureMessage(
      'facet.missing_translation',
      level: SentryLevel.warning,
      withScope: (scope) {
        scope.setTag('facet_catalog', catalog.name);
        scope.setTag('facet_label_key', labelKey);
        scope.setTag('facet_fallback_label', fallbackLabel);
      },
    );
  } catch (_) {
    // Telemetry must never break label rendering.
  }
}
