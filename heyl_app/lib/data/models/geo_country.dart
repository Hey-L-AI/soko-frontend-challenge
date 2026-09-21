/// A country entry returned by `GET /api/v1/app/geo/countries`.
///
/// Comes from the backend's `pycountry`-backed list (249 ISO-3166-1 entries).
/// `hasLocalCoverage` is a hint: when true, the city picker for this country
/// will be backed by our own `geographic_locations` table; when false, the
/// backend proxies to Google Places Autocomplete. The frontend doesn't need
/// to branch on this — routing is entirely backend-side — but the hint can
/// drive visual polish (e.g. a "local" badge).
class GeoCountry {
  final String iso2;

  /// Localized per the request's `?locale=`. Already normalized — render directly.
  final String name;
  final String flagEmoji;
  final bool hasLocalCoverage;

  const GeoCountry({
    required this.iso2,
    required this.name,
    required this.flagEmoji,
    required this.hasLocalCoverage,
  });

  factory GeoCountry.fromJson(Map<String, dynamic> json) {
    return GeoCountry(
      iso2: (json['iso2'] as String).toUpperCase(),
      name: json['name'] as String,
      flagEmoji: json['flag_emoji'] as String? ?? '',
      hasLocalCoverage: json['has_local_coverage'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'iso2': iso2,
    'name': name,
    'flag_emoji': flagEmoji,
    'has_local_coverage': hasLocalCoverage,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GeoCountry && other.iso2 == iso2;
  }

  @override
  int get hashCode => iso2.hashCode;

  @override
  String toString() => 'GeoCountry($iso2, $name, coverage=$hasLocalCoverage)';
}
