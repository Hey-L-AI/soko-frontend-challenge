import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/api_provider.dart' show refreshCoordinatorProvider;
import '../config/environment.dart';
import '../utils/page_visibility_stub.dart'
    if (dart.library.html) '../utils/page_visibility_web.dart'
    if (dart.library.io) '../utils/page_visibility_native.dart';
import 'auth_diagnostics_service.dart';
import 'refresh_coordinator.dart';

/// Duration before token expiry at which to trigger proactive refresh
/// Using 5 minutes to give plenty of buffer for network issues
const _refreshBufferDuration = Duration(minutes: 5);

/// Minimum time before attempting proactive refresh
/// Prevents refresh loops if the token is very short-lived
const _minRefreshInterval = Duration(minutes: 1);

/// Service that proactively refreshes tokens before they expire.
///
/// This service schedules token refresh based on the token's expiry time,
/// preventing users from experiencing 401 errors during normal usage.
///
/// PROD-2095: the actual `/auth/refresh` call is delegated to
/// [RefreshCoordinator] so the proactive refresh path shares the same
/// single-flight discipline as the reactive (401) path. Previously the
/// scheduler had its own Dio + refresh logic that could race with the
/// reactive interceptor on the same token.
class TokenSchedulerService {
  final RefreshCoordinator _coordinator;
  final AuthDiagnosticsService _diagnostics;

  Timer? _refreshTimer;
  bool _isPerformingProactiveRefresh = false;

  /// PROD-2168 Phase 2 Codex round-2 [P2] — disposer for the
  /// `visibilitychange` listener registered when a proactive refresh
  /// is suppressed on a hidden tab. Cleared when the listener fires
  /// (or on `dispose()` / `cancelRefresh()`).
  void Function()? _visibilityDisposer;

  TokenSchedulerService({
    required RefreshCoordinator coordinator,
    required AuthDiagnosticsService diagnostics,
  }) : _coordinator = coordinator,
       _diagnostics = diagnostics;

  /// Schedule proactive token refresh based on expiry time
  void scheduleRefresh(DateTime expiresAt) {
    // Cancel any existing timer (also clears any pending visibility
    // listener — we're explicitly scheduling, not waiting for one).
    _refreshTimer?.cancel();
    _visibilityDisposer?.call();
    _visibilityDisposer = null;

    final now = DateTime.now();
    final timeUntilExpiry = expiresAt.difference(now);

    // Calculate when to refresh (5 minutes before expiry)
    var refreshIn = timeUntilExpiry - _refreshBufferDuration;

    // Ensure minimum refresh interval
    if (refreshIn < _minRefreshInterval) {
      // If we're within the buffer zone, refresh soon but not immediately
      refreshIn = refreshIn.isNegative ? Duration.zero : refreshIn;
    }

    // Don't schedule if already expired
    if (timeUntilExpiry.isNegative) {
      return;
    }

    _refreshTimer = Timer(refreshIn, () {
      _performProactiveRefresh();
    });
  }

  /// Cancel any scheduled refresh
  void cancelRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _visibilityDisposer?.call();
    _visibilityDisposer = null;
  }

  /// Perform proactive token refresh via the coordinator.
  ///
  /// Returns `true` if the refresh succeeded, `false` otherwise. The
  /// coordinator handles single-flight discipline — if a reactive refresh
  /// is already in flight when the scheduler fires, this call piggy-backs
  /// on it instead of starting a parallel POST.
  Future<bool> _performProactiveRefresh() async {
    if (_isPerformingProactiveRefresh) {
      // Local guard against double-fire from a stuck timer; the coordinator
      // would coalesce them anyway but we save the call.
      return false;
    }

    // PROD-2168 Phase 2.D — suppress proactive refresh on hidden tabs.
    // Gated on the kill switch so behavior is unchanged when Phase 2 is
    // off. Reactive (401-driven) refresh stays unconditionally enabled
    // — background API calls already in flight need to recover when the
    // tab returns to the foreground.
    //
    // Codex round-2 [P2] fix: the timer that scheduled this call has
    // already been consumed. If we just return, the token will expire
    // silently and the next reactive 401 (or app foreground) will be
    // the first chance to recover. Instead, register a one-shot
    // `visibilitychange` listener that re-attempts the refresh as soon
    // as the user returns to the tab.
    if (EnvironmentConfig.authInflightSyncEnabled && isPageHidden()) {
      _diagnostics.addBreadcrumb(
        'proactive_refresh_suppressed_hidden_tab',
        data: {'platform': 'web'},
      );
      // Drop any prior visibility listener — we only need one outstanding.
      _visibilityDisposer?.call();
      _visibilityDisposer = onPageVisible(() {
        _visibilityDisposer = null;
        _diagnostics.addBreadcrumb(
          'proactive_refresh_resumed_visibility',
          data: {'platform': 'web'},
        );
        // Fire-and-forget; await would block the visibilitychange
        // event handler in some browsers.
        unawaited(_performProactiveRefresh());
      });
      return false;
    }

    _isPerformingProactiveRefresh = true;

    try {
      _diagnostics.logProactiveRefreshAttempt();
      final fpBefore = await _coordinator.currentRefreshTokenFingerprint();
      final result = await _coordinator.getRefreshedAccessToken(
        reason: 'preemptive',
      );

      // PROD-2095 AC #2 — proactive callers have no triggering request id.
      _diagnostics.logRefreshStart(
        requestId: null,
        refreshTokenFingerprint: fpBefore,
        reason: 'preemptive',
        mutexAcquiredImmediately: result.mutexAcquiredImmediately,
      );

      switch (result.outcome) {
        case RefreshSuccess(:final response):
          _diagnostics.logProactiveRefreshResult(success: true);
          _diagnostics.logRefreshResult(
            requestId: null,
            status: 'success',
            durationMs: result.duration.inMilliseconds,
            newRefreshTokenFingerprint: refreshTokenFingerprint(
              response.refreshToken,
            ),
          );
          // Schedule the next refresh against the new expiry.
          if (response.expiresAt != null) {
            scheduleRefresh(response.expiresAt!);
          }
          return true;
        case RefreshInvalid():
          _diagnostics.logProactiveRefreshResult(
            success: false,
            errorType: 'token_invalid',
          );
          _diagnostics.logRefreshResult(
            requestId: null,
            status: 'invalid',
            durationMs: result.duration.inMilliseconds,
          );
          return false;
        case RefreshTransient():
          // Don't escalate — coordinator already preserved tokens
          // (PROD-1506). The next API call will re-attempt.
          _diagnostics.logProactiveRefreshResult(
            success: false,
            errorType: 'transient',
          );
          _diagnostics.logRefreshResult(
            requestId: null,
            status: 'transient',
            durationMs: result.duration.inMilliseconds,
          );
          return false;
      }
    } catch (e) {
      _diagnostics.logProactiveRefreshResult(
        success: false,
        errorType: '${e.runtimeType}',
      );
      return false;
    } finally {
      _isPerformingProactiveRefresh = false;
    }
  }

  /// Dispose the scheduler and cancel any timers + visibility listeners
  void dispose() {
    cancelRefresh();
  }
}

/// Provider for TokenSchedulerService
final tokenSchedulerServiceProvider = Provider<TokenSchedulerService>((ref) {
  final coordinator = ref.watch(refreshCoordinatorProvider);
  final diagnostics = ref.watch(authDiagnosticsProvider);

  final scheduler = TokenSchedulerService(
    coordinator: coordinator,
    diagnostics: diagnostics,
  );

  // Clean up when provider is disposed
  ref.onDispose(() {
    scheduler.dispose();
  });

  return scheduler;
});
