import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:cookie_jar/cookie_jar.dart';

import '../core/config/environment.dart';
import '../core/constants/api_constants.dart';
import '../core/constants/eula_version.dart';
import '../features/business_home/utils/business_return_state.dart';
import '../core/exceptions/api_exceptions.dart';
import '../core/services/attribution_service.dart';
import '../core/services/auth_diagnostics_service.dart';
import '../core/services/experiment_service.dart';
import '../core/services/klaviyo_service.dart';
import '../core/services/push_permission_service.dart';
import '../core/services/sms_retriever_service.dart';
import '../core/services/refresh_coordinator.dart';
import '../core/services/storage_service.dart';
import '../core/services/token_scheduler_service.dart';
import '../core/services/unified_analytics_service.dart';
import '../core/utils/jwt_sub.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import '../data/datasources/interfaces/eula_api.dart';
import '../data/models/api_responses.dart';
import '../data/models/eula.dart';
import '../data/models/user_profile.dart';
import '../data/models/user_preferences.dart';
import '../features/auth/providers/guest_location_consent_migration.dart';
import '../features/onboarding/providers/login_history_provider.dart';
import 'api_provider.dart';
import 'locale_provider.dart';
import 'preferences_provider.dart';

/// Machine-readable auth failure the screens localize themselves
/// (PROD-2979). [AuthState.error] carries raw text the provider already had
/// (backend `detail`, rate-limit copy); a code is set instead when the
/// screen owns the user-facing copy via `Lt.of(context)`.
enum AuthErrorCode {
  /// `POST /auth/phone/start` rejected the number (400/422).
  invalidPhone,

  /// Any other failure on a sign-in call — show the generic login-failed copy.
  loginFailed,
}

/// Authentication state
class AuthState {
  final UserProfile? user;
  final String? accessToken;
  final DateTime? tokenExpiresAt;
  final bool isLoading;
  final bool isInitialized;
  final String? error;

  /// PROD-2979 — localized-by-the-screen error; takes precedence over
  /// [error] when both are set. Cleared on every `copyWith` like [error].
  final AuthErrorCode? errorCode;
  final String? pendingActivationEmail;
  final String? pendingPhoneVerification;

  /// PROD-1979 — true when [accessToken] is a stateless guest JWT
  /// (minted via `POST /api/v1/auth/guest`, `sub="guest:<visitor_id>"`).
  /// `accessToken` is set in this case too, so the auth interceptor can
  /// attach it to optional-auth endpoints (discovery feeds, public
  /// list/venue/event detail, search). `isAuthenticated` returns
  /// **false** for guests so existing route guards and UI gates
  /// (`requireAuth`, the guest CTAs on discovery, etc.) continue to
  /// treat unauth users correctly.
  final bool isGuest;

  const AuthState({
    this.user,
    this.accessToken,
    this.tokenExpiresAt,
    this.isLoading = false,
    this.isInitialized = false,
    this.error,
    this.errorCode,
    this.pendingActivationEmail,
    this.pendingPhoneVerification,
    this.isGuest = false,
  });

  /// User is authenticated as a **real** account (not a guest). The
  /// `accessToken != null` invariant is no longer enough on its own:
  /// after PROD-1979's guest bootstrap-mint, every running app carries
  /// some token, but guests must still be routed through the sign-in
  /// flow for save/follow/create. Profile may be null temporarily if
  /// network is unavailable.
  bool get isAuthenticated => accessToken != null && !isGuest;

  /// Check if the token is expired (with a 60-second grace period)
  bool get isTokenExpired {
    if (tokenExpiresAt == null) return false;
    // Use 60-second grace period to match backend
    return DateTime.now().isAfter(
      tokenExpiresAt!.subtract(const Duration(seconds: 60)),
    );
  }

  AuthState copyWith({
    UserProfile? user,
    String? accessToken,
    DateTime? tokenExpiresAt,
    bool? isLoading,
    bool? isInitialized,
    String? error,
    AuthErrorCode? errorCode,
    String? pendingActivationEmail,
    String? pendingPhoneVerification,
    bool? isGuest,
    bool clearUser = false,
    bool clearToken = false,
    bool clearPendingEmail = false,
    bool clearPendingPhone = false,
  }) {
    return AuthState(
      user: clearUser ? null : (user ?? this.user),
      accessToken: clearToken ? null : (accessToken ?? this.accessToken),
      tokenExpiresAt: clearToken
          ? null
          : (tokenExpiresAt ?? this.tokenExpiresAt),
      isLoading: isLoading ?? this.isLoading,
      isInitialized: isInitialized ?? this.isInitialized,
      error: error,
      errorCode: errorCode,
      pendingActivationEmail: clearPendingEmail
          ? null
          : (pendingActivationEmail ?? this.pendingActivationEmail),
      pendingPhoneVerification: clearPendingPhone
          ? null
          : (pendingPhoneVerification ?? this.pendingPhoneVerification),
      // PROD-1979 — when clearToken is set, also drop the guest flag so
      // the next state is a clean "no auth at all" baseline before the
      // bootstrap-mint runs again. Otherwise keep the explicit override
      // or the previous value.
      isGuest: clearToken ? false : (isGuest ?? this.isGuest),
    );
  }
}

/// Auth state notifier for managing authentication
class AuthNotifier extends StateNotifier<AuthState> {
  final IAuthApi _authApi;
  final IPreferencesApi _preferencesApi;
  final IEulaApi _eulaApi;
  final StorageService _storageService;
  final UnifiedAnalyticsService _analytics;
  final TokenSchedulerService _tokenSchedulerService;
  final AttributionService _attributionService;
  final AuthDiagnosticsService _diagnostics;
  final RefreshCoordinator _refreshCoordinator;
  final KlaviyoService _klaviyo;
  final CookieJar? _cookieJar;
  final Future<void> Function()? _onIdentityChanged;
  final VoidCallback? _onIdentityCleared;
  final Future<void> Function(
    String userId, {
    required bool shouldRegisterIfAuthorized,
  })?
  _onPushRegistrationNeeded;
  final Future<void> Function()? _onPreferencesLoadNeeded;

  /// PROD-2305 — fired once per successful sign-in to migrate the
  /// guest's pre-auth location-consent answer (from
  /// `guest_location_opt_in.<visitorId>` in SharedPreferences) to the
  /// backend's `user_preferences.location_opt_in` row.
  ///
  /// Wraps `migrateGuestLocationConsentIfNeeded(ref)` so AuthNotifier
  /// stays free of a direct Riverpod dependency. No-op when no local
  /// key exists; fail-soft on PATCH errors (key persists for retry on
  /// next sign-in). MUST run after `_loadPreferences()` so the migration
  /// happens against fresh server state, and BEFORE `state.copyWith(
  /// isGuest: false)` so the router sees the migrated
  /// `location_opt_in` before evaluating the Siga gate.
  final Future<void> Function()? _onMigrateGuestLocationConsent;

  /// PROD-2037 — returns the current app locale as a normalized API code
  /// (`pt-PT`, `pt-BR`, or `en`). Used by [_startGoogleLoginWebRedirect] to
  /// pipe the user's pre-auth choice through the browser-redirect path,
  /// which Dio interceptors cannot reach.
  final String? Function()? _getLocaleCode;

  String? _googleCallbackToken;
  Future<bool>? _googleCallbackCompletion;

  AuthNotifier(
    this._authApi,
    this._preferencesApi,
    this._eulaApi,
    this._storageService,
    this._analytics,
    this._tokenSchedulerService,
    this._attributionService,
    this._diagnostics,
    this._refreshCoordinator,
    this._klaviyo,
    this._cookieJar, {
    Future<void> Function()? onIdentityChanged,
    VoidCallback? onIdentityCleared,
    Future<void> Function(
      String userId, {
      required bool shouldRegisterIfAuthorized,
    })?
    onPushRegistrationNeeded,
    Future<void> Function()? onPreferencesLoadNeeded,
    Future<void> Function()? onMigrateGuestLocationConsent,
    String? Function()? getLocaleCode,
  }) : _onIdentityChanged = onIdentityChanged,
       _onIdentityCleared = onIdentityCleared,
       _onPushRegistrationNeeded = onPushRegistrationNeeded,
       _onPreferencesLoadNeeded = onPreferencesLoadNeeded,
       _onMigrateGuestLocationConsent = onMigrateGuestLocationConsent,
       _getLocaleCode = getLocaleCode,
       super(const AuthState()) {
    _initializeFromStorage();
  }

  @override
  set state(AuthState value) {
    // Publish context before listeners can emit events for the new screen.
    _analytics.updateAuthContext(
      initialized: value.isInitialized,
      authenticated: value.isAuthenticated,
      userId: value.isGuest ? null : value.user?.id,
    );
    super.state = value;
  }

  Future<void> _handleIdentityChanged(
    UserProfile user, {
    String? emailOverride,
    String? phoneOverride,
  }) async {
    // PROD-3478 — Meta Advanced Matching: forward whichever identifier this
    // auth path has (phone OTP → phone, email/Google/Apple → email; Apple
    // only supplies it on first authorization). Raw values — the native Meta
    // SDK hashes on-device. All-null calls are dropped by the destination,
    // so paths without identifiers (cold-start restore, web OAuth callback)
    // are safe no-ops that keep previously persisted matching data intact.
    await _analytics.setAdvancedMatchingData(
      email: emailOverride,
      phone: phoneOverride,
    );
    await _klaviyo.identify(user.id);
    await _onPushRegistrationNeeded?.call(
      user.id,
      shouldRegisterIfAuthorized: false,
    );
    await _onIdentityChanged?.call();
  }

