import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/services/auth_diagnostics_service.dart';
import '../../../../core/services/auth_event_service.dart';
import '../../../../core/services/refresh_coordinator.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/services/token_refresh_service.dart';
import '../../../../core/utils/jwt_sub.dart';
import '../../../models/api_responses.dart';
import 'request_id_interceptor.dart';

/// Interceptor that handles 401 errors by delegating the actual refresh
/// POST to the [RefreshCoordinator] (PROD-2095), then retrying the
/// original failed request with the new token.
///
/// **What this interceptor owns**:
/// - 401 detection
/// - Guest-JWT re-mint branch (PROD-1979) — separate from `/auth/refresh`
/// - The "refreshable=false force-logout" branch (parses structured
///   auth-error responses from the backend)
/// - Retry of the original failed request after a successful refresh
/// - Session-loss reporting (clear tokens + notify session expired +
///   Sentry capture) when the refresh definitively fails
///
/// **What the coordinator owns**:
/// - The single inflight `Future<RefreshOutcome>` (single-flight discipline)
/// - The `/auth/refresh` POST itself, including retry-on-transient logic
/// - Saving rotated tokens to [StorageService]
/// - The `_lastRefreshSuccessAt` timestamp for the
///   `recently_succeeded_refresh` smoke detector
///
/// Multiple concurrent 401s call into the coordinator independently; the
/// coordinator returns the same outcome to all of them via the shared
/// Future. Each interceptor invocation then retries its own original
/// request. There is no interceptor-level queue anymore — serialization
/// lives in one place (the coordinator).
class RefreshInterceptor extends Interceptor {
  final Dio _dio;
  final StorageService _storageService;
  final AuthEventService _authEventService;
  final TokenRefreshService _tokenRefreshService;
  final AuthDiagnosticsService _diagnostics;
  final RefreshCoordinator _coordinator;
  final CookieJar? _cookieJar;

  /// PROD-1979 — async accessor for the persisted `visitor_id`. Used to
  /// re-mint a guest JWT when the current token is a guest session and
  /// it expires (BE returns a generic 401, not `AUTH_TOKEN_INVALID`).
  final Future<String> Function()? _getVisitorId;

  /// Test injection for the guest-mint Dio.
  final Dio Function()? _guestMintDioFactory;

  RefreshInterceptor({
    required Dio dio,
    required StorageService storageService,
    required AuthEventService authEventService,
    required TokenRefreshService tokenRefreshService,
    required AuthDiagnosticsService diagnostics,
    required RefreshCoordinator coordinator,
    CookieJar? cookieJar,
    Future<String> Function()? getVisitorId,
    @visibleForTesting Dio Function()? guestMintDioFactory,
  }) : _dio = dio,
       _storageService = storageService,
       _authEventService = authEventService,
       _tokenRefreshService = tokenRefreshService,
       _diagnostics = diagnostics,
       _coordinator = coordinator,
       _cookieJar = cookieJar,
       _getVisitorId = getVisitorId,
       _guestMintDioFactory = guestMintDioFactory;

  // ============ Guest token re-mint (PROD-1979) ============

