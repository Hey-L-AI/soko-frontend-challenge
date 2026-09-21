import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PROD-3269 — TTL cache for autoDispose providers.
///
/// The Discovery list shelves (Editor Picks, City Guides, Recommended)
/// are `autoDispose` providers whose only consumers unmount whenever the
/// user leaves Discovery — so every return used to re-fire their
/// `/lists/public` requests, the single most expensive query on the
/// backend (PROD-3242 incident). `cacheFor` keeps the state alive for
/// [duration] after it was built, so remounts within the window reuse
/// the cached data; after expiry the provider disposes as soon as it has
/// no listeners and the next mount fetches fresh.
///
/// Forced-refresh paths are unaffected: `ref.invalidate` (pull-to-
/// refresh, error retry) rebuilds immediately, and a `ref.watch`ed
/// dependency change (picker-coords via `resolvedSearchLocationProvider`)
/// marks the provider dirty even while kept alive — the next read
/// rebuilds with the new coords. Each rebuild starts a fresh TTL window
/// (the previous link/timer are torn down with the old state).
extension CacheForExtension on Ref<Object?> {
  /// Keeps this provider's current state alive for [duration] from the
  /// moment it was built.
  KeepAliveLink cacheFor(Duration duration) {
    final link = keepAlive();
    final timer = Timer(duration, link.close);
    onDispose(timer.cancel);
    return link;
  }
}
