import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../data/datasources/api/interceptors/request_id_interceptor.dart';
import '../../data/datasources/api/interceptors/version_header_interceptor.dart';
import '../../data/datasources/api/interceptors/web_credentials_stub.dart'
    if (dart.library.html) '../../data/datasources/api/interceptors/web_credentials_web.dart'
    if (dart.library.io) '../../data/datasources/api/interceptors/web_credentials_native.dart';
import '../../data/models/api_responses.dart';
import '../config/environment.dart';
import '../constants/api_constants.dart';
import '../utils/client_platform.dart';
import 'auth_diagnostics_service.dart';
import 'cross_tab_sync.dart';
import 'cross_tab_sync_stub.dart'
    if (dart.library.html) 'cross_tab_sync_web.dart'
    if (dart.library.io) 'cross_tab_sync_native.dart';
import 'storage_service.dart';
import 'token_refresh_service.dart';

// Re-export so consumers reading `CoordinatedRefreshResult.crossTabRole`
// don't need a separate import to pattern-match on [LockRole].
export 'cross_tab_sync.dart' show LockRole, CrossTabSync, LockOutcome;

/// Outcome of a refresh attempt. Promoted from `RefreshInterceptor`'s
/// private sealed class so all callers can pattern-match on the same
/// result type.
sealed class RefreshOutcome {
  const RefreshOutcome();
}

class RefreshSuccess extends RefreshOutcome {
  final RefreshResponse response;
  const RefreshSuccess(this.response);
}

class RefreshInvalid extends RefreshOutcome {
  /// Why the backend rejected the refresh — a low-cardinality discriminator
  /// surfaced as the `auth.refresh_invalid_reason` Sentry tag. One of:
  /// `non_200_or_malformed`, `non_retryable_dio`, `unexpected_error`,
  /// `fallthrough`, or `unspecified` (the bare-const default used by the
  /// cross-tab follower mapping, which has no local response to inspect).
  final String reason;

  /// HTTP status from the `/auth/refresh` response, when the server answered.
  /// Null on connection/unexpected errors that never got a response.
  final int? statusCode;

  /// Structured backend error code (`detail.error_code`), when present.
  /// Null today — `/auth/refresh` currently returns a string `detail`
  /// ("Invalid or expired refresh token") — but lights up automatically if
  /// the backend enriches the rejection body, with no further FE change.
  final String? backendErrorCode;

  /// Raw `detail` string when the body was unstructured (today's shape).
  /// Carried in the session-loss breadcrumb, not a tag (it's near-constant).
  final String? detail;

  const RefreshInvalid({
    this.reason = 'unspecified',
    this.statusCode,
    this.backendErrorCode,
    this.detail,
  });

  /// PROD-3933 — value for the `auth.backend_error_code` Sentry tag on the
  /// session-loss path. Prefers the structured backend code; otherwise maps a
  /// KNOWN `detail` string to a stable, low-cardinality code. Unknown detail
  /// returns null (the tag stays empty) — the raw string still rides the
  /// session-loss breadcrumb via `refreshFailureReason`, so nothing is lost and
  /// arbitrary/dynamic proxy messages can't blow up tag cardinality. `/auth/refresh`
  /// returns a bare-string `detail` today (no structured code), so before this
  /// the tag was empty on 100% of refresh-rejection events.
  String? get diagnosticErrorCode => backendErrorCode ?? _detailCode(detail);

  static String? _detailCode(String? detail) {
    if (detail == null) return null;
    const known = <String, String>{
      'invalid or expired refresh token': 'INVALID_OR_EXPIRED_REFRESH_TOKEN',
    };
    return known[detail.trim().toLowerCase()];
  }
}

class RefreshTransient extends RefreshOutcome {
  const RefreshTransient();
}

/// Per-call result wrapper. Two concurrent callers awaiting the same
/// in-flight refresh both receive the same [outcome] but each get their
/// own [mutexAcquiredImmediately] flag — `true` only for the caller that
/// actually started the refresh; `false` for piggy-backers. Used by
/// breadcrumb consumers to distinguish "started a refresh" from "waited
/// for one already running".
class CoordinatedRefreshResult {
  final RefreshOutcome outcome;

  /// Local (in-tab) mutex acquisition flag. True for the caller that
  /// actually started the refresh future inside THIS tab; false for
  /// later piggy-backers within the same tab.
  final bool mutexAcquiredImmediately;

  final Duration duration;

  /// PROD-2168 Phase 2 — cross-tab role: `leader` (held the cross-tab
  /// lock and did the work), `follower` (waited for another tab to
  /// release the lock), or `fallback` (no Web Locks API available; ran
  /// without cross-tab coordination — pre-Phase-2 behavior).
  final LockRole crossTabRole;

  /// PROD-2168 Phase 2 — wait time inside `navigator.locks.request`
  /// before the callback fired. Zero for `leader` (acquired immediately)
  /// and `fallback` (no lock). Read by Sentry breadcrumbs as
  /// `lock_wait_ms`.
  final Duration lockWaitDuration;

  /// PROD-2168 Phase 2 — true when the Auth0-style double-check
  /// short-circuited the POST: either the pre-lock cache read or the
  /// post-lock re-read found a fresh access token, so no `/auth/refresh`
  /// request was sent. Read by Sentry breadcrumbs.
  final bool doubleCheckShortCircuit;

  const CoordinatedRefreshResult({
    required this.outcome,
    required this.mutexAcquiredImmediately,
    required this.duration,
    // PROD-2168 Phase 2 — defaults match "no cross-tab coordination",
    // which is both the kill-switch-off behavior and the right shape
    // for the handful of existing tests that construct this directly
    // without exercising the lock path.
    this.crossTabRole = LockRole.fallback,
    this.lockWaitDuration = Duration.zero,
    this.doubleCheckShortCircuit = false,
  });
}

/// Cross-tab lock name. Scoped under `heyl-` so it doesn't collide with
/// third-party scripts on the same origin (Mapbox, PostHog, etc.).
const String _kRefreshLockName = 'heyl-auth-refresh';

