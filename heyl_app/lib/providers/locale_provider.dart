import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' as intl;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/app_group_bridge.dart';
import '../core/services/storage_service.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import '../data/models/models.dart';
import 'api_provider.dart';
import 'auth_provider.dart';

/// Key for storing locale preference
const String _localeKey = 'app_locale';

/// Key marking that the user made an EXPLICIT locale pick (via the
/// AuthHeader globe toggle or the Preferences screen). Distinguishes
/// user-chosen locales from IP-detected ones — `_localeKey` alone can be
/// set by `setLocaleFromDetectedCountry`, so it cannot be used to gate
/// the [LocaleNotifier.syncFromProfile] override.
///
/// PROD-2037: backend profile sync would otherwise silently flip a
/// user's PT pick to `en` because the register response defaults to
/// `preferred_locale = "en"` when no Accept-Language is sent.
const String _localeExplicitKey = 'app_locale_explicit';

/// Available locales with display names
class AppLocale {
  final Locale locale;
  final String displayName;
  final String nativeName;

  const AppLocale({
    required this.locale,
    required this.displayName,
    required this.nativeName,
  });

  /// Default fallback locales if API is not available
  static const List<AppLocale> defaultLocales = [
    AppLocale(
      locale: Locale('en'),
      displayName: 'English',
      nativeName: 'English',
    ),
    AppLocale(
      locale: Locale('pt'),
      displayName: 'Portuguese',
      nativeName: 'Português (Portugal)',
    ),
    AppLocale(
      locale: Locale('pt', 'BR'),
      displayName: 'Portuguese (Brazil)',
      nativeName: 'Português (Brasil)',
    ),
    AppLocale(
      locale: Locale('es', 'MX'),
      displayName: 'Spanish (Mexico)',
      nativeName: 'Español (México)',
    ),
  ];

  /// Create AppLocale from API LocaleInfo
  factory AppLocale.fromLocaleInfo(LocaleInfo info) {
    final parts = info.code.split('-');
    final locale = parts.length == 2
        ? Locale(parts[0], parts[1])
        : Locale(parts[0]);
    return AppLocale(
      locale: locale,
      displayName: info.name,
      nativeName: info.name,
    );
  }

  /// Find AppLocale by Locale from a list
  static AppLocale? fromLocale(
    Locale? locale,
    List<AppLocale> availableLocales,
  ) {
    if (locale == null) return null;
    return availableLocales.cast<AppLocale?>().firstWhere(
      (l) =>
          l!.locale.languageCode == locale.languageCode &&
          l.locale.countryCode == locale.countryCode,
      orElse: () => availableLocales.cast<AppLocale?>().firstWhere(
        (l) => l!.locale.languageCode == locale.languageCode,
        orElse: () => null,
      ),
    );
  }

  /// Convert locale to API-compatible code (e.g., "pt-BR")
  String toApiCode() {
    if (locale.countryCode != null && locale.countryCode!.isNotEmpty) {
      return '${locale.languageCode}-${locale.countryCode}';
    }
    return locale.languageCode;
  }
}

/// Notifier for managing app locale
class LocaleNotifier extends StateNotifier<Locale?> {
  final SharedPreferences _prefs;
  final StorageService _storageService;

  /// PROD-2037 — late-bound auth API lookup. Resolving
  /// [IAuthMethodsApi] at runtime (inside [_syncToApi]) instead of at
  /// LocaleNotifier construction breaks an otherwise circular
  /// dependency: [apiClientProvider] passes `getLocaleCode` to the
  /// AcceptLanguageInterceptor, which would chain back to this notifier
  /// via [authMethodsApiProvider] → [apiClientProvider]. The callback
  /// is only invoked from user-driven `setLocale`, long after the
  /// provider graph has fully initialized.
  final IAuthMethodsApi Function() _getAuthMethodsApi;

  /// Refreshes the cached user profile after a locale PATCH lands, so
  /// `currentUser.preferredLocale` matches the new choice instead of lingering
  /// on the register-time `en` default. Late-bound for the same cyclic-import
  /// reason as [_getAuthMethodsApi], and best-effort — a failure here just
  /// leaves the cached profile stale (the live locale still drives the UI).
  final Future<void> Function()? _refreshProfile;

  LocaleNotifier(
    this._prefs,
    this._storageService,
    this._getAuthMethodsApi, {
    Future<void> Function()? refreshProfile,
  }) : _refreshProfile = refreshProfile,
       super(null) {
    _loadSavedLocale();
  }

