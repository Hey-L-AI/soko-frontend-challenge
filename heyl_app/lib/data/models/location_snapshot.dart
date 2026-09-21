/// Provenance of a location as PERSISTED / served by the backend
/// (`UserLocationOut.source`), and as round-tripped through the local cache.
///
/// This is the *broad* vocabulary: it includes the four client-observed values
/// plus the backend-only `migration`, `whatsapp` and `memoryFact`, and an
/// [unknown] sentinel for any value this build does not recognise (PROD-4486).
///
/// `memoryFact` is an area centroid the backend infers from the user's memory
/// ("I live in Alvalade"), **not** a device fix. It — like `migration`,
/// `whatsapp` and `unknown` — must never be treated as GPS, must never anchor
/// precision / "near you" decisions, and must never be re-submitted. See
/// [ClientLocationSource] for the narrow set the client is allowed to send.
enum LocationSource {
  deviceGps,
  deviceNetwork,
  manualMapPin,
  ipApprox,
  memoryFact,
  migration,
  whatsapp,
  unknown;

  String toJson() {
    switch (this) {
      case LocationSource.deviceGps:
        return 'device_gps';
      case LocationSource.deviceNetwork:
        return 'device_network';
      case LocationSource.manualMapPin:
        return 'manual_map_pin';
      case LocationSource.ipApprox:
        return 'ip_approx';
      case LocationSource.memoryFact:
        return 'memory_fact';
      case LocationSource.migration:
        return 'migration';
      case LocationSource.whatsapp:
        return 'whatsapp';
      case LocationSource.unknown:
        return 'unknown';
    }
  }

  /// Parse a served / persisted `source`. Null, missing, or any unrecognised
  /// value maps to [unknown] — **never** [deviceGps] (PROD-4486). Defaulting an
  /// inferred area (`memory_fact`) or an unknown value to GPS would let
  /// precedence + "near you" logic silently trust a non-fix.
  static LocationSource fromJson(String? json) {
    switch (json) {
      case 'device_gps':
        return LocationSource.deviceGps;
      case 'device_network':
        return LocationSource.deviceNetwork;
      case 'manual_map_pin':
        return LocationSource.manualMapPin;
      case 'ip_approx':
        return LocationSource.ipApprox;
      case 'memory_fact':
        return LocationSource.memoryFact;
      case 'migration':
        return LocationSource.migration;
      case 'whatsapp':
        return LocationSource.whatsapp;
      default:
        return LocationSource.unknown;
    }
  }

  /// A real on-device sensor fix that can warm up to a precise reading. Only
  /// these justify a blue user-location dot / map seed, and are the only
  /// sources Near-You will hold the shelf waiting for a precise fix (PROD-4486).
  bool get isDeviceFix =>
      this == LocationSource.deviceGps || this == LocationSource.deviceNetwork;

  /// Untrusted for precision: carries no reliable on-device accuracy metric, so
  /// it can never anchor precedence, "near you" ranking, a precise badge, or an
  /// IP-fallback decision. Fail-closed — `unknown` and every backend-only value
  /// are included (PROD-4486). `manualMapPin` is excluded: an explicit user pin
  /// keeps its existing (authoritative) treatment.
  bool get isImpreciseSource {
    switch (this) {
      case LocationSource.ipApprox:
      case LocationSource.memoryFact:
      case LocationSource.migration:
      case LocationSource.whatsapp:
      case LocationSource.unknown:
        return true;
      case LocationSource.deviceGps:
      case LocationSource.deviceNetwork:
      case LocationSource.manualMapPin:
        return false;
    }
  }

  /// The submittable projection of this source, or null if it must never be
  /// sent to the backend (backend-only or unknown provenance). Enforces the
  /// "never re-submit `memory_fact` as GPS" rule at the type level (PROD-4486).
  ClientLocationSource? get asClientSource {
    switch (this) {
      case LocationSource.deviceGps:
        return ClientLocationSource.deviceGps;
      case LocationSource.deviceNetwork:
        return ClientLocationSource.deviceNetwork;
      case LocationSource.manualMapPin:
        return ClientLocationSource.manualMapPin;
      case LocationSource.ipApprox:
        return ClientLocationSource.ipApprox;
      case LocationSource.memoryFact:
      case LocationSource.migration:
      case LocationSource.whatsapp:
      case LocationSource.unknown:
        return null;
    }
  }
}

