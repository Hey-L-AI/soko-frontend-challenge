import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'storage_service.dart';

/// PROD-2095 — first 12 hex chars of `sha256(rawToken)`.
///
/// This is a **SHA-256 HASH**, not a substring of the raw token. NEVER
/// "optimize" this into `rawToken.substring(0, 12)` — that would leak the
/// real credential. Must match the backend's `refresh_fp` byte-for-byte
/// (handoff §3) so FE Sentry events and BE `auth_diag` logs pair up.
///
/// Returns `'none'` when [rawToken] is null/empty so the Sentry tag is
/// never absent — makes "no refresh token in scope" queryable.
String refreshTokenFingerprint(String? rawToken) {
  if (rawToken == null || rawToken.isEmpty) return 'none';
  return sha256.convert(utf8.encode(rawToken)).toString().substring(0, 12);
}

/// Service for diagnostic logging of auth state transitions via Sentry.
///
/// Adds breadcrumbs at each auth state transition and fires a custom
/// `unexpected_session_loss` event when a previously-authenticated user
/// is forced to log out. No sensitive data (tokens, user IDs) is logged.
class AuthDiagnosticsService {
  final StorageService _storageService;

  /// Test injection point — overrides the Dio used for the health probe and
  /// the `Connectivity` instance. Real callers leave both null.
  final Dio Function()? _probeDioFactory;
  final Connectivity Function()? _connectivityFactory;

  AuthDiagnosticsService({
    required StorageService storageService,
    @visibleForTesting Dio Function()? probeDioFactory,
    @visibleForTesting Connectivity Function()? connectivityFactory,
  }) : _storageService = storageService,
       _probeDioFactory = probeDioFactory,
       _connectivityFactory = connectivityFactory;

  // ============ Breadcrumbs (auth state transitions) ============

