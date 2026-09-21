import 'package:flutter/foundation.dart';

import 'geo_city.dart';
import 'geo_boundary.dart';

/// How the resolved Search Center (C) was arrived at.
///
/// - [area] — a map-picked [SearchScopeArea] (neighbourhood / city / country).
/// - [city] — an explicit city pick ([SearchScopeCountryCity]).
/// - [auto] — auto-resolved from the profile / IP cascade (not user-chosen).
/// - [gps] — followed the live user location U (reserved; Phase 2).
/// - [defaultLocation] — nothing resolved yet.
enum ResolvedLocationOrigin { area, city, auto, gps, defaultLocation }

/// PROD-4531 — the analytics wire value for an origin.
///
/// An exhaustive `switch` rather than a snake-casing of [Enum.name]: a value
/// added to the enum is then a compile error here, where a regex would quietly
/// invent a string nobody had agreed to and ship it to the dashboard.
///
/// ⚠️ **This is not "GPS fix / IP / picker / cached".** Those are the four the
/// A/B brief asked for and the app does not distinguish them: [auto] collapses
/// an IP-detected city and a live-fix-derived city into one value, and there is
/// no cached concept at all. Separating them is a change to
/// `cityAutoScopeProvider`, not a mapping that belongs here.
extension ResolvedLocationOriginWire on ResolvedLocationOrigin {
  String get wire => switch (this) {
    ResolvedLocationOrigin.area => 'area',
    ResolvedLocationOrigin.city => 'city',
    ResolvedLocationOrigin.auto => 'auto',
    ResolvedLocationOrigin.gps => 'gps',
    ResolvedLocationOrigin.defaultLocation => 'default_location',
  };
}

/// **The resolved Search Center (C)** — one object every location surface reads
/// (PROD-3181, epic PROD-3180). Collapses the old "is it a country / a city /
/// an area?" branching into a single value carrying the center, the tier
/// radius, the `city_id` for city-keyed feeds, the boundary id (reserved for
/// polygon containment), and a display label.
///
/// Consumers share the same [centerLat]/[centerLon] and differ only in which
/// facet they read: coord shelves + Near-You use the center + [radiusMeters];
/// Highlighted / Spaces use [cityId]; the pill / debug use [label].
///
/// Map-picked areas keep their polygon only in picker memory. A local city pick
/// may additionally carry its freshly resolved administrative [boundary]
/// (PROD-3187), so it can use that boundary's centre and shape-aware radius
/// without persisting geometry on the legacy city scope.
@immutable
class ResolvedSearchLocation {
  /// Center of the search. Null only when nothing has resolved (country-only
  /// scope, or [ResolvedLocationOrigin.defaultLocation]).
  final double? centerLat;
  final double? centerLon;

  /// Tier radius (metres) for center+radius ("around") queries. Null for a
  /// country-only scope. Phase-6 consolidates the per-shelf constants onto
  /// this value.
  final double? radiusMeters;

  /// Local GeoCity UUID for the `city_id`-keyed feeds (Highlighted,
  /// venues-with-events, Spaces). Null for a country-only scope, a
  /// Google-sourced city (not feed-acceptable), or an area with no seeded city.
  final String? cityId;

  /// The effective city behind [cityId], including coordinates resolved for a
  /// Google-sourced picker value when available. Compatibility providers and
  /// city-support UI project this value instead of re-running scope logic.
  final GeoCity? city;

  /// Stable boundary place id — reserved for polygon-containment search.
  final String? boundaryId;

  /// Fresh administrative boundary for a city-origin result, when the client
  /// can prove it belongs to [city]. This is intentionally nullable: Google
  /// cities and local cities without a canonical boundary keep point semantics.
  final GeoBoundary? boundary;

  /// Human-readable label for the pill / debug: the leaf place name for an
  /// area (e.g. "Arroios"), "City, ISO2" for a city, the country name for a
  /// country-only scope.
  final String? label;

  /// Resolved city name, when known.
  final String? cityName;

  /// ISO-3166-1 alpha-2 country code, when known.
  final String? countryCode;

  /// True when this came from a deliberate user pick (city or area), false when
  /// auto-resolved.
  final bool isExplicit;

  final ResolvedLocationOrigin origin;

  const ResolvedSearchLocation({
    this.centerLat,
    this.centerLon,
    this.radiusMeters,
    this.cityId,
    this.city,
    this.boundaryId,
    this.boundary,
    this.label,
    this.cityName,
    this.countryCode,
    this.isExplicit = false,
    this.origin = ResolvedLocationOrigin.defaultLocation,
  });