/// Wait timeout for follower callers blocked on the cross-tab lock.
/// `AbortSignal.timeout` on `navigator.locks.request` only aborts the
/// ungranted request — once the leader's callback fires, the signal
/// cannot interrupt it. So this timeout is purely a waiter-side bound:
/// after 8s of waiting, return `RefreshTransient` and let a later API
/// call retry rather than blocking the UI indefinitely on a stalled
/// leader.
const Duration _kLockWaitTimeout = Duration(seconds: 8);

/// Threshold: when the existing access token expires more than this far
/// in the future, the double-check synthesizes a `RefreshSuccess` from
/// storage instead of POSTing. Conservative enough to absorb BE clock
/// skew while still catching genuinely expired tokens.
const Duration _kFreshAccessTokenMargin = Duration(seconds: 60);

/// PROD-2095 — single-flight coordinator for `/auth/refresh`.
///
/// Owns the only `Future<RefreshOutcome>? _inflight`, the dedicated refresh
/// Dio (with [RequestIdInterceptor] wired in so `/auth/refresh` POSTs carry
/// `X-Request-ID` for backend correlation), the actual POST + token
/// rotation + storage write, and a `_lastRefreshSuccessAt` timestamp for
/// the `recently_succeeded_refresh` smoke detector.
///
/// PROD-2168 Phase 2 — cross-tab coordination layer:
///
/// On the web, the refresh now runs inside a `navigator.locks.request`
/// callback so only one tab at a time POSTs `/auth/refresh`. Followers
/// wait, then re-read storage after the leader releases the lock
/// (Auth0-style double-check) and synthesize a [RefreshSuccess] if the
/// leader already populated fresh tokens. BroadcastChannel +
/// `storage`-event listeners invalidate the [StorageService] in-memory
/// cache when another tab rotates.
///
/// Gated on [EnvironmentConfig.authInflightSyncEnabled] — when false the
/// cross-tab layer is a no-op and the coordinator runs identical to its
/// pre-Phase-2 behavior.
///
/// Every refresh entry point in the app delegates here:
///
/// - `RefreshInterceptor` on 401
/// - `TokenSchedulerService` proactively before expiry
/// - `AuthNotifier._attemptTokenRefresh` startup `/auth/me` fallback
/// - `AuthNotifier.ensureFreshToken` before Instagram external nav
///
/// **Acceptance criterion**: at most ONE `/auth/refresh` POST in flight per
/// browser profile (across tabs), regardless of caller. Concurrent
/// callers across tabs share the cross-tab lock; concurrent callers in
/// the same tab share the in-memory `_inflight` future.
class RefreshCoordinator {
  final StorageService _storageService;
  final TokenRefreshService _tokenRefreshService;
  final AuthDiagnosticsService _diagnostics;
  final CookieJar? _cookieJar;
  final String _baseUrl;
  final CrossTabSync _crossTabSync;

  /// Test injection point — overrides the internal Dio builder.
  final Dio Function()? _refreshDioFactory;

  /// Retry delay between transient failures. Tests inject `Duration.zero`.
  final Duration _refreshRetryDelay;

  Future<RefreshOutcome>? _inflight;

  /// PROD-2168 Phase 2 followup — the `_LocalRefreshContext` populated
  /// by `_doRefreshCrossTab` while `_inflight` is non-null. Piggy-backer
  /// callers capture this reference at entry so they see the same
  /// crossTabRole / lockWaitDuration / doubleCheckShortCircuit values
  /// the leader populates. Held across the lifetime of `_inflight`;
  /// reassigned when the next refresh starts. Old captured references
  /// remain valid (they don't follow the reassignment).
  _LocalRefreshContext? _inflightContext;

  int _awaiterCount = 0;
  DateTime? _lastRefreshSuccessAt;

  /// Latest cross-tab signal "another tab just heard an invalid refresh".
  /// Set by the [CrossTabSync] message listener; checked inside the
  /// lock-held callback to short-circuit a follower that would otherwise
  /// re-POST the same dead token.
  DateTime? _invalidNotifiedAt;

  /// PROD-2168 Phase 2 Codex [P2] — latest cross-tab cooldown expiry
  /// timestamp observed from a `refresh-transient` channel message.
  /// In-memory only; bypasses the SharedPreferences cache so other
  /// tabs' transient outcomes propagate without a reload.
  DateTime? _crossTabCooldownUntil;

  /// How long we honor a remote `refresh-invalid` notification before
  /// re-attempting. Bounded to handle the edge case where a tab broadcast
  /// invalid spuriously (e.g. testing, BE blip) and we don't want to keep
  /// followers offline forever.
  static const Duration _invalidNoticeWindow = Duration(seconds: 30);

  /// Active subscriptions from [CrossTabSync] — closed on [dispose].
  final List<StreamSubscription<dynamic>> _crossTabSubscriptions = [];

  /// Set to `true` once `_crossTabSync` has been initialized and tags
  /// pushed to Sentry. Prevents duplicate tag writes on re-entry.
  bool _crossTabInitialized = false;

  RefreshCoordinator({
    required StorageService storageService,
    required TokenRefreshService tokenRefreshService,
    required AuthDiagnosticsService diagnostics,
    CookieJar? cookieJar,
    String? baseUrl,
    CrossTabSync? crossTabSync,
    @visibleForTesting Dio Function()? refreshDioFactory,
    @visibleForTesting Duration refreshRetryDelay = const Duration(seconds: 1),
  }) : _storageService = storageService,
       _tokenRefreshService = tokenRefreshService,
       _diagnostics = diagnostics,
       _cookieJar = cookieJar,
       _baseUrl = baseUrl ?? EnvironmentConfig.baseUrl,
       _crossTabSync =
           crossTabSync ??
           createCrossTabSync(
             enabled: EnvironmentConfig.authInflightSyncEnabled && kIsWeb,
           ),
       _refreshDioFactory = refreshDioFactory,
       _refreshRetryDelay = refreshRetryDelay {
    _initCrossTabSync();
  }