  /// PROD-1979 — mint a fresh guest token using the persisted
  /// `visitor_id`. Returns null on failure so the caller can let the
  /// 401 propagate unchanged.
  Future<RefreshResponse?> _mintGuestToken() async {
    final getVisitor = _getVisitorId;
    if (getVisitor == null) return null;
    try {
      final visitorId = await getVisitor();
      final factory = _guestMintDioFactory;
      final mintDio = factory != null
          ? factory()
          : Dio(
              BaseOptions(
                baseUrl: _dio.options.baseUrl,
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 30),
                headers: {
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                },
              ),
            );
      final response = await mintDio.post(
        ApiConstants.authGuest,
        data: {'visitor_id': visitorId},
      );
      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        final data = response.data as Map<String, dynamic>;
        return RefreshResponse.fromJson(data);
      }
    } catch (_) {
      // Fail-soft — caller will propagate the original 401.
    }
    return null;
  }

  // ============ 401 handling ============

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    // Only handle 401 errors
    if (err.response?.statusCode != 401) {
      return handler.next(err);
    }

    // PROD-2144 — discriminator for the cold-load bootstrap race: did the
    // failed request actually carry an Authorization header? If not, the
    // backend's 401 (typically `AUTH_TOKEN_INVALID`) reflects "no header
    // sent" rather than "the token we sent was rejected", and we can
    // recover by minting (or by reusing a parallel-minted token) and
    // retrying. `_retryRequest` writes the header before the second
    // attempt, so a follow-up 401 will fall through to the regular path
    // — no infinite loop.
    final authHeader = err.requestOptions.headers['Authorization'] as String?;
    final hadAuthHeader = authHeader != null && authHeader.isNotEmpty;

    final currentToken = await _storageService.getAccessToken();
    if (currentToken == null || currentToken.isEmpty) {
      // PROD-2144 — bootstrap race recovery. `AuthNotifier` mints the
      // initial guest JWT fire-and-forget from its constructor, so the
      // first protected request on a cold-load deep link can lose the
      // race and go out tokenless. The pre-existing behavior here was to
      // propagate the 401 unchanged, which surfaced as the "Não foi
      // possível carregar este local" error card on
      // `/lists/<id>/events/<id>` etc. Mint inline (same path as the
      // guest-JWT-expired branch below) and retry.
      if (!hadAuthHeader && _getVisitorId != null) {
        final fresh = await _mintGuestToken();
        if (fresh != null) {
          await _storageService.saveAccessToken(
            fresh.accessToken,
            expiresAt: fresh.expiresAt,
          );
          try {
            final retried = await _retryRequest(
              err.requestOptions,
              fresh.accessToken,
            );
            return handler.resolve(retried);
          } catch (_) {
            return handler.next(err);
          }
        }
      }
      return handler.next(err);
    }

    // PROD-1979 — guest sessions don't go through `/auth/refresh`. If
    // the stored bearer is a guest JWT, branch to the guest re-mint
    // path here BEFORE the refreshable check (the BE doesn't bother to
    // populate the structured `refreshable` flag for guest tokens, so
    // the real-user path would erroneously force-logout an unauth
    // visitor).
    if (isGuestJwt(currentToken)) {
      // PROD-2144 — bootstrap race recovery (token-present variant). If
      // a guest JWT was minted by the parallel `_initializeFromStorage`
      // call AFTER our request had already gone out tokenless, the
      // failed request had no Authorization header but storage now
      // holds a valid token. Retry directly — no re-mint needed,
      // and skip the AUTH_TOKEN_INVALID propagate-as-fatal branch
      // below (which is only meant for guest-hit-real-user-endpoint).
      if (!hadAuthHeader) {
        try {
          final retried = await _retryRequest(err.requestOptions, currentToken);
          return handler.resolve(retried);
        } catch (_) {
          return handler.next(err);
        }
      }
      final authError = _parseAuthError(err.response?.data);
      // A guest token hitting a real-user endpoint surfaces as
      // `AUTH_TOKEN_INVALID` with a message telling the caller to sign
      // in. Don't re-mint — propagate so the UI's `requireAuth` gating
      // (which should have caught this earlier anyway) routes to login.
      //
      // BUT: an *expired* guest JWT also surfaces as `AUTH_TOKEN_INVALID`
      // (the BE behaviour changed from the original generic-401 — see
      // the constructor doc on [_getVisitorId]). Without the local
      // `exp` check, every reload after the 24h guest TTL elapses left
      // the app permanently broken with no way to recover short of
      // clearing localStorage. Disambiguate using the locally-decoded
      // `exp` claim: if the token isn't expired locally, treat as
      // "guest hit real-user endpoint" and propagate; otherwise fall
      // through to re-mint.
      if (authError != null &&
          authError.isTokenInvalid &&
          !isJwtExpired(currentToken)) {
        return handler.next(err);
      }
      // Otherwise the guest JWT has expired (24 h TTL). Mint a fresh
      // one and retry the original request.
      final fresh = await _mintGuestToken();
      if (fresh != null) {
        await _storageService.saveAccessToken(
          fresh.accessToken,
          expiresAt: fresh.expiresAt,
        );
        try {
          final retried = await _retryRequest(
            err.requestOptions,
            fresh.accessToken,
          );
          return handler.resolve(retried);
        } catch (_) {
          return handler.next(err);
        }
      }
      return handler.next(err);
    }

    // The refresh endpoint never goes through this interceptor (it lives
    // on the coordinator's dedicated Dio with no app interceptors). This
    // branch is defensive — if something accidentally routes a refresh
    // request through the main Dio, don't recurse.
    if (_isRefreshEndpoint(err.requestOptions.path)) {
      _diagnostics.logReactiveRefreshResult(
        success: false,
        errorCode: 'refresh_endpoint_401',
      );
      await _diagnostics.logUnexpectedSessionLoss(
        trigger: 'refresh_endpoint_401',
        refreshFailureReason: 'Refresh endpoint itself returned 401',
        hadCookies: await _hasCookies(),
      );
      await _clearTokens();
      _tokenRefreshService.onRefreshFailed();
      _authEventService.notifySessionExpired();
      return handler.next(err);
    }

    // PROD-2095 AC #2 — pull request_id + refresh-token fingerprint so the
    // whole 401 breadcrumb chain is correlatable with backend logs.
    final requestId =
        err.requestOptions.extra[RequestIdInterceptor.requestIdExtraKey]
            as String?;
    final refreshTokenFp = refreshTokenFingerprint(
      await _storageService.getRefreshToken(),
    );

    // Parse the structured 401 error response to check if refresh is allowed
    final authError = _parseAuthError(err.response?.data);
    if (authError != null && !authError.refreshable) {
      // PROD-2131 — hardened `refreshable: false` path.
      //
      // Before the hardening, this branch force-logged-out unconditionally
      // even when a parallel `/auth/refresh` had just succeeded. That race
      // is the FLUTTER-8D signature: BE rotates token at t=0, the next 401
      // arrives at t=+50ms still carrying the OLD token (caller had it
      // stamped pre-rotation), BE responds `refreshable=false` for the
      // already-rotated token, and we log the user out 2 seconds before
      // the success completes. Two ways into this race in the wild:
      //
      //   - Case A: a coordinator refresh is currently in flight. Other
      //     parallel callers might be rotating the token right now; await
      //     the same future and share the outcome.
      //   - Case B: no inflight refresh, but one succeeded in the last
      //     10s. The stored access token IS the rotated value — retry
      //     the original request with it.
      //
      // PROD-2236 — the "did the token change?" gate now compares the
      // FAILED REQUEST's bearer against the post-rotation storage value
      // (Case B) / coordinator-returned token (Case A). The previous
      // gate compared storage-at-handler-entry against
      // storage-after-rotation, but in the named Madrid event (~56ms
      // post-refresh-success) storage already held the rotated token at
      // handler entry → both sides equal → retry skipped → force-logout
      // fired. The bearer attached to the failed `RequestOptions` is the
      // only reliable "stale token" signal — it's whatever was stamped
      // by `AuthInterceptor.onRequest` at dispatch, before any rotation.
      // Helper at `_extractBearerToken` (L598).
      //
      // In both cases, fall through to the existing force-logout path if
      // the retry fails or the outcome isn't a usable token. The
      // force-logout path is gated by `mutexAcquiredImmediately` so
      // piggy-backers don't emit duplicate Sentry events.
      _diagnostics.logReactiveRefreshResult(
        success: false,
        errorCode: authError.errorCode,
        wasRefreshable: false,
      );

      // PROD-2236 — the bearer the BE actually refused (read from the
      // failed request's `Authorization` header, not storage). Stable
      // across the entire refreshable=false branch.
      final failedRequestBearer = _extractBearerToken(err.requestOptions);

      // PROD-2168 (F14) — hoisted so the fall-through force-logout below
      // can apply the Decision 14 mutex-holder gate to its session-loss
      // Sentry capture. The previous version of this branch claimed in
      // the comment above to gate the force-logout, but the code only
      // gated the early-exit silent path at line 314-319 — the
      // fall-through capture at the end was unconditional. Diana's
      // 2026-05-26 08:33 retry storm (5 Sentry events for 1 BE rotation)
      // is exactly this leak. Track the coordinator result outside the
      // try so the gate can read it post-fall-through.
      CoordinatedRefreshResult? refreshableFalseResult;

      // Case A — coordinator refresh in flight: await + share outcome.
      if (_coordinator.isRefreshing) {
        try {
          final result = await _coordinator.getRefreshedAccessToken(
            reason: 'refreshable_false_with_inflight',
          );
          refreshableFalseResult = result;
          if (result.outcome case RefreshSuccess(:final response)) {
            // PROD-2236 — only retry if the failed request was dispatched
            // with a DIFFERENT bearer than what the coordinator just
            // returned. If the same, the BE refused the new token —
            // retrying would just 401 again — fall through to
            // force-logout. Null `failedRequestBearer` means we cannot
            // prove staleness → fall through (defensive).
            if (failedRequestBearer != null &&
                failedRequestBearer != response.accessToken) {
              _logStaleBearerRetry(
                caseLabel: 'A',
                failedBearer: failedRequestBearer,
                currentToken: response.accessToken,
                endpointPath: err.requestOptions.uri.path,
              );
              try {
                final retried = await _retryRequest(
                  err.requestOptions,
                  response.accessToken,
                );
                return handler.resolve(retried);
              } catch (retryErr) {
                _diagnostics.addBreadcrumb(
                  'refreshable_false.retry_failed',
                  data: {'error_type': '${retryErr.runtimeType}'},
                );
                // fall through to force-logout (mutex-holder gated)
              }
            }
            // No bearer mismatch → fall through to force-logout.
          }
          // RefreshInvalid / RefreshTransient: piggy-backers exit quietly
          // so only the mutex holder logs the session-loss event.
          if (!result.mutexAcquiredImmediately) {
            await _clearTokens();
            _tokenRefreshService.onRefreshFailed();
            _authEventService.notifySessionExpired();
            return handler.next(err);
          }
          // fall through — we ARE the mutex holder; emit the Sentry event
        } catch (coordErr) {
          _diagnostics.addBreadcrumb(
            'refreshable_false.coord_threw',
            data: {'error_type': '${coordErr.runtimeType}'},
          );
          // refreshableFalseResult stays null → gate treats as holder
          // fall through to force-logout
        }
      }
      // Case B — no inflight, but a refresh just succeeded. The stored
      // access token IS the rotated value — try it once.
      else if (_coordinator.recentlySucceededRefresh()) {
        final currentTokenAfterRotation = await _storageService
            .getAccessToken();
        // PROD-2236 — compare the failed request's bearer against current
        // storage (post-rotation). The old gate compared
        // storage-at-handler-entry against storage-after-rotation, which
        // is always equal once the rotation has persisted before the
        // handler runs (the named Madrid event's ~56ms post-refresh
        // timing). Null `failedRequestBearer` means we cannot prove
        // staleness → fall through to force-logout.
        if (currentTokenAfterRotation != null &&
            currentTokenAfterRotation.isNotEmpty &&
            failedRequestBearer != null &&
            failedRequestBearer != currentTokenAfterRotation) {
          _logStaleBearerRetry(
            caseLabel: 'B',
            failedBearer: failedRequestBearer,
            currentToken: currentTokenAfterRotation,
            endpointPath: err.requestOptions.uri.path,
          );
          try {
            final retried = await _retryRequest(
              err.requestOptions,
              currentTokenAfterRotation,
            );
            return handler.resolve(retried);
          } catch (retryErr) {
            _diagnostics.addBreadcrumb(
              'refreshable_false.recent_retry_failed',
              data: {'error_type': '${retryErr.runtimeType}'},
            );
            // refreshableFalseResult stays null → gate treats as holder
            // (Case B path doesn't go through the coordinator)
          }
        }
      }

      // Force-logout path (existing behavior, now gated per F14 + Phase 2
      // 2.A.9).
      //
      // Decision 14: only the mutex holder logs the session-loss Sentry
      // event so concurrent 401s don't produce N captures for one
      // logical failure. Null result (Case A coordinator threw, Case B
      // retry-fail with no coordinator interaction at all) is treated
      // as holder — preserves the "log when uncertain" bias.
      //
      // PROD-2168 Phase 2 — additionally suppress when the coordinator
      // ran as a cross-tab follower: another tab was the leader, did the
      // actual POST, and broadcast the invalid outcome. The follower's
      // own session-loss event would be a duplicate of the leader's.
      // Only `leader` and `fallback` roles emit; `follower` stays silent.
      final isMutexHolderRefreshableFalse =
          refreshableFalseResult == null ||
          (refreshableFalseResult.mutexAcquiredImmediately &&
              refreshableFalseResult.crossTabRole != LockRole.follower);
      if (isMutexHolderRefreshableFalse) {
        await _diagnostics.logUnexpectedSessionLoss(
          trigger: 'token_not_refreshable',
          backendErrorCode: authError.errorCode,
          refreshFailureReason: 'Backend returned refreshable=false',
          hadCookies: await _hasCookies(),
          requestId: requestId,
          inflightWasPresent: _coordinator.isRefreshing,
          recentlySucceededRefresh: _coordinator.recentlySucceededRefresh(),
        );
      }
      await _clearTokens();
      _tokenRefreshService.onRefreshFailed();
      _authEventService.notifySessionExpired();
      return handler.next(err);
    }

    // PROD-2095 AC #2 — `401.detected` fires for refreshable 401s only
    // (force-logout branch above already emits the session-loss event).
    _diagnostics.log401Detected(
      requestId: requestId,
      path: err.requestOptions.uri.path,
      inflightRefresh: _coordinator.isRefreshing,
      refreshTokenFingerprint: refreshTokenFp,
    );

    // Delegate the actual refresh to the coordinator. Concurrent 401s
    // from other in-flight requests share the same in-flight future.
    _diagnostics.logReactiveRefreshAttempt(
      triggeringEndpoint: err.requestOptions.path,
    );

    // PROD-2131 — hoisted so the defensive catch below can gate the Sentry
    // session-loss event by `mutexAcquiredImmediately` (Decision 14).
    CoordinatedRefreshResult? result;
    try {
      // PROD-2168 Phase 2 Codex [P1] round 3 — read the rejected token
      // from the FAILED REQUEST's Authorization header, NOT from
      // current storage. If another tab rotated between request
      // dispatch and the 401 landing here, storage already holds the
      // new token. Passing the new token as "rejected" would defeat
      // the synthesis path and force an unnecessary POST. The bearer
      // attached at dispatch time is the actual token the BE refused.
      final rejectedToken = _extractBearerToken(err.requestOptions);
      result = await _coordinator.getRefreshedAccessToken(
        reason: 'got_401',
        rejectedAccessToken: rejectedToken,
      );

      // PROD-2095 AC #2 — `refresh.start` carries the CALLER's request id
      // + the authoritative `mutex_acquired_immediately` flag (only
      // known after the await — pre-await `isRefreshing` would race).
      _diagnostics.logRefreshStart(
        requestId: requestId,
        refreshTokenFingerprint: refreshTokenFp,
        reason: 'got_401',
        mutexAcquiredImmediately: result.mutexAcquiredImmediately,
      );

      switch (result.outcome) {
        case RefreshSuccess(:final response):
          _diagnostics.logReactiveRefreshResult(success: true);
          _diagnostics.logRefreshResult(
            requestId: requestId,
            status: 'success',
            durationMs: result.duration.inMilliseconds,
            newRefreshTokenFingerprint: refreshTokenFingerprint(
              response.refreshToken,
            ),
          );
          // PROD-3143 — the refresh SUCCEEDED; a failure of the retried
          // request must never be misread as a refresh failure. The retry
          // reuses the original RequestOptions including its CancelToken,
          // so a cancellation that landed mid-refresh (navigation,
          // superseded search) throws DioException [request cancelled]
          // here. Previously that bubbled into the outer catch, which
          // cleared tokens and logged out a live session (FLUTTER-BA).
          try {
            final retryResponse = await _retryRequest(
              err.requestOptions,
              response.accessToken,
            );
            _diagnostics.logRetryOriginal(
              requestId: requestId,
              path: err.requestOptions.uri.path,
              queuedCount: _coordinator.awaiterCount,
            );
            handler.resolve(retryResponse);
          } catch (retryErr) {
            _diagnostics.addBreadcrumb(
              'retry.failed_after_refresh_success',
              data: {
                'error_type': '${retryErr.runtimeType}',
                'request_id': requestId,
                'path': err.requestOptions.uri.path,
                if (retryErr is DioException)
                  'dio_error_type': retryErr.type.name,
              },
            );
            // Tokens stay; session stays. Propagate the retry's own error.
            handler.next(retryErr is DioException ? retryErr : err);
          }

        case RefreshInvalid(
          :final reason,
          :final statusCode,
          :final detail,
          // PROD-3933 — bind the getter (object patterns invoke getters):
          // structured backend code, else a normalized code from `detail`.
          :final diagnosticErrorCode,
        ):
          _diagnostics.logReactiveRefreshResult(
            success: false,
            errorCode: 'token_invalid',
          );
          _diagnostics.logRefreshResult(
            requestId: requestId,
            status: 'invalid',
            durationMs: result.duration.inMilliseconds,
          );
          await _clearTokens();
          _authEventService.notifySessionExpired();
          // Only the mutex holder logs the session-loss Sentry event so
          // concurrent 401s don't produce N duplicate captures for the
          // same logical failure.
          //
          // PROD-2168 Phase 2 — additionally suppress when this tab ran
          // as a cross-tab follower (another tab's leader already did
          // the POST and broadcast invalid). Only `leader` and
          // `fallback` roles emit; `follower` stays silent.
          if (result.mutexAcquiredImmediately &&
              result.crossTabRole != LockRole.follower) {
            // PROD-3933 — split the dominant `refresh_token_invalid` bucket by
            // failure shape so a genuine backend 4xx rejection is queryable
            // apart from a client-side unparseable/malformed response. A real
            // backend 4xx arrives via the coordinator's DioException branch with
            // `statusCode` set (401/403 → _4xx); a 200-with-malformed-body,
            // unexpected error, or cross-tab-follower `unspecified` has no 4xx
            // status → _unparseable.
            final is4xx =
                statusCode != null && statusCode >= 400 && statusCode < 500;
            final trigger = is4xx
                ? 'refresh_token_invalid_4xx'
                : 'refresh_token_invalid_unparseable';
            await _diagnostics.logUnexpectedSessionLoss(
              trigger: trigger,
              refreshFailureReason: detail != null
                  ? 'Refresh endpoint rejected token ($reason): $detail'
                  : 'Refresh endpoint rejected token ($reason)',
              refreshInvalidReason: reason,
              refreshStatusCode: statusCode,
              backendErrorCode: diagnosticErrorCode,
              hadCookies: await _hasCookies(),
              requestId: requestId,
              inflightWasPresent: !result.mutexAcquiredImmediately,
              recentlySucceededRefresh: _coordinator.recentlySucceededRefresh(),
            );
          }
          handler.next(err);

        case RefreshTransient():
          // Backend transient failure (5xx/timeout/network) after retries
          // exhausted. Tokens are still valid — keep them and let the next
          // API call re-attempt the refresh (PROD-1506).
          _diagnostics.logReactiveRefreshResult(
            success: false,
            errorCode: 'transient_server_error',
          );
          _diagnostics.logRefreshResult(
            requestId: requestId,
            status: 'transient',
            durationMs: result.duration.inMilliseconds,
          );
          handler.next(err); // propagate original error; user stays signed in
      }
    } catch (e, st) {
      // Should not happen — coordinator catches its own exceptions and
      // returns RefreshInvalid/Transient. Defensive only.
      //
      // PROD-2131 — capture the full stack trace so we can diagnose what's
      // actually throwing in production.
      //
      // PROD-3143 — fail OPEN. An unexpected exception proves nothing
      // about the refresh token; only a backend RefreshInvalid verdict
      // justifies logout. Previously this path cleared tokens and killed
      // provably-live sessions (FLUTTER-BA: a cancelled retry after a
      // SUCCESSFUL refresh landed here). Tokens are preserved; the next
      // 401 re-attempts the refresh, mirroring RefreshTransient.
      unawaited(Sentry.captureException(e, stackTrace: st));
      _diagnostics.logReactiveRefreshResult(
        success: false,
        errorCode: 'exception',
      );
      _diagnostics.addBreadcrumb(
        'refresh.exception_contained',
        data: {
          'error_type': '${e.runtimeType}',
          'request_id': requestId,
          'had_result': result != null,
          'recently_succeeded_refresh': _coordinator.recentlySucceededRefresh(),
        },
      );
      handler.next(err);
    }
  }

  // ============ Helpers ============

  /// Parse structured 401 error response
  AuthErrorResponse? _parseAuthError(dynamic data) {
    if (data == null) return null;
    try {
      if (data is Map<String, dynamic>) {
        final detail = data['detail'];
        if (detail is Map<String, dynamic>) {
          return AuthErrorResponse.fromJson(detail);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Retry a request with a new token
  Future<Response> _retryRequest(
    RequestOptions options,
    String newToken,
  ) async {
    options.headers['Authorization'] = 'Bearer $newToken';
    return await _dio.fetch(options);
  }

  /// Clear stored tokens (idempotent)
  Future<void> _clearTokens() async {
    await _storageService.deleteAccessToken();
    await _storageService.deleteRefreshToken();
  }

  /// Check if path is the refresh endpoint
  bool _isRefreshEndpoint(String path) {
    return path.contains('/auth/refresh');
  }

  /// PROD-2236 — emit a structured breadcrumb when the bearer-comparison
  /// gate fires the retry (Case A or Case B). Used in production
  /// telemetry to prove the fix is actually firing — pair with the
  /// per-request `access_token_fingerprint` on `request.about_to_dispatch`
  /// to chain a stale-bearer 401 from FE dispatch to BE refusal to
  /// post-retry resolution.
  void _logStaleBearerRetry({
    required String caseLabel,
    required String failedBearer,
    required String currentToken,
    required String endpointPath,
  }) {
    final lastRefresh = _coordinator.lastRefreshSuccessAt;
    final timeSinceRefreshMs = lastRefresh == null
        ? null
        : DateTime.now().difference(lastRefresh).inMilliseconds;
    _diagnostics.addBreadcrumb(
      'refreshable_false.stale_bearer_retry',
      data: {
        'case': caseLabel,
        'failed_request_bearer_fp': refreshTokenFingerprint(failedBearer),
        'current_token_fp': refreshTokenFingerprint(currentToken),
        if (timeSinceRefreshMs != null)
          'time_since_refresh_ms': timeSinceRefreshMs,
        'endpoint_path': endpointPath,
      },
    );
  }

  /// PROD-2168 Phase 2 Codex [P1] round 3 — extract the bearer token
  /// the failed request was dispatched with, NOT the current storage
  /// value. If another tab rotated between dispatch and 401 arrival,
  /// storage already holds the new token; we need the OLD one (the
  /// one the BE refused) so the coordinator's synthesis check can
  /// safely return the new stored value.
  ///
  /// Scheme match is case-insensitive per RFC 6750 § 2.1 ("scheme is
  /// case insensitive"). We don't control every code path that sets
  /// `Authorization`, so be tolerant.
  String? _extractBearerToken(RequestOptions options) {
    final header =
        options.headers['Authorization'] ?? options.headers['authorization'];
    if (header is! String) return null;
    if (header.length < 7) return null;
    if (header.substring(0, 7).toLowerCase() != 'bearer ') return null;
    final token = header.substring(7).trim();
    return token.isEmpty ? null : token;
  }

  /// Check if cookie jar has any cookies (for diagnostics)
  Future<bool> _hasCookies() async {
    final jar = _cookieJar;
    if (kIsWeb || jar == null) return false;
    try {
      final baseUri = Uri.parse(_dio.options.baseUrl);
      final cookies = await jar.loadForRequest(baseUri);
      return cookies.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