  /// Update locale state and sync Intl.defaultLocale for DateFormat etc.
  void _setLocaleState(Locale? locale) {
    state = locale;
    if (locale != null) {
      intl.Intl.defaultLocale = locale.toString();
    }
    // Mirror to App Group so the iOS Share Extension picks the same locale.
    final tag = locale == null
        ? null
        : (locale.countryCode != null
              ? '${locale.languageCode}-${locale.countryCode}'
              : locale.languageCode);
    if (tag != null) {
      AppGroupBridge.instance.writeLocale(tag);
    }
  }

  void _loadSavedLocale() {
    final savedLocale = _prefs.getString(_localeKey);
    debugPrint('[LocaleNotifier] _loadSavedLocale: savedLocale=$savedLocale');
    if (savedLocale != null) {
      final parts = savedLocale.split('_');
      if (parts.length == 2) {
        _setLocaleState(Locale(parts[0], parts[1]));
      } else {
        _setLocaleState(Locale(parts[0]));
      }
      debugPrint('[LocaleNotifier] _loadSavedLocale: set state to $state');
    }
    // If null, the app will use the system locale
  }

  /// Sync locale from user profile (called after login/profile refresh)
  /// This ensures the app uses the backend's preferred locale.
  ///
  /// PROD-2037: skip the override when the user has an explicit local pick.
  /// We key on a dedicated flag (set ONLY by [setLocale], NOT by
  /// [setLocaleFromDetectedCountry]) so IP-detected first-launch users still
  /// receive a legitimate post-login sync from the backend, while a user
  /// who deliberately picked PT in the AuthHeader globe doesn't get flipped
  /// to `en` by the backend default.
  void syncFromProfile(String? preferredLocale) {
    debugPrint(
      '[LocaleNotifier] syncFromProfile: preferredLocale=$preferredLocale, currentState=$state',
    );
    if (preferredLocale == null || preferredLocale.isEmpty) {
      // No backend preference - keep local preference or system default
      return;
    }

    final hasExplicitChoice = _prefs.getBool(_localeExplicitKey) ?? false;
    if (hasExplicitChoice) {
      debugPrint(
        '[LocaleNotifier] syncFromProfile: skipping override — explicit '
        'local choice in effect ($state). Backend says: $preferredLocale',
      );
      return;
    }

    // Parse the locale code (e.g., "pt-BR" or "en")
    final parts = preferredLocale.split('-');
    final newLocale = parts.length == 2
        ? Locale(parts[0], parts[1])
        : Locale(parts[0]);

    // Update state and persist locally
    if (state != newLocale) {
      debugPrint(
        '[LocaleNotifier] syncFromProfile: updating locale from $state to $newLocale',
      );
      _setLocaleState(newLocale);
      final localeString = newLocale.countryCode != null
          ? '${newLocale.languageCode}_${newLocale.countryCode}'
          : newLocale.languageCode;
      _prefs.setString(_localeKey, localeString);
    }
  }

  /// Set the app locale (locally and sync to API if authenticated)
  Future<void> setLocale(Locale locale) async {
    // PROD-2037: persist the "explicit user choice" guard FIRST — before we
    // mutate state or sync to the API. Onboarding refreshes the backend profile
    // at several checkpoints (onboarding_chat_screen.dart), and each refresh can
    // fire `syncFromProfile`, which overrides the locale UNLESS this flag is
    // already set (see [syncFromProfile]). Writing it up front closes the race
    // where a profile refresh landing mid-switch reads the guard as still-false
    // and clobbers the pick straight back to the backend's register-time
    // `en` default — the "language reverts a moment after I pick it" bug.
    await _prefs.setBool(_localeExplicitKey, true);
    final localeString = locale.countryCode != null
        ? '${locale.languageCode}_${locale.countryCode}'
        : locale.languageCode;
    await _prefs.setString(_localeKey, localeString);

    // Only now flip the live state — any listener the state change wakes up
    // (or any concurrent profile refresh) already sees the guard in place.
    _setLocaleState(locale);

    // Clear cached message starters so they refresh in new locale
    await _storageService.clearMessageStarters();

    // Sync to API if authenticated
    await _syncToApi(locale);
  }

  /// Reset to system locale
  Future<void> resetToSystem() async {
    _setLocaleState(null);
    await _prefs.remove(_localeKey);
    await _prefs.remove(_localeExplicitKey);

    // Note: We don't sync null to API - user can set preferred_locale to null
    // via profile update if needed
  }