  void _initCrossTabSync() {
    if (_crossTabInitialized) return;
    _crossTabInitialized = true;

    // Push capability tags once at init so every subsequent Sentry event
    // is sliceable by whether the cross-tab layer is available for this
    // session. Tags live on the active scope, so this is fire-and-forget.
    Sentry.configureScope((scope) {
      scope.setTag(
        'auth.inflight_sync.locks_available',
        '${_crossTabSync.locksAvailable}',
      );
      scope.setTag(
        'auth.inflight_sync.channel_available',
        '${_crossTabSync.channelAvailable}',
      );
    });

    if (_crossTabSync.channelAvailable) {
      _crossTabSubscriptions.add(
        _crossTabSync.listenMessages(_handleCrossTabMessage),
      );
    }

    // Storage event fallback (Codex 2026-05-26 PM, [P2] fix): even
    // when BroadcastChannel construction failed, the `storage` event on
    // localStorage still fires cross-tab. flutter_secure_storage on web
    // prefixes every key with the configured `publicKey`, so we need
    // to subscribe to the FULL prefixed key (`heyl_app_key.token_generation`),
    // not bare `token_generation` — that was the original code's bug.
    _crossTabSubscriptions.add(
      _crossTabSync.listenStorageKey(StorageKeys.tokenGenerationStorageKey, (
        newValue,
      ) {
        _storageService.invalidateAccessTokenCache(
          reason: 'storage_event:token_generation',
        );
      }),
    );

    // PROD-2168 Phase 2 Codex round-2 [P2] — also listen on the
    // cooldown localStorage key for the BroadcastChannel-missing case.
    // The same `storage` event delivers the new value to other tabs,
    // bypassing SharedPreferences cache entirely.
    _crossTabSubscriptions.add(
      _crossTabSync.listenStorageKey(_crossTabSync.cooldownStorageKey, (
        newValue,
      ) {
        if (newValue == null) return;
        final ms = int.tryParse(newValue);
        if (ms == null) return;
        final until = DateTime.fromMillisecondsSinceEpoch(ms);
        if (_crossTabCooldownUntil == null ||
            until.isAfter(_crossTabCooldownUntil!)) {
          _crossTabCooldownUntil = until;
        }
      }),
    );
  }

  void _handleCrossTabMessage(CrossTabMessage message) {
    switch (message) {
      case CrossTabRefreshComplete(:final generation):
        _storageService.invalidateAccessTokenCache(
          reason: 'cross_tab_complete:gen=$generation',
        );
      case CrossTabRefreshInvalid():
        _invalidNotifiedAt = DateTime.now();
        _storageService.invalidateAccessTokenCache(reason: 'cross_tab_invalid');
      case CrossTabRefreshTransient(:final untilMs):
        // Codex [P2] — set the in-memory cooldown without touching
        // SharedPreferences (which would still be cached in other tabs).
        // _isCooldownActive() consults both this AND the SharedPreferences
        // value; the in-memory one wins for cross-tab signals.
        final until = DateTime.fromMillisecondsSinceEpoch(untilMs);
        if (_crossTabCooldownUntil == null ||
            until.isAfter(_crossTabCooldownUntil!)) {
          _crossTabCooldownUntil = until;
        }
    }
  }

  /// Combined cooldown check. Returns the effective cooldown timestamp
  /// — the most recent (max) of three signals:
  ///   1. SharedPreferences-backed value (this-tab writes; SET-time —
  ///      `getRefreshTransientCooldownAt()` already returns null when
  ///      past the cooldown window, so any non-null value is "active")
  ///   2. Channel-driven in-memory value (other tabs' live broadcasts;
  ///      EXPIRY-time — only valid while in the future)
  ///   3. Direct-localStorage marker (PR-599-followup Codex [P2] —
  ///      covers tabs opened AFTER another tab persisted the cooldown,
  ///      where neither SharedPreferences cache nor an in-memory
  ///      storage event delivers the value; EXPIRY-time — only valid
  ///      while in the future)
  ///
  /// Returns null when all three are absent or expired.
  DateTime? _effectiveCooldownAt() {
    final now = DateTime.now();
    final fromPrefs = _storageService.getRefreshTransientCooldownAt();
    final fromChannel = _crossTabCooldownUntil;
    if (fromChannel != null && fromChannel.isBefore(now)) {
      // Cooldown expired — clear the in-memory marker.
      _crossTabCooldownUntil = null;
    }
    final live = _crossTabCooldownUntil;
    final fromPersistedRaw = _crossTabSync.readPersistedCooldown();
    final fromPersisted =
        (fromPersistedRaw != null && fromPersistedRaw.isAfter(now))
        ? fromPersistedRaw
        : null;

    if (fromPrefs == null && live == null && fromPersisted == null) {
      return null;
    }

    DateTime? best;
    for (final candidate in [fromPrefs, live, fromPersisted]) {
      if (candidate == null) continue;
      if (best == null || candidate.isAfter(best)) best = candidate;
    }
    return best;
  }

  // ============ Public read-only state (for breadcrumb consumers) ============

  /// True if a refresh is currently in flight. Read by [RequestIdInterceptor]
  /// for the `inflight_refresh` field on `request.about_to_dispatch`
  /// breadcrumbs.
  bool get isRefreshing => _inflight != null;

  /// Approximate count of callers currently awaiting the in-flight refresh.
  /// Read by [RequestIdInterceptor] for the `queue_depth` breadcrumb field.
  int get awaiterCount => _awaiterCount;

  /// Timestamp of the last successful refresh, or null if none yet (or after
  /// a failed refresh). Used by the `session.lost` breadcrumb to flag
  /// `recently_succeeded_refresh` cases — if a session-loss event fires
  /// within ~10s of a successful refresh here, a parallel refresh succeeded
  /// but the failing path is logging the user out anyway, which is the
  /// FLUTTER-8D race signature on the breadcrumb chain.
  DateTime? get lastRefreshSuccessAt => _lastRefreshSuccessAt;

