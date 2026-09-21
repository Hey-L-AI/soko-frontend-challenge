import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/geo_boundary.dart';
import '../../../data/repositories/country_repository.dart';
import '../../../providers/detected_country_provider.dart';
import '../../../providers/locale_provider.dart';
import '../../../providers/location_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// The effective search area the Business Connect claim finder sends to
/// `searchPortalVenues` (PROD-4268, S3). **Local to Business Connect** — this
/// never mutates `cityScopeProvider` / global Discovery location, and imports no
/// Discovery radius/boundary/corpus restriction.
///
/// [latitude]/[longitude] are attached to the portal search **only** when both
/// are known ([hasCoordinates]); a country-only / label-only context sends the
/// name query alone (never a partial coordinate pair). [label] is what the
/// "Search area" row shows (null → "Not set"). [userChosen] is set once the
/// owner explicitly picks an area or "Search without an area" — it drives the
/// Change-vs-Choose copy and suppresses the automatic fallback below.
class BusinessSearchArea {
  const BusinessSearchArea({
    this.latitude,
    this.longitude,
    this.label,
    this.countryCode,
    this.userChosen = false,
  });

  final double? latitude;
  final double? longitude;
  final String? label;

  /// ISO-3166-1 alpha-2 country of the area, when the tier that produced it
  /// knows one (a picked boundary, the device fix's reverse-geocode, or the
  /// Discovery centre). It is the first source of the Google `region_code`
  /// bias (PROD-4296) — see [businessSearchRegionProvider]. Never a
  /// restriction; a country-only context still sends no coordinates.
  final String? countryCode;
  final bool userChosen;

  bool get hasCoordinates => latitude != null && longitude != null;

  /// Empty context: no coordinates, no label — the row reads "Not set".
  static const BusinessSearchArea none = BusinessSearchArea();
}

/// The `{city, country}` label shown for an area, e.g. "Ciudad de México,
/// Mexico". Resolves the ISO country code to a display name via
/// [CountryRepository], falling back to the raw code (then to the city alone).
String? businessAreaLabel(String? city, String? isoCode) {
  final trimmedCity = city?.trim();
  if (trimmedCity == null || trimmedCity.isEmpty) return null;
  final code = isoCode?.trim();
  if (code == null || code.isEmpty) return trimmedCity;
  final country = CountryRepository.findByIsoCode(code)?.name ?? code;
  return '$trimmedCity, $country';
}

/// The `{city, country}` label for a resolved administrative boundary. Prefers
/// the seeded city name, else the boundary's own leaf name.
String? businessAreaLabelForBoundary(GeoBoundary boundary) => businessAreaLabel(
  boundary.city?.name ?? boundary.name,
  boundary.countryCode,
);

/// Holds the owner's Business Connect search-area choice and resolves the
/// effective [BusinessSearchArea] by precedence (spec §4.3, decisions 1 & 10):
///
///   1. explicit Business Connect area (pick / "Use my location")  → coords + label
///   2. an already-available usable user fix (captured **once** here) → coords + label
///   3. an existing Discovery city/search center                    → **label only**
///   4. nothing / explicit "Search without an area"                 → no coords, no label
///
/// The tier-2 seed is read **once** in [build] (`ref.read`, never `watch`), so
/// background GPS can neither re-seed it nor reorder a focused result list
/// (decision D2). Never substitutes a seeded Portugal default.
class BusinessSearchAreaNotifier extends Notifier<BusinessSearchArea> {
  @override
  BusinessSearchArea build() {
    // Tier 2 — an already-available, precise, non-IP fix. Captured once.
    // `locationStateProvider` is the read-only projection (overridable with a
    // plain LocationState in tests); a `read`, never a `watch`.
    final location = ref.read(locationStateProvider);
    final fix = location.lastLocation;
    if (fix != null && location.isPrecise && !location.isIpFallback) {
      return BusinessSearchArea(
        latitude: fix.lat,
        longitude: fix.lon,
        // Label from the backend's last reverse-geocode when it's already
        // known; otherwise null — the row still reads the coords' effect, and a
        // later "Change" / "Use my location" fills in a resolved name.
        label: businessAreaLabel(
          location.resolvedCityName,
          location.resolvedCountryCode,
        ),
        countryCode: _iso(location.resolvedCountryCode),
      );
    }

    // Tier 3 — an existing explicit Discovery city/search center. Label only:
    // we deliberately do NOT send its coordinates (that would drag Discovery's
    // center into portal ranking). A pure read — no Discovery mutation.
    final discovery = ref.read(resolvedSearchLocationProvider).valueOrNull;
    final discoveryLabel = discovery?.label;
    if (discoveryLabel != null && discoveryLabel.isNotEmpty) {
      return BusinessSearchArea(
        label: discoveryLabel,
        countryCode: _iso(discovery?.countryCode),
      );
    }

    // Tier 4 — nothing usable available.
    return BusinessSearchArea.none;
  }

