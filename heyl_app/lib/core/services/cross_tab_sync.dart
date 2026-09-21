import 'dart:async';

/// PROD-2168 Phase 2 — cross-tab inflight refresh synchronization.
///
/// On the web, multiple tabs of the same browser profile can race
/// `/auth/refresh` against each other. The Web Locks API
/// (`navigator.locks.request`) lets us serialize them across tabs;
/// BroadcastChannel + the `storage` event let us notify other tabs to
/// invalidate their in-memory access-token cache without ever carrying
/// the token over a same-origin message bus.
///
/// On native (iOS/Android) there is no analogous primitive and the
/// problem doesn't exist (no multi-tab), so this abstraction is a no-op
/// there. Same for the web build when [EnvironmentConfig.authInflightSyncEnabled]
/// is false — the factory returns a stub.
abstract class CrossTabSync {
  /// True when the `navigator.locks` API is available AND the kill-switch
  /// flag is on AND we're on web. Read by [RefreshCoordinator] to set the
  /// `auth.inflight_sync.locks_available` Sentry tag once at init.
  bool get locksAvailable;

  /// True when `BroadcastChannel` is available AND the kill-switch flag
  /// is on AND we're on web. Distinct from [locksAvailable] because some
  /// embedded webviews ship one without the other.
  bool get channelAvailable;

  /// Run [callback] while holding the exclusive cross-tab lock named
  /// [lockName]. If [locksAvailable] is false, [callback] runs
  /// immediately (degraded "Phase 1 fallback" path — each tab refreshes
  /// independently, as it does pre-Phase 2).
  ///
  /// The returned [LockOutcome.role] tells the caller whether they ran
  /// as `leader` (held the lock, did the work), `follower` (waited for
  /// another tab and ran after the lock released), or `fallback` (no
  /// lock available; ran immediately).
  ///
  /// [waitTimeout], if provided, bounds how long this call will wait for
  /// the lock to become available. If the wait times out BEFORE the lock
  /// is granted, [LockOutcome.timedOut] is `true` and [callback] is NOT
  /// invoked — callers should return `RefreshTransient` and let a later
  /// API call retry. `LockManager.request({ signal })` cannot kill a
  /// running leader's callback, so this timeout only protects waiters.
  Future<LockOutcome<T>> withLock<T>(
    String lockName,
    Future<T> Function() callback, {
    Duration? waitTimeout,
  });

  /// Notify other tabs that a rotation completed and they should
  /// invalidate their access-token cache + re-read storage. NEVER carries
  /// tokens.
  void notifyRefreshComplete({required int generation});

  /// Notify other tabs that a refresh produced an invalid result (BE
  /// returned 4xx on a valid-looking token). Followers should
  /// short-circuit their own refresh attempts and propagate the invalid
  /// outcome.
  void notifyRefreshInvalid();

  /// PROD-2168 Phase 2 Codex [P2] — notify other tabs that this tab
  /// just observed a transient BE failure (5xx, network timeout) and
  /// is starting an origin-wide cooldown until [untilMs]. Other tabs
  /// short-circuit refresh attempts during the window.
  ///
  /// Uses BroadcastChannel because [StorageService.setRefreshTransientCooldownAt]
  /// writes through SharedPreferences, which caches per-tab in memory
  /// — other tabs wouldn't observe the SharedPreferences write until
  /// reload. The channel message gives followers an in-memory signal
  /// that doesn't depend on SharedPreferences cache invalidation.
  void notifyRefreshTransient({required int untilMs});

  /// PROD-2168 Phase 2 Codex round-2 [P2] — persist the cooldown
  /// timestamp to a known localStorage key (web) so other tabs receive
  /// a `storage` event AND can re-read the value directly, bypassing
  /// SharedPreferences cache. Belt-and-braces fallback for the case
  /// where Web Locks works but BroadcastChannel construction failed
  /// (the BroadcastChannel `notifyRefreshTransient` would otherwise be
  /// silently dropped). Native and stub implementations no-op.
  ///
  /// Stored at the key returned by [cooldownStorageKey] so callers
  /// can `listenStorageKey` to it.
  void persistCooldownUntil({required int untilMs});

