import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tiktok_business_sdk/tiktok_business_sdk.dart';
import 'package:tiktok_business_sdk/tiktok_business_sdk_platform_interface.dart';

import 'analytics_destination.dart';

/// TikTok Business SDK destination adapter (PROD-2919).
///
/// Mirrors the design of `MetaDestination`:
/// - Created un-initialised. [TikTokAnalyticsService] flips [markInitialized]
///   once the SDK is booted (immediately on Android, after ATT on iOS).
/// - Buffers ops issued while the gate is closed and replays them on flush so
///   the `sign_up` fired mid-onboarding (before ATT resolves) is not lost —
///   same PROD-2137 reasoning as Meta.
///
/// TikTok SDK API constraints (from `tiktok_business_sdk` 0.0.1) shape this:
/// - `trackTTEvent` takes only a fixed [EventName] enum + optional `eventId`
///   — no event properties, so `properties` from [track] are dropped.
/// - The enum has no `ViewContent`/`InitiateChat`/`AddToWishlist`
///   equivalents; unmapped events are ignored (never sent, never buffered).
///
/// Event map:
/// - `sign_up` → [EventName.Registration]
/// - `login` → [EventName.Login]
/// - `search` → [EventName.Search]
/// - `list_create` → [EventName.CreateGroup] (semantic match for grouping items
///   into a themed collection)
class TikTokDestination implements AnalyticsDestination {
  TikTokDestination({
    TiktokBusinessSdk? client,
    int maxBufferedOps = 50,
    Duration bufferTtl = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : _client = client ?? TiktokBusinessSdk(),
       _maxBufferedOps = maxBufferedOps,
       _bufferTtl = bufferTtl,
       _now = now ?? DateTime.now;

  final TiktokBusinessSdk _client;
  final int _maxBufferedOps;
  final Duration _bufferTtl;
  final DateTime Function() _now;

  bool _initialized = false;
  final List<_PendingTikTokOp> _pending = [];

  /// Flip the gate open and replay any ops buffered while it was closed.
  void markInitialized() {
    if (_initialized) return;
    _initialized = true;
    unawaited(_flushPending());
  }

  // ---------------------------------------------------------------------------
  // AnalyticsDestination
  // ---------------------------------------------------------------------------

  @override
  String get name => 'tiktok';

  /// Only these HeyL events forward to TikTok. Everything else is a no-op
  /// (never sent, never buffered).
  static const _eventNameMap = <String, EventName>{
    'sign_up': EventName.Registration,
    'login': EventName.Login,
    'search': EventName.Search,
    'list_create': EventName.CreateGroup,
  };

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {
    final mapped = _eventNameMap[event];
    if (mapped == null) return;

    if (!_initialized) {
      _enqueue(() => _trackEvent(event, mapped));
      return;
    }
    await _trackEvent(event, mapped);
  }

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {
    if (!_initialized) {
      _enqueue(() => _setIdentify(userId));
      return;
    }
    await _setIdentify(userId);
  }

  @override
  Future<void> reset() async {
    _pending.clear();
    if (!_initialized) return;
    await _logout();
  }

  // ---------------------------------------------------------------------------
  // Buffer
  // ---------------------------------------------------------------------------

  void _enqueue(Future<void> Function() op) {
    _pending.add(_PendingTikTokOp(_now(), op));
    while (_pending.length > _maxBufferedOps) {
      _pending.removeAt(0);
    }
  }

  Future<void> _flushPending() async {
    if (_pending.isEmpty) return;
    final ops = List<_PendingTikTokOp>.of(_pending);
    _pending.clear();
    final cutoff = _now().subtract(_bufferTtl);
    for (final op in ops) {
      if (op.createdAt.isBefore(cutoff)) continue;
      await op.apply();
    }
  }

  // ---------------------------------------------------------------------------
  // SDK calls (fire-and-forget contract — never rethrow)
  // ---------------------------------------------------------------------------

  Future<void> _trackEvent(String event, EventName mapped) async {
    try {
      await _client.trackTTEvent(event: mapped);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('TikTokDestination.track("$event") error: $e\n$st');
      }
    }
  }

  Future<void> _setIdentify(String userId) async {
    try {
      await _client.setIdentify(externalId: userId);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('TikTokDestination.identify error: $e\n$st');
      }
    }
  }

  Future<void> _logout() async {
    try {
      await _client.logout();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('TikTokDestination.reset error: $e\n$st');
      }
    }
  }
}

class _PendingTikTokOp {
  _PendingTikTokOp(this.createdAt, this.apply);

  final DateTime createdAt;
  final Future<void> Function() apply;
}