  /// True if a refresh succeeded within the last [withinSeconds] seconds.
  bool recentlySucceededRefresh({int withinSeconds = 10}) {
    final ts = _lastRefreshSuccessAt;
    if (ts == null) return false;
    return DateTime.now().difference(ts).inSeconds < withinSeconds;
  }

  /// PROD-2095 — current refresh-token fingerprint as it would be sent to the
  /// backend. Exposed for non-interceptor callers (proactive scheduler,
  /// manual fallback) that need to thread the fingerprint into their
  /// `refresh.start` breadcrumb without having a direct [StorageService]
  /// reference. Returns `'none'` when no refresh token is stored.
  Future<String> currentRefreshTokenFingerprint() async {
    return refreshTokenFingerprint(await _storageService.getRefreshToken());
  }

  // ============ Public API ============

  /// Get a fresh access token, coordinating with any in-flight refresh.
  ///
  /// Concurrent callers share the same in-flight future. The first caller
  /// gets `mutexAcquiredImmediately: true`; subsequent callers get `false`
  /// and piggy-back on the same future.
  ///
  /// On [RefreshSuccess], the new tokens are already written to
  /// [StorageService] before this future resolves — callers should NOT
  /// write the response back to storage themselves. They may want to
  /// reschedule proactive refresh against the new expiry, but the token
  /// write is the coordinator's responsibility.
  ///
  /// [reason] is recorded in breadcrumbs (`access_token_expired`,
  /// `got_401`, `preemptive`, `manual`, etc.) so we can tell why a refresh
  /// fired in post-hoc analysis.
  ///
  /// [rejectedAccessToken] (PROD-2168 Phase 2 Codex [P1]) — for `got_401`
  /// callers, the access token the BE just rejected (read from the
  /// FAILED request's `Authorization` header, NOT from current storage
  /// — storage may have already rotated by the time onError runs).
  /// The pre/post-lock synthesis check uses this as one of two valid
  /// state-change signals: synthesize if the stored token differs from
  /// [rejectedAccessToken] (another tab rotated AND we know it), OR
  /// if `token_generation` advanced during this call. Pass `null` for
  /// proactive callers (`preemptive`, `manual`, `access_token_expired`)
  /// — they fall back to the generation discriminator alone. **Bare
  /// freshness is no longer sufficient** for any caller (Codex round 3
  /// [P1] — caused a 0-delay scheduler loop).
  Future<CoordinatedRefreshResult> getRefreshedAccessToken({
    required String reason,
    String? rejectedAccessToken,
  }) async {
    final wasInflight = _inflight != null;
    _awaiterCount++;
    final stopwatch = Stopwatch()..start();

    // Local single-flight bracket. Across tabs the cross-tab lock
    // serializes; within this tab the Completer pattern coalesces
    // concurrent callers. No await between the null-check and assignment
    // — Dart event loop guarantees no interleaving here.
    //
    // PROD-2168 Phase 2 followup: piggy-backers must see the SAME
    // context the leader populated (crossTabRole, lockWaitDuration,
    // doubleCheckShortCircuit). Store as a field while _inflight is
    // non-null and capture by reference at call entry — captured refs
    // remain valid even after a subsequent refresh reassigns the field.
    if (_inflight == null) {
      _inflightContext = _LocalRefreshContext();
      _inflight =
          _doRefreshCrossTab(
            reason: reason,
            rejectedAccessToken: rejectedAccessToken,
            context: _inflightContext!,
          ).whenComplete(() {
            _inflight = null;
          });
    }
    final context = _inflightContext!;

    try {
      final outcome = await _inflight!;
      stopwatch.stop();
      return CoordinatedRefreshResult(
        outcome: outcome,
        mutexAcquiredImmediately: !wasInflight,
        duration: stopwatch.elapsed,
        crossTabRole: context.crossTabRole,
        lockWaitDuration: context.lockWaitDuration,
        doubleCheckShortCircuit: context.doubleCheckShortCircuit,
      );
    } catch (e, st) {
      // PROD-3143 — containment: no exception may escape the coordinator.
      // Callers treat an escaped throw as a fatal auth failure (the
      // interceptor's defensive catch used to clear tokens on it). An
      // unexpected throw proves nothing about token validity, so map it
      // to RefreshTransient: tokens preserved, next call re-attempts.
      stopwatch.stop();
      unawaited(Sentry.captureException(e, stackTrace: st));
      _diagnostics.addBreadcrumb(
        'refresh.coordinator_exception_contained',
        data: {'error_type': '${e.runtimeType}', 'reason': reason},
      );
      _tokenRefreshService.resetToIdle(); // reset state, preserve tokens
      return CoordinatedRefreshResult(
        outcome: const RefreshTransient(),
        mutexAcquiredImmediately: !wasInflight,
        duration: stopwatch.elapsed,
        crossTabRole: context.crossTabRole,
        lockWaitDuration: context.lockWaitDuration,
        doubleCheckShortCircuit: context.doubleCheckShortCircuit,
      );
    } finally {
      _awaiterCount--;
    }
  }

  /// Dispose all cross-tab listeners. Idempotent. Coordinator is
  /// provider-scoped so this is rare in practice; tests rely on it.
  void dispose() {
    for (final sub in _crossTabSubscriptions) {
      sub.cancel();
    }
    _crossTabSubscriptions.clear();
    _crossTabSync.dispose();
  }

  // ============ Private — the actual refresh ============