  Future<void> _recordLegalAcceptance() async {
    try {
      await _preferencesApi.updatePreferences(
        const UpdatePreferencesRequest(
          termsAccepted: true,
          privacyAccepted: true,
        ),
      );
    } catch (e) {
      debugPrint('[AuthNotifier] Legal acceptance sync failed: $e');
    }

    // PROD-2264 — Record EULA acceptance server-side. The user has just
    // tapped Continue / Google / Apple / Register, which the inline tagline
    // declares as agreement to the Terms + Privacy + EULA. Idempotent on
    // the backend; safe to fire on every successful auth. Fail-soft —
    // the next cold-start `GET /eula/me` check will re-prompt if this fails.
    try {
      await _eulaApi.accept(
        EulaAcceptRequest(
          eulaVersion: kCurrentEulaVersion,
          locale: _getLocaleCode?.call(),
        ),
      );
    } catch (e) {
      debugPrint('[AuthNotifier] EULA acceptance sync failed: $e');
    }
  }

  /// PROD-2073 — load server-side preferences into `preferencesProvider`.
  /// The router watches `needsSokoIntroProvider` (derived from
  /// `preferencesProvider.state.preferences.smsMarketingOptInAt`) and
  /// re-evaluates the Siga gate once this completes. Called after every
  /// real-user sign-in AND from `_initializeFromStorage` on cold-start
  /// when a session is restored — together those cover every path the
  /// router needs server truth on.
  Future<void> _loadPreferences() async {
    try {
      await _onPreferencesLoadNeeded?.call();
    } catch (e) {
      debugPrint('[AuthNotifier] preferences load failed: $e');
      // Fail-soft: needsSokoIntroProvider stays `null`, router does not
      // redirect to Siga. Next sign-in retries.
    }
  }

  /// PROD-1979 — mint a stateless guest JWT keyed off the persisted
  /// [AttributionService.getVisitorId]. Stores the token via the same
  /// `saveAccessToken` path as a real login so the auth interceptor
  /// picks it up automatically and the refresh interceptor can detect
  /// it by JWT `sub` claim. Fail-soft on network/server errors — the
  /// caller decides what to do (bootstrap leaves state tokenless and
  /// re-mints on the next 401; logout falls back to a clean signed-out
  /// state).
  Future<bool> _mintGuestSession() async {
    try {
      final visitorId = await _attributionService.getVisitorId();
      final guest = await _authApi.createGuestSession(visitorId: visitorId);
      await _storageService.saveAccessToken(
        guest.accessToken,
        expiresAt: guest.expiresAt,
      );
      state = state.copyWith(
        accessToken: guest.accessToken,
        tokenExpiresAt: guest.expiresAt,
        isGuest: true,
        clearUser: true,
      );
      print(
        '[AuthNotifier] Minted guest session (visitor=$visitorId, expires=${guest.expiresAt})',
      );
      return true;
    } catch (e) {
      print('[AuthNotifier] Guest mint failed: $e');
      return false;
    }
  }

  /// Initialize auth state from persisted token
  /// PERFORMANCE: Does NOT block on API call - marks initialized immediately if token exists
  Future<void> _initializeFromStorage() async {
    print('[AuthNotifier] Starting initialization from storage...');
    final token = await _storageService.getAccessToken();
    final tokenExpiresAt = await _storageService.getTokenExpiresAt();

    // PROD-2095 — seed the refresh_token_fingerprint Sentry scope tag from
    // restored storage so any Sentry event in this session can be paired
    // with backend `auth_diag refresh.*` log lines. Falls back to 'none'
    // when no refresh token is present.
    final restoredRefreshToken = await _storageService.getRefreshToken();
    await _diagnostics.setRefreshTokenFingerprint(restoredRefreshToken);

    if (token == null || token.isEmpty) {
      // No token stored, check for pending phone verification
      print(
        '[AuthNotifier] No token found, checking for pending verification...',
      );

      // Check for pending phone verification (user was on OTP screen when tab was killed)
      final pendingPhone = _storageService.getPendingPhoneVerification();
      if (pendingPhone != null &&
          !_storageService.isPendingPhoneVerificationExpired()) {
        print('[AuthNotifier] Found pending phone verification: $pendingPhone');
        state = state.copyWith(
          isInitialized: true,
          pendingPhoneVerification: pendingPhone,
        );
        return;
      }

      // Clear expired pending verification
      if (pendingPhone != null) {
        print('[AuthNotifier] Pending verification expired, clearing...');
        await _storageService.clearPendingPhoneVerification();
      }

      print('[AuthNotifier] No pending verification — minting guest session');
      // PROD-1979 — bootstrap a guest token so every running app has a
      // bearer for optional-auth endpoints (discovery feeds, search,
      // public detail). Fail-soft if offline / BE down: the app still
      // launches in a tokenless state and the next API call's 401 will
      // trigger another mint attempt via the refresh interceptor.
      await _mintGuestSession();
      state = state.copyWith(isInitialized: true);
      return;
    }

    // Token exists - trust it and mark initialized immediately (no blocking API call)
    // This eliminates the splash screen delay on app startup
    final restoredIsGuest = isGuestJwt(token);
    print(
      '[AuthNotifier] Token found (isGuest=$restoredIsGuest), marking initialized',
    );

    // Diagnostic breadcrumb: token restored from storage
    _diagnostics.logTokenRestored(
      hasExpiry: tokenExpiresAt != null,
      isExpired:
          tokenExpiresAt != null && DateTime.now().isAfter(tokenExpiresAt),
    );

    // Load cached user profile for instant UI display
    final cachedUser = _storageService.loadCachedUserProfile();
    if (cachedUser != null) {
      print('[AuthNotifier] Restored cached user profile: ${cachedUser.id}');
    }

    state = state.copyWith(
      accessToken: token,
      tokenExpiresAt: tokenExpiresAt,
      user: cachedUser,
      isInitialized: true,
      isGuest: restoredIsGuest,
    );

    // PROD-1979 — guest tokens don't have a refresh cookie (the BE
    // re-mints on 401) and `/auth/me` is a real-user endpoint that
    // rejects them, so skip both paths for guest sessions.
    if (restoredIsGuest) {
      print('[AuthNotifier] Guest session restored — skipping me + refresh');
      return;
    }

    // Schedule proactive token refresh if we have expiry info
    if (tokenExpiresAt != null) {
      print(
        '[AuthNotifier] Scheduling proactive refresh (expires: $tokenExpiresAt)',
      );
      _tokenSchedulerService.scheduleRefresh(tokenExpiresAt);
      _diagnostics.logProactiveRefreshScheduled(
        timeUntilRefresh: tokenExpiresAt.difference(DateTime.now()),
      );
    }

    // Re-identify with PostHog and reload feature flags for the cached user.
    // This is non-blocking — the UI shows immediately with constructor defaults,
    // then updates reactively when flags resolve.
    if (cachedUser != null) {
      _analytics
          .setUserId(cachedUser.id)
          .then((_) => _handleIdentityChanged(cachedUser));
    }

    // PROD-2073 — load server preferences so `needsSokoIntroProvider` can
    // gate the router. Without this, a returning user with a restored
    // session is missed by the per-login `_loadPreferences()` calls and
    // would never re-prompt for Siga even if they hadn't completed it.
    // ignore: unawaited_futures
    _loadPreferences();

    // Fetch user profile in background (non-blocking)
    // If token is invalid, the error interceptor will catch 401 on first API call
    _refreshUserProfileInBackground();
  }

