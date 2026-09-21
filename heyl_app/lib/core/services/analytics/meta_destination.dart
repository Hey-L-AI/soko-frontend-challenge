import 'dart:async';

import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:flutter/foundation.dart';

import 'analytics_destination.dart';

/// Meta (Facebook) App Events destination adapter.
///
/// Maps generic analytics events to Meta's App Events SDK.
///
/// The adapter is created in an un-initialised state. The owning
/// [MetaAnalyticsService] calls [markInitialized] once the SDK is ready
/// (ATT permission resolved on iOS, or immediately on Android).
///
/// ## PROD-2137 — buffer-and-replay across the ATT gate
///
/// On iOS the gate (`markInitialized`) only opens once the user reaches the
/// home screen and resolves the ATT prompt. But a fresh-install user signs up
/// during onboarding — *before* that — so the `sign_up` (and its `identify`)
/// fire while the gate is closed. Dropping them, as the original design did,
/// meant `fb_mobile_complete_registration` was never sent for the exact
/// signups it exists to attribute.
///
/// So instead of dropping, ops issued while uninitialised are queued **in
/// order** ([track] then [identify], matching the auth call order) and
/// replayed on [markInitialized]. Nothing leaves the device until ATT
/// resolves (consent preserved): if the user allows, the replayed events
/// carry the IDFA; if they deny, the SDK sends them "limited" (no IDFA) per
/// Meta's documented model — either way the registration is counted.
///
/// The queue is bounded ([maxBufferedOps]) and TTL'd ([bufferTtl]) so it can
/// never grow into a general offline-analytics queue, and [reset] (logout /
/// account switch) clears it so one user's pre-consent signup is never
/// replayed against the next.
///
/// Note on debug mode: `facebook_app_events 0.27.2` does not expose a
/// `setIsDebugEnabled` API from Dart. Test-event routing is configured via
/// Meta Events Manager using the device's advertiser ID — no runtime flag.
class MetaDestination implements AnalyticsDestination {
  MetaDestination({
    FacebookAppEvents? client,
    int maxBufferedOps = 50,
    Duration bufferTtl = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : _client = client ?? FacebookAppEvents(),
       _maxBufferedOps = maxBufferedOps,
       _bufferTtl = bufferTtl,
       _now = now ?? DateTime.now;

  final FacebookAppEvents _client;

  /// Upper bound on the pre-ATT queue. On overflow the oldest op is dropped —
  /// a fresh signup matters more than a stale one, and an unbounded
  /// pre-consent queue is a leak risk.
  final int _maxBufferedOps;

  /// Buffered ops older than this at flush time are discarded. Guards against
  /// replaying a registration from a session the user abandoned long ago.
  final Duration _bufferTtl;

  /// Injectable clock so TTL behaviour is testable.
  final DateTime Function() _now;

  bool _initialized = false;

  /// Ordered queue of Meta operations captured while the gate is closed.
  /// Empty and unused once [_initialized] is true.
  final List<_PendingMetaOp> _pending = [];

  /// Flip the gate open and replay anything buffered while it was closed.
  ///
  /// Called by [MetaAnalyticsService] after `setAdvertiserTracking` (so the
  /// replayed events are tagged tracked/limited correctly) once the Meta SDK
  /// is booted and ATT has resolved. The replay runs fire-and-forget; ops are
  /// awaited internally so their order is preserved.
  void markInitialized() {
    if (_initialized) return;
    _initialized = true;
    unawaited(_flushPending());
  }

  // ---------------------------------------------------------------------------
  // AnalyticsDestination interface
  // ---------------------------------------------------------------------------

  @override
  String get name => 'meta';

  /// Maps HeyL event names to Meta standard / custom event name strings.
  ///
  /// Only events present in this map are forwarded to the SDK.
  /// All other events are silently dropped (no-op) and never buffered.
  static const _eventNameMap = <String, String>{
    'sign_up': 'fb_mobile_complete_registration',
    'message_sent_user': 'InitiateChat',
    'list_create': 'CreateList',
    'list_open': 'fb_mobile_content_view',
  };

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {
    final mapped = _eventNameMap[event];
    if (mapped == null) return; // not routed to Meta — never send or buffer

    final cleaned = _stripNulls(properties);
    if (!_initialized) {
      _enqueue(() => _logEvent(event, mapped, cleaned));
      return;
    }
    await _logEvent(event, mapped, cleaned);
  }

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {
    // `traits` are intentionally ignored — Meta's SDK only stores a single
    // user ID for attribution, not arbitrary person properties.
    if (!_initialized) {
      _enqueue(() => _setUserId(userId));
      return;
    }
    await _setUserId(userId);
  }

  @override
  Future<void> reset() async {
    // PROD-2137: a logout / account switch before ATT resolves must discard
    // the buffered pre-consent ops, so the prior session's signup is never
    // replayed against the next user. `trackLogout()` routes here.
    _pending.clear();
    if (!_initialized) return;
    await _clearUserId();
    // PROD-3478: Advanced Matching data persists on-device between app
    // instances — without this, the previous account's hashed email/phone
    // would keep matching events fired by the next account.
    await _clearUserData();
  }

  /// Meta Advanced Matching (PROD-3478): forwards identifiers to the SDK's
  /// `setUserData`. Pass RAW values — the native Meta SDK SHA-256-hashes
  /// them on-device before anything is sent; pre-hashed input would be
  /// double-hashed and never match. Normalization per Meta's rules happens
  /// here (email lowercased/trimmed, phone digits-only incl. country code).
  ///
  /// All-null/empty calls are dropped instead of forwarded: `setUserData`
  /// persists between app instances, and overwriting stored values with
  /// nulls would erase good matching data (e.g. Apple re-login, where
  /// `credential.email` is only supplied on the FIRST authorization).
  ///
  /// Respects the ATT gate exactly like [track]/[identify]: buffered while
  /// uninitialised, replayed on [markInitialized].
  Future<void> setAdvancedMatchingData({String? email, String? phone}) async {
    final normalizedEmail = email?.trim().toLowerCase();
    final normalizedPhone = phone?.replaceAll(RegExp(r'[^0-9]'), '');
    final effectiveEmail = (normalizedEmail?.isEmpty ?? true)
        ? null
        : normalizedEmail;
    final effectivePhone = (normalizedPhone?.isEmpty ?? true)
        ? null
        : normalizedPhone;
    if (effectiveEmail == null && effectivePhone == null) return;

    if (!_initialized) {
      _enqueue(
        () => _setUserData(email: effectiveEmail, phone: effectivePhone),
      );
      return;
    }
    await _setUserData(email: effectiveEmail, phone: effectivePhone);
  }

  // ---------------------------------------------------------------------------
  // Buffer
  // ---------------------------------------------------------------------------

  void _enqueue(Future<void> Function() op) {
    _pending.add(_PendingMetaOp(_now(), op));
    while (_pending.length > _maxBufferedOps) {
      _pending.removeAt(0); // drop oldest
    }
  }

  Future<void> _flushPending() async {
    if (_pending.isEmpty) return;
    final ops = List<_PendingMetaOp>.of(_pending);
    _pending.clear();
    final cutoff = _now().subtract(_bufferTtl);
    for (final op in ops) {
      if (op.createdAt.isBefore(cutoff)) continue; // expired — drop
      await op.apply(); // sequential — preserves track-before-identify order
    }
  }

  // ---------------------------------------------------------------------------
  // SDK calls (fire-and-forget contract — never rethrow)
  // ---------------------------------------------------------------------------

  Future<void> _logEvent(
    String event,
    String mapped,
    Map<String, dynamic> cleaned,
  ) async {
    try {
      await _client.logEvent(name: mapped, parameters: cleaned);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('MetaDestination.track("$event") error: $e\n$st');
      }
    }
  }

  Future<void> _setUserId(String userId) async {
    try {
      await _client.setUserID(userId);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('MetaDestination.identify error: $e\n$st');
      }
    }
  }