  Future<RefreshOutcome> _doRefreshCrossTab({
    required String reason,
    required _LocalRefreshContext context,
    String? rejectedAccessToken,
  }) async {
    // ---- 1. Origin-wide transient cooldown check (Codex 2.A.10 +
    // [P2] cross-tab cooldown via BroadcastChannel). ----
    final cooldownAt = _effectiveCooldownAt();
    if (cooldownAt != null) {
      final ageMs = DateTime.now().difference(cooldownAt).inMilliseconds;
      _emitTransientCooldownHit(ageMs);
      _tokenRefreshService.resetToIdle(); // reset state, preserve tokens
      return const RefreshTransient();
    }

    // ---- 2. Pre-lock double-check (Auth0 step 1). ----
    //
    // PROD-2168 Phase 2 — synthesis requires a state-change signal
    // regardless of caller `reason`. Bare expiry-based freshness is
    // not safe: for `got_401` it would retry the rejected token
    // (Codex round 1 [P1]); for `preemptive` it would loop the
    // proactive scheduler at 0 delay against the unchanged expiry
    // (Codex round 3 [P1]). The two valid signals — `tokenSignal`
    // (storage's access token differs from `rejectedAccessToken`)
    // OR `generationSignal` (token_generation advanced during this
    // call) — are enforced uniformly in `_trySynthesizeFromStorage`.
    // See docs/learnings/auth-refresh-synthesis-discriminator.md.
    final initialGeneration = await _storageService.getTokenGeneration();
    context.initialGeneration = initialGeneration;

    final preLockSynthesized = await _trySynthesizeFromStorage(
      stage: 'pre_lock',
      callerReason: reason,
      initialGeneration: initialGeneration,
      rejectedAccessToken: rejectedAccessToken,
    );
    if (preLockSynthesized != null) {
      context.doubleCheckShortCircuit = true;
      context.crossTabRole = LockRole.fallback;
      context.lockWaitDuration = Duration.zero;
      // PROD-2168 Phase 2 followup — match post-lock synthesis: setting
      // _lastRefreshSuccessAt lets PROD-2095 Decision 14's smoke
      // detector (`recentlySucceededRefresh`) flag the
      // FLUTTER-8D-style race when a session-loss event fires within
      // 10s of any synthesized success.
      _lastRefreshSuccessAt = DateTime.now();
      _tokenRefreshService.resetToIdle();
      _emitDoubleCheckShortCircuit(stage: 'pre_lock', reason: reason);
      return preLockSynthesized;
    }

    // ---- 3. Acquire the cross-tab lock. ----
    final lockOutcome = await _crossTabSync.withLock<RefreshOutcome>(
      _kRefreshLockName,
      () => _runUnderLock(
        reason: reason,
        context: context,
        rejectedAccessToken: rejectedAccessToken,
      ),
      waitTimeout: _kLockWaitTimeout,
    );

    context.lockWaitDuration = lockOutcome.waitDuration;

    if (lockOutcome.timedOut) {
      _emitFollowerWaitTimeout(lockOutcome.waitDuration.inMilliseconds);
      context.crossTabRole = LockRole.follower;
      _tokenRefreshService.resetToIdle(); // preserve tokens
      return const RefreshTransient();
    }

    context.crossTabRole = lockOutcome.role;
    // `LockOutcome.value` is `T?`, not an `AsyncValue` — the lint pattern
    // misclassifies it. The `!` is already guarded by the `timedOut` early
    // return above (which is the only path that leaves `value` null).
    final outcome =
        lockOutcome.value!; // gstack:allow check-error-handling value-bang
    _emitRoleBreadcrumb(context: context, reason: reason);
    return outcome;
  }

  /// Runs inside the held cross-tab lock. Performs the post-lock
  /// double-check, the actual POST if needed, and broadcasts completion
  /// or invalidation to other tabs.
  Future<RefreshOutcome> _runUnderLock({
    required String reason,
    required _LocalRefreshContext context,
    String? rejectedAccessToken,
  }) async {
    // Codex 2.A.2 (post-lock double-check) — invalidate cache before
    // re-reading so a previous leader's write inside this same browser
    // profile is observed.
    _storageService.invalidateAccessTokenCache(reason: 'lock_acquired');

    // Codex 2.A.9 — if another tab just broadcast `refresh-invalid`, do
    // NOT re-POST. Return RefreshInvalid and let the interceptor's F14
    // gate suppress the follower's session-loss Sentry event.
    final invalidNotice = _invalidNotifiedAt;
    if (invalidNotice != null &&
        DateTime.now().difference(invalidNotice) < _invalidNoticeWindow) {
      _emitInvalidShortCircuit(
        ageMs: DateTime.now().difference(invalidNotice).inMilliseconds,
      );
      _tokenRefreshService.onRefreshFailed();
      return const RefreshInvalid();
    }

    final postLockSynthesized = await _trySynthesizeFromStorage(
      stage: 'post_lock',
      callerReason: reason,
      initialGeneration: context.initialGeneration,
      rejectedAccessToken: rejectedAccessToken,
    );
    if (postLockSynthesized != null) {
      context.doubleCheckShortCircuit = true;
      _emitDoubleCheckShortCircuit(stage: 'post_lock', reason: reason);
      _lastRefreshSuccessAt = DateTime.now();
      _tokenRefreshService.resetToIdle();
      return postLockSynthesized;
    }

    // ---- 4. POST. ----
    // Pass initialGeneration as expectedGeneration so saveRotatedTokens
    // rejects clobbering a newer rotation in the no-lock fallback case
    // (two tabs racing without Web Locks). The cross-tab lock prevents
    // this in the happy path; the guard is defense-in-depth.
    final outcome = await _postRefresh(
      reason: reason,
      expectedGeneration: context.initialGeneration,
    );

    switch (outcome) {
      case RefreshSuccess():
        // Use the generation produced by saveRotatedTokens directly
        // when available — re-reading from storage races against any
        // other tab that may have rotated past us in the few
        // microseconds since.
        final gen =
            _lastWrittenGeneration ??
            await _storageService.getTokenGeneration();
        _crossTabSync.notifyRefreshComplete(generation: gen);
      case RefreshInvalid():
        _crossTabSync.notifyRefreshInvalid();
      case RefreshTransient():
        final now = DateTime.now();
        await _storageService.setRefreshTransientCooldownAt(now);
        final until = now.add(_storageService.refreshTransientCooldownWindow);
        final untilMs = until.millisecondsSinceEpoch;
        // Codex [P2] — broadcast so other tabs honor the cooldown
        // without depending on their SharedPreferences cache picking
        // up the write.
        _crossTabSync.notifyRefreshTransient(untilMs: untilMs);
        // Codex round-2 [P2] — also persist to a known localStorage
        // key so other tabs receive a `storage` event AND can read the
        // value back uncached. Covers the case where Web Locks works
        // but BroadcastChannel construction failed.
        _crossTabSync.persistCooldownUntil(untilMs: untilMs);
    }

    return outcome;
  }

