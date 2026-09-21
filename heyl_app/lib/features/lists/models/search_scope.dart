import '../../../data/models/models.dart';

/// Scope applied to the add-to-list venue search (PROD-1326 v2).
///
/// Variants:
/// - [SearchScopeCountry] — country filter only (no geo-radius). Whole-country
///   scope. Produced by the auto IP/profile cascade (`cityAutoScopeProvider`).
/// - [SearchScopeCountryCity] — country filter + city centroid (or user GPS
///   when auto-preselected) with a 20 km radius. Also from the auto cascade.
/// - [SearchScopeArea] — the map picker's own result (center + radius +
///   optional seeded city).
///
/// `_scope` in the add-to-list sheet is `SearchScope?` — null means no scope
/// picked yet AND auto-detection hasn't resolved one. The sheet blocks venue
/// search until the user picks a country.
///
/// [isAuto] on both variants signals the scope was filled from GPS/IP
/// pre-selection and the user hasn't overridden it. Flips to false on any
/// explicit picker interaction. Used to render the "Auto" badge on the pill
/// and to enable the "reset to auto" action in the picker.
sealed class SearchScope {
  const SearchScope();

  /// Encode any variant to a JSON map. Pair with [SearchScope.fromJson] for
  /// round-tripping through SharedPreferences (used by Discovery to persist
  /// the user's per-account location override).
  Map<String, dynamic> toJson() => switch (this) {
    SearchScopeCountry s => {
      'type': 'country',
      'iso2': s.iso2,
      'country_name': s.countryName,
      'flag_emoji': s.flagEmoji,
      'is_auto': s.isAuto,
    },
    SearchScopeCountryCity s => {
      'type': 'country_city',
      'iso2': s.iso2,
      'country_name': s.countryName,
      'flag_emoji': s.flagEmoji,
      'is_auto': s.isAuto,
      'city': s.city.toJson(),
    },
    SearchScopeArea s => {
      'type': 'area',
      'center_lat': s.centerLat,
      'center_lng': s.centerLng,
      'radius_m': s.radiusMeters,
      'boundary_id': s.boundaryId,
      'boundary_version': s.boundaryVersion,
      'boundary_level': s.boundaryLevel.name,
      'display_name': s.displayName,
      'is_auto': s.isAuto,
      // Lean payload — the seeded city (id + name + centroid) round-trips, but
      // never the polygon geometry (kept in-memory only; re-fetched on tap).
      if (s.city != null) 'city': s.city!.toJson(),
    },
  };

  /// Decode a JSON map produced by [toJson] back to the matching variant.
  /// Returns null on shape mismatch (defensive — stored payloads can drift
  /// across app updates).
  static SearchScope? fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    // Area scopes have no iso2/country_name — handle before the country guard.
    if (type == 'area') {
      final centerLat = json['center_lat'] as num?;
      final centerLng = json['center_lng'] as num?;
      final radius = json['radius_m'] as num?;
      if (centerLat == null || centerLng == null || radius == null) return null;
      final cityJson = json['city'] as Map<String, dynamic>?;
      return SearchScopeArea(
        centerLat: centerLat.toDouble(),
        centerLng: centerLng.toDouble(),
        radiusMeters: radius.toDouble(),
        displayName: (json['display_name'] as String?) ?? '',
        boundaryId: json['boundary_id'] as String?,
        boundaryVersion: json['boundary_version'] as String?,
        boundaryLevel: GeoBoundaryLevel.fromStoredName(
          json['boundary_level'] as String?,
        ),
        isAuto: (json['is_auto'] as bool?) ?? false,
        // Absent on picks persisted before PROD-3181 → null; those re-resolve
        // to a city on the next boundary fetch (documented Phase-1 caveat).
        city: cityJson != null ? GeoCity.fromJson(cityJson) : null,
      );
    }
    final iso2 = json['iso2'] as String?;
    final countryName = json['country_name'] as String?;
    if (iso2 == null || countryName == null) return null;
    final flagEmoji = (json['flag_emoji'] as String?) ?? '';
    final isAuto = (json['is_auto'] as bool?) ?? false;
    switch (type) {
      case 'country':
        return SearchScopeCountry(
          iso2: iso2,
          countryName: countryName,
          flagEmoji: flagEmoji,
          isAuto: isAuto,
        );
      case 'country_city':
        final cityJson = json['city'] as Map<String, dynamic>?;
        if (cityJson == null) return null;
        return SearchScopeCountryCity(
          iso2: iso2,
          countryName: countryName,
          flagEmoji: flagEmoji,
          isAuto: isAuto,
          city: GeoCity.fromJson(cityJson),
        );
      default:
        return null;
    }
  }
}

class SearchScopeCountry extends SearchScope {
  final String iso2;
  final String countryName;
  final String flagEmoji;

  /// True when this scope came from pre-selection and the user hasn't
  /// changed the country. Becomes false once the user picks a country
  /// deliberately.
  final bool isAuto;

  const SearchScopeCountry({
    required this.iso2,
    required this.countryName,
    this.flagEmoji = '',
    this.isAuto = false,
  });

  SearchScopeCountry copyWith({bool? isAuto}) => SearchScopeCountry(
    iso2: iso2,
    countryName: countryName,
    flagEmoji: flagEmoji,
    isAuto: isAuto ?? this.isAuto,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SearchScopeCountry &&
        other.iso2 == iso2 &&
        other.isAuto == isAuto;
  }

  @override
  int get hashCode => Object.hash(iso2, isAuto);
}

