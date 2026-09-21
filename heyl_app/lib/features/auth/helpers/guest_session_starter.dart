import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/environment.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/attribution_service.dart';
import '../../../core/services/storage_service.dart';
import '../../onboarding/providers/login_history_provider.dart';

/// SharedPreferences key prefix for per-visitor guest location consent.
/// Keyed by `visitor_id` so a fresh device or cleared storage gets a fresh
/// ask. Value is the boolean answer (`true` = Allow, `false` = Skip /
/// dismiss). On web the actual localStorage key is `flutter.<this>` — the
/// `flutter.` prefix is added by the SharedPreferences plugin and is not
/// included in Dart code.
///
/// Shared with `migrateGuestLocationConsentIfNeeded` so the writer (the
/// session starter) and the reader (the migration helper) agree on the
/// key format.
const guestLocationOptInKeyPrefix = 'guest_location_opt_in.';

/// Build the per-visitor consent key. Shared between the writer
/// ([startGuestSession]) and the reader (the sign-in migration helper).
String guestLocationOptInKey(String visitorId) =>
    '$guestLocationOptInKeyPrefix$visitorId';

/// Shared entry point for the explicit "Continue as guest" tap.
///
/// Sets the explicit-guest flag, ensures the visitor id is cached
/// (so the router-side `currentLocationAskIdentityProvider` can read
/// it synchronously), then routes:
///
/// - If we've already shown the location ask on this device for this
///   visitor, go straight to home.
/// - Otherwise navigate to `/auth/location-ask` — the slim screen
///   writes the guest-consent key, fires the OS prompt, marks the
///   per-device flag, and navigates onward when the user taps Continue.
///
/// Trigger placement is deliberate: this runs ONLY at the user-initiated
/// guest tap, never on bootstrap-mint (`_initializeFromStorage`) or 401
/// re-mint (those have no user intent attached, so surfacing a permission
/// surface would be jarring).
///
/// The caller is responsible for any analytics events that should fire
/// BEFORE the user enters this flow (e.g. `trackAuthPrompt(... guest)`).
Future<void> startGuestSession(BuildContext context, WidgetRef ref) async {
  // Defense-in-depth for the native guest-mode removal: the "Continue as
  // guest" button is already hidden when [guestModeEnabled] is false, but if
  // any path reaches here on such a build, refuse to mint a guest choice and
  // send the user to /login instead.
  if (!EnvironmentConfig.guestModeEnabled) {
    if (context.mounted) context.go(AppRoutes.login);
    return;
  }
  await setExplicitGuestMode(ref, value: true);
  if (!context.mounted) return;

  // Forces the visitor id into the AttributionService's sync cache so
  // currentLocationAskIdentityProvider can resolve it on the very next
  // router pass.
  final visitorId = await ref.read(attributionServiceProvider).getVisitorId();
  if (!context.mounted) return;

  final prefs = ref.read(sharedPreferencesProvider);
  final alreadyAsked = prefs.containsKey(
    locationAskShownKey(scope: 'guest', id: visitorId),
  );
  if (alreadyAsked) {
    context.go(AppRoutes.home);
  } else {
    context.go(AppRoutes.locationAsk);
  }
}