  /// Pre/post-lock double-check helper. Returns a synthesized
  /// [RefreshSuccess] when storage holds a fresh access token that's
  /// PROVABLY safe to use; null when the caller should fall through to
  /// a POST.
  ///
  /// PROD-2168 Phase 2 Codex [P1] round 3 — "fresh enough by expiry"
  /// is NOT sufficient on its own. Proactive scheduling fires 5min
  /// before expiry against an access token that's still ~5min from
  /// expiring; synthesizing in that case returned the same token with
  /// the same expiry and TokenSchedulerService re-armed the timer for
  /// `Duration.zero`, busy-looping until the token actually expired.
  ///
  /// Synthesis is safe ONLY when state has changed in our favor since
  /// this refresh attempt started. Two valid signals:
  ///
  /// 1. **Token differs from the one the caller observed** — for
  ///    `got_401`, [rejectedAccessToken] is the bearer the BE refused.
  ///    If storage now holds a different value, another tab rotated.
  /// 2. **Generation has advanced** — [initialGeneration] was captured
  ///    before locking. If `currentGeneration > initialGeneration`, a
  ///    rotation landed during our wait.
  ///
  /// Without either signal, the stored token is the same one that was
  /// in play when this call started. For `got_401` that's the rejected
  /// token; for `preemptive` it's the about-to-expire token; for
  /// `manual` / `access_token_expired` it's a caller asking us to
  /// actually rotate. All three resolve to POST.
  ///
  /// **Known partial-write corner case** (documented, not fixed):
  /// `saveRotatedTokens` writes access → expiry → refresh →
  /// `token_generation` LAST. If a leader tab crashes between the
  /// access-token write and the generation write, a follower can
  /// observe partial state: storage's access token differs from
  /// [rejectedAccessToken] (tokenSignal=true) but generation hasn't
  /// advanced (genSignal=false). The follower synthesizes from the
  /// new access token, but `refresh_token` in storage may still be
  /// the old value. Auto-recovers within one refresh cycle. The
  /// alternative (requiring tokenSignal AND genSignal) re-introduces
  /// the post-broadcast wasted-POST race in a much more common
  /// scenario, so we accept this as the lesser evil.
  Future<RefreshOutcome?> _trySynthesizeFromStorage({
    required String stage,
    required String callerReason,
    required int initialGeneration,
    String? rejectedAccessToken,
  }) async {
    final accessToken = await _storageService.getAccessToken();
    final expiresAt = await _storageService.getTokenExpiresAt();
    if (accessToken == null || accessToken.isEmpty || expiresAt == null) {
      return null;
    }
    final now = DateTime.now();
    if (expiresAt.isBefore(now.add(_kFreshAccessTokenMargin))) {
      // Token is expired or about to expire — must POST.
      return null;
    }

    // Codex [P1] round 3 — require a state-change signal regardless of
    // reason. Bare freshness alone is not safe (see preemptive-loop bug
    // in round 2).
    final tokenSignal =
        rejectedAccessToken != null && accessToken != rejectedAccessToken;
    final currentGeneration = await _storageService.getTokenGeneration();
    final generationSignal = currentGeneration > initialGeneration;

    if (!tokenSignal && !generationSignal) {
      _diagnostics.addBreadcrumb(
        'refresh.synth_skipped_no_state_change',
        data: {
          'stage': stage,
          'reason': callerReason,
          'initial_generation': initialGeneration,
          'current_generation': currentGeneration,
          'had_rejected_token': rejectedAccessToken != null,
        },
      );
      return null;
    }

    final refreshToken = await _storageService.getRefreshToken();
    final synthesized = RefreshResponse(
      accessToken: accessToken,
      tokenType: 'bearer',
      expiresAt: expiresAt,
      refreshToken: refreshToken,
    );
    return RefreshSuccess(synthesized);
  }

