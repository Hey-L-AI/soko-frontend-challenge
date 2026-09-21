@JS()
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:web/web.dart' as web;

import 'cross_tab_sync.dart';

/// PROD-2168 Phase 2 — web implementation of [CrossTabSync].
///
/// Uses Web Locks (`navigator.locks.request`) for exclusive cross-tab
/// election, BroadcastChannel for completion notification (no tokens
/// ever carried), and the `storage` event on `localStorage` as a
/// fallback for cache-invalidation broadcasts when BroadcastChannel is
/// unavailable.
///
/// All construction is wrapped in try/catch so Safari private mode,
/// sandboxed iframes, embedded webviews, or other locked-down contexts
/// fall back cleanly to the disabled implementation rather than crashing
/// the app at boot.
CrossTabSync createCrossTabSync({required bool enabled}) {
  if (!enabled) {
    return _DisabledWebCrossTabSync(
      reason: 'kill_switch_off',
    );
  }
  try {
    return _WebCrossTabSync();
  } catch (e, st) {
    // Defensive — log so we can spot environments where construction
    // throws, but never break boot.
    unawaited(
      Sentry.captureException(
        e,
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('auth.inflight_sync.init', 'failed');
        },
      ),
    );
    return _DisabledWebCrossTabSync(reason: 'init_threw');
  }
}

/// Channel name shared across all tabs of the same browser profile.
/// `heyl-auth` is generic on purpose so we can carry other auth-related
/// cross-tab messages (e.g. logout broadcast) on this channel later if
/// needed without bumping a version.
const _channelName = 'heyl-auth';

/// PROD-2168 Phase 2 Codex round-2 [P2] — localStorage key where the
/// transient cooldown expiry timestamp is persisted. Direct localStorage
/// (not via flutter_secure_storage or SharedPreferences) so other tabs
/// receive a `storage` event AND can read the value back uncached.
const _cooldownStorageKey = 'heyl_auth_cooldown_until_ms';

/// Threshold (in milliseconds) under which a Web Locks acquisition is
/// considered "immediate" — i.e. the caller did not wait for another
/// tab. Above the threshold, the caller waited and is tagged as a
/// follower. The exact value matters less than picking something below
/// typical inter-tab wakeup latency; 10ms is comfortably above noise but
/// well under any real network delay.
const _leaderWaitThresholdMs = 10;

class _WebCrossTabSync implements CrossTabSync {
  /// Optional — `null` when BroadcastChannel construction failed.
  final web.BroadcastChannel? _channel;

  final bool _locksAvailable;

  /// Active subscriptions to [listenMessages] — broadcast to all of them
  /// whenever a `message` event lands. We tee through a single
  /// `_messages` controller so multiple listeners don't each register
  /// a separate JS event handler.
  final _messages = StreamController<CrossTabMessage>.broadcast();

  /// JS-side message handler kept as a field so we can remove it on dispose.
  late final JSFunction? _onMessage;

  /// Window-level storage handler — one per registered key. Multiple
  /// [listenStorageKey] calls share one window listener and filter by key
  /// inside; we keep both the JS function and per-key controllers here.
  late final JSFunction? _onWindowStorage;
  final _storageControllers =
      <String, StreamController<String?>>{};

  _WebCrossTabSync()
      : _channel = _tryCreateChannel(),
        _locksAvailable = _detectLocksAvailable() {
    if (_channel != null) {
      final handler = ((web.MessageEvent event) {
        _handleChannelMessage(event);
      }).toJS;
      _onMessage = handler;
      _channel.addEventListener('message', handler);
    } else {
      _onMessage = null;
    }

    final storageHandler = ((web.StorageEvent event) {
      final key = event.key;
      if (key == null) return;
      final controller = _storageControllers[key];
      if (controller == null || controller.isClosed) return;
      controller.add(event.newValue);
    }).toJS;
    _onWindowStorage = storageHandler;
    web.window.addEventListener('storage', storageHandler);
  }

  static web.BroadcastChannel? _tryCreateChannel() {
    try {
      return web.BroadcastChannel(_channelName);
    } catch (_) {
      return null;
    }
  }

