import 'dart:async';

import 'package:flutter/foundation.dart';

import 'analytics_destination.dart';
import 'appsflyer_client.dart';

/// AppsFlyer destination adapter (spec §1). Maps HeyL event names to AppsFlyer
/// names; only mapped events are forwarded. Events fired before the SDK has
/// started are buffered in order (ordering only — never an ATT gate) and
/// flushed on [markStarted].
///
/// Constructed with a null [client] on web or when credentials are absent —
/// then every method is a no-op (never throws).
class AppsflyerDestination implements AnalyticsDestination {
  AppsflyerDestination({
    required AppsflyerClient? client,
    int maxBufferedOps = 50,
  }) : _client = client,
       _maxBufferedOps = maxBufferedOps;

  final AppsflyerClient? _client;
  final int _maxBufferedOps;
  bool _started = false;
  final List<Future<void> Function()> _pending = [];

  /// HeyL event name -> AppsFlyer event name (spec §3). Only these are sent.
  static const _eventNameMap = <String, String>{
    'sign_up': 'af_complete_registration',
    'login': 'af_login',
    'view_item': 'af_content_view',
    'list_open': 'af_list_open',
    'search_result_click': 'af_search_result_click',
    // Dedicated AF-only client event — NOT the shared `search` event (which is
    // backend-emitted with a `search_term` field; reusing it would double-count
    // and mismatch Firebase). See Task 8.
    'search_submitted': 'af_search',
    'list_item_add': 'af_add_to_wishlist',
    'message_sent_user': 'af_message_send',
    'list_create': 'af_create_list',
    // share: completion events only (spec §3 decision)
    'share_completed': 'af_share',
    'list_share': 'af_share',
    'instagram_link_submitted': 'af_share',
    // follow: user_follow only
    'user_follow': 'af_follow',
    // shared_list_open is logged from the UDL callback, NOT via the registry.
    // NOTE: no `business_qr_signup` entry — PROD-3533 Task 9 found no
    // distinguishable business-QR signup code path in the app (only generic
    // marketing QR codes feeding the standard install/signup flow via
    // soko.fyi/get). Revisit when a business-QR onboarding entry ships; see
    // the Task 14 name-mapping doc for the recorded gap.
  };

  @override
  String get name => 'appsflyer';

  /// Open the gate and flush anything buffered while closed. Called by
  /// [AppsflyerAnalyticsService] right after startSDK().
  void markStarted() {
    if (_started) return;
    _started = true;
    unawaited(_flush());
  }

  Future<void> _flush() async {
    // Each pending op is already _safe-wrapped, so this never throws.
    for (final op in _pending) {
      await op();
    }
    _pending.clear();
  }

  /// Append to the pending buffer, dropping the OLDEST entry first if at
  /// capacity (mirrors MetaDestination). Guards against unbounded growth if
  /// [markStarted] is never reached (e.g. initSdk()/startSdk() throws before
  /// it — see AppsflyerAnalyticsService.init()) — a fresh event matters more
  /// than a stale one.
  void _buffer(Future<void> Function() op) {
    if (_pending.length >= _maxBufferedOps) {
      _pending.removeAt(0);
    }
    _pending.add(op);
  }

  /// The [AnalyticsDestination] contract requires track/identify/reset to be
  /// fire-and-forget and NEVER throw (mirrors MetaDestination). Every SDK call
  /// goes through here.
  Future<void> _safe(Future<void> Function() op) async {
    try {
      await op();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[AppsflyerDestination] SDK call failed: $e\n$st');
      }
    }
  }

  /// Snapshot (copy) at call time so a later caller mutation can't change a
  /// buffered payload, and strip nulls (the AF plugin is not proven null-safe
  /// on values — mirrors MetaDestination._stripNulls).
  Map<String, dynamic> _clean(Map<String, dynamic> props) {
    final out = <String, dynamic>{};
    props.forEach((k, v) {
      if (v != null) out[k] = v;
    });
    return out;
  }

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {
    final client = _client;
    if (client == null) return;
    final mapped = _eventNameMap[event];
    if (mapped == null) return; // not routed to AF — never send or buffer
    final cleaned = _clean(properties); // snapshot now — see _clean
    if (!_started) {
      _buffer(() => _safe(() => client.logEvent(mapped, cleaned)));
      return;
    }
    await _safe(() => client.logEvent(mapped, cleaned));
  }

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {
    final client = _client;
    if (client == null) return;
    if (!_started) {
      _buffer(() => _safe(() => client.setCustomerUserId(userId)));
      return;
    }
    await _safe(() => client.setCustomerUserId(userId));
  }

  @override
  Future<void> reset() async {
    // No-op for AppsFlyer (spec §5): AF has no clean CUID clear;
    // anonymizeUser/stop carry suppression risk. Deferred to a privacy call.
  }

  /// Exposed so [appsflyerAnalyticsServiceProvider] can build the owning
  /// service from the same instance held in the adapters map (Task 6).
  AppsflyerClient? get client => _client;
}