  /// Fetch user profile in background without blocking initialization
  Future<void> _refreshUserProfileInBackground() async {
    if (state.accessToken == null) return;
    final requestedToken = state.accessToken;
    final requestedContext = _analytics.actionContext;

    try {
      print('[AuthNotifier] Fetching user profile in background...');
      final user = await _authApi.getMe();
      if (!mounted ||
          state.accessToken != requestedToken ||
          !_analytics.isActionContextCurrent(requestedContext)) {
        return;
      }
      print('[AuthNotifier] User profile loaded: ${user.id}');
      state = state.copyWith(user: user);
      // Cache user profile for instant display on next refresh
      await _storageService.saveCachedUserProfile(user);
      await _analytics.setUserId(user.id);
      await _klaviyo.identify(user.id);
      await _onPushRegistrationNeeded?.call(
        user.id,
        shouldRegisterIfAuthorized: false,
      );
      _diagnostics.logBackgroundValidationResult(success: true);
    } catch (e) {
      print('[AuthNotifier] Background profile fetch failed: $e');
      // Check if this is an authentication error (401)
      if (_isAuthenticationError(e)) {
        print(
          '[AuthNotifier] 401 error - token expired, clearing and requiring new login',
        );
        _diagnostics.logBackgroundValidationResult(
          success: false,
          errorType: '401',
        );

        // Check if RefreshInterceptor already handled this 401.
        // The interceptor clears the token before propagating the error,
        // and logs a more specific session loss event (refresh_retries_exhausted,
        // token_not_refreshable, etc.). Avoid logging a duplicate event here.
        final currentToken = await _storageService.getAccessToken();
        if (currentToken == null) {
          // Interceptor already handled cleanup — just update local state.
          // No session loss event here (interceptor already logged a specific one).
          print(
            '[AuthNotifier] Token already cleared by RefreshInterceptor — skipping duplicate session loss event',
          );
          await _storageService.clearCachedUserProfile();
          state = state.copyWith(
            isInitialized: true,
            clearUser: true,
            clearToken: true,
          );
        } else {
          // Token still present — interceptor didn't handle it.
          // Attempt a manual refresh before giving up (PROD-691 fix).
          print(
            '[AuthNotifier] Interceptor did not handle 401 — attempting manual refresh',
          );
          _diagnostics.addBreadcrumb(
            'bg_refresh_attempt',
            data: {'reason': 'interceptor_did_not_handle_401'},
          );

          final refreshResult = await _attemptTokenRefresh();
          final refreshResponse = refreshResult.response;

          if (refreshResponse != null) {
            // Refresh succeeded — save new tokens and retry /auth/me
            await _storageService.saveAccessToken(
              refreshResponse.accessToken,
              expiresAt: refreshResponse.expiresAt,
            );
            if (refreshResponse.refreshToken != null) {
              await _storageService.saveRefreshToken(
                refreshResponse.refreshToken!,
              );
            }

            try {
              final user = await _authApi.getMe();
              state = state.copyWith(
                user: user,
                accessToken: refreshResponse.accessToken,
                tokenExpiresAt: refreshResponse.expiresAt,
              );
              await _storageService.saveCachedUserProfile(user);
              _diagnostics.addBreadcrumb(
                'bg_refresh_success',
                data: {'has_expiry': refreshResponse.expiresAt != null},
              );
              print(
                '[AuthNotifier] Manual refresh succeeded — session preserved',
              );

              // Schedule proactive refresh for the new token
              if (refreshResponse.expiresAt != null) {
                _tokenSchedulerService.scheduleRefresh(
                  refreshResponse.expiresAt!,
                );
                _diagnostics.logProactiveRefreshScheduled(
                  timeUntilRefresh: refreshResponse.expiresAt!.difference(
                    DateTime.now(),
                  ),
                );
              }
              return; // Success — no session loss
            } catch (retryError) {
              print(
                '[AuthNotifier] Retry /auth/me after refresh also failed: $retryError',
              );
              _diagnostics.addBreadcrumb(
                'bg_refresh_retry_failed',
                data: {'error': '$retryError'},
              );
              // Fall through to session loss below
            }
          } else {
            _diagnostics.addBreadcrumb(
              'bg_refresh_failed',
              data: {'reason': 'refresh_returned_null'},
            );
          }

          // Refresh failed or retry failed — log session loss and clean up.
          //
          // PROD-2131 — cookie-check URI was previously `Uri.parse('')`
          // (empty), which makes `loadForRequest` look up cookies for an
          // empty origin → always empty → `had_cookies` always false on
          // native, masking real cookie-presence state on bg_validation_401.
          // Use the API base URL so the lookup matches the same origin our
          // refresh Dio would actually send the cookie to.
          bool? hadCookies;
          final jar = _cookieJar;
          if (jar != null) {
            try {
              final cookies = await jar.loadForRequest(
                Uri.parse(EnvironmentConfig.baseUrl),
              );
              hadCookies = cookies.isNotEmpty;
            } catch (_) {}
          }
          // PROD-2131 — Decision 14 dedup: only the mutex holder logs the
          // Sentry session-loss event. Null mutex flag means we never got
          // a coordinator result (coordinator threw, or refresh wasn't
          // attempted) — treat as holder.
          final isMutexHolder = refreshResult.mutexAcquiredImmediately ?? true;
          // PROD-2168 Phase 2 parity — the interceptor's refresh_token_invalid
          // path suppresses follower-tab captures via `crossTabRole`. Mirror it
          // here so N follower tabs hitting bg_validation_401 don't each emit a
          // duplicate session-loss event. Null role (coordinator threw) counts
          // as holder and logs.
          final invalid = refreshResult.invalid;
          if (isMutexHolder &&
              refreshResult.crossTabRole != LockRole.follower) {
            await _diagnostics.logUnexpectedSessionLoss(
              trigger: 'bg_validation_401',
              refreshFailureReason:
                  'Background /auth/me returned 401, manual refresh also failed',
              refreshInvalidReason: invalid?.reason,
              refreshStatusCode: invalid?.statusCode,
              // PROD-3933 — normalized code (structured code, else known-detail
              // fallback) so `auth.backend_error_code` is populated on this path
              // too, not just the reactive interceptor.
              backendErrorCode: invalid?.diagnosticErrorCode,
              hadCookies: hadCookies,
              inflightWasPresent: _refreshCoordinator.isRefreshing,
              recentlySucceededRefresh: _refreshCoordinator
                  .recentlySucceededRefresh(),
            );
          }
          await _storageService.deleteAccessToken();
          await _storageService.clearCachedUserProfile();
          state = state.copyWith(
            isInitialized: true,
            clearUser: true,
            clearToken: true,
          );
        }
      } else {
        _diagnostics.logBackgroundValidationResult(
          success: false,
          errorType: '${e.runtimeType}',
        );
      }
      // For network errors, keep the token - validation will happen on next API call
    }
  }

  /// Check if an error is an authentication error (401)
  bool _isAuthenticationError(dynamic error) {
    if (error is AuthenticationException) return true;
    if (error is DioException) {
      // Check if the wrapped error is an AuthenticationException
      if (error.error is AuthenticationException) return true;
      // Also check the response status code directly
      if (error.response?.statusCode == 401) return true;
    }
    return false;
  }

  /// Last-chance token refresh attempt for background validation.
  ///
  /// PROD-2095: delegates to [RefreshCoordinator] so this path shares the
  /// same single-flight discipline as the reactive (401) and proactive
  /// (scheduler) refresh paths. Previously this method had its own bare
  /// Dio + refresh logic that could race with the interceptor on the
  /// same refresh token.
  ///
  /// The coordinator already writes the rotated tokens to [StorageService]
  /// on success, so callers double-saving is a no-op. Callers may still
  /// want to call `_tokenSchedulerService.scheduleRefresh(...)` against
  /// the new expiry.
  ///
  /// Returns the [RefreshResponse] on success, or `null` on invalid /
  /// transient / unexpected failure (the breadcrumb chain from the
  /// coordinator records why).
  /// PROD-2131 — returns the refresh response plus the coordinator's
  /// `mutexAcquiredImmediately` flag so callers can apply Decision 14 dedup
  /// (only the mutex holder logs Sentry session-loss events). When the
  /// coordinator throws or no `result` was obtained, `mutexAcquiredImmediately`
  /// is null — treat null as "be the holder, log".
  Future<
    ({
      RefreshResponse? response,
      bool? mutexAcquiredImmediately,
      LockRole? crossTabRole,
      RefreshInvalid? invalid,
    })
  >
  _attemptTokenRefresh() async {
    try {
      // PROD-2095 AC #2 — manual callers (bg-validation fallback,
      // Instagram pre-nav) have no triggering request id; their fingerprint
      // breadcrumb is the current pre-refresh state.
      final fpBefore = await _refreshCoordinator
          .currentRefreshTokenFingerprint();
      final result = await _refreshCoordinator.getRefreshedAccessToken(
        reason: 'manual',
      );
      _diagnostics.logRefreshStart(
        requestId: null,
        refreshTokenFingerprint: fpBefore,
        reason: 'manual',
        mutexAcquiredImmediately: result.mutexAcquiredImmediately,
      );
      if (result.outcome case RefreshSuccess(:final response)) {
        _diagnostics.logRefreshResult(
          requestId: null,
          status: 'success',
          durationMs: result.duration.inMilliseconds,
          newRefreshTokenFingerprint: refreshTokenFingerprint(
            response.refreshToken,
          ),
        );
        return (
          response: response,
          mutexAcquiredImmediately: result.mutexAcquiredImmediately,
          crossTabRole: result.crossTabRole,
          invalid: null,
        );
      }
      _diagnostics.logRefreshResult(
        requestId: null,
        status: result.outcome is RefreshInvalid ? 'invalid' : 'transient',
        durationMs: result.duration.inMilliseconds,
      );
      _diagnostics.addBreadcrumb(
        'bg_refresh_non_success',
        data: {
          'outcome': result.outcome.runtimeType.toString(),
          'mutex_acquired_immediately': result.mutexAcquiredImmediately,
        },
      );
      return (
        response: null,
        mutexAcquiredImmediately: result.mutexAcquiredImmediately,
        crossTabRole: result.crossTabRole,
        invalid: result.outcome is RefreshInvalid
            ? result.outcome as RefreshInvalid
            : null,
      );
    } catch (e) {
      _diagnostics.addBreadcrumb(
        'bg_refresh_error',
        data: {'error_type': '${e.runtimeType}'},
      );
      return (
        response: null,
        mutexAcquiredImmediately: null,
        crossTabRole: null,
        invalid: null,
      );
    }
  }

  /// Proactively refresh the access token to ensure it's fresh.
  /// Used before operations that navigate away from the app (e.g., Instagram OAuth
  /// on web, which causes a full page reload and may lose the session if the token
  /// expires while the user is on the external site).
  /// Best-effort: if refresh fails, proceeds silently with the current token.
  Future<void> ensureFreshToken() async {
    if (state.accessToken == null) return;

    try {
      print(
        '[AuthNotifier] Proactively refreshing token before external navigation...',
      );
      final refreshResult = await _attemptTokenRefresh();
      final refreshResponse = refreshResult.response;
      if (refreshResponse != null) {
        await _storageService.saveAccessToken(
          refreshResponse.accessToken,
          expiresAt: refreshResponse.expiresAt,
        );
        if (refreshResponse.refreshToken != null) {
          await _storageService.saveRefreshToken(refreshResponse.refreshToken!);
        }
        state = state.copyWith(
          accessToken: refreshResponse.accessToken,
          tokenExpiresAt: refreshResponse.expiresAt,
        );
        if (refreshResponse.expiresAt != null) {
          _tokenSchedulerService.scheduleRefresh(refreshResponse.expiresAt!);
        }
        print('[AuthNotifier] Proactive refresh succeeded — token is fresh');
      }
    } catch (e) {
      print(
        '[AuthNotifier] Proactive refresh failed (proceeding with current token): $e',
      );
    }
  }