/// The narrow set of provenance values the client is allowed to **submit**
/// (`UserLocationCreate.source` / `UserLocationTaggedCreate.source`). Backend-
/// only values (`migration`, `whatsapp`, `memory_fact`) and `unknown` are
/// excluded by construction, so a re-submit can never falsify an inferred area
/// as a device fix (PROD-4486).
enum ClientLocationSource {
  deviceGps,
  deviceNetwork,
  manualMapPin,
  ipApprox;

  String toJson() {
    switch (this) {
      case ClientLocationSource.deviceGps:
        return 'device_gps';
      case ClientLocationSource.deviceNetwork:
        return 'device_network';
      case ClientLocationSource.manualMapPin:
        return 'manual_map_pin';
      case ClientLocationSource.ipApprox:
        return 'ip_approx';
    }
  }

  /// Widen back to the broad enum (e.g. to stamp a freshly-built snapshot).
  LocationSource get asLocationSource {
    switch (this) {
      case ClientLocationSource.deviceGps:
        return LocationSource.deviceGps;
      case ClientLocationSource.deviceNetwork:
        return LocationSource.deviceNetwork;
      case ClientLocationSource.manualMapPin:
        return LocationSource.manualMapPin;
      case ClientLocationSource.ipApprox:
        return LocationSource.ipApprox;
    }
  }
}

/// Location snapshot model matching OpenAPI LocationSnapshot schema
class LocationSnapshot {
  final double lat;
  final double lon;
  final double? accuracyM;
  final LocationSource source;
  final DateTime capturedAt;

  /// PROD-2303 step 6 — IP-resolved city name from `IpGeolocationService`
  /// (e.g. "Lisbon"). Optional; backend may normalize on write (e.g.
  /// "Lisbon" → "Lisboa"). Null for GPS / map-pin sources.
  final String? city;

  /// PROD-2303 step 6 — country resolved from the IP source. Currently the
  /// full country name (e.g. "Portugal") via `CountryRepository.findByIsoCode`
  /// — the backend OpenAPI accepts a free-form string and PROD-2302's
  /// staging smoke test confirmed it persists both fields.
  final String? country;

  const LocationSnapshot({
    required this.lat,
    required this.lon,
    this.accuracyM,
    required this.source,
    required this.capturedAt,
    this.city,
    this.country,
  });

  factory LocationSnapshot.fromJson(Map<String, dynamic> json) {
    // GET `/users/me/location` returns `UserLocationOut`, which names the
    // coordinates `latitude` / `longitude`; the local cache (this class's own
    // [toJson]) writes `lat` / `lon`. Accept both so the server read-back and
    // the cache round-trip through one parser (PROD-4486). Without the
    // `latitude` / `longitude` fallback the GET body failed to parse and
    // `LocationApi.getLocation()` silently returned null.
    final latRaw = json['latitude'] ?? json['lat'];
    final lonRaw = json['longitude'] ?? json['lon'];
    return LocationSnapshot(
      lat: (latRaw as num).toDouble(),
      lon: (lonRaw as num).toDouble(),
      accuracyM: (json['accuracy_m'] as num?)?.toDouble(),
      // Null / missing / unknown → LocationSource.unknown, never deviceGps.
      source: LocationSource.fromJson(json['source'] as String?),
      capturedAt: DateTime.parse(json['captured_at'] as String),
      city: json['city'] as String?,
      country: json['country'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'lat': lat,
      'lon': lon,
      if (accuracyM != null) 'accuracy_m': accuracyM,
      'source': source.toJson(),
      'captured_at': capturedAt.toIso8601String(),
      if (city != null) 'city': city,
      if (country != null) 'country': country,
    };
  }

  LocationSnapshot copyWith({
    double? lat,
    double? lon,
    double? accuracyM,
    LocationSource? source,
    DateTime? capturedAt,
    String? city,
    String? country,
  }) {
    return LocationSnapshot(
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      accuracyM: accuracyM ?? this.accuracyM,
      source: source ?? this.source,
      capturedAt: capturedAt ?? this.capturedAt,
      city: city ?? this.city,
      country: country ?? this.country,
    );
  }

  /// Factory for creating from device GPS
  factory LocationSnapshot.fromGps({
    required double lat,
    required double lon,
    double? accuracy,
  }) {
    return LocationSnapshot(
      lat: lat,
      lon: lon,
      accuracyM: accuracy,
      source: LocationSource.deviceGps,
      capturedAt: DateTime.now(),
    );
  }

  /// Factory for creating from manual map pin
  factory LocationSnapshot.fromMapPin({
    required double lat,
    required double lon,
  }) {
    return LocationSnapshot(
      lat: lat,
      lon: lon,
      source: LocationSource.manualMapPin,
      capturedAt: DateTime.now(),
    );
  }

  /// Factory for creating from IP-based approximate geolocation.
  ///
  /// PROD-2303 step 6 — accepts `city` + `country` from the
  /// `IpGeolocationService` result so the IP-approx PUT carries the same
  /// resolved admin context the GPS path gets back from the backend
  /// (PROD-1326 resolved-admin capture). The backend accepts both fields
  /// per `UserLocationCreate` and persists them under `user_locations.city`
  /// / `.country`.
  factory LocationSnapshot.fromIpApprox({
    required double lat,
    required double lon,
    String? city,
    String? country,
  }) {
    return LocationSnapshot(
      lat: lat,
      lon: lon,
      source: LocationSource.ipApprox,
      capturedAt: DateTime.now(),
      city: city,
      country: country,
    );
  }
}

/// Request model for location update
class LocationUpdateRequest {
  final double lat;
  final double lon;
  final double? accuracyM;