  bool get hasCenter => centerLat != null && centerLon != null;

  /// True when C is a real, deliberate area pick that simply has **no place
  /// name** — the point+radius scope the picker produces where the backend has
  /// no covering administrative polygon (`pointScope`, `displayName: ''`).
  ///
  /// Surfaces must not confuse this with "nothing has resolved yet": the user
  /// DID choose an area, so they see the picker's own "Selected area" copy
  /// (`locationScopeUnnamedArea`) rather than the generic "Location"
  /// placeholder. Resolve labels through
  /// `shared/utils/search_location_label.dart` so every surface agrees.
  ///
  /// Only [ResolvedLocationOrigin.area] qualifies. A GPS/auto origin resolves
  /// an area only when `/geo/boundary/at` returned a named boundary, and a
  /// city/country origin always carries a label.
  bool get isUnnamedArea =>
      origin == ResolvedLocationOrigin.area &&
      hasCenter &&
      (label?.trim().isEmpty ?? true);

  ({double lat, double lon})? get center =>
      hasCenter ? (lat: centerLat!, lon: centerLon!) : null;

  /// The tier [radiusMeters] expressed in kilometres for the `radius_km`-shaped
  /// list/feed endpoints. Null (→ backend per-endpoint default) for a
  /// country-only scope with no resolved radius. Phase-6 (PROD-3201) routes the
  /// coord shelves through this instead of a hardcoded per-shelf constant.
  double? get radiusKm => radiusMeters == null ? null : radiusMeters! / 1000;

  /// Whether this location can drive a polygon-containment ("contain") query
  /// (PROD-3196, epic PROD-3180 — the per-drawer contain-vs-around switch).
  ///
  /// True only for a deliberate administrative-area pick that resolved to a
  /// real boundary: an explicit [ResolvedLocationOrigin.area]/[ResolvedLocationOrigin.city]
  /// origin carrying a [boundaryId]. Auto / GPS / default origins stay proximity
  /// ("around"), matching the backend's "explicit administrative-area intent".
  ///
  /// When true, [boundaryId] is the *public* boundary token to send as the
  /// `admin_boundary_id` request param; the backend resolves it to the internal
  /// `admin_boundaries` id. Mode is chosen per drawer at the call site — this
  /// getter only reports whether contain is *available*, never forces it. The
  /// backend gates contain behind rollout flags (default off), so a `contain`
  /// request is a safe no-op until a flag flips.
  bool get canContain =>
      isExplicit &&
      (boundaryId?.trim().isNotEmpty ?? false) &&
      (origin == ResolvedLocationOrigin.area ||
          origin == ResolvedLocationOrigin.city);

  /// The `(location_mode, admin_boundary_id)` request params a contain-capable
  /// list drawer forwards (PROD-3196). Emits `'contain'` + the public boundary
  /// token when [canContain]; otherwise both are null, which the backend reads
  /// as the default `around` — so proximity requests stay byte-for-byte
  /// unchanged. Proximity-only drawers simply never read this.
  ({String? locationMode, String? adminBoundaryId}) get containRequestParams =>
      canContain
      // Trim to match the [canContain] non-blank guard — never forward a
      // padded token the backend would fail to resolve.
      ? (locationMode: 'contain', adminBoundaryId: boundaryId!.trim())
      : (locationMode: null, adminBoundaryId: null);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedSearchLocation &&
          other.centerLat == centerLat &&
          other.centerLon == centerLon &&
          other.radiusMeters == radiusMeters &&
          other.cityId == cityId &&
          other.city == city &&
          other.boundaryId == boundaryId &&
          other.boundary == boundary &&
          other.label == label &&
          other.cityName == cityName &&
          other.countryCode == countryCode &&
          other.isExplicit == isExplicit &&
          other.origin == origin;

  @override
  int get hashCode => Object.hash(
    centerLat,
    centerLon,
    radiusMeters,
    cityId,
    city,
    boundaryId,
    boundary,
    label,
    cityName,
    countryCode,
    isExplicit,
    origin,
  );

  @override
  String toString() =>
      'ResolvedSearchLocation(origin=${origin.name}, explicit=$isExplicit, '
      'center=$centerLat,$centerLon, r=${radiusMeters}m, cityId=$cityId, '
      'boundaryId=$boundaryId, label=$label)';
}
