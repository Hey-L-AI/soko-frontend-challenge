import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Token refresh status
enum TokenRefreshStatus {
  /// No refresh in progress
  idle,

  /// Token refresh is currently happening
  refreshing,

  /// Refresh failed definitively (not retryable)
  failed,
}

/// State for token refresh operations
class TokenRefreshState {
  final TokenRefreshStatus status;
  final int failureCount;

  const TokenRefreshState({
    this.status = TokenRefreshStatus.idle,
    this.failureCount = 0,
  });

  /// Whether a token refresh is currently in progress
  bool get isRefreshing => status == TokenRefreshStatus.refreshing;

  /// Whether the refresh has definitively failed
  bool get hasFailed => status == TokenRefreshStatus.failed;

  TokenRefreshState copyWith({TokenRefreshStatus? status, int? failureCount}) {
    return TokenRefreshState(
      status: status ?? this.status,
      failureCount: failureCount ?? this.failureCount,
    );
  }
}

/// Service for coordinating token refresh state across the app.
///
/// This service tracks when a token refresh is in progress, allowing
/// other parts of the app (like the router) to avoid reacting to
/// temporary "unauthenticated" states during refresh.
class TokenRefreshService extends StateNotifier<TokenRefreshState> {
  TokenRefreshService() : super(const TokenRefreshState());

  /// Called when token refresh starts
  void onRefreshStarted() {
    state = state.copyWith(status: TokenRefreshStatus.refreshing);
  }

  /// Reset to idle and zero the failure count.
  ///
  /// Called after a successful refresh AND from the coordinator's
  /// fail-open containment catch (RefreshTransient = nothing proven).
  void resetToIdle() {
    state = const TokenRefreshState(
      status: TokenRefreshStatus.idle,
      failureCount: 0,
    );
  }

  /// Called when token refresh fails definitively
  void onRefreshFailed() {
    state = state.copyWith(
      status: TokenRefreshStatus.failed,
      failureCount: state.failureCount + 1,
    );
  }

  /// Reset state (e.g., after successful login or logout)
  void reset() {
    state = const TokenRefreshState();
  }
}

/// Provider for TokenRefreshService
final tokenRefreshServiceProvider =
    StateNotifierProvider<TokenRefreshService, TokenRefreshState>((ref) {
      return TokenRefreshService();
    });