  /// Refresh user profile from API
  Future<void> refreshUserProfile() async {
    if (state.accessToken == null) return;

    try {
      final user = await _authApi.getMe();
      state = state.copyWith(user: user);
      // Update cached profile
      await _storageService.saveCachedUserProfile(user);
    } catch (e) {
      if (_isAuthenticationError(e)) {
        // Token expired during session
        await _storageService.deleteAccessToken();
        await _storageService.clearCachedUserProfile();
        state = state.copyWith(clearUser: true, clearToken: true);
      }
      // Network or other error - keep current state
    }
  }

  /// Start phone login (sends OTP).
  ///
  /// Returns the typed [PhoneStartResponse] so callers can branch on
  /// `status` (`sent` / `region_unsupported` / `channel_unavailable`) and
  /// read `smsFallbackAvailable` to enable the OTP-screen SMS retry
  /// button (PROD-2632). Returns null on real transport failures
  /// (rate-limit / network / 5xx) — those still populate `state.error`.
  Future<PhoneStartResponse?> startPhoneLogin(
    String phone, {
    String channel = 'sms',
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Android SMS Retriever hash (PROD-3323) — null off Android, so the SMS
      // is unchanged everywhere else. Threaded here so resend + SMS-fallback
      // paths (which all funnel through this method) inherit it automatically.
      final appHash = await SmsRetrieverService().getAppSignature();
      final response = await _authApi.startPhoneLogin(
        phone,
        channel: channel,
        appHash: appHash,
      );
      // Save pending phone verification to localStorage (survives tab kill on web)
      await _storageService.savePendingPhoneVerification(phone);
      state = state.copyWith(isLoading: false, pendingPhoneVerification: phone);
      return response;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return null;
    } on DioException catch (e, stackTrace) {
      // PROD-2979: the ErrorInterceptor rejects with the typed exception
      // INSIDE `DioException.error`, so the `on RateLimitException` above
      // never matched in production and the screen rendered
      // `e.toString()` — "DioException [bad response]: null / Error:
      // ValidationException: Invalid phone number". Unwrap and branch.
      final inner = unwrapApiError(e);
      if (inner is RateLimitException) {
        state = state.copyWith(
          isLoading: false,
          error:
              'Too many attempts. Please wait ${inner.retryAfterSeconds} seconds.',
        );
        return null;
      }
      if (inner is ValidationException) {
        // 400/422 from `POST /auth/phone/start` — the backend refused the
        // number itself (not a transport problem), so no health probe.
        state = state.copyWith(
          isLoading: false,
          errorCode: AuthErrorCode.invalidPhone,
        );
        return null;
      }
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(
        isLoading: false,
        errorCode: AuthErrorCode.loginFailed,
      );
      return null;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — every generic login catch runs the health
      // probe + captures the exception. Without this, Diana-class wedges
      // (instant "Login failed", no Sentry event) stay invisible.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(
        isLoading: false,
        errorCode: AuthErrorCode.loginFailed,
      );
      return null;
    }
  }

  /// Verify OTP and complete login
  /// PROD-4040 T2.4: the backend's echoed `business_return_to` from the most
  /// recent phone/email verify. The OTP screen honors it post-login (navigate
  /// back to the portal). Null for ordinary logins.
  String? pendingBusinessReturnTo;

  Future<bool> verifyOtp(
    String phone,
    String code, {
    String? returnTo,
    String? claimIntent,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Get attribution data for tracking
      final attribution = await _attributionService.getStoredAttribution();
      final response = await _authApi.verifyOtp(
        phone,
        code,
        attribution: attribution,
        returnTo: returnTo,
        claimIntent: claimIntent,
      );
      // T2.4: stash the backend-validated business return for the screen.
      pendingBusinessReturnTo = response.businessReturnTo;

      // Parse user from response
      final user = UserProfile.fromJson(response.user);
      final token = response.accessToken;
      final tokenExpiresAt = response.expiresAt;

      // Persist the token with expiry and clear pending phone verification
      await _storageService.saveAccessToken(token, expiresAt: tokenExpiresAt);
      if (response.refreshToken != null) {
        await _storageService.saveRefreshToken(response.refreshToken!);
        await _diagnostics.setRefreshTokenFingerprint(response.refreshToken);
      }
      await _storageService.setHasEverLoggedIn();
      await _storageService.clearPendingPhoneVerification();
      await _storageService.saveLoginMetadata('phone');
      // Cache user profile for instant display on refresh
      await _storageService.saveCachedUserProfile(user);

      // Resolve preferences BEFORE flipping isAuthenticated so the router's
      // logged-in branch sees a non-null `needsSokoIntro` on first redirect.
      // Without this, isAuth=true && needsSokoIntro=null falls through to
      // /home and the user briefly sees discovery before the Siga gate
      // re-fires. The interceptor reads the token from storage (saved
      // above), so this works pre-state-flip.
      await _recordLegalAcceptance();
      await _loadPreferences();
      // PROD-2305 — migrate any pre-auth guest location-consent answer to
      // the backend BEFORE `isGuest: false`, so the router's Siga gate
      // sees the migrated state. Fail-soft: PATCH errors leave the local
      // key for retry.
      await _onMigrateGuestLocationConsent?.call();

      state = state.copyWith(
        isLoading: false,
        user: user,
        accessToken: token,
        tokenExpiresAt: tokenExpiresAt,
        clearPendingPhone: true,
        // PROD-1979 — bootstrap-mint leaves `isGuest=true` on the state.
        // The real-user OTP token must reset it so `isAuthenticated` flips
        // true and the router guard stops redirecting to /login.
        isGuest: false,
      );

      // Schedule proactive token refresh
      if (tokenExpiresAt != null) {
        _tokenSchedulerService.scheduleRefresh(tokenExpiresAt);
      }

      // Track login / signup — PROD-2137: a phone OTP that just created the
      // account fires sign_up (→ Meta fb_mobile_complete_registration), not login.
      await _analytics.setUserId(user.id);
      if (response.isNewUser) {
        await _analytics.trackSignUp(method: 'phone');
      } else {
        await _analytics.trackLogin(method: 'phone');
      }
      await _handleIdentityChanged(user, phoneOverride: phone);

      // Clear stored attribution after successful login
      await _attributionService.clearStoredAttribution();

      return true;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return false;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — see startPhoneLogin probe comment.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  /// Start a passwordless email-OTP login (PROD-3595) — the email fallback
  /// rung of the phone-login channel ladder. Sends a one-time code to [email].
  /// Returns the generic [EmailLoginStartResponse] (`status: "sent"`) on
  /// success, or null on a real transport failure (rate-limit / network / 5xx),
  /// which also populates `state.error`.
  Future<EmailLoginStartResponse?> startEmailLogin(String email) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final response = await _authApi.startEmailLogin(email);
      state = state.copyWith(isLoading: false);
      return response;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return null;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — see startPhoneLogin probe comment.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(isLoading: false, error: e.toString());
      return null;
    }
  }

  /// Verify an email-OTP code and complete login (PROD-3595). On success the
  /// backend finds-or-creates the user by email, so this handles both login
  /// and first-time signup — mirrors [verifyOtp].
  Future<bool> verifyEmailLogin(
    String email,
    String code, {
    String? returnTo,
    String? claimIntent,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final attribution = await _attributionService.getStoredAttribution();
      final response = await _authApi.verifyEmailLogin(
        email,
        code,
        attribution: attribution,
        returnTo: returnTo,
        claimIntent: claimIntent,
      );
      // T2.4: stash the backend-validated business return for the screen.
      pendingBusinessReturnTo = response.businessReturnTo;

      final user = UserProfile.fromJson(response.user);
      final token = response.accessToken;
      final tokenExpiresAt = response.expiresAt;

      await _storageService.saveAccessToken(token, expiresAt: tokenExpiresAt);
      if (response.refreshToken != null) {
        await _storageService.saveRefreshToken(response.refreshToken!);
        await _diagnostics.setRefreshTokenFingerprint(response.refreshToken);
      }
      await _storageService.setHasEverLoggedIn();
      await _storageService.saveLoginMetadata('email');
      await _storageService.saveCachedUserProfile(user);

      // Resolve preferences BEFORE flipping isAuthenticated so the router's
      // Siga gate sees a non-null `needsSokoIntro` on first redirect (see the
      // verifyOtp note for the discovery-flash this prevents).
      await _recordLegalAcceptance();
      await _loadPreferences();
      await _onMigrateGuestLocationConsent?.call();

      state = state.copyWith(
        isLoading: false,
        user: user,
        accessToken: token,
        tokenExpiresAt: tokenExpiresAt,
        // PROD-1979 — reset the bootstrap-mint guest flag so isAuthenticated
        // flips true and the router stops redirecting to /login.
        isGuest: false,
      );

      if (tokenExpiresAt != null) {
        _tokenSchedulerService.scheduleRefresh(tokenExpiresAt);
      }

      // A passwordless email verify that just created the account fires
      // sign_up (→ Meta complete_registration), not login — same as phone.
      await _analytics.setUserId(user.id);
      if (response.isNewUser) {
        await _analytics.trackSignUp(method: 'email');
      } else {
        await _analytics.trackLogin(method: 'email');
      }
      await _handleIdentityChanged(user, emailOverride: email);

      await _attributionService.clearStoredAttribution();

      return true;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many attempts. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return false;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — see startPhoneLogin probe comment.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  /// Logout
  Future<void> logout() async {
    // Cancel any scheduled token refresh
    _tokenSchedulerService.cancelRefresh();

    // Track logout before clearing state (Firebase + Backend)
    await _analytics.trackLogout();
    await _klaviyo.resetProfile();

    try {
      await _authApi.logout();
    } catch (e) {
      // Ignore logout errors, we'll clear local state anyway
    }

    await _storageService.deleteAccessToken();
    await _storageService.deleteRefreshToken();
    await _diagnostics.setRefreshTokenFingerprint(null);
    await _storageService.clearLoginMetadata();
    // Clear active session and cached user so next login starts fresh
    await _storageService.clearActiveSessionId();
    await _storageService.clearCachedUserProfile();
    await _storageService.clearUserLists();
    await _storageService.clearDiscoverSections();
    // Clear stale OAuth return URL from previous session
    await _storageService.clearOAuthReturnUrl();
    // Clear any pending Business Connect return/claim so an in-flight portal
    // OAuth doesn't route the next account after login (PROD-4040).
    await _storageService.clearBusinessConnectReturnPath();
    await _storageService.clearPendingVenueClaimVenueId();
    // Clear active import job to prevent cross-account state bleed
    await _storageService.clearActiveImportJob();
    // Clear cookies to prevent stale refresh tokens across accounts
    await _clearCookies();
    // Reset feature flags so they re-evaluate for the next user
    _onIdentityCleared?.call();
    state = AuthState(isInitialized: true);
    // PROD-1979 — keep the app in the "always tokenized" invariant by
    // immediately minting a fresh guest session. Optional-auth surfaces
    // (discovery feeds, public detail) keep working without waiting for
    // the next 401-driven re-mint.
    await _mintGuestSession();
  }

  /// Force logout without calling API (for when token is already invalid/expired)
  Future<void> forceLogout() async {
    print('[AuthNotifier] Force logout - session expired');
    // Cancel any scheduled token refresh
    _tokenSchedulerService.cancelRefresh();
    _analytics.trackSessionExpired();
    await _analytics.setUserId(null);
    await _klaviyo.resetProfile();
    await _storageService.deleteAccessToken();
    await _storageService.deleteRefreshToken();
    await _diagnostics.setRefreshTokenFingerprint(null);
    await _storageService.clearLoginMetadata();
    // Clear active session and cached user so next login starts fresh
    await _storageService.clearActiveSessionId();
    await _storageService.clearCachedUserProfile();
    await _storageService.clearUserLists();
    await _storageService.clearDiscoverSections();
    // Clear stale OAuth return URL from previous session
    await _storageService.clearOAuthReturnUrl();
    // Clear any pending Business Connect return/claim so an in-flight portal
    // OAuth doesn't route the next account after login (PROD-4040).
    await _storageService.clearBusinessConnectReturnPath();
    await _storageService.clearPendingVenueClaimVenueId();
    // Clear active import job to prevent cross-account state bleed
    await _storageService.clearActiveImportJob();
    // Clear cookies to prevent stale refresh tokens across accounts
    await _clearCookies();
    // Reset feature flags so they re-evaluate for the next user
    _onIdentityCleared?.call();
    state = AuthState(isInitialized: true);
    // PROD-1979 — same "always tokenized" invariant as logout above.
    await _mintGuestSession();
  }

  /// Clear all cookies from the cookie jar (for logout)
  Future<void> _clearCookies() async {
    final jar = _cookieJar;
    if (jar == null) return;
    try {
      await jar.deleteAll();
    } catch (e) {
      print('[AuthNotifier] Failed to clear cookies: $e');
    }
  }

  /// Clear error
  void clearError() {
    state = state.copyWith(error: null);
  }

  // ========== Email/Password Authentication ==========

  /// Register with email and password
  Future<bool> register({
    required String email,
    required String password,
    String? fullName,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Get attribution data for tracking
      final attribution = await _attributionService.getStoredAttribution();
      final response = await _authApi.register(
        email: email,
        password: password,
        fullName: fullName,
        attribution: attribution,
      );

      // Store token with expiry - account is created but needs activation
      final user = UserProfile.fromJson(response.user);
      final tokenExpiresAt = response.expiresAt;
      await _storageService.saveAccessToken(
        response.accessToken,
        expiresAt: tokenExpiresAt,
      );
      if (response.refreshToken != null) {
        await _storageService.saveRefreshToken(response.refreshToken!);
        await _diagnostics.setRefreshTokenFingerprint(response.refreshToken);
      }
      // PROD-2073: do NOT setHasEverLoggedIn here — register is pre-activation.
      // Doing so makes main.dart's soko-intro migration mark the welcome as
      // "seen" on the next restart. Set the flag on actual sign-in paths.
      await _storageService.saveLoginMetadata('email');
      // Cache user profile for instant display on refresh
      await _storageService.saveCachedUserProfile(user);

      // PROD-2305 — migrate guest location consent before state flip.
      // No `_loadPreferences()` here (register is pre-activation, see
      // PROD-2073 note above), but the migration helper does not depend
      // on the loaded state — it idempotently PATCHes the backend with
      // the local consent and clears the local key on 2xx.
      await _onMigrateGuestLocationConsent?.call();

      state = state.copyWith(
        isLoading: false,
        user: user,
        accessToken: response.accessToken,
        tokenExpiresAt: tokenExpiresAt,
        pendingActivationEmail: email,
        // PROD-1979 — see note on verifyOtp; resets the bootstrap-mint
        // guest flag once the real-user signup token arrives.
        isGuest: false,
      );

      // Schedule proactive token refresh
      if (tokenExpiresAt != null) {
        _tokenSchedulerService.scheduleRefresh(tokenExpiresAt);
      }

      await _recordLegalAcceptance();

      // Track signup success
      await _analytics.setUserId(user.id);
      await _analytics.trackSignUp(method: 'email');
      await _handleIdentityChanged(user, emailOverride: email);

      // Clear stored attribution after successful signup
      await _attributionService.clearStoredAttribution();

      return true;
    } on DioException catch (e, stackTrace) {
      // Extract typed exception from DioException.error (set by ErrorInterceptor)
      final innerError = e.error;

      // PROD-2095 Decision 3 — Diana's failure is `DioException [connection
      // timeout]` wrapping `NetworkException`. The typed branches below
      // (EmailExists, WeakPassword, etc.) are expected user-facing errors;
      // only Network / GatewayTimeout inners deserve the probe + capture.
      if (innerError is NetworkException ||
          innerError is GatewayTimeoutException) {
        await _diagnostics.runHealthProbe(
          loginError: e,
          stackTrace: stackTrace,
          resolvedBaseUrl: EnvironmentConfig.baseUrl,
        );
      }

      if (innerError is EmailExistsException) {
        state = state.copyWith(
          isLoading: false,
          error: 'This email is already registered. Try logging in instead.',
        );
        return false;
      }

      if (innerError is WeakPasswordException) {
        state = state.copyWith(isLoading: false, error: innerError.message);
        return false;
      }

      if (innerError is ValidationException) {
        state = state.copyWith(isLoading: false, error: innerError.message);
        return false;
      }

      if (innerError is RateLimitException) {
        state = state.copyWith(
          isLoading: false,
          error:
              'Too many attempts. Please wait ${innerError.retryAfterSeconds} seconds.',
        );
        return false;
      }

      // Fallback for other DioExceptions
      state = state.copyWith(
        isLoading: false,
        error: 'Registration failed. Please try again.',
      );
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — generic catch always runs the probe.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(
        isLoading: false,
        error: 'Registration failed. Please try again.',
      );
      return false;
    }
  }

  /// Login with email and password
  Future<bool> loginWithEmail({
    required String email,
    required String password,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Get attribution data for tracking
      final attribution = await _attributionService.getStoredAttribution();
      final response = await _authApi.loginWithEmail(
        email: email,
        password: password,
        attribution: attribution,
      );

      final user = UserProfile.fromJson(response.user);
      final tokenExpiresAt = response.expiresAt;
      await _storageService.saveAccessToken(
        response.accessToken,
        expiresAt: tokenExpiresAt,
      );
      if (response.refreshToken != null) {
        await _storageService.saveRefreshToken(response.refreshToken!);
        await _diagnostics.setRefreshTokenFingerprint(response.refreshToken);
      }
      await _storageService.setHasEverLoggedIn();
      await _storageService.saveLoginMetadata('email');
      // Cache user profile for instant display on refresh
      await _storageService.saveCachedUserProfile(user);

      // Resolve preferences BEFORE flipping isAuthenticated — see verifyOtp.
      await _recordLegalAcceptance();
      await _loadPreferences();
      // PROD-2305 — migrate guest location consent before state flip,
      // see verifyOtp comment.
      await _onMigrateGuestLocationConsent?.call();

      state = state.copyWith(
        isLoading: false,
        user: user,
        accessToken: response.accessToken,
        tokenExpiresAt: tokenExpiresAt,
        clearPendingEmail: true,
        // PROD-1979 — see note on verifyOtp; resets the bootstrap-mint
        // guest flag once the real-user email-login token arrives.
        isGuest: false,
      );

      // Schedule proactive token refresh
      if (tokenExpiresAt != null) {
        _tokenSchedulerService.scheduleRefresh(tokenExpiresAt);
      }

      // Track email login success
      await _analytics.setUserId(user.id);
      await _analytics.trackLogin(method: 'email');
      await _handleIdentityChanged(user, emailOverride: email);

      // Clear stored attribution after successful login
      await _attributionService.clearStoredAttribution();

      return true;
    } on DioException catch (e, stackTrace) {
      // Extract typed exception from DioException.error (set by ErrorInterceptor)
      final innerError = e.error;

      // PROD-2095 Decision 3 — Diana's failure path. ErrorInterceptor
      // wraps connection timeouts as NetworkException inside DioException.
      if (innerError is NetworkException ||
          innerError is GatewayTimeoutException) {
        await _diagnostics.runHealthProbe(
          loginError: e,
          stackTrace: stackTrace,
          resolvedBaseUrl: EnvironmentConfig.baseUrl,
        );
      }

      if (innerError is AccountNotActivatedException) {
        state = state.copyWith(
          isLoading: false,
          error: 'Account not activated. Please check your email.',
          pendingActivationEmail: email,
        );
        return false;
      }

      if (innerError is AuthenticationException) {
        // Generic error for security (don't reveal if email exists)
        state = state.copyWith(
          isLoading: false,
          error: 'Invalid email or password',
        );
        return false;
      }

      if (innerError is RateLimitException) {
        state = state.copyWith(
          isLoading: false,
          error:
              'Too many attempts. Please wait ${innerError.retryAfterSeconds} seconds.',
        );
        return false;
      }

      // Fallback for other DioExceptions
      state = state.copyWith(
        isLoading: false,
        error: 'Login failed. Please try again.',
      );
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — generic catch always runs the probe.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      debugPrint('[AuthNotifier] loginWithEmail failed: $e');
      debugPrint('[AuthNotifier] stackTrace: $stackTrace');
      state = state.copyWith(
        isLoading: false,
        error: 'Login failed. Please try again.',
      );
      return false;
    }
  }

  /// Activate account via token (from deep link)
  Future<bool> activateAccount(String token) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await _authApi.activateAccount(token);
      state = state.copyWith(isLoading: false, clearPendingEmail: true);
      // Mirrors the per-login _loadPreferences() calls so the router's
      // needsSokoIntroProvider transitions null → true in the same
      // session as activation. Without this, a freshly-activated user
      // lands on /home and only sees Siga on the next cold start.
      await _loadPreferences();
      return true;
    } on InvalidTokenException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — generic catch always runs the probe.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(
        isLoading: false,
        error: 'Activation failed. The link may be invalid or expired.',
      );
      return false;
    }
  }

  /// Resend activation email
  Future<bool> resendActivation(String email) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await _authApi.resendActivation(email);
      state = state.copyWith(isLoading: false);
      return true;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many requests. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — Diagnostically capture in Sentry but
      // keep the user-facing "success for security" behavior (backend
      // also returns 200 regardless of whether the email exists).
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      // Always show success for security (backend also returns 200)
      state = state.copyWith(isLoading: false);
      return true;
    }
  }

  /// Request password reset email
  Future<bool> forgotPassword(String email) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Pass origin so backend can generate correct reset URLs
      // On web, use the current page origin; on mobile, use the custom URL scheme
      final origin = kIsWeb ? Uri.base.origin : 'heyl://';
      await _authApi.forgotPassword(email, origin: origin);
      state = state.copyWith(isLoading: false);
      return true;
    } on RateLimitException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Too many requests. Please wait ${e.retryAfterSeconds} seconds.',
      );
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — capture diagnostically but keep
      // "success for security" behavior.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      // Always show success for security (don't reveal if email exists)
      state = state.copyWith(isLoading: false);
      return true;
    }
  }

  /// Reset password with token
  Future<bool> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await _authApi.resetPassword(token: token, newPassword: newPassword);
      state = state.copyWith(isLoading: false);
      return true;
    } on InvalidTokenException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } on WeakPasswordException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } on ValidationException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — generic catch always runs the probe.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(
        isLoading: false,
        error: 'Password reset failed. The link may be invalid or expired.',
      );
      return false;
    }
  }

  /// Clear pending activation email
  void clearPendingActivation() {
    state = state.copyWith(clearPendingEmail: true);
  }

  /// Clear pending phone verification (when user cancels OTP flow)
  Future<void> clearPendingPhoneVerification() async {
    await _storageService.clearPendingPhoneVerification();
    state = state.copyWith(clearPendingPhone: true);
  }

  /// Start Google login flow
  /// On web: redirects in same tab, callback handled by router
  /// On mobile: uses native Google Sign-In SDK for account picker
  Future<bool> startGoogleLogin({String? returnUrl}) async {
    if (kIsWeb) {
      return _startGoogleLoginWebRedirect(returnUrl: returnUrl);
    } else {
      return _startGoogleLoginNative();
    }
  }

  /// Native Google Sign-In (iOS/Android)
  /// Uses the google_sign_in package to show the native OS account picker,
  /// which has access to all Google accounts configured on the device.
  Future<bool> _startGoogleLoginNative() async {
    state = state.copyWith(isLoading: true, error: null);

    // Clear any existing token before starting OAuth flow
    await _storageService.deleteAccessToken();
    state = state.copyWith(clearToken: true);

    try {
      final serverClientId = EnvironmentConfig.googleServerClientId;

      final googleSignIn = GoogleSignIn(
        serverClientId: serverClientId.isNotEmpty ? serverClientId : null,
      );

      // PROD-2278 — force the native account picker. On Android, google_sign_in
      // v6 silently reuses the last-authorized account if one is cached, so the
      // user never gets to choose. signOut() clears the local sign-in state
      // (without revoking granted scopes) so the next signIn() always shows the
      // picker, matching iOS/web. Best-effort: a failure here must not block login.
      try {
        await googleSignIn.signOut();
      } catch (_) {
        // ignore — proceed to signIn() regardless
      }

      final account = await googleSignIn.signIn();
      if (account == null) {
        // User cancelled the picker
        state = state.copyWith(isLoading: false);
        return false;
      }

      final authentication = await account.authentication;
      final idToken = authentication.idToken;

      if (idToken == null || idToken.isEmpty) {
        state = state.copyWith(
          isLoading: false,
          error: 'No ID token received from Google',
        );
        return false;
      }

      // Get attribution data for tracking
      final attribution = await _attributionService.getStoredAttribution();

      // Send the Google ID token to our backend for verification
      final response = await _authApi.loginWithGoogle(
        idToken: idToken,
        attribution: attribution,
      );

      final user = UserProfile.fromJson(response.user);
      final tokenExpiresAt = response.expiresAt;
      await _storageService.saveAccessToken(
        response.accessToken,
        expiresAt: tokenExpiresAt,
      );
      if (response.refreshToken != null) {
        await _storageService.saveRefreshToken(response.refreshToken!);
        await _diagnostics.setRefreshTokenFingerprint(response.refreshToken);
      }
      await _storageService.setHasEverLoggedIn();
      await _storageService.saveCachedUserProfile(user);
      await _storageService.saveLoginMetadata('google');

      // Resolve preferences BEFORE flipping isAuthenticated — see verifyOtp.
      await _recordLegalAcceptance();
      await _loadPreferences();
      // PROD-2305 — migrate guest location consent before state flip,
      // see verifyOtp comment.
      await _onMigrateGuestLocationConsent?.call();

      state = state.copyWith(
        isLoading: false,
        user: user,
        accessToken: response.accessToken,
        tokenExpiresAt: tokenExpiresAt,
        // PROD-1979 — defense-in-depth. The pre-login `clearToken: true`
        // above already resets the guest flag, but stating intent here
        // means a future refactor that drops the pre-clear doesn't
        // silently reintroduce the post-login redirect bug.
        isGuest: false,
      );

      // Schedule proactive token refresh
      if (tokenExpiresAt != null) {
        _tokenSchedulerService.scheduleRefresh(tokenExpiresAt);
      }

      // Track Google login / signup — PROD-2137: a first-time Google account
      // fires sign_up (→ Meta fb_mobile_complete_registration); linking Google
      // onto an existing email user stays a login (is_new_user=false).
      await _analytics.setUserId(user.id);
      if (response.isNewUser) {
        await _analytics.trackSignUp(method: 'google');
      } else {
        await _analytics.trackLogin(method: 'google');
      }
      await _handleIdentityChanged(user, emailOverride: account.email);

      // Clear stored attribution after successful login
      await _attributionService.clearStoredAttribution();

      return true;
    } on DioException catch (e, stackTrace) {
      // Backend error
      final innerError = e.error;
      // PROD-2095 Decision 3 — Network/GatewayTimeout inners are the
      // Diana-class shape; everything else is expected.
      if (innerError is NetworkException ||
          innerError is GatewayTimeoutException) {
        await _diagnostics.runHealthProbe(
          loginError: e,
          stackTrace: stackTrace,
          resolvedBaseUrl: EnvironmentConfig.baseUrl,
        );
      }
      if (innerError is AuthenticationException) {
        state = state.copyWith(
          isLoading: false,
          error: 'Authentication failed. Please try again.',
        );
        return false;
      }
      state = state.copyWith(
        isLoading: false,
        error: 'Login failed. Please try again.',
      );
      return false;
    } on PlatformException catch (e) {
      // Google Sign-In SDK error (e.g., network, config issue)
      state = state.copyWith(
        isLoading: false,
        error: 'Google Sign-In failed: ${e.message ?? e.code}',
      );
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — generic catch always runs the probe.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(
        isLoading: false,
        error: 'Google Sign-In failed: $e',
      );
      return false;
    }
  }

  /// Server-side OAuth2 redirect flow for web.
  /// Redirects in same tab to backend's /auth/google/login, which initiates
  /// the OAuth2 flow. The backend redirects back to /auth/callback with token.
  Future<bool> _startGoogleLoginWebRedirect({String? returnUrl}) async {
    // Ensure loading state (may already be set by caller)
    if (!state.isLoading) {
      state = state.copyWith(isLoading: true, error: null);
    }

    try {
      final origin = Uri.encodeComponent(Uri.base.origin);
      // PROD-2037: append the app's current locale as ?lang=<code>. The
      // AcceptLanguageInterceptor wired into Dio cannot reach this path
      // because launchUrl performs a full-page browser redirect — the
      // browser's own Accept-Language goes out, not the app's pick. The
      // backend's /auth/google/login handler should prefer this query
      // param over the header for the same reason.
      final lang = _getLocaleCode?.call();
      final langParam = (lang != null && lang.isNotEmpty)
          ? '&lang=${Uri.encodeComponent(lang)}'
          : '';
      // PROD-4040 T2.4: thread Business Connect return-state (return_to +
      // claim_intent + utm_*) so the backend validates it and echoes back a
      // signed business_return_to on the callback. Additive — empty for a
      // normal login.
      final businessParams = businessReturnStateQuery(returnTo: returnUrl);
      final googleLoginUrl = Uri.parse(
        '${EnvironmentConfig.baseUrl}${ApiConstants.authGoogleLogin}'
        '?origin=$origin$langParam$businessParams',
      );

      // Persist return URL before navigating away (in-memory state is lost)
      if (returnUrl != null) {
        await _storageService.saveOAuthReturnUrl(returnUrl);
      }

      // Redirect in same tab - user will return to /auth/callback?access_token=...
      await launchUrl(googleLoginUrl, webOnlyWindowName: '_self');

      // On web, the page navigates away, so we won't reach here
      return true;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — generic catch always runs the probe.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to start Google login: $e',
      );
      return false;
    }
  }

  /// Complete Google OAuth login with token from callback
  /// Called by router when OAuth callback is received
  Future<bool> completeGoogleLogin(String accessToken, {String? refreshToken}) {
    // A callback screen can remount while completing login (for example when
    // profile locale changes rebuild MaterialApp). Share in-flight work, then
    // treat a replay of the active session token as already completed. This
    // protects all login side effects, including the success analytics event.
    if (_googleCallbackToken == accessToken &&
        _googleCallbackCompletion != null) {
      return _googleCallbackCompletion!;
    }
    if (state.isAuthenticated &&
        state.user != null &&
        state.accessToken == accessToken) {
      return Future<bool>.value(true);
    }
    _googleCallbackToken = accessToken;
    late final Future<bool> completion;
    completion =
        Future<bool>.microtask(
          () => _completeGoogleLogin(accessToken, refreshToken: refreshToken),
        ).whenComplete(() {
          if (identical(_googleCallbackCompletion, completion)) {
            _googleCallbackToken = null;
            _googleCallbackCompletion = null;
          }
        });
    _googleCallbackCompletion = completion;
    return completion;
  }

  Future<bool> _completeGoogleLogin(
    String accessToken, {
    String? refreshToken,
  }) async {
    print('[AuthNotifier] completeGoogleLogin started');
    state = state.copyWith(isLoading: true, error: null);

    try {
      // PROD-2168 — read access-token expiry from the JWT itself. The
      // web OAuth callback URL only carries `access_token` (per OpenAPI
      // `/api/v1/auth/google/callback` — only `Location` query param +
      // HttpOnly Set-Cookie for refresh). Previously this path used a
      // hardcoded 15-min fallback that didn't match the BE's actual
      // 30-min default and meant proactive refresh fired ~15 min early
      // for the wrong reason. Decoding the JWT gets us the real expiry.
      final tokenExpiresAt =
          jwtExpiryAt(accessToken) ??
          DateTime.now().add(const Duration(minutes: 15));

      // Store the token (with expiry inline — single write, no double save).
      print('[AuthNotifier] Saving access token...');
      await _storageService.saveAccessToken(
        accessToken,
        expiresAt: tokenExpiresAt,
      );
      if (refreshToken != null) {
        await _storageService.saveRefreshToken(refreshToken);
        await _diagnostics.setRefreshTokenFingerprint(refreshToken);
      }
      await _storageService.setHasEverLoggedIn();
      print('[AuthNotifier] Token saved successfully');

      // Fetch user profile to validate token and get user info
      print('[AuthNotifier] Fetching user profile via getMe()...');
      final user = await _authApi.getMe();
      print('[AuthNotifier] User profile fetched: ${user.id}');

      // Cache user profile for instant display on refresh
      await _storageService.saveCachedUserProfile(user);
      await _storageService.saveLoginMetadata('google');

      _tokenSchedulerService.scheduleRefresh(tokenExpiresAt);
      _diagnostics.logProactiveRefreshScheduled(
        timeUntilRefresh: tokenExpiresAt.difference(DateTime.now()),
      );

      // Resolve preferences BEFORE flipping isAuthenticated — see verifyOtp.
      await _recordLegalAcceptance();
      await _loadPreferences();
      // PROD-2305 — migrate guest location consent before state flip,
      // see verifyOtp comment.
      await _onMigrateGuestLocationConsent?.call();

      state = state.copyWith(
        isLoading: false,
        accessToken: accessToken,
        tokenExpiresAt: tokenExpiresAt,
        user: user,
        // PROD-1979 — the web OAuth callback path arrives after the
        // bootstrap-mint already set `isGuest=true`. Reset it so the
        // router stops bouncing the just-signed-in user back to /login.
        isGuest: false,
      );

      // Track Google login success. PROD-2137: the web OAuth-callback path
      // only receives a bare token (no LoginResponse), so is_new_user isn't
      // available here — web stays login-only (Meta App Events is mobile-only).
      await _analytics.setUserId(user.id);
      await _analytics.trackLogin(method: 'google');
      await _handleIdentityChanged(user);

      print('[AuthNotifier] completeGoogleLogin completed successfully');
      return true;
    } on DioException catch (e, stackTrace) {
      // Network or API error
      print(
        '[AuthNotifier] DioException during Google login: ${e.type} - ${e.message}',
      );
      print(
        '[AuthNotifier] Response: ${e.response?.statusCode} - ${e.response?.data}',
      );
      await _storageService.deleteAccessToken();

      // PROD-2095 Decision 3 — connection timeout / network error is the
      // Diana-class shape (also raw DioExceptionType timeouts here).
      final innerError = e.error;
      final isNetworkLike =
          innerError is NetworkException ||
          innerError is GatewayTimeoutException ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError;
      if (isNetworkLike) {
        await _diagnostics.runHealthProbe(
          loginError: e,
          stackTrace: stackTrace,
          resolvedBaseUrl: EnvironmentConfig.baseUrl,
        );
      }

      String errorMessage;
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        errorMessage =
            'Connection timeout. Please check your network and try again.';
      } else if (e.response?.statusCode == 401) {
        errorMessage = 'Authentication failed. Please try logging in again.';
      } else if (e.type == DioExceptionType.connectionError) {
        errorMessage = 'Cannot connect to server. Please check your network.';
      } else {
        errorMessage = 'Login failed: ${e.message ?? 'Unknown error'}';
      }

      state = state.copyWith(
        isLoading: false,
        error: errorMessage,
        clearToken: true,
      );
      return false;
    } catch (e, stackTrace) {
      // Other errors — PROD-2095 Decision 3, run the probe.
      print('[AuthNotifier] Unexpected error during Google login: $e');
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      await _storageService.deleteAccessToken();
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to complete login: $e',
        clearToken: true,
      );
      return false;
    }
  }

  /// Handle OAuth error from callback
  void handleOAuthError(String error) {
    state = state.copyWith(
      isLoading: false,
      error: 'Google login failed: $error',
    );
  }

  /// Cancel OAuth flow (user returned without completing)
  void cancelOAuth() {
    if (state.isLoading) {
      print('[AuthNotifier] cancelOAuth: resetting stale isLoading state');
      state = state.copyWith(isLoading: false);
    }
  }

  /// Start Apple Sign-In flow
  /// Uses native Sign in with Apple on iOS/macOS only
  /// Web is not supported due to sign_in_with_apple package limitations
  Future<bool> startAppleLogin() async {
    // Apple Sign-In is only available on iOS and macOS (native platforms)
    // Web is not supported because sign_in_with_apple has JS interop issues
    if (kIsWeb) {
      state = state.copyWith(
        isLoading: false,
        error:
            'Apple Sign-In is not available on web. Please use Google or email login.',
      );
      return false;
    }

    if (!Platform.isIOS && !Platform.isMacOS) {
      state = state.copyWith(
        isLoading: false,
        error: 'Apple Sign-In is not available on this device',
      );
      return false;
    }

    state = state.copyWith(isLoading: true, error: null);

    // Clear any existing token before starting OAuth flow
    await _storageService.deleteAccessToken();
    state = state.copyWith(clearToken: true);

    try {
      // Generate nonce for security
      final rawNonce = _generateNonce();
      final nonce = sha256.convert(utf8.encode(rawNonce)).toString();

      // Request credentials from Apple
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: nonce,
      );

      // Get the identity token (JWT from Apple)
      final identityToken = credential.identityToken;
      if (identityToken == null) {
        state = state.copyWith(
          isLoading: false,
          error: 'No identity token received from Apple',
        );
        return false;
      }

      // Get attribution data for tracking
      final attribution = await _attributionService.getStoredAttribution();

      // Send the Apple credentials to our backend
      // The backend will verify the token with Apple and create/login the user
      final response = await _authApi.loginWithApple(
        identityToken: identityToken,
        authorizationCode: credential.authorizationCode,
        email: credential.email,
        fullName: credential.givenName != null || credential.familyName != null
            ? '${credential.givenName ?? ''} ${credential.familyName ?? ''}'
                  .trim()
            : null,
        nonce: rawNonce,
        attribution: attribution,
      );

      final user = UserProfile.fromJson(response.user);
      final tokenExpiresAt = response.expiresAt;
      await _storageService.saveAccessToken(
        response.accessToken,
        expiresAt: tokenExpiresAt,
      );
      if (response.refreshToken != null) {
        await _storageService.saveRefreshToken(response.refreshToken!);
        await _diagnostics.setRefreshTokenFingerprint(response.refreshToken);
      }
      await _storageService.setHasEverLoggedIn();
      await _storageService.saveCachedUserProfile(user);
      await _storageService.saveLoginMetadata('apple');

      // Resolve preferences BEFORE flipping isAuthenticated — see verifyOtp.
      await _recordLegalAcceptance();
      await _loadPreferences();
      // PROD-2305 — migrate guest location consent before state flip,
      // see verifyOtp comment.
      await _onMigrateGuestLocationConsent?.call();

      state = state.copyWith(
        isLoading: false,
        user: user,
        accessToken: response.accessToken,
        tokenExpiresAt: tokenExpiresAt,
        isGuest: false,
      );

      // Schedule proactive token refresh
      if (tokenExpiresAt != null) {
        _tokenSchedulerService.scheduleRefresh(tokenExpiresAt);
      }

      // Track Apple login / signup — PROD-2137: a first-time Apple account
      // fires sign_up (→ Meta fb_mobile_complete_registration); linking Apple
      // onto an existing email user stays a login (is_new_user=false).
      await _analytics.setUserId(user.id);
      if (response.isNewUser) {
        await _analytics.trackSignUp(method: 'apple');
      } else {
        await _analytics.trackLogin(method: 'apple');
      }
      await _handleIdentityChanged(user, emailOverride: credential.email);

      // Clear stored attribution after successful login
      await _attributionService.clearStoredAttribution();

      return true;
    } on SignInWithAppleAuthorizationException catch (e) {
      // User cancelled or other Apple Sign-In error
      if (e.code == AuthorizationErrorCode.canceled) {
        state = state.copyWith(isLoading: false);
        return false;
      }
      state = state.copyWith(
        isLoading: false,
        error: 'Apple Sign-In failed: ${e.message}',
      );
      return false;
    } on DioException catch (e, stackTrace) {
      // Backend error
      final innerError = e.error;
      // PROD-2095 Decision 3 — Diana-class probe.
      if (innerError is NetworkException ||
          innerError is GatewayTimeoutException) {
        await _diagnostics.runHealthProbe(
          loginError: e,
          stackTrace: stackTrace,
          resolvedBaseUrl: EnvironmentConfig.baseUrl,
        );
      }
      if (innerError is AuthenticationException) {
        state = state.copyWith(
          isLoading: false,
          error: 'Authentication failed. Please try again.',
        );
        return false;
      }
      state = state.copyWith(
        isLoading: false,
        error: 'Login failed. Please try again.',
      );
      return false;
    } catch (e, stackTrace) {
      // PROD-2095 Decision 3 — generic catch always runs the probe.
      await _diagnostics.runHealthProbe(
        loginError: e,
        stackTrace: stackTrace,
        resolvedBaseUrl: EnvironmentConfig.baseUrl,
      );
      state = state.copyWith(
        isLoading: false,
        error: 'Apple Sign-In failed: $e',
      );
      return false;
    }
  }

  /// Generate a random nonce for Apple Sign-In
  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => charset[random.nextInt(charset.length)],
    ).join();
  }
}

