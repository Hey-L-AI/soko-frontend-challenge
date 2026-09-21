import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/exceptions/api_exceptions.dart';
import '../core/services/attribution_service.dart';
import '../core/services/storage_service.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import '../data/models/models.dart';
import '../features/onboarding/providers/login_history_provider.dart';
import 'api_provider.dart';
import 'auth_provider.dart';

class PreferencesState {
  final UserPreferences? preferences;
  final bool isLoading;
  final bool isSaving;
  final String? error;

  const PreferencesState({
    this.preferences,
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  static const initial = PreferencesState();

  PreferencesState copyWith({
    UserPreferences? preferences,
    bool? isLoading,
    bool? isSaving,
    String? error,
    bool clearError = false,
  }) {
    return PreferencesState(
      preferences: preferences ?? this.preferences,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PreferencesNotifier extends StateNotifier<PreferencesState> {
  final IPreferencesApi _api;

  PreferencesNotifier(this._api) : super(PreferencesState.initial);

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final preferences = await _api.getPreferences();
      state = state.copyWith(isLoading: false, preferences: preferences);
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load preferences. Please try again.',
      );
    }
  }

  Future<bool> update({
    bool? emailMarketingOptIn,
    bool? smsMarketingOptIn,
    bool? pnOptin,
    String? pushNotificationToken,
    String? pushNotificationPlatform,
    bool? termsAccepted,
    bool? privacyAccepted,
    bool? locationOptIn,
    String? locationOptInSource,
    String? locationOptInPlatform,
    List<int>? defaultReminderOffsetsMinutes,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);

    try {
      final preferences = await _api.updatePreferences(
        UpdatePreferencesRequest(
          emailMarketingOptIn: emailMarketingOptIn,
          smsMarketingOptIn: smsMarketingOptIn,
          pnOptin: pnOptin,
          pushNotificationToken: pushNotificationToken,
          pushNotificationPlatform: pushNotificationPlatform,
          termsAccepted: termsAccepted,
          privacyAccepted: privacyAccepted,
          locationOptIn: locationOptIn,
          locationOptInSource: locationOptInSource,
          locationOptInPlatform: locationOptInPlatform,
          defaultReminderOffsetsMinutes: defaultReminderOffsetsMinutes,
        ),
      );
      state = state.copyWith(isSaving: false, preferences: preferences);
      return true;
    } on DioException catch (e) {
      // PROD-2439 — surface the backend's `detail` on 422 (channel-
      // unreachable explanation) instead of a generic message. The
      // error interceptor packs `detail` into ValidationException.message.
      final inner = e.error;
      final message = inner is ValidationException
          ? inner.message
          : 'Failed to update preferences. Please try again.';
      state = state.copyWith(isSaving: false, error: message);
      return false;
    } catch (_) {
      state = state.copyWith(
        isSaving: false,
        error: 'Failed to update preferences. Please try again.',
      );
      return false;
    }
  }
}

final preferencesProvider =
    StateNotifierProvider<PreferencesNotifier, PreferencesState>((ref) {
      // PROD-2285 Phase 2 / PROD-2244 — clear stale preferences so a
      // prior session can't leak into a new user's view. Mirrors
      // `accountProvider`'s listener.
      //
      // CRITICAL: do NOT invalidate on a null→user transition. The
      // login flows (OTP / Google / Apple — see `auth_provider.dart`
      // `_loadPreferences()`) load preferences BEFORE flipping
      // `authState.user`. An eager invalidate here wipes those
      // just-loaded preferences right after auth flips, leaving
      // `needsSokoIntroProvider` stuck at `null` (preferences=null) and
      // the router won't redirect to Siga — exactly the cohort PROD-2285
      // is trying to capture (PROD-2283 regression). Only invalidate
      // when going FROM an authenticated user (logout, or true account
      // switch with no logout in between).
      ref.listen<String?>(authStateProvider.select((s) => s.user?.id), (
        prev,
        next,
      ) {
        if (prev != null && prev != next) ref.invalidateSelf();
      });
      final api = ref.watch(preferencesApiProvider);
      return PreferencesNotifier(api);
    });

/// Whether the app is running on the web platform. Defaults to [kIsWeb];
/// exists as a provider so tests can override it. Still consumed by
/// [needsLocationAskProvider]'s legacy callers and a few feature flags.
final isWebPlatformProvider = Provider<bool>((ref) => kIsWeb);

/// Server-derived Siga gate. The backend filters `*_at` keys on
/// `GET /me/preferences` (driven by `X-Client-Platform`) to only the
/// channels the user/platform can actually fulfill, so the gate is a
/// single null-check across the filtered set. Covers both cohorts:
///
/// - **New users** — every applicable `*_at` is present-but-null, so
///   `hasUnrecordedConsent` is true and Siga fires.
/// - **Returning users with cross-device gaps** — a single channel's
///   `*_at` being null still trips the gate, so a web-first signup
///   opening iOS still sees Siga for push consent.
///
/// Returns `null` while preferences are still loading (router treats
/// this as "don't redirect — let current navigation continue").
final needsSokoIntroProvider = Provider<bool?>((ref) {
  final p = ref.watch(preferencesProvider).preferences;
  if (p == null) return null;
  return p.hasUnrecordedConsent;
});

/// Identifies who the location-ask key should be scoped to right now.
/// Authed users → `('user', userId)`. Explicit guests with a cached
/// visitor id → `('guest', visitorId)`. Returns `null` while either
/// signal is still resolving (router treats it as "wait").
class LocationAskIdentity {
  const LocationAskIdentity({required this.scope, required this.id});
  final String scope;
  final String id;
}

final currentLocationAskIdentityProvider = Provider<LocationAskIdentity?>((
  ref,
) {
  final auth = ref.watch(authStateProvider);
  if (auth.isAuthenticated) {
    final userId = auth.user?.id;
    if (userId == null) return null;
    return LocationAskIdentity(scope: 'user', id: userId);
  }
  // Guest path: only meaningful once the user has explicitly chosen guest
  // mode (bootstrap-mint guests should never see this surface).
  if (!ref.watch(explicitGuestModeProvider)) return null;
  final visitorId = ref.watch(attributionServiceProvider).cachedVisitorId;
  if (visitorId == null) return null;
  return LocationAskIdentity(scope: 'guest', id: visitorId);
});

/// Per-device "ask the user for location once" gate. Fires when the slim
/// surface hasn't yet been shown for the current `(scope, id)` on this
/// device AND full Siga isn't already going to fire.
///
/// - **Guest** who tapped "Continue as guest" for the first time on this
///   device → fires (no per-visitor flag yet).
/// - **Brand-new authed user** → does NOT fire here; full Siga handles
///   it via the bundled location card, and Siga's `_onContinue` marks
///   the per-device flag so the slim doesn't re-prompt on the same
///   device.
/// - **Returning authed user, new device** → fires (no per-user flag for
///   this install yet); Siga doesn't fire because every `*_at` is
///   already stamped server-side.
/// - **Anyone who already saw the slim surface (or finished Siga) on
///   this device under the same identity** → does not fire.
///
/// Returns `null` while preferences or the identity are still resolving
/// (router treats this as "don't redirect").
final needsLocationAskProvider = Provider<bool?>((ref) {
  final needsSoko = ref.watch(needsSokoIntroProvider);
  if (needsSoko == null) return null;
  if (needsSoko) return false;
  final identity = ref.watch(currentLocationAskIdentityProvider);
  if (identity == null) return null;
  final prefs = ref.watch(sharedPreferencesProvider);
  final key = locationAskShownKey(scope: identity.scope, id: identity.id);
  return !prefs.containsKey(key);
});
