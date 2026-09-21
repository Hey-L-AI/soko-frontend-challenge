// PROD-2303 step 4 — canonical state machine for "should the app act on the
// user's location, and how precisely?" — derived from three orthogonal inputs
// that previously had to be stitched together at every consumer site:
//
//   1. Server consent       — `UserPreferences.location_opt_in` (true/false/null)
//   2. OS/browser permission — `LocationState.permissionStatus`
//   3. Last known fix        — `LocationState.lastLocation` (GPS / IP / none)
//
// The state collapses the 18-cell input grid into 7 named outcomes that
// `LocationNotifier`, the Settings UI, and the future PUT-dedup state can
// query without re-deriving the same logic. PROD-2305's local guest consent
// (`flutter.guest_location_opt_in.<visitor_id>`) plugs into the unauth branch
// without changing the public API.
//
// Tests pin every transition. The provider itself is a thin wrapper over the
// pure [computeLocationConsentState] function so consumers stay testable
// independently of Riverpod and the wider provider graph.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/location_service.dart';
import '../data/models/location_snapshot.dart';
import '../data/models/user_preferences.dart';
import 'auth_provider.dart';
import 'location_provider.dart';
import 'preferences_provider.dart';

/// Canonical state describing the user's location-consent intent + the
/// best-available data the app can act on right now.
sealed class LocationConsentState {
  const LocationConsentState();
}

/// Preferences are still loading (or guest local key not yet read). The
/// router treats this as "don't redirect"; UI should show neutral copy.
class LocationConsentUnknown extends LocationConsentState {
  const LocationConsentUnknown();
}

/// Authed user with `location_opt_in == true`, OS/browser permission
/// granted, and the most recent fix is `device_gps`. The precise path.
class LocationConsentGrantedGps extends LocationConsentState {
  const LocationConsentGrantedGps({required this.lastKnown});
  final LocationSnapshot lastKnown;
}

/// Authed user with `location_opt_in == true` but the most recent fix is
/// IP-approx, OR the OS denied permission (intent says yes, system
/// overrode). `lastKnown == null` means we have nothing usable yet (still
/// resolving) — consumers should treat this as a transient loading state.
class LocationConsentGrantedButIp extends LocationConsentState {
  const LocationConsentGrantedButIp({this.lastKnown});
  final LocationSnapshot? lastKnown;
}

/// Authed user with `location_opt_in == false`. We still have an IP-approx
/// last-known location, so shelves and scoping can use it; backend stores
/// it with `source: 'ip_approx'`.
class LocationConsentDeniedIp extends LocationConsentState {
  const LocationConsentDeniedIp({required this.lastKnown});
  final LocationSnapshot lastKnown;
}

/// Authed user with `location_opt_in == false` AND no IP fallback either.
/// Backend has no usable record; UI must surface a country/locale default.
class LocationConsentDeniedNoIp extends LocationConsentState {
  const LocationConsentDeniedNoIp();
}

/// Guest who answered "Allow" on the local sheet (PROD-2305). `lastKnown`
/// may be GPS, IP, or null while still resolving — the distinction matters
/// to the UI but not to the consent-PUT decision (guests never PUT).
class LocationConsentGuestGranted extends LocationConsentState {
  const LocationConsentGuestGranted({this.lastKnown});
  final LocationSnapshot? lastKnown;
}

/// Guest who answered "Skip" (or dismissed) on the local sheet. May still
/// have an IP fallback to drive shelves.
class LocationConsentGuestDenied extends LocationConsentState {
  const LocationConsentGuestDenied({this.ipFallback});
  final LocationSnapshot? ipFallback;
}