/// Provider for auth state
final StateNotifierProvider<AuthNotifier, AuthState>
authStateProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final authApi = ref.watch(authApiProvider);
  final preferencesApi = ref.watch(preferencesApiProvider);
  final eulaApi = ref.watch(eulaApiProvider);
  final storageService = ref.watch(storageServiceProvider);
  final analytics = ref.watch(unifiedAnalyticsProvider);
  final tokenSchedulerService = ref.watch(tokenSchedulerServiceProvider);
  final attributionService = ref.watch(attributionServiceProvider);
  final diagnostics = ref.watch(authDiagnosticsProvider);
  final refreshCoordinator = ref.watch(refreshCoordinatorProvider);
  final klaviyo = ref.watch(klaviyoServiceProvider);
  final cookieJar = ref.watch(cookieJarProvider).valueOrNull;
  final experimentNotifier = ref.read(experimentServiceProvider.notifier);
  return AuthNotifier(
    authApi,
    preferencesApi,
    eulaApi,
    storageService,
    analytics,
    tokenSchedulerService,
    attributionService,
    diagnostics,
    refreshCoordinator,
    klaviyo,
    cookieJar,
    // PROD-2305 follow-up — extends PR #711's wrap pattern to the other
    // two unprotected post-auth callbacks. Codex-verified call path
    // (consult session 019e7d55): `completeGoogleLogin` → unwrapped
    // `_handleIdentityChanged` → `onIdentityChanged` / `onPushRegistrationNeeded`.
    // The latter does raw `ref.read(needsSokoIntroProvider)` which sits at
    // a suspected back-edge: `needsSokoIntroProvider` watches
    // `accountProvider`, whose build registers `ref.listen` on
    // `authStateProvider` — readable as a cycle when triggered during
    // an in-flight auth-state notification. Wrapping at the closure level
    // mirrors `onMigrateGuestLocationConsent` below so login can't break
    // on a Riverpod cycle here either. Identity-change side-effects
    // (experiment flag reload, klaviyo identify, push registration
    // trigger) are non-critical to sign-in completion. The debugPrints
    // surface the real cycle on next failure for a proper structural fix.
    onIdentityChanged: () async {
      try {
        await experimentNotifier.reloadFlags();
      } catch (e, st) {
        debugPrint(
          '[AuthNotifier] experiment flags reload failed (login continues): $e\n$st',
        );
      }
    },
    onIdentityCleared: () {
      experimentNotifier.resetFlags();
      // Reset the persisted "Continue as guest" choice so the next
      // navigation bounces the user back to /login. Without this, a
      // signed-out user with `explicit_guest_mode=true` from a prior
      // session would silently fall through into the guest UI.
      unawaited(setExplicitGuestMode(ref, value: false));
    },
    onPushRegistrationNeeded:
        (userId, {required shouldRegisterIfAuthorized}) async {
          try {
            final needsSokoIntro = ref.read(needsSokoIntroProvider);
            // Do not silently PATCH pn_optin before Siga. A false/null
            // gate means auth-change may refresh local push state, but
            // consent writes wait for SokoWelcomeScreen.requestAndRegister.
            await ref
                .read(pushPermissionServiceProvider.notifier)
                .onAuthChanged(
                  userId: userId,
                  shouldRegisterIfAuthorized:
                      shouldRegisterIfAuthorized || needsSokoIntro == false,
                );
          } catch (e, st) {
            debugPrint(
              '[AuthNotifier] push registration onAuthChanged failed (login continues): $e\n$st',
            );
          }
        },
    onPreferencesLoadNeeded: () =>
        ref.read(preferencesProvider.notifier).load(),
    // PROD-2305 — migrate any pre-auth guest location-consent answer
    // to the backend the moment a guest signs in. No-op when no
    // local answer exists; fail-soft on PATCH errors.
    //
    // The helper docstring promises "no exception thrown" but a
    // CircularDependencyError thrown by `ref.read` inside the helper
    // can still escape (seen on iOS Google sign-in after PROD-2305 +
    // step 7 landed). Wrapping the closure here enforces the
    // fail-soft contract at the call-site so login can never break
    // due to the migration call. The debugPrint surfaces the real
    // root cause + stack on next failure so we can fix the cycle
    // properly without users seeing it as a sign-in error.
    onMigrateGuestLocationConsent: () async {
      try {
        await migrateGuestLocationConsentIfNeeded(ref);
      } catch (e, st) {
        debugPrint(
          '[AuthNotifier] guest-location migration failed (login continues): $e\n$st',
        );
      }
    },
    // PROD-2037: late-bound locale lookup for the web Google OAuth
    // redirect URL. Same pattern as the api_provider callbacks — keeps
    // AuthNotifier free of a direct Riverpod dependency.
    getLocaleCode: () => ref.read(apiLocaleCodeProvider),
  );
});

/// Provider for checking if user is authenticated
final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(authStateProvider).isAuthenticated;
});

/// Provider for current user
final currentUserProvider = Provider<UserProfile?>((ref) {
  return ref.watch(authStateProvider).user;
});

/// Currently authenticated user-id, or null when no one is signed in.
///
/// Extracted as its own provider so identity-sensitive leaves (e.g.
/// [detectedCountryCodeProvider]) can subscribe to identity changes without
/// rebuilding on every other [AuthState] field churn, and so unit tests can
/// override the identity directly without standing up the full auth notifier.
final currentUserIdProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider.select((s) => s.user?.id));
});
