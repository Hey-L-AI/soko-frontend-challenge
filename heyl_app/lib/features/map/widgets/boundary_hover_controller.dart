import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../data/models/models.dart';
import 'boundary_hover_cache.dart';

/// Debounced hover resolver. Cache-first (instant, no network); on a miss,
/// debounces one cancelable `/geo/boundary/at` resolve. Drops a resolve if a
/// newer hover started (generation) or the screen's selection changed
/// (selectionSeq) — a stale hover must never paint over a committed selection.
class BoundaryHoverController extends ChangeNotifier {
  BoundaryHoverController({
    required this.resolve,
    required this.cache,
    required this.selectionSeq,
    this.debounce = const Duration(milliseconds: 150),
  });

  final Future<GeoBoundary?> Function(double lat, double lng, CancelToken cancel) resolve;
  final BoundaryHoverCache cache;
  final int Function() selectionSeq;
  final Duration debounce;

  Timer? _timer;
  CancelToken? _cancel;
  int _gen = 0;

  GeoBoundary? hoverBoundary;
  bool resolving = false;

  void onHover(double lat, double lng) {
    final hit = cache.lookup(lat, lng);
    if (hit != null) {
      _timer?.cancel();
      _cancel?.cancel('hover cache hit');
      _gen++; // invalidate any in-flight resolve so it can't clobber the hit
      if (hoverBoundary?.id != hit.id || resolving) {
        hoverBoundary = hit;
        resolving = false;
        notifyListeners();
      }
      return;
    }
    // Miss: the cursor is not over any cached boundary — drop the stale preview.
    if (hoverBoundary != null) {
      hoverBoundary = null;
      notifyListeners();
    }
    if (!cache.shouldResolve(lat, lng)) return; // same cell, already tried
    _timer?.cancel();
    _cancel?.cancel('new hover');
    _cancel = CancelToken();
    _gen++;
    resolving = true;
    notifyListeners();
    final gen = _gen;
    final startSeq = selectionSeq();
    final cancel = _cancel!;
    _timer = Timer(debounce, () => _run(lat, lng, gen, startSeq, cancel));
  }

  Future<void> _run(double lat, double lng, int gen, int startSeq, CancelToken cancel) async {
    GeoBoundary? b;
    try {
      b = await resolve(lat, lng, cancel);
    } catch (_) {
      b = null;
    }
    if (gen != _gen) return; // a newer hover owns the resolving state
    if (startSeq != selectionSeq()) {
      // Selection committed while resolving — drop the result, clear the spinner.
      resolving = false;
      notifyListeners();
      return;
    }
    if (b != null) cache.add(b);
    hoverBoundary = b;
    resolving = false;
    notifyListeners();
  }

  /// Cursor left the map, or a selection was committed — clear the preview.
  void onExit() {
    _timer?.cancel();
    _cancel?.cancel('hover exit');
    _gen++;
    if (hoverBoundary != null || resolving) {
      hoverBoundary = null;
      resolving = false;
      notifyListeners();
    }
  }

  /// Called when the screen's `_selectionSeq` bumps (tap/search/clear/restore).
  void onSelectionChanged() => onExit();

  @override
  void dispose() {
    _timer?.cancel();
    _cancel?.cancel('disposed');
    super.dispose();
  }
}
