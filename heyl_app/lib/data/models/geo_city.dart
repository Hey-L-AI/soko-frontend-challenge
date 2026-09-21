import 'bounding_box.dart';

/// A city entry returned by `GET /api/v1/app/geo/cities` and
/// `GET /api/v1/app/geo/cities/{id}`.
///
/// `id` is either a local DB UUID or a Google `place_id` depending on [source].
/// [latitude] / [longitude] are populated for `local` sources; they are null
/// for `google` sources until resolved via `GeoApi.resolveCity`.
class GeoCity {
  final String id;
  final String name;

  /// Backend-formatted display line (e.g. `"Paris, Île-de-France, France"`).
  /// Safe to render directly.
  final String displayName;

  final double? latitude;
  final double? longitude;

  /// `"local"` (our DB) or `"google"` (Google Places). Determines whether
  /// [latitude] / [longitude] are already populated or need a follow-up
  /// `/geo/cities/{id}` resolve call.
  final String source;

  /// ISO-3166-1 alpha-2 country code. Set by the resolve endpoint; may be null
  /// on autocomplete response items (the country is implicit from the request).
  final String? countryCode;

  /// Human-readable formatted address from Google — only present on the
  /// resolve endpoint's response for Google-sourced cities. Null otherwise.
  final String? formattedAddress;

  /// Axis-aligned lat/lng bounding box for the city, used to fit map views.
  /// Sourced from `admin_boundaries` (local cities) or Google `viewport`
  /// (Google cities). Null when no source has bounds for this city — callers
  /// should fall back to fit-to-pins.
  final BoundingBox? boundingBox;

  /// PROD-3675 — whether this city is "open" for discovery (has curated
  /// content depth), owned by the backend's per-city `discovery_enabled` flag.
  /// Present (`true`/`false`) only on cities returned by `/geo/cities` and
  /// `/geo/cities/{id}`. **`null` means unreported** — e.g. cities seeded from
  /// a boundary/area resolve (`GeoBoundary.city`) that don't carry the flag.
  /// Consumers must treat `null` as "unknown", NOT as closed.
  final bool? isOpen;

  const GeoCity({
    required this.id,
    required this.name,
    required this.displayName,
    required this.source,
    this.latitude,
    this.longitude,
    this.countryCode,
    this.formattedAddress,
    this.boundingBox,
    this.isOpen,
  });

  bool get isGoogleSourced => source == 'google';
  bool get isLocalSourced => source == 'local';
  bool get hasCoordinates => latitude != null && longitude != null;

  factory GeoCity.fromJson(Map<String, dynamic> json) {
    return GeoCity(
      id: json['id'] as String,
      name: json['name'] as String,
      displayName: (json['display_name'] as String?) ?? (json['name'] as String),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      source: json['source'] as String? ?? 'local',
      countryCode: (json['country_code'] as String?)?.toUpperCase(),
      formattedAddress: json['formatted_address'] as String?,
      boundingBox: json['bounding_box'] is Map<String, dynamic>
          ? BoundingBox.fromJson(json['bounding_box'] as Map<String, dynamic>)
          : null,
      // Absent (boundary/area-seeded cities) → null "unknown", never false.
      isOpen: json['is_open'] as bool?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'display_name': displayName,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
    'source': source,
    if (countryCode != null) 'country_code': countryCode,
    if (formattedAddress != null) 'formatted_address': formattedAddress,
    if (boundingBox != null) 'bounding_box': boundingBox!.toJson(),
    if (isOpen != null) 'is_open': isOpen,
  };

  /// Returns a copy with lat/lon/country_code filled in — used after a
  /// `/geo/cities/{id}` resolve call on a Google-sourced pick.
  GeoCity withResolvedCoordinates(GeoCity resolved) {
    return GeoCity(
      id: id,
      name: name,
      displayName: displayName,
      latitude: resolved.latitude,
      longitude: resolved.longitude,
      source: source,
      countryCode: resolved.countryCode ?? countryCode,
      formattedAddress: resolved.formattedAddress ?? formattedAddress,
      boundingBox: resolved.boundingBox ?? boundingBox,
      // The resolve endpoint (`/geo/cities/{id}`) is authoritative for is_open;
      // keep the original only when the resolve didn't report it.
      isOpen: resolved.isOpen ?? isOpen,
    );
  }

  /// Returns a copy carrying [other]'s [isOpen] when this city doesn't already
  /// report it. Used when swapping to a boundary-seeded [GeoCity] of the same
  /// identity so the authoritative `/geo/cities` open flag survives the swap.
  GeoCity withOpenFrom(GeoCity other) {
    if (isOpen != null) return this;
    return GeoCity(
      id: id,
      name: name,
      displayName: displayName,
      latitude: latitude,
      longitude: longitude,
      source: source,
      countryCode: countryCode,
      formattedAddress: formattedAddress,
      boundingBox: boundingBox,
      isOpen: other.isOpen,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GeoCity && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'GeoCity($id, $name, source=$source)';
}

/// Response envelope for `GET /api/v1/app/geo/cities` — includes the top-level
/// `source` so callers can show a "via Google Maps" banner without inspecting
/// every item.
class GeoCitySearchResponse {
  final List<GeoCity> items;
  final String source;

  const GeoCitySearchResponse({required this.items, required this.source});

  factory GeoCitySearchResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return GeoCitySearchResponse(
      items: rawItems
          .map((e) => GeoCity.fromJson(e as Map<String, dynamic>))
          .toList(),
      source: json['source'] as String? ?? 'local',
    );
  }
}
