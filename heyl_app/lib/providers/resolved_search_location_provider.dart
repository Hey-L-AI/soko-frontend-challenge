import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/models/area_prediction.dart';
import '../data/models/geo_boundary.dart';
import '../data/models/geo_city.dart';
import '../data/models/resolved_search_location.dart';
import '../features/lists/models/search_scope.dart';
import '../features/map/utils/map_boundary_scope.dart';
import '../shared/utils/search_range.dart';
import 'api_provider.dart';
import 'city_auto_scope_provider.dart';
import 'city_scope_provider.dart';
import 'locale_provider.dart';
import 'location_provider.dart';

/// **The single resolver for the Search Center (C)** (PROD-3181).
///
/// Reads the explicit pick ([cityScopeProvider]) first, else the auto cascade
/// ([cityAutoScopeProvider]), and folds whichever [SearchScope] variant results
/// into one [ResolvedSearchLocation]. All scope branching and Google-city
/// coordinate resolution lives here; older discovery providers are thin
/// projections of this value for compatibility.
///
/// Surfaces read the facet they need off the returned object: coord shelves +
/// Near-You use `center` + `radiusMeters`; Highlighted / Spaces use `cityId`;
/// the pill / debug use `label`.
typedef SearchScopeResolutionRequest = ({SearchScope? scope, bool isExplicit});

/// Resolves a specific scope without first publishing it as global C. Picker
/// and Map commits use this preview to persist the active chat before exposing
/// the new global value, preventing a failed session write from splitting C.
final resolvedSearchScopeProvider = FutureProvider.autoDispose
    .family<ResolvedSearchLocation, SearchScopeResolutionRequest>((
      ref,
      request,
    ) async {
      final scope = request.scope;
      final isExplicit = request.isExplicit;

      switch (scope) {
        case SearchScopeArea a:
          return _resolveArea(
            a,
            isExplicit: isExplicit,
            origin: ResolvedLocationOrigin.area,
          );
        case SearchScopeCountryCity c:
          final city = await _resolveCityCoordinates(ref, c.city);
          final boundary = await ref.watch(
            resolvedCityBoundaryProvider(city).future,
          );
          // `boundary.city` (same UUID as `city`, guaranteed by
          // matchingBoundaryForCity) carries only {id,name,lat,lon} and so
          // lacks the `/geo/cities` `is_open` flag — graft it back on from the
          // resolved city so an open city keeps driving the discovery hero.
          final effectiveCity = boundary?.city?.withOpenFrom(city) ?? city;
          return ResolvedSearchLocation(
            centerLat: boundary?.centroidLat ?? city.latitude,
            centerLon: boundary?.centroidLon ?? city.longitude,
            // A proven admin boundary owns the city radius. Point-only / Google
            // picks retain the legacy tier until canonical city identity lands.
            radiusMeters:
                boundary?.recommendedRadiusM.toDouble() ??
                SearchRange.city.radiusMeters,
            cityId: _feedCityId(effectiveCity),
            city: effectiveCity,
            boundaryId: boundary?.id,
            boundary: boundary,
            label: '${c.city.name}, ${c.iso2}',
            cityName: effectiveCity.name,
            countryCode: c.iso2,
            isExplicit: isExplicit,
            origin: isExplicit
                ? ResolvedLocationOrigin.city
                : ResolvedLocationOrigin.auto,
          );
        case SearchScopeCountry co:
          return ResolvedSearchLocation(
            label: co.countryName,
            countryCode: co.iso2,
            isExplicit: isExplicit,
            origin: isExplicit
                ? ResolvedLocationOrigin.city
                : ResolvedLocationOrigin.auto,
          );
        case null:
          return const ResolvedSearchLocation(
            origin: ResolvedLocationOrigin.defaultLocation,
          );
      }
    });