  Future<RefreshOutcome> _postRefresh({
    required String reason,
    int? expectedGeneration,
  }) async {
    const maxRetries = 2;

    _tokenRefreshService.onRefreshStarted();

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      Map<String, dynamic>? bodyData;
      try {
        final refreshDio = _refreshDioFactory?.call() ?? _buildRefreshDio();

        // Fallback to body-based refresh token when cookies are missing
        // (web third-party cookie blocking; native cookie-jar miss).
        //
        // PROD-2168 retrospective: previously we tried to gate this whole
        // block on `!kIsWeb` (web cookie-only). Safari ITP staging test
        // confirmed cross-site HttpOnly cookies are blocked from being
        // attached, so cookie-only is structurally impossible without a
        // same-origin BE proxy. We restore the body fallback for ALL
        // platforms; Pattern B (stale body beats fresh cookie) gets fixed
        // BE-side by flipping precedence from `body or cookie` to
        // `cookie or body` in `auth.py:1747`.
        final hasCookieToken = await _hasCookies();
        if (!hasCookieToken) {
          final refreshToken = await _storageService.getRefreshToken();
          if (refreshToken != null) {
            bodyData = {'refresh_token': refreshToken};
          }
          _diagnostics.addBreadcrumb(
            'refresh_token_lookup',
            data: {
              'has_stored_token': refreshToken != null,
              'has_cookies': false,
              'body_will_send_token': bodyData != null,
              'platform': kIsWeb ? 'web' : 'native',
              'attempt': attempt,
              'reason': reason,
            },
          );
        }

        final response = await refreshDio.post(
          '${ApiConstants.apiPrefix}/auth/refresh',
          data: bodyData,
        );

        if (response.statusCode == 200 && response.data != null) {
          final data = response.data;
          if (data is Map<String, dynamic>) {
            final accessToken = data['access_token'];
            if (accessToken is String && accessToken.isNotEmpty) {
              final refreshResponse = RefreshResponse.fromJson(data);
              await _persistRotation(
                refreshResponse,
                expectedGeneration: expectedGeneration,
              );
              _lastRefreshSuccessAt = DateTime.now();
              // Clear any prior transient cooldown — BE is healthy again.
              unawaited(_storageService.clearRefreshTransientCooldown());
              _tokenRefreshService.resetToIdle();
              return RefreshSuccess(refreshResponse);
            }
          }
        }

        // 200-with-malformed-body or any non-200 — server answered, but not
        // with a usable token. Treat as invalid.
        _diagnostics.addBreadcrumb(
          'refresh_non_200',
          data: {
            'status_code': response.statusCode,
            'body_had_token': bodyData != null,
            'attempt': attempt,
            'reason': reason,
          },
        );
        _tokenRefreshService.onRefreshFailed();
        final (code, detail) = _extractInvalidMeta(response.data);
        return RefreshInvalid(
          reason: 'non_200_or_malformed',
          statusCode: response.statusCode,
          backendErrorCode: code,
          detail: detail,
        );
      } on DioException catch (e) {
        final isRetryable = _isRetryableError(e);
        _diagnostics.addBreadcrumb(
          'refresh_dio_error',
          data: {
            'type': e.type.name,
            'status_code': e.response?.statusCode,
            'is_retryable': isRetryable,
            'body_had_token': bodyData != null,
            'attempt': attempt,
            'reason': reason,
          },
        );

        if (isRetryable && attempt < maxRetries) {
          await Future.delayed(_refreshRetryDelay * (attempt + 1));
          continue;
        }

        if (isRetryable) {
          // Transient — keep tokens (PROD-1506). User stays signed in;
          // next API call will re-attempt.
          _tokenRefreshService.resetToIdle(); // reset state
          return const RefreshTransient();
        }
        _tokenRefreshService.onRefreshFailed();
        final (code, detail) = _extractInvalidMeta(e.response?.data);
        return RefreshInvalid(
          reason: 'non_retryable_dio',
          statusCode: e.response?.statusCode,
          backendErrorCode: code,
          detail: detail,
        );
      } catch (_) {
        // Unexpected non-Dio error — treat as invalid (preserves prior
        // behavior in the old `RefreshInterceptor._refreshToken`).
        _tokenRefreshService.onRefreshFailed();
        return const RefreshInvalid(reason: 'unexpected_error');
      }
    }