  /// Set locale based on detected country code (only if no explicit preference).
  /// This is called on first app launch when IP detection returns a country.
  /// Maps country codes to supported locales:
  /// - BR → pt_BR
  /// - PT, AO, MZ, CV, GW, ST, TL → pt
  /// - Others or null → en (English default)
  void setLocaleFromDetectedCountry(String? countryCode) {
    // Only set if user hasn't made an explicit choice yet
    final savedLocale = _prefs.getString(_localeKey);
    if (savedLocale != null) {
      debugPrint(
        '[LocaleNotifier] setLocaleFromDetectedCountry: user has explicit preference ($savedLocale), skipping',
      );
      return;
    }

    final locale = _localeForCountryCode(countryCode);
    debugPrint(
      '[LocaleNotifier] setLocaleFromDetectedCountry: countryCode=$countryCode → locale=$locale',
    );

    _setLocaleState(locale);
    final localeString = locale.countryCode != null
        ? '${locale.languageCode}_${locale.countryCode}'
        : locale.languageCode;
    _prefs.setString(_localeKey, localeString);
  }

  /// Maps country code to locale.
  /// Portuguese-speaking countries → Portuguese variants
  /// All others → English
  Locale _localeForCountryCode(String? countryCode) {
    if (countryCode == null) {
      return const Locale('en'); // Default to English
    }

    switch (countryCode.toUpperCase()) {
      case 'BR':
        return const Locale('pt', 'BR');
      case 'PT': // Portugal
      case 'AO': // Angola
      case 'MZ': // Mozambique
      case 'CV': // Cape Verde
      case 'GW': // Guinea-Bissau
      case 'ST': // São Tomé and Príncipe
      case 'TL': // Timor-Leste
        return const Locale('pt');
      case 'MX': // Mexico
        // Matches the backend, which maps the +52 phone prefix to es-MX. Only
        // Mexico is mapped here: serving Mexican Spanish to other Spanish-
        // speaking markets by IP is a market decision, not a technical one.
        return const Locale('es', 'MX');
      default:
        return const Locale('en'); // Default to English for all other countries
    }
  }

  /// Sync locale preference to API
  Future<void> _syncToApi(Locale locale) async {
    // Check if user is authenticated by checking for stored token
    final token = await _storageService.getAccessToken();
    if (token == null || token.isEmpty) return;

    try {
      // Convert locale to API format (e.g., "pt-BR")
      final apiCode =
          locale.countryCode != null && locale.countryCode!.isNotEmpty
          ? '${locale.languageCode}-${locale.countryCode}'
          : locale.languageCode;

      await _getAuthMethodsApi().updateProfile(
        ProfileUpdateRequest(preferredLocale: apiCode),
      );
      // Pull the updated profile back so `currentUser.preferredLocale` no longer
      // lingers on the register-time `en` default — otherwise any surface still
      // keyed on the cached profile (e.g. server-side content generation) keeps
      // seeing English after the user has switched. Best-effort.
      await _refreshProfile?.call();
    } catch (e) {
      // Silently fail - local preference is already saved
      // API sync is best-effort
      debugPrint('[LocaleNotifier] Failed to sync locale to API: $e');
    }
  }
}

/// Provider for locale state
// ignore: type_annotate_public_apis -- explicit type breaks the cyclic
// inference between apiClientProvider, apiLocaleCodeProvider, localeProvider
// and authMethodsApiProvider (see [LocaleNotifier._getAuthMethodsApi]).
final StateNotifierProvider<LocaleNotifier, Locale?> localeProvider =
    StateNotifierProvider<LocaleNotifier, Locale?>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      final storageService = ref.watch(storageServiceProvider);
      // PROD-2037: lazy lookup of the auth API breaks the construction-time
      // cycle apiClientProvider → apiLocaleCodeProvider → localeProvider →
      // authMethodsApiProvider → apiClientProvider. The callback fires only
      // when the user changes locale (`setLocale` → `_syncToApi`), well
      // after every provider in the graph has been constructed.
      return LocaleNotifier(
        prefs,
        storageService,
        () => ref.read(authMethodsApiProvider),
        // Late-bound (same cyclic-import reason as the auth API above): fired
        // only from user-driven setLocale, long after the graph is built.
        refreshProfile: () =>
            ref.read(authStateProvider.notifier).refreshUserProfile(),
      );
    });

/// Provider for the current AppLocale (with display names)
final currentAppLocaleProvider = Provider<AppLocale?>((ref) {
  final locale = ref.watch(localeProvider);
  final availableLocales = ref.watch(availableLocalesProvider);
  return AppLocale.fromLocale(locale, availableLocales);
});