/// Folds a [SearchScopeArea] into the canonical [ResolvedSearchLocation]. Shared
/// by the explicit map-pick path ([resolvedSearchScopeProvider], `origin:
/// area`) and the auto follow-user path ([resolvedSearchLocationProvider],
/// `origin: gps`) so the two never drift in what facets an area exposes.
ResolvedSearchLocation _resolveArea(
  SearchScopeArea a, {
  required bool isExplicit,
  required ResolvedLocationOrigin origin,
}) {
  final city = a.city;
  return ResolvedSearchLocation(
    centerLat: a.centerLat,
    centerLon: a.centerLng,
    radiusMeters: a.radiusMeters,
    cityId: _feedCityId(city),
    city: city,
    boundaryId: a.boundaryId,
    label: a.displayName.isEmpty ? null : a.displayName,
    cityName: city?.name,
    countryCode: city?.countryCode,
    isExplicit: isExplicit,
    origin: origin,
  );
}

/// **Decision 13 — "Auto → C follows U".** When there is no explicit pick and
/// the live user location is a *precise* fix, resolve that point to its
/// containing administrative boundary (`/geo/boundary/at`) and expose it as an
/// auto [SearchScopeArea] labelled with the leaf place name (e.g. "Arroios").
/// This is what lets Discovery, the pill, and chat seed follow the
/// neighbourhood the user is actually in instead of the coarser profile/IP city.
///
/// Returns null — callers then fall back to [cityAutoScopeProvider] (the
/// profile/IP city cascade) — when:
///   - the fix is missing or coarse (`!isPrecise`): a WiFi/IP-grade sample must
///     not anchor a neighbourhood (mirrors the Near-You precision gate); OR
///   - the point has no served boundary (non-PT, ocean, coverage gap): an
///     honest city-level scope beats a fabricated neighbourhood.
///
/// City-requiring callers (contribution, profiling, add-to-list) deliberately
/// keep reading [cityAutoScopeProvider] directly — they tag a *city*, not C.
final autoFollowUserScopeProvider = FutureProvider<SearchScopeArea?>((
  ref,
) async {
  // Best-effort enrichment: any failure (location deps unavailable, boundary
  // resolve network error) must fall back to the city cascade, never break C —
  // so the location read lives inside the try too.
  try {
    // Rebuild only when the fix crosses a ~110 m bucket (3 dp), not on every
    // sub-bucket GPS jitter: `select` returns a record, so an unchanged bucket
    // compares equal and skips the refetch. Null → not precise / no fix → fall
    // through to the city cascade.
    final bucket = ref.watch(
      locationStateProvider.select((s) {
        final fix = s.lastLocation;
        if (!s.isPrecise || fix == null) return null;
        return (lat: _round3(fix.lat), lng: _round3(fix.lon));
      }),
    );
    if (bucket == null) return null;

    // Resolve against the EXACT current fix, not the rounded bucket — rounding
    // is only the rebuild key; resolving a rounded point could land in the
    // wrong boundary within ~110 m of an edge. `read` (not `watch`) so the
    // exact coords don't re-introduce per-jitter rebuilds. Resolve directly via
    // the API (not the non-autoDispose `boundaryResolveProvider` family, which
    // retains one entry per coordinate) so this keeps a single cached value.
    final fix = ref.read(locationStateProvider).lastLocation;
    if (fix == null) return null;
    final boundary = await ref
        .read(geoApiProvider)
        .resolveBoundaryAt(lat: fix.lat, lng: fix.lon);
    if (boundary == null) return null;
    return searchScopeAreaForBoundary(boundary, isAuto: true);
  } catch (error) {
    debugPrint('[ResolvedSearchLocation] follow-user (C←U) failed: $error');
    return null;
  }
});

final resolvedSearchLocationProvider = FutureProvider<ResolvedSearchLocation>((
  ref,
) async {
  final explicit = ref.watch(cityScopeProvider);
  if (explicit != null) {
    return ref.watch(
      resolvedSearchScopeProvider((scope: explicit, isExplicit: true)).future,
    );
  }

  // Decision 13 — no explicit pick → C follows U. Prefer the precise-fix
  // neighbourhood area; fall back to the profile/IP city cascade.
  final followUser = await ref.watch(autoFollowUserScopeProvider.future);
  if (followUser != null) {
    return _resolveArea(
      followUser,
      isExplicit: false,
      origin: ResolvedLocationOrigin.gps,
    );
  }

  final auto = await ref.watch(cityAutoScopeProvider.future);
  return ref.watch(
    resolvedSearchScopeProvider((scope: auto, isExplicit: false)).future,
  );
});