  static bool _detectLocksAvailable() {
    try {
      // PROD-2168 Phase 2 Codex [P1] fix: simply reading
      // `navigator.locks` is not enough — on browsers that don't
      // implement the Web Locks API the JS property is `undefined` and
      // the Dart bridge happily returns a non-null extension-type
      // pointing at it. The subsequent `.request(...)` call then
      // throws synchronously instead of taking the documented fallback
      // path. Verify the underlying object actually has a callable
      // `request` method.
      final navJs = web.window.navigator as JSObject;
      if (!navJs.has('locks')) return false;
      final locksRaw = navJs.getProperty('locks'.toJS);
      if (locksRaw == null || locksRaw.isUndefinedOrNull) return false;
      final locksObj = locksRaw as JSObject;
      if (!locksObj.has('request')) return false;
      final requestRaw = locksObj.getProperty('request'.toJS);
      if (requestRaw == null || !requestRaw.typeofEquals('function')) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool get locksAvailable => _locksAvailable;

  @override
  bool get channelAvailable => _channel != null;

  @override
  Future<LockOutcome<T>> withLock<T>(
    String lockName,
    Future<T> Function() callback, {
    Duration? waitTimeout,
  }) async {
    if (!_locksAvailable) {
      // Fall back to immediate execution (pre-Phase-2 behavior). Caller
      // sees `LockRole.fallback` and is responsible for its own
      // serialization (in-memory Completer in RefreshCoordinator).
      final value = await callback();
      return LockOutcome(
        role: LockRole.fallback,
        timedOut: false,
        waitDuration: Duration.zero,
        value: value,
      );
    }

    final start = DateTime.now();
    var callbackEntered = false;
    Duration waitDuration = Duration.zero;
    LockRole role = LockRole.leader;

    web.AbortController? abortController;
    Timer? timeoutTimer;
    JSAny? jsOptions;

    if (waitTimeout != null) {
      abortController = web.AbortController();
      timeoutTimer = Timer(waitTimeout, () {
        if (!callbackEntered) {
          // AbortSignal only aborts UNGRANTED lock requests. Once the
          // callback fires, this is a no-op — we let the leader's work
          // finish.
          abortController!.abort();
        }
      });
      jsOptions = _buildLockOptions(
        mode: 'exclusive',
        signal: abortController.signal,
      );
    } else {
      jsOptions = _buildLockOptions(mode: 'exclusive');
    }

    T? result;
    Object? caughtError;
    StackTrace? caughtStack;

    final jsCallback = ((JSAny? _) {
      callbackEntered = true;
      waitDuration = DateTime.now().difference(start);
      role = waitDuration.inMilliseconds < _leaderWaitThresholdMs
          ? LockRole.leader
          : LockRole.follower;
      // Bridge Dart Future → JS Promise. The lock is held until this
      // Promise resolves; the locks API's outer Promise resolves to the
      // callback's resolved value (we ignore the resolved value here).
      return Future<void>(() async {
        try {
          result = await callback();
        } catch (e, st) {
          caughtError = e;
          caughtStack = st;
        }
      }).toJS;
    }).toJS;

    try {
      await web.window.navigator.locks
          .request(lockName, jsOptions as JSObject, jsCallback)
          .toDart;
    } catch (e) {
      // The locks API rejects with a DOMException when the request is
      // aborted before being granted. We can't pattern-match on
      // DOMException directly through js_interop, so fall back to
      // string sniffing — `AbortError` is the canonical name.
      if (!callbackEntered) {
        final isAbort = e.toString().toLowerCase().contains('abort');
        if (isAbort) {
          return LockOutcome(
            role: LockRole.follower,
            timedOut: true,
            waitDuration: DateTime.now().difference(start),
            value: null,
          );
        }
      }
      rethrow;
    } finally {
      timeoutTimer?.cancel();
    }

    if (caughtError != null) {
      Error.throwWithStackTrace(caughtError!, caughtStack ?? StackTrace.empty);
    }

    return LockOutcome(
      role: role,
      timedOut: false,
      waitDuration: waitDuration,
      value: result,
    );
  }

  void _handleChannelMessage(web.MessageEvent event) {
    final data = event.data;
    if (data == null) return;
    String? text;
    if (data.typeofEquals('string')) {
      text = (data as JSString).toDart;
    } else {
      return;
    }
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      switch (json['type']) {
        case 'refresh-complete':
          final gen = json['generation'];
          if (gen is int) {
            _messages.add(CrossTabRefreshComplete(generation: gen));
          }
          break;
        case 'refresh-invalid':
          _messages.add(const CrossTabRefreshInvalid());
          break;
        case 'refresh-transient':
          final until = json['untilMs'];
          if (until is int) {
            _messages.add(CrossTabRefreshTransient(untilMs: until));
          }
          break;
      }
    } catch (_) {
      // Malformed / foreign message — ignore. We're on a generic
      // channel name and tolerant of future siblings.
    }
  }

  @override
  void notifyRefreshComplete({required int generation}) {
    final channel = _channel;
    if (channel == null) return;
    final payload =
        jsonEncode({'type': 'refresh-complete', 'generation': generation});
    try {
      channel.postMessage(payload.toJS);
    } catch (_) {
      // Channel closed under us — nothing actionable.
    }
  }

  @override
  void notifyRefreshInvalid() {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.postMessage(jsonEncode({'type': 'refresh-invalid'}).toJS);
    } catch (_) {}
  }

