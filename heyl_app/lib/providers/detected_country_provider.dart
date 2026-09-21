import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/ip_geolocation_service.dart';
import '../core/services/storage_service.dart';
import '../data/models/country.dart';
import '../data/repositories/country_repository.dart';
import 'auth_provider.dart';

/// Key for storing detected country code in SharedPreferences
const String _detectedCountryKey = 'detected_country_code';

/// Key for storing the IP-detected city name in SharedPreferences (read by
/// [detectedIpCityProvider] before triggering a fresh detection).
const String _detectedCityKey = 'detected_city_name';

/// Key for checking if locale was already set from detection
const String _localeSetFromDetectionKey = 'locale_set_from_detection';

/// PROD-2285 — last authenticated user-id observed by this provider. The
/// value survives sign-out, so a re-creation of the provider on the next
/// sign-in can compare and wipe the cache if the identity changed.
const String _lastSeenUserIdKey = 'detected_country_last_user_id';

/// Provider for IP geolocation service
final ipGeolocationServiceProvider = Provider<IpGeolocationService>((ref) {
  return IpGeolocationService();
});

Future<void> _invalidateCacheFor(
  SharedPreferences prefs,
  IpGeolocationService service,
) async {
  await prefs.remove(_detectedCountryKey);
  await prefs.remove(_detectedCityKey);
  await prefs.remove(_localeSetFromDetectionKey);
  await service.clearCache(prefs);
}

/// Provider for detected country code.
/// Returns cached country code if available, otherwise detects via IP.
/// Returns null if detection fails or was already performed.
final detectedCountryCodeProvider = FutureProvider<String?>((ref) async {
  final prefs = ref.watch(sharedPreferencesProvider);
  final service = ref.read(ipGeolocationServiceProvider);

  // PROD-2285 Phase 2 — invalidate the cache when the authenticated identity
  // changes, even across a sign-out → sign-in cycle that disposed this
  // provider in between (an earlier `ref.listen`-based version of this fix
  // missed that case because the listener died with the provider).
  //
  // The persisted `_lastSeenUserIdKey` outlives any single provider
  // lifecycle, so the body re-entry on the next sign-in can compare it to
  // the current user-id and decide whether to wipe.
  //
  // Author intent (preserved): a null→user transition (first authed access
  // on this install) MUST NOT wipe the cache, because the country was
  // resolved during the pre-auth phone-picker flow and the value is
  // device-scoped, not session-scoped. The wipe gate requires BOTH ids
  // to be non-null AND distinct.
  final currentUserId = ref.watch(currentUserIdProvider);
  final lastSeenUserId = prefs.getString(_lastSeenUserIdKey);
  if (currentUserId != null &&
      lastSeenUserId != null &&
      lastSeenUserId != currentUserId) {
    debugPrint(
      '[detectedCountryCodeProvider] User changed ($lastSeenUserId → $currentUserId), wiping IP cache',
    );
    await _invalidateCacheFor(prefs, service);
  }
  if (currentUserId != null && currentUserId != lastSeenUserId) {
    await prefs.setString(_lastSeenUserIdKey, currentUserId);
  }

  // Check if we already have a cached detection
  final cached = prefs.getString(_detectedCountryKey);
  if (cached != null) {
    debugPrint(
      '[detectedCountryCodeProvider] Using cached country code: $cached',
    );
    return cached;
  }

  // Check if locale was already set from detection (don't detect again)
  final alreadySet = prefs.getBool(_localeSetFromDetectionKey) ?? false;
  if (alreadySet) {
    debugPrint(
      '[detectedCountryCodeProvider] Locale already set from detection, skipping',
    );
    return null;
  }

  // Detect via IP
  final result = await service.detectLocation();

  if (result != null) {
    // Cache both fields so [detectedIpCityProvider] doesn't re-call ipapi.
    await prefs.setString(_detectedCountryKey, result.countryCode);
    final city = result.city;
    if (city != null && city.isNotEmpty) {
      await prefs.setString(_detectedCityKey, city);
    }
    debugPrint(
      '[detectedCountryCodeProvider] Cached detected country: ${result.countryCode}, city: ${result.city}',
    );
  }

  return result?.countryCode;
});

/// IP-detected city name (e.g. "Lisbon", "São Paulo"). Free-form string from
/// ipapi.co — not a [GeoCity] UUID. Used by [cityAutoScopeProvider] as a
/// fallback `q` for `/geo/cities` when `user_profile.city` is empty.
///
/// Reads the cache populated by [detectedCountryCodeProvider] (which is the
/// only call site that hits the network); falls back to the underlying
/// service if the cache is missing.
final detectedIpCityProvider = FutureProvider<String?>((ref) async {
  final prefs = ref.watch(sharedPreferencesProvider);
  final cached = prefs.getString(_detectedCityKey);
  if (cached != null && cached.isNotEmpty) return cached;

  // Trigger the country provider so the same IP call hydrates both keys.
  await ref.watch(detectedCountryCodeProvider.future);
  final hydrated = prefs.getString(_detectedCityKey);
  if (hydrated != null && hydrated.isNotEmpty) return hydrated;
  return null;
});

/// Provider for default phone country based on detected country.
/// Falls back to Portugal if detection fails or country not found.
final defaultPhoneCountryProvider = Provider<Country>((ref) {
  final detectedCodeAsync = ref.watch(detectedCountryCodeProvider);

  return detectedCodeAsync.when(
    data: (countryCode) {
      if (countryCode != null) {
        final country = CountryRepository.findByIsoCode(countryCode);
        if (country != null) {
          debugPrint(
            '[defaultPhoneCountryProvider] Using detected country: ${country.name}',
          );
          return country;
        }
      }
      debugPrint(
        '[defaultPhoneCountryProvider] Falling back to default: Portugal',
      );
      return CountryRepository.defaultCountry;
    },
    loading: () => CountryRepository.defaultCountry,
    error: (_, __) => CountryRepository.defaultCountry,
  );
});

/// Mark that locale was set from detection (prevents re-detection on app restart)
Future<void> markLocaleSetFromDetection(WidgetRef ref, bool value) async {
  final prefs = ref.read(sharedPreferencesProvider);
  await prefs.setBool(_localeSetFromDetectionKey, value);
}
