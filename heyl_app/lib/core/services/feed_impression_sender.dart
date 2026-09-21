import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/datasources/api/feed_impressions_api.dart';
import '../../data/models/feed_impression.dart';

/// Buffers feed impressions and flushes them in batches — on a debounce, when
/// the buffer fills, and when the app backgrounds. Backend upserts are
/// idempotent, so a duplicate flush (debounce vs lifecycle race) is harmless.
class FeedImpressionSender with WidgetsBindingObserver {
  final FeedImpressionsApi _api;
  final List<FeedImpressionIn> _buffer = [];
  Timer? _flushTimer;

  static const Duration _debounce = Duration(seconds: 5);
  static const int _maxBuffer = 100;

  FeedImpressionSender(this._api) {
    WidgetsBinding.instance.addObserver(this);
  }

  void enqueue(FeedImpressionIn impression) {
    _buffer.add(impression);
    if (_buffer.length >= _maxBuffer) {
      unawaited(flush());
      return;
    }
    _flushTimer ??= Timer(_debounce, () => unawaited(flush()));
  }

  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffer.isEmpty) return;
    // Snapshot + clear BEFORE awaiting so a concurrent flush can't double-send.
    final batch = List<FeedImpressionIn>.of(_buffer);
    _buffer.clear();
    await _api.post(batch);
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
