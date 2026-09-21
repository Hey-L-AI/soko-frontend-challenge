import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/discovery_for_you_feed.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// Page size for the admin discovery feed shelves — sent as `num_results` on
/// each `POST /api/v1/app/discovery` call.
const int _pageSize = 15;

/// Paged state for one admin discovery feed shelf. Mirrors the shape of
/// `PagedShelfState` (used by the Yours/Following shelves) so it slots into the
/// `DiscoveryShelf` pagination hooks, but holds [DiscoveryForYouItem]s instead
/// of `UserList`s. There is no client-side filtering here, so `hasMore` comes
/// straight from the backend response and `nextOffset` is just the number of
/// rows fetched so far.
@immutable
class DiscoveryFeedShelfState {
  final List<DiscoveryForYouItem> items;
  final int nextOffset;
  final bool hasMore;
  final bool isLoadingMore;
  final Object? loadMoreError;

  const DiscoveryFeedShelfState({
    required this.items,
    required this.nextOffset,
    required this.hasMore,
    required this.isLoadingMore,
    required this.loadMoreError,
  });

  DiscoveryFeedShelfState copyWith({
    List<DiscoveryForYouItem>? items,
    int? nextOffset,
    bool? hasMore,
    bool? isLoadingMore,
    Object? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return DiscoveryFeedShelfState(
      items: items ?? this.items,
      nextOffset: nextOffset ?? this.nextOffset,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
    );
  }
}

/// Admin-only discovery feed shelf data, keyed by `entity_types`
/// (`'events'` / `'venues'`). Surfaces the Discovery API's `for_you` ranking
/// (PROD-3912) per entity type with horizontal infinite scroll — resend the
/// same request with a growing `offset` and stop when `has_more` is false.
///
/// `autoDispose`, no caching: fetched fresh per Discovery mount since it's an
/// admin evaluation surface, not a hot user path.
final discoveryFeedShelfProvider = AsyncNotifierProvider.autoDispose
    .family<DiscoveryFeedShelfNotifier, DiscoveryFeedShelfState, String>(
      DiscoveryFeedShelfNotifier.new,
    );

class DiscoveryFeedShelfNotifier
    extends AutoDisposeFamilyAsyncNotifier<DiscoveryFeedShelfState, String> {
  // Bumped on every `build()` and every `loadMore` fetch. An in-flight fetch
  // captures the version at start; if it moved by the time the await resolves
  // (rebuild from account switch, or a concurrent `loadMore`), the late
  // response is discarded so it can't overwrite newer state.
  int _currentVersion = 0;

  // Riverpod 2.6.x doesn't expose `ref.mounted` here, so this flag (set in
  // `ref.onDispose`) is the equivalent post-await guard.
  bool _disposed = false;

  String get _entityTypes => arg;

  @override
  Future<DiscoveryFeedShelfState> build(String arg) async {
    final fetchVersion = ++_currentVersion;
    // Riverpod runs the PREVIOUS build's `onDispose` before a rebuild, not
    // only on a real teardown, and preserves this notifier instance across
    // builds — so without clearing it here the flag latches on the first
    // rebuild and every guard below silently wins forever. `_currentVersion`
    // is what answers "superseded"; this only answers "gone".
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
    });

    // Rebuild on account switch so one admin's ranked feed never survives into
    // another session. `.select` on the id ignores token refreshes.
    ref.watch(authStateProvider.select((s) => s.user?.id));

    // Coords scope the results when available; the BE falls back to the
    // viewer's memory location otherwise (both are optional on the endpoint).
    final resolved = await ref.watch(resolvedSearchLocationProvider.future);

    final response = await ref
        .read(feedApiProvider)
        .getDiscoveryForYou(
          objective: 'for_you',
          entityTypes: _entityTypes,
          latitude: resolved.centerLat,
          longitude: resolved.centerLon,
          numResults: _pageSize,
          offset: 0,
        );
    if (fetchVersion != _currentVersion) {
      throw StateError('Superseded by newer build');
    }
    return DiscoveryFeedShelfState(
      items: response.items,
      nextOffset: response.items.length,
      hasMore: response.hasMore,
      isLoadingMore: false,
      loadMoreError: null,
    );
  }

  /// Auto-fire path: triggered when the user scrolls near the right edge of
  /// the shelf, or by the post-frame underfilled-row check. No-ops if
  /// pagination is already in flight, end-of-stream reached, or a prior
  /// `loadMore` errored (use [retryLoadMore] to recover).
  Future<void> loadMore() async {
    final initial = state.valueOrNull;
    if (initial == null) return;
    if (!initial.hasMore ||
        initial.isLoadingMore ||
        initial.loadMoreError != null) {
      return;
    }
    await _fetchAndAppend(initial);
  }

  /// Explicit retry path used by the trailing error tile. Clears the error
  /// first so [loadMore]'s error-guard can pass, then delegates to the shared
  /// fetch.
  Future<void> retryLoadMore() async {
    final initial = state.valueOrNull;
    if (initial == null) return;
    if (initial.isLoadingMore) return;
    final cleared = initial.copyWith(clearLoadMoreError: true);
    state = AsyncData(cleared);
    await _fetchAndAppend(cleared);
  }

  Future<void> _fetchAndAppend(DiscoveryFeedShelfState initial) async {
    final fetchVersion = ++_currentVersion;
    state = AsyncData(
      initial.copyWith(isLoadingMore: true, clearLoadMoreError: true),
    );

    try {
      final resolved = await ref.read(resolvedSearchLocationProvider.future);
      final response = await ref
          .read(feedApiProvider)
          .getDiscoveryForYou(
            objective: 'for_you',
            entityTypes: _entityTypes,
            latitude: resolved.centerLat,
            longitude: resolved.centerLon,
            numResults: _pageSize,
            offset: initial.nextOffset,
          );
      if (_disposed) return;
      if (fetchVersion != _currentVersion) return;

      final current = state.valueOrNull ?? initial;
      final merged = _dedupeAppend(current.items, response.items);
      state = AsyncData(
        current.copyWith(
          items: merged,
          nextOffset: current.nextOffset + response.items.length,
          hasMore: response.hasMore,
          isLoadingMore: false,
          clearLoadMoreError: true,
        ),
      );
    } catch (e) {
      if (_disposed) return;
      if (fetchVersion != _currentVersion) return;
      final current = state.valueOrNull ?? initial;
      state = AsyncData(
        current.copyWith(isLoadingMore: false, loadMoreError: e),
      );
    }
  }

  /// Append [incoming] to [existing], dropping any id already present. Cheap
  /// insurance against offset drift if the ranked pool shifts between pages.
  List<DiscoveryForYouItem> _dedupeAppend(
    List<DiscoveryForYouItem> existing,
    List<DiscoveryForYouItem> incoming,
  ) {
    final seen = {for (final i in existing) i.id};
    return [...existing, ...incoming.where((i) => seen.add(i.id))];
  }
}
