import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'retry_after.dart';

/// Retries **idempotent** requests on **transient** failures so a slow first
/// hit (cold backend, flaky network) recovers on its own instead of surfacing a
/// scary error to the user.
///
/// Scope (deliberately narrow — a retry must never duplicate work or mask a
/// real client error):
///   * GET by default — never POST/PATCH/DELETE, since a generic mutation isn't
///     safe to replay. A non-GET request may **opt in** by setting
///     `options.extra['idempotentRetry'] == true` — use this only for calls that
///     are genuinely safe to replay: pure reads issued as POST (e.g. discovery
///     ranking, entity hydrate) or full-state upserts (e.g. `PUT
///     /onboarding/state`, a forward-replay that lands the same state each time).
///   * Transient only — connection/send/receive timeouts, connection errors,
///     and 5xx responses. **Never** 4xx: 401 is the refresh interceptor's job;
///     403/404/409/422/429 are terminal and shown immediately.
///   * Bounded — at most [maxRetries] extra attempts with a short backoff.
///
/// **PROD-4369 — do not fight the server when it is already overloaded.** The
/// 2026-09-09 outage (PROD-4321) was amplified by this interceptor: it answered
/// the backend's `503 + Retry-After` load-shed with two more requests 400 ms and
/// 900 ms later, and re-sent feed requests that had merely *timed out* (which the
/// server was still working on), doubling the load each wave. Three rules fix it:
///   1. A 503 that carries `Retry-After` or names itself saturated
///      (`error_code: pool_saturated | feed_admission_saturated`) is **not
///      retried** — it passes through to [ErrorInterceptor], which surfaces a
///      typed [PoolSaturatedException] the UI shows with a manual Retry.
///   2. A `receiveTimeout` on a `/app/feed/` path is **not retried** — the first
///      request is still running server-side; re-sending only piles on. Feed
///      connection/send-timeout and connection errors (network-side, the
///      original #1117/#1367 cold-start cases) are still retried.
///   3. Any 5xx retry that *does* proceed waits a jittered
///      [serverErrorBackoffMin]–[serverErrorBackoffMax] floor (never the old
///      400 ms), and never less than the server's `Retry-After`.
///
/// Placement: added AFTER [RefreshInterceptor] (so 401s refresh first) and
/// BEFORE [ErrorInterceptor] (which `reject`s and would otherwise stop the
/// error before this interceptor's `onError` ran). The re-dispatch goes
/// through the full interceptor chain again, so auth headers etc. are fresh.
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required Dio dio,
    this.maxRetries = 2,
    this.backoff = const [
      Duration(milliseconds: 400),
      Duration(milliseconds: 900),
    ],
    this.serverErrorBackoffMin = const Duration(seconds: 2),
    this.serverErrorBackoffMax = const Duration(seconds: 5),
    Random? random,
  }) : _dio = dio,
       _random = random ?? Random();

  final Dio _dio;
  final int maxRetries;

  /// Backoff for **network-side** transients (connection/send/receive timeout,
  /// connection error). Short on purpose: these are the cold-start / flaky-link
  /// cases the interceptor exists for, where a quick re-try genuinely recovers.
  final List<Duration> backoff;

  /// Lower/upper bound of the jittered floor for a **server-side** 5xx retry.
  /// A mobile app is not a queue consumer; 2–5 s is plenty and never hammers.
  final Duration serverErrorBackoffMin;
  final Duration serverErrorBackoffMax;

  final Random _random;

  static const _retryCountKey = 'retry_count';

  /// The consecutive path segments (`.../app/feed/...`) that mark a feed
  /// request. A `receiveTimeout` on one means the server is still working on the
  /// first request, so re-sending doubles its load.
  static const _feedSegments = ['app', 'feed'];

  /// Per-request opt-in (`options.extra`) that lets a non-GET request be retried.
  /// Set it ONLY on calls that are safe to replay (idempotent reads/upserts).
  static const idempotentRetryKey = 'idempotentRetry';

  /// Whether [err] is a transient failure this request should be re-sent for.
  /// Split out from the delay so the "should we retry" and "how long to wait"
  /// decisions stay independently readable and testable.
  bool _shouldRetry(DioException err, RequestOptions options) {
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.connectionError:
        // Network-side: the request never reached a working server (or could
        // not be sent). Safe to retry — the #1117/#1367 cold-start cases.
        return true;
      case DioExceptionType.receiveTimeout:
        // The request WAS sent and the server is still working on it. Re-sending
        // a feed request doubles its load (PROD-4369); leave non-feed cold-start
        // recovery intact.
        return !_isFeedPath(options.path);
      case DioExceptionType.badResponse:
        final code = err.response?.statusCode ?? 0;
        if (code < 500 || code > 599) return false;
        // A shed 503 is the server explicitly asking us to back off; retrying
        // it immediately is exactly what amplified the outage. Surface it.
        if (code == 503 && _isLoadShed(err.response)) return false;
        return true;
      default:
        return false;
    }
  }

  /// Matches on segment boundaries (not a raw substring) so it catches every
  /// real shape the path can take — absolute `/api/v1/app/feed/home`, a bare
  /// `/app/feed`, or a relative `app/feed/...` — without ever matching a stray
  /// `.../myapp/feed-digest` that merely contains the letters.
  bool _isFeedPath(String path) {
    final segments = Uri.parse(path).pathSegments;
    for (var i = 0; i + 1 < segments.length; i++) {
      if (segments[i] == _feedSegments[0] && segments[i + 1] == _feedSegments[1]) {
        return true;
      }
    }
    return false;
  }

  /// A 503 the backend's load-shedding middleware raised: it either carries a
  /// `Retry-After` header or a flat top-level `error_code` naming the shed.
  bool _isLoadShed(Response? response) {
    if (retryAfterSeconds(response) != null) return true;
    final data = response?.data;
    if (data is Map) {
      final code = data['error_code'];
      return code == 'pool_saturated' || code == 'feed_admission_saturated';
    }
    return false;
  }

  /// How long to wait before re-dispatching [err]'s request on [attempt].
  @visibleForTesting
  Duration backoffFor(int attempt, DioException err) {
    final code = err.response?.statusCode ?? 0;
    final is5xx =
        err.type == DioExceptionType.badResponse &&
        code >= 500 &&
        code <= 599;
    if (is5xx) {
      // Never shorter than the server's own ask, never the old 400 ms.
      final serverAsk = retryAfterSeconds(err.response);
      final floor = _jitteredServerErrorBackoff();
      if (serverAsk != null) {
        final ask = Duration(seconds: serverAsk);
        return ask > floor ? ask : floor;
      }
      return floor;
    }
    // Network-side transient: the short staged backoff.
    return attempt < backoff.length ? backoff[attempt] : backoff.last;
  }

  Duration _jitteredServerErrorBackoff() {
    final minMs = serverErrorBackoffMin.inMilliseconds;
    final maxMs = serverErrorBackoffMax.inMilliseconds;
    final span = maxMs - minMs;
    final jitter = span <= 0 ? 0 : _random.nextInt(span + 1);
    return Duration(milliseconds: minMs + jitter);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final isGet = options.method.toUpperCase() == 'GET';
    final optedIn = options.extra[idempotentRetryKey] == true;
    final attempt = (options.extra[_retryCountKey] as int?) ?? 0;

    if ((!isGet && !optedIn) ||
        attempt >= maxRetries ||
        !_shouldRetry(err, options)) {
      // Let the ErrorInterceptor transform + reject as usual.
      return handler.next(err);
    }

    await Future<void>.delayed(backoffFor(attempt, err));

    final retried = options.copyWith(
      extra: {...options.extra, _retryCountKey: attempt + 1},
    );
    try {
      final response = await _dio.fetch<dynamic>(retried);
      return handler.resolve(response);
    } on DioException catch (e) {
      // The re-dispatch ran the full chain (including ErrorInterceptor), so
      // `e` is already the final, typed error — reject with it directly.
      return handler.reject(e);
    } catch (_) {
      // Non-Dio error from a downstream transform — fall back to the original.
      return handler.reject(err);
    }
  }
}
