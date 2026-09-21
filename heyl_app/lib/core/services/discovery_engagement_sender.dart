import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/datasources/api/discovery_engagement_api.dart';
import '../../data/models/discovery_engagement.dart';

/// Buffers discovery-session engagement events and flushes them in batches —
/// on a debounce, when the buffer fills, and when the app backgrounds
/// (PROD-4257). Mirrors [FeedImpressionSender]; the ledger is append-only and
/// the endpoint is best-effort per row, so a duplicate or dropped flush is
/// harmless.
///
/// **Session-keyed.** The endpoint takes one `session_id` per POST, but a
/// single buffer can straddle a visit boundary (a `session_end` for visit N
/// and a `session_start` for visit N+1). Each buffered event is tagged with
/// its session, and [flush] groups by session so each visit's events land
/// under their own id.
class DiscoveryEngagementSender with WidgetsBindingObserver {
  /// Resolves the API **lazily**, at flush time — never at construction. This is
  /// load-bearing: the session tracker (which owns this sender) is read from
  /// feed card widgets, and resolving the API eagerly would drag the whole
  /// api-client provider chain into every feed-block widget's `build`, so every
  /// widget test rendering a block would have to stub it. Deferring the read to
  /// the flush means constructing the sender touches no network layer.
  final DiscoveryEngagementApi Function() _api;

  /// Resolves the anonymous visitor id at flush time, or null when unknown.
  /// A function rather than a value so the sender need not be rebuilt when the
  /// visitor id resolves.
  final String? Function()? _visitorId;

  final List<_Tagged> _buffer = [];
  Timer? _flushTimer;

  static const Duration _debounce = Duration(seconds: 5);
  static const int _maxBuffer = 100;

  DiscoveryEngagementSender(this._api, {String? Function()? visitorId})
    : _visitorId = visitorId {
    WidgetsBinding.instance.addObserver(this);
  }

  void enqueue(String sessionId, DiscoveryEngagementEventIn event) {
    _buffer.add(_Tagged(sessionId, event));
    if (_buffer.length >= _maxBuffer) {
      unawaited(flush());
      return;
    }
    _flushTimer ??= Timer(_debounce, () => unawaited(flush()));
  }

  /// Drop everything buffered without sending. Called on sign-out / account
  /// switch (identity-epoch boundary, PROD-4308): events observed under the
  /// old actor must never be posted under a newly signed-in user's token —
  /// dropping them is loss the ledger can account for; misattributing them is
  /// corruption it cannot.
  void clearForIdentityChange() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _buffer.clear();
  }

  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffer.isEmpty) return;
    // Snapshot + clear BEFORE awaiting so a concurrent flush can't double-send.
    final batch = List<_Tagged>.of(_buffer);
    _buffer.clear();

    // Group by session, preserving insertion order within each session.
    final bySession = <String, List<DiscoveryEngagementEventIn>>{};
    for (final tagged in batch) {
      (bySession[tagged.sessionId] ??= []).add(tagged.event);
    }
    // Resolve visitor id + API here, not at construction (see [_api]). Both
    // guarded: a missing provider (e.g. a widget test that never stubbed the
    // chain but did advance a card to a flush — or reached one via the screen's
    // dispose-time session end) must not throw out of this fire-and-forget
    // path.
    String? visitorId;
    try {
      visitorId = _visitorId?.call();
    } catch (_) {
      visitorId = null;
    }
    final DiscoveryEngagementApi api;
    try {
      api = _api();
    } catch (_) {
      return;
    }
    for (final entry in bySession.entries) {
      await api.post(entry.key, entry.value, visitorId: visitorId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(flush());
    }
  }

  void dispose() {
    _flushTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

class _Tagged {
  final String sessionId;
  final DiscoveryEngagementEventIn event;
  const _Tagged(this.sessionId, this.event);
}