  /// Token restored from secure storage on app startup
  void logTokenRestored({required bool hasExpiry, required bool isExpired}) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'Token restored from storage',
        category: 'auth',
        type: 'info',
        data: {
          'has_expiry': hasExpiry,
          'is_expired': isExpired,
          'platform': _platform,
        },
      ),
    );
  }

  /// Proactive refresh timer scheduled
  void logProactiveRefreshScheduled({required Duration timeUntilRefresh}) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'Proactive refresh scheduled',
        category: 'auth.refresh',
        type: 'info',
        data: {'refresh_in_seconds': timeUntilRefresh.inSeconds},
      ),
    );
  }

  /// Proactive refresh attempt started
  void logProactiveRefreshAttempt() {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'Proactive refresh attempt',
        category: 'auth.refresh',
        type: 'info',
      ),
    );
  }

  /// Proactive refresh completed
  void logProactiveRefreshResult({required bool success, String? errorType}) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: success
            ? 'Proactive refresh succeeded'
            : 'Proactive refresh failed',
        category: 'auth.refresh',
        type: 'info',
        level: success ? SentryLevel.info : SentryLevel.warning,
        data: {
          'success': success,
          if (errorType != null) 'error_type': errorType,
        },
      ),
    );
  }

  /// Reactive refresh triggered by 401 on an API call
  void logReactiveRefreshAttempt({required String triggeringEndpoint}) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'Reactive refresh attempt (401)',
        category: 'auth.refresh',
        type: 'info',
        data: {'triggering_endpoint': triggeringEndpoint},
      ),
    );
  }

  /// Reactive refresh completed
  void logReactiveRefreshResult({
    required bool success,
    String? errorCode,
    bool? wasRefreshable,
  }) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: success
            ? 'Reactive refresh succeeded'
            : 'Reactive refresh failed',
        category: 'auth.refresh',
        type: 'info',
        level: success ? SentryLevel.info : SentryLevel.warning,
        data: {
          'success': success,
          if (errorCode != null) 'error_code': errorCode,
          if (wasRefreshable != null) 'was_refreshable': wasRefreshable,
        },
      ),
    );
  }

  /// Background /auth/me validation result
  void logBackgroundValidationResult({
    required bool success,
    String? errorType,
  }) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: success
            ? 'Background validation succeeded'
            : 'Background validation failed',
        category: 'auth',
        type: 'info',
        level: success ? SentryLevel.info : SentryLevel.warning,
        data: {
          'success': success,
          if (errorType != null) 'error_type': errorType,
        },
      ),
    );
  }

  /// Generic breadcrumb for auth-related diagnostic events
  void addBreadcrumb(String message, {Map<String, dynamic>? data}) {
    Sentry.addBreadcrumb(
      Breadcrumb(message: message, category: 'auth', type: 'info', data: data),
    );
  }

  // ============ Interceptor decision-point breadcrumbs (PROD-2095) ============
  //
  // Category `auth.interceptor` matches the backend handoff so the FE↔BE
  // breadcrumb chain reads consistently in Sentry. Every entry threads
  // `request_id` (set by the X-Request-ID interceptor) so each breadcrumb
  // joins back to its matching backend log line.

  /// Fired by the X-Request-ID interceptor just before Dio dispatches the
  /// request. Most important breadcrumb for Diana-class wedges where the
  /// request never leaves the app — if this doesn't fire for a login
  /// attempt, the bug is upstream of Dio.
  void logRequestAboutToDispatch({
    required String requestId,
    required String method,
    required String path,
    required String resolvedBaseUrl,
    required bool hasAccessToken,
    int? accessTokenAgeS,
    required bool inflightRefresh,
    required int queueDepth,
    String accessTokenFingerprint = 'none',
  }) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'request.about_to_dispatch',
        category: 'auth.interceptor',
        type: 'info',
        data: {
          'request_id': requestId,
          'method': method,
          'path': path,
          'resolved_base_url': resolvedBaseUrl,
          'has_access_token': hasAccessToken,
          if (accessTokenAgeS != null) 'access_token_age_s': accessTokenAgeS,
          'inflight_refresh': inflightRefresh,
          'queue_depth': queueDepth,
          // PROD-2236 — per-request access-token fingerprint. Used to
          // correlate the bearer the FE dispatched with the bearer the
          // BE refused (in BE access logs / Sentry session-loss events).
          // Makes future investigations a lookup instead of an
          // archaeology dig.
          'access_token_fingerprint': accessTokenFingerprint,
        },
      ),
    );
  }

  /// PROD-2095 — set the `refresh_token_fingerprint` Sentry scope tag.
  ///
  /// Call this after every refresh-token write (login, refresh rotation,
  /// app-start token restore) and on logout (with `null`). Lets us pair
  /// FE Sentry events with backend `auth_diag refresh.*` log lines that
  /// carry the same fingerprint.
  ///
  /// **Do NOT call this from `StorageService`** — `AuthDiagnosticsService`
  /// already depends on `StorageService`, so the reverse direction would
  /// form a Riverpod provider cycle (Decision 7 in PROD-2095 plan).
  Future<void> setRefreshTokenFingerprint(String? rawToken) async {
    await Sentry.configureScope((scope) {
      scope.setTag(
        'refresh_token_fingerprint',
        refreshTokenFingerprint(rawToken),
      );
    });
  }

  /// Generic interceptor-category breadcrumb. Used for less-frequent events
  /// like X-Request-ID echo mismatches.
  void logInterceptorEvent(String message, {Map<String, dynamic>? data}) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: message,
        category: 'auth.interceptor',
        type: 'info',
        data: data,
      ),
    );
  }

  /// PROD-2095 AC #2 — fires when the RefreshInterceptor confirms a 401 on a
  /// real-user (non-guest, non-refresh-endpoint) request and is about to
  /// delegate to the coordinator. Lets the breadcrumb chain show "the 401
  /// was definitely received by the FE" — distinguishes "we got 401 and
  /// kept going" from "we never saw a 401 but logged the user out".
  void log401Detected({
    required String? requestId,
    required String path,
    required bool inflightRefresh,
    required String refreshTokenFingerprint,
  }) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: '401.detected',
        category: 'auth.interceptor',
        type: 'info',
        data: {
          if (requestId != null) 'request_id': requestId,
          'path': path,
          'inflight_refresh': inflightRefresh,
          'refresh_token_fingerprint': refreshTokenFingerprint,
        },
      ),
    );
  }

  /// PROD-2095 AC #2 — fires per CALLER (not per refresh POST). The
  /// `mutex_acquired_immediately` field distinguishes the caller that
  /// started the refresh from piggy-backers awaiting the same future.
  /// Reason: `got_401` | `preemptive` | `manual`.
  void logRefreshStart({
    required String? requestId,
    required String refreshTokenFingerprint,
    required String reason,
    required bool mutexAcquiredImmediately,
  }) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'refresh.start',
        category: 'auth.interceptor',
        type: 'info',
        data: {
          if (requestId != null) 'request_id': requestId,
          'refresh_token_fingerprint': refreshTokenFingerprint,
          'reason': reason,
          'mutex_acquired_immediately': mutexAcquiredImmediately,
        },
      ),
    );
  }

  /// PROD-2095 AC #2 — fires per CALLER after the coordinator returns.
  /// `status`: `success` | `invalid` | `transient`.
  void logRefreshResult({
    required String? requestId,
    required String status,
    int? httpStatus,
    required int durationMs,
    String? newRefreshTokenFingerprint,
  }) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'refresh.result',
        category: 'auth.interceptor',
        type: 'info',
        level: status == 'success' ? SentryLevel.info : SentryLevel.warning,
        data: {
          if (requestId != null) 'request_id': requestId,
          'status': status,
          if (httpStatus != null) 'http_status': httpStatus,
          'duration_ms': durationMs,
          if (newRefreshTokenFingerprint != null)
            'new_refresh_token_fingerprint': newRefreshTokenFingerprint,
        },
      ),
    );
  }

  /// PROD-2095 AC #2 — fires after RefreshInterceptor retries the original
  /// failed request with the new access token. `queuedCount` is the
  /// coordinator's `awaiterCount` at the moment of the retry — non-zero
  /// indicates concurrent callers were sharing the in-flight refresh.
  void logRetryOriginal({
    required String? requestId,
    required String path,
    required int queuedCount,
  }) {
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'retry.original',
        category: 'auth.interceptor',
        type: 'info',
        data: {
          if (requestId != null) 'request_id': requestId,
          'path': path,
          'queued_count': queuedCount,
        },
      ),
    );
  }

  // ============ Connectivity health probe (PROD-2095 AC #5) ============

  /// PROD-2095 — runs a 5s-timeout GET against `<baseUrl>/health` to
  /// determine whether the backend is reachable AT THE MOMENT of a login
  /// failure. Always captures the original [loginError] to Sentry, even
  /// when the probe itself throws — the probe is purely diagnostic and
  /// must never swallow the user-visible failure.
  ///
  /// `connectivity_status` comes from a **fresh** `Connectivity().
  /// checkConnectivity()` call, NOT from the cached
  /// `ConnectivityService._currentStatus` (Decision 12): the cached value
  /// initializes to `online` and only updates via stream, so at the
  /// moment of an instant login failure the cache may be stale.
  Future<void> runHealthProbe({
    required Object loginError,
    StackTrace? stackTrace,
    required String resolvedBaseUrl,
  }) async {
    final stopwatch = Stopwatch()..start();
    bool reachable = false;
    int? statusCode;
    String? errorType;
    String? errorSummary;
    try {
      final probe =
          _probeDioFactory?.call() ??
          Dio(
            BaseOptions(
              // Decision 11 — set ALL three timeouts. Diana's failure shape
              // is `connection timeout`; without connectTimeout the probe
              // can hang indefinitely.
              connectTimeout: const Duration(seconds: 5),
              sendTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
              headers: {'Accept': 'application/json'},
            ),
          );
      final response = await probe.get('$resolvedBaseUrl/health');
      reachable =
          response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 500;
      statusCode = response.statusCode;
    } catch (probeErr) {
      errorType = probeErr.runtimeType.toString();
      errorSummary = probeErr.toString().split('\n').first;
    } finally {
      stopwatch.stop();
    }

    // Decision 12 — fresh connectivity check, not cached state.
    String connectivityStatus = 'unknown';
    try {
      final connectivity = _connectivityFactory?.call() ?? Connectivity();
      final result = await connectivity.checkConnectivity();
      connectivityStatus = result.toString();
    } catch (_) {
      // Swallow — diagnostic only.
    }

    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'health_probe',
        category: 'auth.diagnostic',
        type: reachable ? 'info' : 'error',
        level: reachable ? SentryLevel.info : SentryLevel.error,
        data: {
          'reachable': reachable,
          if (statusCode != null) 'status': statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
          'resolved_base_url_at_failure': resolvedBaseUrl,
          'connectivity_status': connectivityStatus,
          if (errorType != null) 'error_type': errorType,
          if (errorSummary != null) 'error_summary': errorSummary,
        },
      ),
    );

    // ALWAYS capture the original login error, even if the probe itself
    // threw above. The probe is purely diagnostic; it must never swallow
    // the user-visible failure.
    unawaited(Sentry.captureException(loginError, stackTrace: stackTrace));
  }

  // ============ Unexpected Session Loss Event ============

  /// Fire a Sentry event when a previously-authenticated user is forced out.
  /// This is the main diagnostic event for investigating PROD-691.
  ///
  /// PROD-2095 — augmented with `requestId`, `inflightWasPresent`, and
  /// `recentlySucceededRefresh` so the FLUTTER-8D race signature shows up
  /// in the event tags: a session loss with `recently_succeeded_refresh=true`
  /// means a parallel refresh succeeded but the failing path is logging
  /// the user out anyway.
  Future<void> logUnexpectedSessionLoss({
    required String trigger,
    String? backendErrorCode,
    String? refreshFailureReason,
    String? refreshInvalidReason,
    int? refreshStatusCode,
    bool? hadCookies,
    String? requestId,
    bool? inflightWasPresent,
    bool? recentlySucceededRefresh,
  }) async {
    // Gather context from storage (non-sensitive metadata only)
    final loginMethod = _storageService.getLoginMethod() ?? 'unknown';
    final loginTimestamp = _storageService.getLoginTimestamp();
    final tokenExpiresAt = await _storageService.getTokenExpiresAt();

    final now = DateTime.now();
    final tokenAgeSeconds = loginTimestamp != null
        ? now.difference(loginTimestamp).inSeconds
        : -1;
    final hadExpiry = tokenExpiresAt != null;
    final wasExpired = tokenExpiresAt != null && now.isAfter(tokenExpiresAt);

    // Add a detailed breadcrumb right before the event so Sentry captures
    // the full context in the breadcrumb trail
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: 'Session loss diagnostics',
        category: 'auth.session_loss',
        type: 'info',
        level: SentryLevel.warning,
        data: {
          'trigger': trigger,
          'platform': _platform,
          'login_method': loginMethod,
          'had_expiry': hadExpiry,
          'was_expired': wasExpired,
          'token_age_seconds': tokenAgeSeconds,
          if (backendErrorCode != null) 'backend_error_code': backendErrorCode,
          if (refreshFailureReason != null)
            'refresh_failure_reason': refreshFailureReason,
          if (refreshInvalidReason != null)
            'refresh_invalid_reason': refreshInvalidReason,
          if (refreshStatusCode != null)
            'refresh_status_code': refreshStatusCode,
          // PROD-2168 (F8) — `hadCookies` reflects only JS-readable
          // cookies; the refresh cookie is HttpOnly so this signal is
          // misleading on web (always false even when the BE absolutely
          // received the cookie). Keep the breadcrumb data field for
          // backward-compat with prior events but DROP the Sentry tag
          // below. BE-side `has_cookie` in `auth_diag refresh.enter`
          // covers what this tag was trying to surface.
          if (hadCookies != null) 'had_cookies_js_only': hadCookies,
          if (requestId != null) 'request_id': requestId,
          if (inflightWasPresent != null)
            'inflight_was_present': inflightWasPresent,
          if (recentlySucceededRefresh != null)
            'recently_succeeded_refresh': recentlySucceededRefresh,
        },
      ),
    );

    // Fire the event — tags are searchable/filterable in Sentry dashboard
    Sentry.captureMessage(
      'Unexpected session loss: $trigger',
      level: SentryLevel.warning,
      params: [trigger, _platform, loginMethod],
      withScope: (scope) {
        scope.setTag('auth.trigger', trigger);
        scope.setTag('auth.platform', _platform);
        scope.setTag('auth.login_method', loginMethod);
        scope.setTag('auth.had_expiry', '$hadExpiry');
        scope.setTag('auth.was_expired', '$wasExpired');
        scope.setTag('auth.token_age_seconds', '$tokenAgeSeconds');
        if (backendErrorCode != null) {
          scope.setTag('auth.backend_error_code', backendErrorCode);
        }
        // PROD-691 (Inv #7) — split the dominant `refresh_token_invalid`
        // bucket by WHY it fired. `refresh_invalid_reason` is the FE-side
        // discriminator (4xx vs unparseable vs unexpected); `refresh_status_code`
        // is the HTTP status the backend answered with. Both are low-cardinality
        // and searchable in `/check-session-loss`.
        if (refreshInvalidReason != null) {
          scope.setTag('auth.refresh_invalid_reason', refreshInvalidReason);
        }
        if (refreshStatusCode != null) {
          scope.setTag('auth.refresh_status_code', '$refreshStatusCode');
        }
        // PROD-2168 (F8) — the old `auth.had_cookies` tag was dropped because
        // its name misled: `CookieJar.loadForRequest` only sees JS-readable
        // cookies, but the refresh cookie is HttpOnly, so on web it always
        // reported false even when the BE received the cookie fine.
        //
        // PROD-3933 — restore the signal under an honest name. It is meaningful
        // on native (the app owns its cookie jar) and, by design, always `false`
        // on web (`_hasCookies()` short-circuits on `kIsWeb`). BE-side
        // `auth_diag refresh.enter.has_cookie` remains the web source of truth.
        if (hadCookies != null) {
          scope.setTag('auth.native_cookie_jar_nonempty', '$hadCookies');
        }
        if (requestId != null) {
          scope.setTag('auth.request_id', requestId);
        }
        if (inflightWasPresent != null) {
          scope.setTag('auth.inflight_was_present', '$inflightWasPresent');
        }
        if (recentlySucceededRefresh != null) {
          scope.setTag(
            'auth.recently_succeeded_refresh',
            '$recentlySucceededRefresh',
          );
        }
      },
    );
  }

  // ============ Helpers ============

  String get _platform {
    if (kIsWeb) return 'web';
    // On native, check platform
    try {
      // dart:io Platform is not available on web, but we're past the kIsWeb check
      return _nativePlatform;
    } catch (_) {
      return 'unknown';
    }
  }
}

/// Separate function to avoid importing dart:io on web
String get _nativePlatform {
  // Use defaultTargetPlatform which works on all platforms
  // This is imported via foundation.dart
  return 'native'; // Will be refined by Sentry's device context automatically
}

/// Provider for AuthDiagnosticsService
final authDiagnosticsProvider = Provider<AuthDiagnosticsService>((ref) {
  final storageService = ref.watch(storageServiceProvider);
  return AuthDiagnosticsService(storageService: storageService);
});