class SearchScopeCountryCity extends SearchScope {
  final String iso2;
  final String countryName;
  final String flagEmoji;
  final GeoCity city;
  final bool isAuto;

  const SearchScopeCountryCity({
    required this.iso2,
    required this.countryName,
    required this.city,
    this.flagEmoji = '',
    this.isAuto = false,
  });

  SearchScopeCountryCity copyWith({GeoCity? city, bool? isAuto}) =>
      SearchScopeCountryCity(
        iso2: iso2,
        countryName: countryName,
        flagEmoji: flagEmoji,
        city: city ?? this.city,
        isAuto: isAuto ?? this.isAuto,
      );

  /// Drop the city, keeping the country. Used when the user clears the city
  /// field → whole-country scope.
  SearchScopeCountry withoutCity() => SearchScopeCountry(
    iso2: iso2,
    countryName: countryName,
    flagEmoji: flagEmoji,
    isAuto: false, // any city-clear is a deliberate action
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SearchScopeCountryCity &&
        other.iso2 == iso2 &&
        other.city == city &&
        other.isAuto == isAuto;
  }

  @override
  int get hashCode => Object.hash(iso2, city, isAuto);
}

/// A free-form area scope produced by the full-screen map location picker
/// (PROD-3109). Carries a center + radius (radius mode today) plus an optional
/// stable [boundaryId] reserved for polygon-containment search (mode ii). The
/// backend reads center+radius now and can read [boundaryId] per-leg later
/// without any client change.
class SearchScopeArea extends SearchScope {
  final double centerLat;
  final double centerLng;
  final double radiusMeters;
  final String? boundaryId;
  final String? boundaryVersion;

  /// Product-facing level copied from the selected [GeoBoundary]. Older
  /// persisted scopes safely restore as [GeoBoundaryLevel.unknown].
  final GeoBoundaryLevel boundaryLevel;

  /// The selected polygon for this in-memory picker handoff. It is deliberately
  /// excluded from [toJson]: persisted scopes keep only [boundaryId] and
  /// re-fetch the latest geometry on reopen, avoiding stale or oversized
  /// SharedPreferences payloads.
  final Map<String, dynamic>? boundaryGeometry;

  final String displayName;
  final bool isAuto;

  /// The seeded [GeoCity] this area resolves to (from `boundary.city`,
  /// PROD-3155). Its local UUID is what the `city_id`-keyed feeds
  /// (Highlighted / venues-with-events / Spaces) consume, so an area pick no
  /// longer hides those shelves. Null for a point pick with no containing
  /// boundary, and for area picks persisted before this field existed.
  ///
  /// Note: this is the *city* the area sits in (e.g. Lisboa for an Arroios
  /// pick) — it supplies the `city_id` only. Coord shelves and Near-You anchor
  /// on [centerLat]/[centerLng] (the area's own center), never the city
  /// centroid.
  final GeoCity? city;

  const SearchScopeArea({
    required this.centerLat,
    required this.centerLng,
    required this.radiusMeters,
    required this.displayName,
    this.boundaryId,
    this.boundaryVersion,
    this.boundaryLevel = GeoBoundaryLevel.unknown,
    this.boundaryGeometry,
    this.isAuto = false,
    this.city,
  });

  // Equality intentionally ignores [displayName] (a label) and
  // [boundaryVersion] (observability-only per spec §9 — scopes bind to stable
  // place identity, and the backend resolves the latest-active boundary
  // regardless of the version echoed here). [boundaryGeometry] is intentionally
  // ignored because it is a re-fetchable rendering cache. [city] and
  // [boundaryLevel] ARE included: a legacy pick that gains either must notify
  // consumers of the enriched resolution. [city] is included (by id): a
  // legacy area persisted with `city == null` and the same spot re-picked with
  // a seeded city must compare unequal so listeners recompute the `city_id`
  // feeds (Highlighted / Spaces) instead of staying hidden.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SearchScopeArea &&
        other.centerLat == centerLat &&
        other.centerLng == centerLng &&
        other.radiusMeters == radiusMeters &&
        other.boundaryId == boundaryId &&
        other.boundaryLevel == boundaryLevel &&
        other.isAuto == isAuto &&
        other.city?.id == city?.id;
  }

  @override
  int get hashCode => Object.hash(
    centerLat,
    centerLng,
    radiusMeters,
    boundaryId,
    boundaryLevel,
    isAuto,
    city?.id,
  );
}

/// Normalise either picker's output into the seeded city a city-requiring
/// caller (contribution, profiling) needs. Two producers, one selection:
/// - [SearchScopeCountryCity] → its [SearchScopeCountryCity.city] + `iso2`.
/// - [SearchScopeArea] → its `boundary.city` ([SearchScopeArea.city]) once it
///   resolved to a seeded [GeoCity] whose `countryCode` is set (inherited from
///   the boundary in [GeoBoundary.fromJson]).
///
/// Returns null for scopes that carry no usable city: a country-only scope, or
/// a point-pick area with no containing boundary ([SearchScopeArea.city] ==
/// null). Phase 7 / PROD-3202: this is what lets the map picker feed the
/// city-keyed contribution + profiling flows now that a map pick yields a real
/// `city_id` (PROD-3155).
({GeoCity city, String iso2})? cityScopeSelection(SearchScope? scope) =>
    switch (scope) {
      SearchScopeCountryCity(:final city, :final iso2) => (
        city: city,
        iso2: iso2,
      ),
      SearchScopeArea(city: final c?) when c.countryCode != null => (
        city: c,
        iso2: c.countryCode!,
      ),
      _ => null,
    };