  Future<void> _clearUserId() async {
    try {
      await _client.clearUserID();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('MetaDestination.reset error: $e\n$st');
      }
    }
  }

  Future<void> _setUserData({String? email, String? phone}) async {
    try {
      await _client.setUserData(email: email, phone: phone);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('MetaDestination.setAdvancedMatchingData error: $e\n$st');
      }
    }
  }

  Future<void> _clearUserData() async {
    try {
      await _client.clearUserData();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('MetaDestination.reset clearUserData error: $e\n$st');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Returns a copy of [props] with all null-valued entries removed.
  ///
  /// The Meta SDK's [FacebookAppEvents.logEvent] accepts
  /// `Map<String, dynamic>?` but the underlying Android Bundle codec rejects
  /// null values at runtime, so we strip them pre-emptively.
  Map<String, dynamic> _stripNulls(Map<String, dynamic> props) {
    final result = <String, dynamic>{};
    for (final entry in props.entries) {
      if (entry.value != null) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }
}

/// A Meta operation captured while the ATT gate was closed, tagged with the
/// time it was queued so [MetaDestination] can TTL it on replay.
class _PendingMetaOp {
  _PendingMetaOp(this.createdAt, this.apply);

  final DateTime createdAt;
  final Future<void> Function() apply;
}
