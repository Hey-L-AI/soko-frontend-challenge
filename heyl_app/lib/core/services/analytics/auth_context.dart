/// Application authentication at the time of an analytics action. This is
/// independent of PostHog's asynchronous SDK identification state.
enum AnalyticsAuthState {
  unknown('unknown'),
  loggedOut('logged_out'),
  loggedIn('logged_in');

  const AnalyticsAuthState(this.wire);
  final String wire;
}

/// Immutable action identity. The generation also catches A → logout → A,
/// where comparing account IDs alone would accept a stale completion.
class AnalyticsActionContext {
  const AnalyticsActionContext._(this.authState, this.userId, this.generation);

  final AnalyticsAuthState authState;
  final String? userId;
  final int generation;

  Map<String, Object> get properties => {
    'auth_state': authState.wire,
    'analytics_context_version': 1,
    if (userId != null) 'auth_user_id': userId!,
  };
}

/// Owned by the analytics facade; authentication pushes updates into it.
/// Analytics never reads auth providers, avoiding an auth ↔ analytics cycle.
class AnalyticsAuthContext {
  AnalyticsActionContext _current = const AnalyticsActionContext._(
    AnalyticsAuthState.unknown,
    null,
    0,
  );

  AnalyticsActionContext get current => _current;
  bool isCurrent(AnalyticsActionContext action) => identical(action, _current);

  void update(AnalyticsAuthState state, String? userId) {
    final account = state == AnalyticsAuthState.loggedIn ? userId : null;
    if (_current.authState == state && _current.userId == account) return;
    _current = AnalyticsActionContext._(
      state,
      account,
      _current.generation + 1,
    );
  }
}