  /// Set an explicit area from a picked place or "Use my location" (tier 1).
  void setArea({
    required double latitude,
    required double longitude,
    String? label,
    String? countryCode,
  }) {
    state = BusinessSearchArea(
      latitude: latitude,
      longitude: longitude,
      label: label,
      countryCode: _iso(countryCode),
      userChosen: true,
    );
  }

  /// The owner explicitly chose "Search without an area": send no coordinates
  /// and suppress the automatic tier-2/3 fallback until they change it.
  void useNoArea() {
    state = const BusinessSearchArea(userChosen: true);
  }
}

final businessSearchAreaProvider =
    NotifierProvider<BusinessSearchAreaNotifier, BusinessSearchArea>(
      BusinessSearchAreaNotifier.new,
    );

/// Normalise a country signal to an upper-case ISO-3166-1 alpha-2 code.
/// Accepts an ISO code or a full country name — `LocationState.resolvedCountryCode`
/// is documented as ISO but is populated from the backend's `country` string
/// upper-cased, which can be a name ("MEXICO"); the catalog resolves those.
/// Anything else (a locale tag, an unknown label) yields null.
String? _iso(String? code) {
  final trimmed = code?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final upper = trimmed.toUpperCase();
  if (RegExp(r'^[A-Z]{2}$').hasMatch(upper)) return upper;
  return CountryRepository.findByName(trimmed)?.isoCode.toUpperCase();
}

/// The **one** effective country to bias the Google "Find more" search with
/// (`region_code`, PROD-4296). Google's Text Search falls back to **IP bias**
/// when it gets neither coordinates nor a region — and the request comes from
/// the backend host, so an owner in Mexico got studios from the hosting region.
/// Order:
///
///   1. the effective search area's own country ([BusinessSearchArea.countryCode])
///   2. the IP-detected country the app already resolves ([detectedCountryCodeProvider])
///   3. the region of the app's own locale code ([apiLocaleCodeProvider], e.g.
///      `es-MX` → `MX`; a bare `en` has none)
///
/// The finder both sends this value and listens to it for tier resets, so the
/// request and the reset always see the same region (a late IP detection that
/// agrees with the locale region is not a change). Null means nothing is
/// known: the finder opens the area chooser instead of searching blind.
final businessSearchRegionProvider = Provider<String?>((ref) {
  final areaCountry = ref.watch(businessSearchAreaProvider).countryCode;
  if (areaCountry != null) return areaCountry;
  final detected = _iso(ref.watch(detectedCountryCodeProvider).valueOrNull);
  if (detected != null) return detected;
  return regionOfLocaleTag(ref.watch(apiLocaleCodeProvider));
});

/// The region subtag of a BCP-47 / POSIX locale code (`pt-BR`, `es_MX` → `BR`,
/// `MX`), or null when the code carries none (`en`, `pt`).
String? regionOfLocaleTag(String? tag) {
  if (tag == null) return null;
  final parts = tag.trim().split(RegExp(r'[-_]'));
  if (parts.length < 2) return null;
  return _iso(parts[1]);
}