  /// Narrowed to [ClientLocationSource] so the PUT body can only ever carry a
  /// client-observed provenance — a backend-only value (`memory_fact`,
  /// `migration`, `whatsapp`) or `unknown` is unrepresentable here (PROD-4486).
  final ClientLocationSource source;
  final DateTime capturedAt;

  /// PROD-2303 step 6 — IP-resolved city / country, propagated through to
  /// the `PUT /me/location` body so the backend can persist
  /// `user_locations.city` / `.country` for IP-approx writes the same way
  /// it does for `device_gps` (post-resolve).
  final String? city;
  final String? country;

  const LocationUpdateRequest({
    required this.lat,
    required this.lon,
    this.accuracyM,
    required this.source,
    required this.capturedAt,
    this.city,
    this.country,
  });

  /// Build a PUT request from a snapshot, or return null when the snapshot's
  /// provenance is not client-submittable (backend-only or unknown) — a
  /// fail-closed guard so a `memory_fact` read-back can never be re-submitted
  /// as a device fix (PROD-4486). Snapshots minted by the device factories
  /// ([LocationSnapshot.fromGps] / [fromIpApprox] / [fromMapPin]) always carry
  /// a submittable source, so this returns non-null on every real write path.
  static LocationUpdateRequest? fromSnapshot(LocationSnapshot snapshot) {
    final clientSource = snapshot.source.asClientSource;
    if (clientSource == null) return null;
    return LocationUpdateRequest(
      lat: snapshot.lat,
      lon: snapshot.lon,
      accuracyM: snapshot.accuracyM,
      source: clientSource,
      capturedAt: snapshot.capturedAt,
      city: snapshot.city,
      country: snapshot.country,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': lat,
      'longitude': lon,
      if (accuracyM != null) 'accuracy_m': accuracyM,
      'source': source.toJson(),
      'captured_at': capturedAt.toIso8601String(),
      if (city != null) 'city': city,
      if (country != null) 'country': country,
    };
  }
}

/// Response model for location update (matches UserLocationOut schema)
class LocationUpdateResponse {
  final String id;
  final double latitude;
  final double longitude;
  final String geoHash;
  final DateTime capturedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? tag;
  final String? address;
  final String? neighborhood;
  final String? city;
  final String? country;
  final double? accuracyM;
  final String? source;

  const LocationUpdateResponse({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.geoHash,
    required this.capturedAt,
    required this.createdAt,
    required this.updatedAt,
    this.tag,
    this.address,
    this.neighborhood,
    this.city,
    this.country,
    this.accuracyM,
    this.source,
  });

  factory LocationUpdateResponse.fromJson(Map<String, dynamic> json) {
    return LocationUpdateResponse(
      id: json['id'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      geoHash: json['geo_hash'] as String,
      capturedAt: DateTime.parse(json['captured_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      tag: json['tag'] as String?,
      address: json['address'] as String?,
      neighborhood: json['neighborhood'] as String?,
      city: json['city'] as String?,
      country: json['country'] as String?,
      accuracyM: (json['accuracy_m'] as num?)?.toDouble(),
      source: json['source'] as String?,
    );
  }
}
