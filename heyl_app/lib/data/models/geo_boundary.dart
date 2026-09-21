import 'geo_city.dart';

/// Product-facing classification of an administrative boundary.
///
/// The backend remains the authority for the raw OSM [GeoBoundary.adminLevel].
/// This small, stable vocabulary lets picker/search state distinguish the
/// levels the product supports without leaking OSM numbers through consumers.
/// Unknown includes point-only area-search results (`admin_level=0`) and
/// regional levels that are not yet Search Center modes.
enum GeoBoundaryLevel {
  country,
  city,
  neighborhood,
  unknown;

  static GeoBoundaryLevel fromAdminLevel(int adminLevel) =>
      switch (adminLevel) {
        2 => GeoBoundaryLevel.country,
        7 => GeoBoundaryLevel.city,
        >= 8 => GeoBoundaryLevel.neighborhood,
        _ => GeoBoundaryLevel.unknown,
      };

  /// Backward-compatible parser for the compact SearchScope persistence form.
  static GeoBoundaryLevel fromStoredName(String? name) {
    for (final level in GeoBoundaryLevel.values) {
      if (level.name == name) return level;
    }
    return GeoBoundaryLevel.unknown;
  }
}

/// Axis-aligned lat/lng bounding box for a boundary (mirrors the OpenAPI
/// `BoundingBox` shape). Used to fit the map camera to a selected area.
class GeoBounds {
  final double north;
  final double south;
  final double east;
  final double west;

  const GeoBounds({
    required this.north,
    required this.south,
    required this.east,
    required this.west,
  });

  factory GeoBounds.fromJson(Map<String, dynamic> j) => GeoBounds(
    north: (j['north'] as num).toDouble(),
    south: (j['south'] as num).toDouble(),
    east: (j['east'] as num).toDouble(),
    west: (j['west'] as num).toDouble(),
  );
}

/// A neighborhood/administrative boundary resolved from a tapped coordinate by
/// `GET /geo/boundary/at` (PROD-3109). Portugal-only in practice today.
///
/// [geometry] is a raw GeoJSON MultiPolygon (or null when the backend capped
/// the payload — draw [bbox] instead). [id] is a stable place id reserved for
/// polygon-containment search (mode ii); it is carried on the resulting
/// `SearchScopeArea` but ignored by the backend in radius mode.
class GeoBoundary {
  final String id;
  final String? sourceId;
  final String? version;
  final String name;
  final int adminLevel;
  final String countryCode;
  final double centroidLat;
  final double centroidLon;
  final GeoBounds bbox;
  final int recommendedRadiusM;
  final String? parentName;

  /// The seeded [GeoCity] this boundary resolves to (PROD-3155). Its `id` is a
  /// local GeoCity UUID accepted by the `city_id`-keyed feeds (Highlighted,
  /// venues-with-events, Spaces) — distinct from [id]/[parentName], which are
  /// admin-boundary identities. Null when the backend returned no `city`.
  final GeoCity? city;

  /// The containing municipality (admin_level 7) boundary — its own centroid,
  /// bbox, recommended radius, and **polygon** — returned inline by
  /// `GET /geo/boundary/at` alongside the tight (freguesia, L8) boundary. Lets a
  /// single tap offer both a neighbourhood-level and a city-level selection
  /// without a second call. Null when this boundary IS the municipality (no
  /// finer level) or when the backend omits it.
  final GeoBoundary? municipality;

  final Map<String, dynamic>? geometry;

  const GeoBoundary({
    required this.id,
    required this.name,
    required this.adminLevel,
    required this.countryCode,
    required this.centroidLat,
    required this.centroidLon,
    required this.bbox,
    required this.recommendedRadiusM,
    this.sourceId,
    this.version,
    this.parentName,
    this.city,
    this.municipality,
    this.geometry,
  });

  /// Display label: "Alvalade, Lisboa" when a parent exists, else just the name.
  String get displayName => parentName != null ? '$name, $parentName' : name;

  /// Product-level classification derived from the raw OSM [adminLevel].
  GeoBoundaryLevel get level => GeoBoundaryLevel.fromAdminLevel(adminLevel);

  factory GeoBoundary.fromJson(Map<String, dynamic> j) {
    final parent = j['parent'] as Map<String, dynamic>?;
    final cityJson = j['city'] as Map<String, dynamic>?;
    // The nested municipality carries no country_code of its own — inherit this
    // boundary's — and has no further parent/city/municipality nesting.
    final municipalityJson = j['municipality'] as Map<String, dynamic>?;
    return GeoBoundary(
      id: j['id'] as String,
      sourceId: j['source_id'] as String?,
      version: j['version'] as String?,
      name: j['name'] as String,
      adminLevel: (j['admin_level'] as num).toInt(),
      countryCode: j['country_code'] as String,
      centroidLat: (j['centroid_lat'] as num).toDouble(),
      centroidLon: (j['centroid_lon'] as num).toDouble(),
      bbox: GeoBounds.fromJson(j['bbox'] as Map<String, dynamic>),
      recommendedRadiusM: (j['recommended_radius_m'] as num).toInt(),
      parentName: parent?['name'] as String?,
      // `boundary.city` carries only {id, name, latitude, longitude}; GeoCity
      // defaults source→'local' (feed-acceptable) and displayName→name. The
      // city carries no country of its own, so inherit the boundary's — else a
      // persisted area scope loses its country for list-suggestions filtering.
      city: cityJson != null
          ? GeoCity.fromJson({
              ...cityJson,
              if (cityJson['country_code'] == null)
                'country_code': j['country_code'],
            })
          : null,
      municipality: municipalityJson != null
          ? GeoBoundary.fromJson({
              ...municipalityJson,
              if (municipalityJson['country_code'] == null)
                'country_code': j['country_code'],
            })
          : null,
      geometry: j['geometry'] as Map<String, dynamic>?,
    );
  }
}