/// Resolves a local GeoCity point to its polygon-backed city boundary.
///
/// `/geo/areas` can currently return both a `gl:` point and an `ab:` boundary
/// for the same name. Never select by name alone: each candidate boundary is
/// resolved and accepted only when its seeded `boundary.city.id` matches the
/// original GeoCity UUID. This fails closed for aliases, duplicate city names,
/// Google picks, and cities outside polygon coverage.
final resolvedCityBoundaryProvider =
    FutureProvider.family<GeoBoundary?, GeoCity>((ref, city) async {
      if (!city.isLocalSourced || !city.hasCoordinates) return null;

      try {
        // Live in-app locale, not the cached profile `preferred_locale` (which
        // defaults to `en` at register and only updates on a profile refresh) —
        // so a mid-session language switch immediately returns place names in
        // the newly-picked language.
        final locale = ref.read(apiLocaleCodeProvider) ?? 'en';
        final sessionToken = const Uuid().v4();
        final api = ref.read(geoApiProvider);
        final predictions = await api.searchAreas(
          q: city.name,
          sessionToken: sessionToken,
          locale: locale,
          countryCode: city.countryCode,
          nearLat: city.latitude,
          nearLng: city.longitude,
        );

        for (final prediction in predictions.where(
          (prediction) => isCityBoundaryPrediction(prediction, city),
        )) {
          final area = await api.resolveArea(
            id: prediction.id,
            sessionToken: sessionToken,
            locale: locale,
          );
          final boundary = matchingBoundaryForCity(area: area, city: city);
          if (boundary != null) return boundary;
        }
      } catch (error) {
        // This enrichment must never make the established city-point path fail.
        debugPrint(
          '[ResolvedSearchLocation] city-boundary(${city.id}) failed: $error',
        );
      }
      return null;
    });

/// Cheap pre-filter before resolving candidates. The UUID check in
/// [matchingBoundaryForCity] is the authoritative identity guard.
@visibleForTesting
bool isCityBoundaryPrediction(AreaPrediction prediction, GeoCity city) =>
    prediction.id.startsWith('ab:') &&
    prediction.type.toLowerCase() == 'city' &&
    _normalizedPlaceName(prediction.name) == _normalizedPlaceName(city.name);

/// Returns [area]'s boundary only when the backend proves it represents
/// [city], rather than a same-named place somewhere else.
@visibleForTesting
GeoBoundary? matchingBoundaryForCity({
  required ResolvedArea? area,
  required GeoCity city,
}) {
  if (area?.kind != AreaKind.boundary || area?.boundary.city?.id != city.id) {
    return null;
  }
  return area!.boundary;
}

/// Rounds a coordinate to 3 decimal places (~110 m) for the boundary-resolve
/// family key — see [autoFollowUserScopeProvider].
double _round3(double v) => (v * 1000).roundToDouble() / 1000;

String _normalizedPlaceName(String value) => value.trim().toLowerCase();

String? _feedCityId(GeoCity? city) {
  if (city == null || city.isGoogleSourced) return null;
  return city.id;
}

Future<GeoCity> _resolveCityCoordinates(Ref ref, GeoCity city) async {
  if (city.hasCoordinates || !city.isGoogleSourced) return city;

  try {
    // Live in-app locale (see resolvedCityBoundaryProvider) rather than the
    // cached profile locale, so a language switch takes effect immediately.
    final locale = ref.read(apiLocaleCodeProvider) ?? 'en';
    final resolved = await ref
        .read(geoApiProvider)
        .resolveCity(
          cityId: city.id,
          sessionToken: const Uuid().v4(),
          locale: locale,
        );
    return city.withResolvedCoordinates(resolved);
  } catch (e) {
    debugPrint('[ResolvedSearchLocation] resolve(${city.id}) failed: $e');
    return city;
  }
}