  /// The localStorage key under which [persistCooldownUntil] writes
  /// the cooldown timestamp. Web returns the prefixed key
  /// (`heyl_auth_cooldown_until_ms`); native/stub return any sentinel
  /// since they never receive storage events anyway.
  String get cooldownStorageKey;

  /// Read the cooldown timestamp directly from the persistent backing
  /// (localStorage on web). Bypasses SharedPreferences cache so an
  /// already-open tab sees the latest value. Returns null when not set
  /// or invalid. Native/stub return null.
  DateTime? readPersistedCooldown();

  /// Subscribe to cross-tab messages. Returns a cancellable subscription.
  /// On platforms where the channel is unavailable, the stream is empty
  /// and the subscription is a no-op.
  StreamSubscription<CrossTabMessage> listenMessages(
    void Function(CrossTabMessage message) onMessage,
  );

  /// Subscribe to storage events on the [storageKey]. Used as a fallback
  /// channel for cache invalidation when BroadcastChannel construction
  /// fails — `storage` events work on every browser that supports
  /// `localStorage` (effectively all of them). Same-origin only; never
  /// echoed to the writing tab.
  StreamSubscription<String?> listenStorageKey(
    String storageKey,
    void Function(String? newValue) onChange,
  );

  /// Tear down all listeners and abort any pending ungranted lock
  /// requests. Must be called when the owning [RefreshCoordinator] is
  /// disposed or recreated; otherwise stale listeners pile up and a
  /// recreated coordinator can receive duplicate completions.
  void dispose();
}

/// Returned by [CrossTabSync.withLock].
class LockOutcome<T> {
  /// Role this caller played in the lock acquisition.
  final LockRole role;

  /// True when the caller hit the [waitTimeout] before the lock was
  /// granted. When `true`, [value] is `null` and [callback] was never
  /// invoked. Callers should return `RefreshTransient`.
  final bool timedOut;

  /// Time spent waiting for the lock. Always `Duration.zero` for
  /// `fallback` and `leader` paths where the lock was immediately
  /// available.
  final Duration waitDuration;

  /// The callback's return value. `null` when [timedOut] is true.
  final T? value;

  const LockOutcome({
    required this.role,
    required this.timedOut,
    required this.waitDuration,
    required this.value,
  });
}

/// Role played by a particular caller when acquiring the cross-tab lock.
///
/// - [leader]: held the lock and ran the callback. The "active" path.
/// - [follower]: waited for another tab's lock to release, then ran the
///   callback (typically: re-read storage, return synthesized result).
/// - [fallback]: lock API not available; ran the callback immediately
///   without any cross-tab coordination. Pre-Phase-2 behavior.
enum LockRole { leader, follower, fallback }

/// Message sent over [CrossTabSync]'s BroadcastChannel.
sealed class CrossTabMessage {
  const CrossTabMessage();
}

/// Another tab successfully rotated tokens. Followers should invalidate
/// their access-token cache so the next [StorageService.getAccessToken]
/// re-reads from secure storage.
class CrossTabRefreshComplete extends CrossTabMessage {
  final int generation;
  const CrossTabRefreshComplete({required this.generation});
}

/// Another tab attempted a refresh and got an invalid result. Followers
/// should NOT independently retry — the BE already knows this user's
/// token is bad.
class CrossTabRefreshInvalid extends CrossTabMessage {
  const CrossTabRefreshInvalid();
}

/// Another tab observed a transient BE failure and started an
/// origin-wide cooldown that lasts until [untilMs] (epoch millis).
/// Listening tabs maintain an in-memory cooldown timestamp from this
/// message so the cooldown is observable without a SharedPreferences
/// cache reload.
class CrossTabRefreshTransient extends CrossTabMessage {
  final int untilMs;
  const CrossTabRefreshTransient({required this.untilMs});
}