    // Loop fall-through — defensive; not expected in practice.
    _tokenRefreshService.onRefreshFailed();
    return const RefreshInvalid(reason: 'fallthrough');
  }

  /// Best-effort, non-throwing extraction of `(backendErrorCode, detail)` from
  /// an `/auth/refresh` error body. Handles both the current unstructured
  /// shape (`{"detail": "Invalid or expired refresh token"}` → returns the
  /// string as `detail`) and a future structured shape
  /// (`{"detail": {"error_code": ...}}` or top-level `{"error_code": ...}` →
  /// returns the code). The detail string is length-capped so an HTML/error
  /// page body can't bloat the Sentry breadcrumb.
  static (String?, String?) _extractInvalidMeta(dynamic data) {
    try {
      if (data is Map) {
        final detail = data['detail'];
        if (detail is Map) {
          final code = detail['error_code'];
          return (code is String ? code : null, null);
        }
        if (detail is String) {
          return (
            null,
            detail.length > 120 ? detail.substring(0, 120) : detail,
          );
        }
        final topCode = data['error_code'];
        if (topCode is String) return (topCode, null);
      }
    } catch (_) {}
    return (null, null);
  }

  /// PROD-2168 Phase 2 — persist a successful rotation via the atomic
  /// `saveRotatedTokens` path. Falls back to the per-key writes when the
  /// response is missing an `expiresAt` (the BE always provides it in
  /// practice, but the response model declares it nullable).
  /// Tracks the generation produced by the most recent successful
  /// rotation write. Read by [_runUnderLock] when broadcasting
  /// `refresh-complete` so other tabs receive the exact generation we
  /// just committed (rather than re-reading storage, which races with
  /// any other tab that may have already rotated past us).
  int? _lastWrittenGeneration;

  Future<void> _persistRotation(
    RefreshResponse response, {
    int? expectedGeneration,
  }) async {
    // PR-599-followup Codex [P2] — clear the broadcast marker so a later
    // rotation attempt that falls into the legacy path or the
    // StaleRotationWriteException catch can't broadcast a generation
    // committed by an earlier rotation in this tab's lifetime. Both
    // fallback paths leave `_lastWrittenGeneration` untouched on
    // purpose; the broadcast in `_runUnderLock` then falls back to a
    // fresh `getTokenGeneration()` read of whatever is currently
    // committed in storage.
    _lastWrittenGeneration = null;
    final expiresAt = response.expiresAt;
    if (expiresAt != null) {
      try {
        final newGen = await _storageService.saveRotatedTokens(
          accessToken: response.accessToken,
          expiresAt: expiresAt,
          refreshToken: response.refreshToken,
          expectedGeneration: expectedGeneration,
          caller: 'refresh_coordinator',
        );
        _lastWrittenGeneration = newGen;
        // setRefreshTokenFingerprint is a Sentry diagnostic; a failure
        // here must not trigger the legacy-fallback write path.
        if (response.refreshToken != null) {
          try {
            await _diagnostics.setRefreshTokenFingerprint(
              response.refreshToken,
            );
          } catch (_) {
            // Diagnostic-only — swallow.
          }
        }
        return;
      } on StaleRotationWriteException {
        // PROD-2168 Phase 2 followup — another tab already committed
        // a newer rotation between our pre-lock initialGeneration
        // capture and this write. Storage holds their newer state;
        // do NOT fall through to legacy `saveAccessToken` (which
        // would clobber it). Invalidate our in-memory cache so the
        // next read picks up the newer state, and return — the
        // caller's outcome stands but storage already reflects a
        // chain step ahead of what we POSTed.
        _storageService.invalidateAccessTokenCache(
          reason: 'stale_rotation_write_rejected',
        );
        return;
      } catch (_) {
        // Other failures fall through to legacy per-key writes —
        // saveRotatedTokens captures its own Sentry event on failure.
      }
    }
    // Legacy path: no expiry available, or atomic write threw. Keep
    // pre-Phase-2 behavior so the rotation doesn't silently drop.
    await _storageService.saveAccessToken(
      response.accessToken,
      expiresAt: response.expiresAt,
    );
    if (response.refreshToken != null) {
      await _storageService.saveRefreshToken(response.refreshToken!);
      await _diagnostics.setRefreshTokenFingerprint(response.refreshToken);
    }
  }

  /// PROD-3933 — exposes the built refresh Dio so tests can assert the outgoing
  /// static headers (notably `X-Client-Platform`) without a network round-trip.
  /// Building the Dio has no side effects; the injected `refreshDioFactory`
  /// bypasses `_buildRefreshDio`, so this is the only way to cover the real wiring.
  @visibleForTesting
  Dio debugBuildRefreshDio() => _buildRefreshDio();

  Dio _buildRefreshDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          // PROD-3933 — highest-precedence native-ness signal for the backend's
          // sliding refresh-token lifetime (365d native / 30d web). Without it,
          // 100% of native refreshes arrived `platform:null` and resolved via
          // the UA heuristic; the explicit header makes the 365d lifetime robust.
          'X-Client-Platform': clientPlatformHeader(),
          if (EnvironmentConfig.isDev) 'ngrok-skip-browser-warning': 'true',
        },
        extra: kIsWeb ? {'withCredentials': true} : null,
      ),
    );

    // PROD-2095 Decision 8 / Finding 11: refresh Dio must also carry
    // `X-Request-ID` for backend correlation. Wire the interceptor first
    // so it stamps the header before cookie attachment.
    dio.interceptors.add(
      RequestIdInterceptor(
        storageService: _storageService,
        diagnostics: _diagnostics,
        isRefreshInflight: () => isRefreshing,
        refreshQueueDepth: () => _awaiterCount,
      ),
    );

    // PROD-2131 — refresh Dio also needs X-App-Version so backend
    // `auth_diag refresh.*` events carry the FE build that produced them.
    // Adding it only to the main ApiClient Dio would leave the most
    // diagnostic-critical events (refresh.enter / refresh.validate /
    // refresh.rotate_create / refresh.rotate_delete) with app_version=null.
    dio.interceptors.add(VersionHeaderInterceptor());

    final jar = _cookieJar;
    if (!kIsWeb && jar != null) {
      dio.interceptors.add(CookieManager(jar));
    }
    configureWebCredentials(dio);

    return dio;
  }

  bool _isRetryableError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    if (e.type == DioExceptionType.connectionError) {
      return true;
    }
    final statusCode = e.response?.statusCode;
    if (statusCode != null && statusCode >= 500) {
      return true;
    }
    return false;
  }

  Future<bool> _hasCookies() async {
    final jar = _cookieJar;
    if (kIsWeb || jar == null) return false;
    try {
      final baseUri = Uri.parse(_baseUrl);
      final cookies = await jar.loadForRequest(baseUri);
      return cookies.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ============ Sentry emit helpers ============

  void _emitTransientCooldownHit(int ageMs) {
    // PROD-2168 Phase 2 followup — downgraded from captureMessage to
    // breadcrumb. Sustained BE transient failures (multi-tab × multi-401
    // × 10s window) can produce many hits per minute per user; emitting
    // each as a Sentry event would generate quota noise. Breadcrumbs
    // attach to the next real event for free and give the same diagnostic
    // chain when something breaks.
    _diagnostics.addBreadcrumb(
      'auth.refresh.transient_cooldown_hit',
      data: {
        'cooldown_age_ms': ageMs,
        'cooldown_window_ms':
            _storageService.refreshTransientCooldownWindow.inMilliseconds,
      },
    );
  }

  void _emitFollowerWaitTimeout(int waitMs) {
    Sentry.captureMessage(
      'auth.inflight_sync.follower_wait_timeout',
      level: SentryLevel.warning,
      withScope: (scope) {
        scope.setExtra('wait_ms', waitMs);
        scope.setExtra('lock_timeout_ms', _kLockWaitTimeout.inMilliseconds);
      },
    );
  }

  void _emitDoubleCheckShortCircuit({
    required String stage,
    required String reason,
  }) {
    _diagnostics.addBreadcrumb(
      'refresh.double_check_short_circuit',
      data: {'stage': stage, 'reason': reason},
    );
  }

  void _emitInvalidShortCircuit({required int ageMs}) {
    _diagnostics.addBreadcrumb(
      'refresh.cross_tab_invalid_short_circuit',
      data: {'invalid_notice_age_ms': ageMs},
    );
  }

  void _emitRoleBreadcrumb({
    required _LocalRefreshContext context,
    required String reason,
  }) {
    _diagnostics.addBreadcrumb(
      'refresh.cross_tab_role',
      data: {
        'role': context.crossTabRole.name,
        'lock_wait_ms': context.lockWaitDuration.inMilliseconds,
        'double_check_short_circuit': context.doubleCheckShortCircuit,
        'reason': reason,
      },
    );
  }
}

/// Per-call scratch space. Lets `_doRefreshCrossTab` and `_runUnderLock`
/// thread the cross-tab role + wait duration + short-circuit flag back
/// to [getRefreshedAccessToken] without changing the [RefreshOutcome]
/// sealed-class shape (which is shared with non-coordinator callers).
class _LocalRefreshContext {
  LockRole crossTabRole = LockRole.fallback;
  Duration lockWaitDuration = Duration.zero;
  bool doubleCheckShortCircuit = false;

  /// `token_generation` observed at the very start of this refresh call.
  /// Used by the [`_trySynthesizeFromStorage`] generation-advanced
  /// discriminator (Codex [P1] — pre-lock synthesis must not return
  /// the same token the BE just rejected on a `got_401` call).
  int initialGeneration = 0;
}