/// Pure decision function. Public so tests can pin every transition without
/// standing up a `ProviderContainer`.
///
/// - [isAuthenticated]: true when the session represents a real user (guest
///   tokens count as `false` per `isAuthenticatedProvider`).
/// - [preferences]: `null` while the user-preferences fetch is in flight.
/// - [permissionStatus]: OS / browser permission as reported by
///   `LocationService.checkPermission()`.
/// - [lastLocation]: best-available last-known fix. May be `device_gps`,
///   `ip_approx`, etc.
/// - [guestLocalOptIn]: PROD-2305's local sheet answer. `null` until the
///   guest has been asked, `true`/`false` afterward. Ignored when
///   [isAuthenticated] is `true`.
LocationConsentState computeLocationConsentState({
  required bool isAuthenticated,
  required UserPreferences? preferences,
  required LocationPermissionStatus? permissionStatus,
  required LocationSnapshot? lastLocation,
  required bool? guestLocalOptIn,
}) {
  if (!isAuthenticated) {
    if (guestLocalOptIn == null) return const LocationConsentUnknown();
    if (guestLocalOptIn) {
      return LocationConsentGuestGranted(lastKnown: lastLocation);
    }
    return LocationConsentGuestDenied(ipFallback: lastLocation);
  }

  // Authed path.
  if (preferences == null) return const LocationConsentUnknown();
  final consent = preferences.locationOptIn;
  if (consent == null) {
    // Siga gate will fire; treat as "don't act yet."
    return const LocationConsentUnknown();
  }

  if (consent == false) {
    if (lastLocation != null) {
      return LocationConsentDeniedIp(lastKnown: lastLocation);
    }
    return const LocationConsentDeniedNoIp();
  }

  // consent == true
  final isGps = lastLocation?.source == LocationSource.deviceGps;
  final hasGrant = permissionStatus == LocationPermissionStatus.granted;
  if (hasGrant && isGps && lastLocation != null) {
    return LocationConsentGrantedGps(lastKnown: lastLocation);
  }
  return LocationConsentGrantedButIp(lastKnown: lastLocation);
}

/// Provider wrapping [computeLocationConsentState] over the live inputs.
///
/// PROD-2305 will add `currentVisitorIdProvider` + a `guestLocationConsent`
/// reader; until then the guest branch returns `Unknown` (the local key
/// reader passed below is `null`-returning by default), which is the safe
/// "wait for the sheet to ship" behavior.
final Provider<LocationConsentState> locationConsentStateProvider =
    Provider<LocationConsentState>((ref) {
      final isAuthenticated = ref.watch(isAuthenticatedProvider);
      final preferences = ref.watch(preferencesProvider).preferences;
      final locState = ref.watch(locationProvider);
      // PROD-2305 — when the guest local key reader lands, swap this in.
      const bool? guestLocalOptIn = null;
      return computeLocationConsentState(
        isAuthenticated: isAuthenticated,
        preferences: preferences,
        permissionStatus: locState.permissionStatus,
        lastLocation: locState.lastLocation,
        guestLocalOptIn: guestLocalOptIn,
      );
    });

/// PROD-2303 step 5 — slim "is the consent decision available?" view used by
/// [LocationNotifier] to gate `_tryUpdateBackend`. Deliberately does NOT
/// depend on [locationProvider] (no `permissionStatus` / `lastLocation`
/// reads) so it can be consumed from inside the location provider without
/// creating a circular dependency.
///
/// Returns `true` when:
///   - authed user has a loaded `UserPreferences` with `location_opt_in`
///     set to true OR false (the user has been through Siga or Location-Ask
///     and answered), OR
///   - the session is a guest (PROD-2303 step 2's auth gate already prevents
///     guest PUTs; consent is "resolved" in the sense that no further wait
///     is needed before the auth gate fires).
///
/// Returns `false` while preferences are still loading or `location_opt_in`
/// is `null`. In that state `_tryUpdateBackend` stashes the snapshot in
/// `_pendingBackendUpdate`; the `ref.listen` wired in `locationProvider`
/// flushes it on the false → true transition.
final Provider<bool> locationConsentResolvedProvider = Provider<bool>((ref) {
  final isAuthenticated = ref.watch(isAuthenticatedProvider);
  if (!isAuthenticated) {
    // Guest sessions: PROD-2303 step 2's auth gate already prevents PUTs.
    // "Resolved" here means "no extra wait needed for the consent layer."
    return true;
  }
  final prefs = ref.watch(preferencesProvider).preferences;
  if (prefs == null) return false;
  return prefs.locationOptIn != null;
});
