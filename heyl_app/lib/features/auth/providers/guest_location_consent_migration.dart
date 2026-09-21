import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

import '../../../core/services/attribution_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../providers/preferences_provider.dart';
import '../helpers/guest_session_starter.dart';

/// Value the FE sends in `location_opt_in_source` when migrating a
/// pre-sign-in guest consent. Currently NOT in the OpenAPI enum
/// (`open-api/heyl-webapp-v1.openapi.yaml:13708`); waiting on PROD-2301
/// Child 1. Until the enum extension ships, every PATCH carrying this
/// source 422s; the helper's `if (patched)` guard keeps the local key
/// for retry on the next sign-in, so behaviour is forward-compatible.
///
/// TODO(PROD-2301 Child 1): replace with the generated enum/source
/// constant once `guest_migration` is added to the OpenAPI spec.
const _guestMigrationSource = 'guest_migration';

/// Source platform reported alongside the migration PATCH. Web is the
/// primary guest surface today; iOS / Android land via the same flow on
/// native builds. Uses `defaultTargetPlatform` (from `foundation.dart`)
/// rather than `dart:io::Platform` so the helper compiles cleanly on
/// every Flutter target.
String _platform() {
  if (kIsWeb) return 'web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      // No native HeyL build for desktop today; fall back to the
      // closest reasonable value so the PATCH still describes "not web".
      return 'android';
  }
}

/// PROD-2305 — migrate a guest's locally-stored location consent answer
/// (set by `SokoLocationAskScreen` via `startGuestSession`) to the
/// backend's `user_preferences.location_opt_in` row on first successful
/// sign-in.
///
/// Idempotent and fail-soft:
///   - no local key            → no-op (nothing to migrate)
///   - PATCH 2xx               → local key cleared (migration complete)
///   - PATCH non-2xx / network → local key persists, no exception thrown
///     (next sign-in retries with the same value)
///
/// Takes `dynamic ref` to accept both `Ref` (from `AuthNotifier`) and
/// `WidgetRef` (from tests / future widget call sites). Mirrors the
/// precedent set by `setExplicitGuestMode`.
///
/// MUST be called AFTER `_loadPreferences()` (so the helper isn't racing
/// the server-side state load) and BEFORE `state.copyWith(isGuest:
/// false)` in each sign-in path, so the router sees the migrated
/// `location_opt_in` before evaluating the Siga gate.
Future<void> migrateGuestLocationConsentIfNeeded(dynamic ref) async {
  final visitorId = await ref.read(attributionServiceProvider).getVisitorId();
  final prefs = ref.read(sharedPreferencesProvider);
  final key = guestLocationOptInKey(visitorId);

  final local = prefs.getBool(key);
  if (local == null) return;

  // Consent-integrity guard: if the freshly-loaded server preference
  // already has a `location_opt_in` value, the server is authoritative —
  // do NOT overwrite an existing user's settings-screen choice with a
  // stale guest answer from this device. Drop the local key so the guest
  // cohort flow is considered complete (it is — the user has a
  // real consent on file already) and bail before any PATCH fires.
  final serverPreferences = ref.read(preferencesProvider).preferences;
  if (serverPreferences?.locationOptIn != null) {
    await prefs.remove(key);
    return;
  }

  final patched = await ref
      .read(preferencesProvider.notifier)
      .update(
        locationOptIn: local,
        locationOptInSource: _guestMigrationSource,
        locationOptInPlatform: _platform(),
      );

  if (patched) {
    await prefs.remove(key);
  }
}
