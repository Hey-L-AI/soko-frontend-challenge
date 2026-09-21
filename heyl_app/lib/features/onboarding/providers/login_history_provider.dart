import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/environment.dart';
import '../../../core/services/storage_service.dart';
import '../../../providers/preferences_provider.dart';

const _explicitGuestModeKey = 'explicit_guest_mode';

/// Persisted flag set when the user explicitly taps "Continue as guest" on
/// the login screen. Survives app restarts and browser refreshes so the
/// user is not forced to re-affirm the choice on every cold launch.
/// Cleared on logout (see `AuthNotifier`'s `onIdentityCleared` callback).
///
/// Without this flag, the router bounces all unauthenticated visitors to
/// `/login` on every navigation — see the redirect block in
/// `app_router.dart`. The flag is what tells the router "the user has
/// already chosen guest mode, let them through".
final explicitGuestModeProvider = Provider<bool>((ref) {
  // Guest mode is web-only when [EnvironmentConfig.guestModeEnabled] is false
  // (native removal). Short-circuit to `false` so the router walls native
  // visitors to /login — this also ignores any `explicit_guest_mode=true`
  // persisted by a prior guest session, so existing native guests are walled
  // on next launch rather than lingering.
  if (!EnvironmentConfig.guestModeEnabled) return false;
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getBool(_explicitGuestModeKey) ?? false;
});

/// Persists the user's "Continue as guest" choice (or clears it on logout).
/// Works with both WidgetRef (from widgets) and Ref (from providers/router).
Future<void> setExplicitGuestMode(dynamic ref, {required bool value}) async {
  final prefs = ref.read(sharedPreferencesProvider);
  await prefs.setBool(_explicitGuestModeKey, value);
  ref.invalidate(explicitGuestModeProvider);
}

// `needsSokoIntroProvider` (defined in `preferences_provider.dart`)
// derives directly from server preferences — the backend is the single
// source of truth for whether Siga is owed.

/// Per-device-per-identity "we've shown the location-ask surface" flag.
/// Lives in SharedPreferences so it's device-local; the suffix is
/// `user.<userId>` for an authed account or `guest.<visitorId>` for a
/// guest session. Set by `SokoWelcomeScreen` (after Siga's PATCH) and
/// `SokoLocationAskScreen` (after either the authed PATCH or the guest
/// local write). Read by `needsLocationAskProvider`.
const locationAskShownKeyPrefix = 'location_ask_shown.';

String locationAskShownKey({required String scope, required String id}) =>
    '$locationAskShownKeyPrefix$scope.$id';

/// Marks the slim location-ask surface as "shown for this (scope, id) on
/// this device". `scope` is `'user'` or `'guest'`; `id` is the user or
/// visitor id. Works with both `WidgetRef` and `Ref`.
Future<void> markLocationAskShown(
  dynamic ref, {
  required String scope,
  required String id,
}) async {
  final key = locationAskShownKey(scope: scope, id: id);
  final prefs = ref.read(sharedPreferencesProvider);
  final hadKeyBefore = prefs.containsKey(key);
  debugPrint(
    '[SIGA-DIAG] markLocationAskShown: writing key="$key" '
    '(hadKeyBefore=$hadKeyBefore)',
  );
  await prefs.setBool(key, true);
  final hasKeyAfter = prefs.containsKey(key);
  // `sharedPreferencesProvider` is a fixed overridden instance, so a `setBool`
  // mutates it in place without changing the provider's identity — readers of
  // `needsLocationAskProvider` (notably the router gate) never observe the
  // write. Invalidate the gate explicitly so it re-reads the flag, mirroring
  // how `setExplicitGuestMode` invalidates `explicitGuestModeProvider`. Without
  // this, the slim location-ask screen bounces in a loop: the PATCH succeeds
  // but the router keeps reading a stale `needsLocationAsk == true`.
  ref.invalidate(needsLocationAskProvider);
  debugPrint(
    '[SIGA-DIAG] markLocationAskShown: write done (hasKeyAfter=$hasKeyAfter), '
    'invalidated needsLocationAskProvider',
  );
}
