import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/models/models.dart';
import '../data/repositories/country_repository.dart';
import '../features/lists/models/search_scope.dart';
import 'api_provider.dart';
import 'detected_country_provider.dart';
import 'locale_provider.dart';
import 'location_provider.dart';

/// Country-name → ISO-3166-1 alpha-2 mapping for Soko's launch markets.
const Map<String, String> kSokoCountryCodes = {
  'Portugal': 'PT',
  'Brazil': 'BR',
  'Brasil': 'BR',
  'United States': 'US',
  'United Kingdom': 'GB',
  'Spain': 'ES',
  'France': 'FR',
};

/// Reverse of [kSokoCountryCodes] (ISO-2 → canonical English country name).
///
/// Used when the auto-resolution flow has only an IP-detected/locale ISO-2
/// and we still need a human-readable country name to render in the picker
/// pre-fill.
const Map<String, String> kSokoCountryNamesByIso2 = {
  'PT': 'Portugal',
  'BR': 'Brazil',
  'US': 'United States',
  'GB': 'United Kingdom',
  'ES': 'Spain',
  'FR': 'France',
};

/// Auto-detected city scope, shared across Discovery + `/lists` + any
/// surface that needs the "best guess city" when the user hasn't picked
/// explicitly. Returns null when neither the live fix nor IP detection
/// produces a country — callers should render a "pick a city" affordance
/// rather than a guessed default.
///
/// Country comes from the latest location history (the live GPS fix's
/// reverse-geocoded [LocationState.resolvedCountryCode]) → IP → device
/// locale. The denormalised `user_profile.country` is deliberately NOT read
/// (see the body + PROD-4111).
///
/// City cascade (each step short-circuits on first hit):
///   1. live-fix city name ([LocationState.resolvedCityName]) against the ISO-2.
///   2. IP-detected city name (from `ipapi.co`, currently surfaced by
///      [detectedIpCityProvider]) against the resolved ISO-2.
///
/// When a country resolves but no city does, returns a
/// [SearchScopeCountry] so the action bar can still render the country
/// name; city-keyed shelves see no city and hide. The previous "snap to
/// PT/Lisboa" fallback (PROD-1999) is gone — a user in an unseeded city
/// gets a thinner-but-honest Discovery instead of Lisboa-flavoured lies.
///
/// `isAuto: true` on the returned scope marks this as auto-resolved.
///
/// Single source of truth for auto-resolution; [discoveryCityIdProvider]
/// (for shelves) and the action bar's pill label derive from it.
final cityAutoScopeProvider = FutureProvider<SearchScope?>((ref) async {
  // Live in-app locale, not the cached profile `preferred_locale` (which is `en`
  // until a profile refresh lands) — so geo/city name resolution follows a
  // mid-session language switch immediately instead of reverting to English.
  final locale = ref.watch(apiLocaleCodeProvider) ?? 'en';

  // The latest location-history entry: the live GPS fix, reverse-geocoded by the
  // backend on the last `PUT /app/users/me/location`. This — NOT the
  // denormalised `user_profile.country`/`.city` — is the source of "where the
  // user actually is". The profile fields are written once at onboarding and
  // never repointed as the user travels, so a user who onboarded in the UK and
  // is now in Helsinki would otherwise resolve to "United Kingdom". Home/Work
  // are just tagged pointers into this same history. Backend removal of the
  // denormalised column is tracked in PROD-4111.
  //
  // NOTE: `resolvedCountryCode` is an uppercased full country *name* (e.g.
  // "FINLAND"), NOT an ISO-2 code — see
  // `docs/learnings/location-provider-resolvedcountrycode-is-uppercase-name.md`.
  // Resolve it to a real ISO-2 via the complete 219-country `CountryRepository`
  // (not the 6-market `kSokoCountryCodes`), so a live fix in ANY country — not
  // just a launch market — yields the correct country instead of falling
  // through to a stale IP/locale guess.
  final (fixCountryName, fixCityName) = ref.watch(
    locationStateProvider.select(
      (s) => (s.resolvedCountryCode, s.resolvedCityName),
    ),
  );

  // ----- ISO-2 resolution: live fix (latest history) → IP → device locale. -----
  String? iso2;
  String? countryName;
  if (fixCountryName != null && fixCountryName.isNotEmpty) {
    final country = CountryRepository.findByName(fixCountryName);
    if (country != null) {
      iso2 = country.isoCode;
      countryName = country.name;
    }
  }
  iso2 ??= await ref.watch(detectedCountryCodeProvider.future);

  // PROD-2065: `detectedCountryCodeProvider` is a FutureProvider whose result
  // is cached for the session. If its first run hit a transient failure
  // (e.g. ipapi.co 429-rate-limited the app at startup), the cached null
  // sticks even though `LocationNotifier`'s separate `detectLocation()`
  // call (fired on permission grant) may have since populated
  // `IpGeolocationService`'s own 24h cache. Read the service directly to
  // recover from this state — the service's internal cache makes this
  // cheap, and on a true fresh-network-failure case it falls through to
  // null anyway.
  if (iso2 == null) {
    final result = await ref
        .read(ipGeolocationServiceProvider)
        .detectLocation();
    if (result != null && result.countryCode.isNotEmpty) {
      iso2 = result.countryCode.toUpperCase();
    }
  }

  // PROD-2065: Last-resort fallback — read the device's locale region.
  // ipapi.co can be unreachable (sustained 429s, anti-VPN blocks, captive
  // portals, offline). When IP detection fails AND the user's profile has
  // no country, the entire auto-scope used to return null — which hid the
  // location pill's value AND the picker's "reset to auto" button.
  // `LocationNotifier` already mirrors this pattern at
  // `location_provider.dart:710`. Only accept the locale region when
  // it's one of the Soko launch markets (matches the IP-detected
  // branch's acceptance rule); unsupported regions still return null.
  if (iso2 == null) {
    final localeCountry = PlatformDispatcher.instance.locale.countryCode
        ?.toUpperCase();
    if (localeCountry != null &&
        kSokoCountryNamesByIso2.containsKey(localeCountry)) {
      iso2 = localeCountry;
    }
  }
  // Full-country display name (all 219 countries), falling back to the
  // launch-market table then the raw ISO-2. So an IP/locale-detected non-launch
  // country still renders its name (e.g. "FI" → "Finland"), not the bare code.
  countryName ??= iso2 == null
      ? null
      : (CountryRepository.findByIsoCode(iso2)?.name ??
            kSokoCountryNamesByIso2[iso2]);

  // No country signal at all — return null so callers render the explicit
  // empty state. Manufacturing a default here is what produced PROD-1999.
  if (iso2 == null) return null;

  final geoApi = ref.read(geoApiProvider);
  final sessionToken = const Uuid().v4();

  Future<GeoCity?> tryQuery(String? q) async {
    if (q == null || q.length < 2) return null;
    try {
      final response = await geoApi.searchCities(
        countryCode: iso2!,
        q: q,
        sessionToken: sessionToken,
        locale: locale,
        limit: 5,
      );
      return _pickBestMatch(response.items, q);
    } catch (e) {
      debugPrint('[CityAutoScope] query "$q" failed: $e');
      return null;
    }
  }

  // 1. live-fix city name (latest history entry)
  GeoCity? city = await tryQuery(fixCityName);

  // 2. IP-detected city name
  if (city == null) {
    final ipCity = await ref.watch(detectedIpCityProvider.future);
    city = await tryQuery(ipCity);
  }

  final resolvedCountryName = countryName ?? iso2;

  if (city == null) {
    return SearchScopeCountry(
      iso2: iso2,
      countryName: resolvedCountryName,
      isAuto: true,
    );
  }

  return SearchScopeCountryCity(
    iso2: iso2,
    countryName: resolvedCountryName,
    city: city,
    isAuto: true,
  );
});

/// Picks the best `/geo/cities` row for a given wanted name. Prefers an
/// exact (case-insensitive) name match; falls back to the first item.
/// Accepts both `local`- and `google`-source rows so non-launch markets can
/// still resolve a city — Google `place_id`s don't power city-keyed shelves
/// but the pill label is correct.
GeoCity? _pickBestMatch(List<GeoCity> items, String wantedName) {
  if (items.isEmpty) return null;
  final lower = wantedName.toLowerCase();
  for (final c in items) {
    if (c.name.toLowerCase() == lower) return c;
  }
  return items.first;
}