  @override
  void notifyRefreshTransient({required int untilMs}) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.postMessage(
        jsonEncode({'type': 'refresh-transient', 'untilMs': untilMs}).toJS,
      );
    } catch (_) {}
  }

  @override
  void persistCooldownUntil({required int untilMs}) {
    try {
      web.window.localStorage.setItem(_cooldownStorageKey, '$untilMs');
    } catch (_) {
      // localStorage can throw in Safari private mode + sandboxed
      // iframes. Non-fatal — the in-memory cooldown + BroadcastChannel
      // notify still provide some coverage.
    }
  }

  @override
  String get cooldownStorageKey => _cooldownStorageKey;

  @override
  DateTime? readPersistedCooldown() {
    try {
      final raw = web.window.localStorage.getItem(_cooldownStorageKey);
      if (raw == null) return null;
      final ms = int.tryParse(raw);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  @override
  StreamSubscription<CrossTabMessage> listenMessages(
    void Function(CrossTabMessage message) onMessage,
  ) {
    return _messages.stream.listen(onMessage);
  }

  @override
  StreamSubscription<String?> listenStorageKey(
    String storageKey,
    void Function(String? newValue) onChange,
  ) {
    final controller = _storageControllers.putIfAbsent(
      storageKey,
      () => StreamController<String?>.broadcast(),
    );
    return controller.stream.listen(onChange);
  }

  @override
  void dispose() {
    final onMsg = _onMessage;
    final channel = _channel;
    if (onMsg != null && channel != null) {
      try {
        channel.removeEventListener('message', onMsg);
      } catch (_) {}
      try {
        channel.close();
      } catch (_) {}
    }
    final onStorage = _onWindowStorage;
    if (onStorage != null) {
      try {
        web.window.removeEventListener('storage', onStorage);
      } catch (_) {}
    }
    for (final c in _storageControllers.values) {
      c.close();
    }
    _storageControllers.clear();
    _messages.close();
  }
}

/// Disabled implementation used on web when the kill switch is off or
/// when construction of the real implementation throws. Reports both
/// capabilities as false so the Sentry tags `locks_available` and
/// `channel_available` reflect reality.
class _DisabledWebCrossTabSync implements CrossTabSync {
  final String reason;
  _DisabledWebCrossTabSync({required this.reason});

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
  String get cooldownStorageKey => '__heyl_auth_cooldown_disabled';

  @override
  DateTime? readPersistedCooldown() => null;

  @override
  StreamSubscription<CrossTabMessage> listenMessages(
    void Function(CrossTabMessage message) onMessage,
  ) =>
      const Stream<CrossTabMessage>.empty().listen(onMessage);

  @override
  StreamSubscription<String?> listenStorageKey(
    String storageKey,
    void Function(String? newValue) onChange,
  ) =>
      const Stream<String?>.empty().listen(onChange);

  @override
  void dispose() {}
}

/// Build a `LockOptions` JS object via `package:web`'s extension-type
/// factory. All fields are optional; we always pass `mode` and only pass
/// `signal` when a timeout was requested.
JSObject _buildLockOptions({
  required String mode,
  web.AbortSignal? signal,
}) {
  return signal != null
      ? web.LockOptions(mode: mode, signal: signal)
      : web.LockOptions(mode: mode);
}
