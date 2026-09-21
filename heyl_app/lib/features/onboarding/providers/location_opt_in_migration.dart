import 'package:flutter/foundation.dart';

import '../../../core/services/storage_service.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/preferences_provider.dart';

const _migrationDoneKey = 'location_opt_in_migration_done_v1';
const _legacyLocalFlagKey = 'has_completed_location_setup';

/// One-time client migration that backfills `location_opt_in=true` on
/// the server for users who already have the legacy
/// `has_completed_location_setup` SharedPreferences flag set.
/// Idempotent: a successful PATCH writes
/// `location_opt_in_migration_done_v1=true` so subsequent calls skip.
///
/// Why: PROD-2285 Phase 1 makes `location_opt_in` the source of
/// truth. Without this backfill every existing user with a granted
/// location would re-evaluate Siga as "needed" and be re-prompted on
/// first launch after deploy.
///
/// Trigger sites:
/// - `app.dart`'s post-frame callback for users who launch with a
///   cached, already-authenticated session.
/// - The authStateProvider listener (also in `app.dart`) for users
///   who sign in during the same app session — the startup call
///   would have early-returned because `isAuthenticated` was false.
///
/// Guards:
/// - Skipped on web (the local flag is mobile-only; web `locationOptIn`
///   must stay NULL by design).
/// - Skipped when not authenticated — guards against PATCH /me/preferences
///   firing on the guest bootstrap token (which would either fail or
///   write to the wrong user). [codex P2]
/// - Skipped when the local flag isn't set (users who never completed
///   Siga don't trigger anything — they'll see Siga as intended).
/// - Skipped when the migration done flag is already set.
/// - Failure is silent — the next trigger retries.
///
/// `ref` accepts either `WidgetRef`, `Ref`, or `ProviderContainer` —
/// any object with a `read<T>(provider)` method. We type it loosely so
/// the same helper works from `app.dart`'s `ConsumerState` and from
/// tests using a `ProviderContainer`.
Future<void> runLocationOptInMigrationIfNeeded(dynamic ref) async {
  if (kIsWeb) return;
  // [codex P2] gate on real-user auth — never PATCH on guest token.
  if (!ref.read(isAuthenticatedProvider)) return;
  final prefs = ref.read(sharedPreferencesProvider);
  if (prefs.getBool(_migrationDoneKey) ?? false) return;
  final hasLocalFlag = prefs.getBool(_legacyLocalFlagKey) ?? false;
  if (!hasLocalFlag) return;

  final platform = defaultTargetPlatform == TargetPlatform.iOS
      ? 'ios'
      : defaultTargetPlatform == TargetPlatform.android
      ? 'android'
      : null;

  final patched = await ref
      .read(preferencesProvider.notifier)
      .update(
        locationOptIn: true,
        locationOptInSource: 'migration',
        locationOptInPlatform: platform,
      );

  if (patched) {
    await prefs.setBool(_migrationDoneKey, true);
  }
}
