import 'dart:async';

import 'cross_tab_sync.dart';

/// Default platform implementation. Used on native (no multi-tab problem)
/// and as the no-op fallback when [EnvironmentConfig.authInflightSyncEnabled]
/// is false on web. Every method short-circuits to the [LockRole.fallback]
/// behavior — callers run immediately, no listeners, no messages.
CrossTabSync createCrossTabSync({required bool enabled}) {
  return _StubCrossTabSync();
}

class _StubCrossTabSync implements CrossTabSync {
  @override
  bool get locksAvailable => false;

  @override
  bool get channelAvailable => false;

  @override
  Future<LockOutcome<T>> withLock<T>(
    String lockName,
    Future<T> Function() callback, {
    Duration? waitTimeout,
  }) async {
    final value = await callback();
    return LockOutcome(
      role: LockRole.fallback,
      timedOut: false,
      waitDuration: Duration.zero,
      value: value,
    );
  }

  @override
  void notifyRefreshComplete({required int generation}) {}

  @override
  void notifyRefreshInvalid() {}

  @override
  void notifyRefreshTransient({required int untilMs}) {}

  @override
  void persistCooldownUntil({required int untilMs}) {}

  @override
  String get cooldownStorageKey => '__heyl_auth_cooldown_stub';

  @override
  DateTime? readPersistedCooldown() => null;

  @override
  StreamSubscription<CrossTabMessage> listenMessages(
    void Function(CrossTabMessage message) onMessage,
  ) {
    return const Stream<CrossTabMessage>.empty().listen(onMessage);
  }

  @override
  StreamSubscription<String?> listenStorageKey(
    String storageKey,
    void Function(String? newValue) onChange,
  ) {
    return const Stream<String?>.empty().listen(onChange);
  }

  @override
  void dispose() {}
}