/// Provider for fetching available locales from API with caching
/// Returns cached data immediately if available, then refreshes in background
final apiLocalesProvider = FutureProvider<List<LocaleInfo>>((ref) async {
  final localesApi = ref.watch(localesApiProvider);
  final storageService = ref.watch(storageServiceProvider);

  // Check cache first - return immediately if cached (avoids 487ms API call)
  final cachedLocales = storageService.loadCachedLocales();
  if (cachedLocales != null && cachedLocales.isNotEmpty) {
    debugPrint(
      '[apiLocalesProvider] Using cached locales (${cachedLocales.length} items)',
    );

    // Refresh cache in background (fire-and-forget)
    _refreshLocalesCache(localesApi, storageService);

    return cachedLocales;
  }

  // No cache - fetch from API
  try {
    debugPrint('[apiLocalesProvider] No cache, fetching from API...');
    final response = await localesApi.listLocales();

    // Cache the response for next time
    await storageService.saveCachedLocales(response.locales);
    debugPrint(
      '[apiLocalesProvider] Cached ${response.locales.length} locales',
    );

    return response.locales;
  } catch (e) {
    debugPrint('[apiLocalesProvider] Failed to fetch locales: $e');
    // Return empty list on error, will fall back to defaults
    return [];
  }
});

/// Refresh locales cache in background (fire-and-forget)
Future<void> _refreshLocalesCache(
  ILocalesApi localesApi,
  StorageService storageService,
) async {
  try {
    final response = await localesApi.listLocales();
    await storageService.saveCachedLocales(response.locales);
    debugPrint(
      '[apiLocalesProvider] Background refresh: cached ${response.locales.length} locales',
    );
  } catch (e) {
    // Silently fail - we already have cached data
    debugPrint('[apiLocalesProvider] Background refresh failed: $e');
  }
}

/// Provider for all available locales (from API or defaults)
final availableLocalesProvider = Provider<List<AppLocale>>((ref) {
  final apiLocalesAsync = ref.watch(apiLocalesProvider);

  return apiLocalesAsync.when(
    data: (locales) {
      if (locales.isEmpty) {
        return AppLocale.defaultLocales;
      }
      // The displayed set is backend-driven: whatever `/app/locales` returns.
      // `defaultLocales` is only the transient loading/error/empty fallback
      // below. TODO(PROD-3679): once the backend owns locale normalization we
      // can trust this list 100% and drop the fallback + `normalizeToApiLocale`.
      return locales.map((info) => AppLocale.fromLocaleInfo(info)).toList();
    },
    loading: () => AppLocale.defaultLocales,
    error: (_, __) => AppLocale.defaultLocales,
  );
});

/// Normalize a Flutter [Locale] to one of the backend's supported API locale
/// codes: `"pt-PT"`, `"pt-BR"`, `"es-MX"`, `"es"`, or `"en"`. Returns `null`
/// only if [locale] is `null`.
///
/// PROD-2037: the client stores Portugal as `Locale('pt')` (no country code),
/// but the backend's `detect_locale_from_accept_language` only recognizes
/// `"pt-PT"` and `"pt-BR"` explicitly — bare `"pt"` would fall through to
/// the EN default and reintroduce the locale-override bug. Likewise, raw
/// platform locales like `"en-US"` / `"en-GB"` aren't in the supported set
/// and would round-trip to `"en"` anyway. This helper makes the mapping
/// explicit so every outbound request, every analytics payload, and every
/// API consumer agrees on the same three values.
String? normalizeToApiLocale(Locale? locale) {
  if (locale == null) return null;
  final lang = locale.languageCode.toLowerCase();
  final country = locale.countryCode?.toUpperCase();

  if (lang == 'pt') {
    if (country == 'BR') return 'pt-BR';
    // Bare 'pt' OR any other country (including 'PT' itself) → pt-PT.
    return 'pt-PT';
  }
  if (lang == 'es') {
    // Mirror the `pt` guard: Mexico → es-MX, any other Spanish region (or
    // bare 'es') → 'es'. The backend collapses every es-* variant to es-MX.
    if (country == 'MX') return 'es-MX';
    return 'es';
  }
  // Everything else clamps to 'en'. The backend's supported set is
  // {pt-PT, pt-BR, es-MX, en}; raw codes outside it round-trip to 'en' anyway.
  return 'en';
}

/// Provider for current locale as API code (one of `pt-PT`, `pt-BR`, `es-MX`,
/// `es`, `en`).
/// Falls back to the platform locale if no explicit preference is set,
/// so the backend always receives a locale (important for guest users).
// Same explicit-type rationale as [localeProvider] — see comment above.
final Provider<String?> apiLocaleCodeProvider = Provider<String?>((ref) {
  final locale = ref.watch(localeProvider);
  if (locale != null) return normalizeToApiLocale(locale);
  return normalizeToApiLocale(PlatformDispatcher.instance.locale);
});
