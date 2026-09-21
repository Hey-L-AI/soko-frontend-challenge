import 'package:flutter/foundation.dart';

import '../../../data/models/models.dart';

/// PROD-2091 — paged shelf state, shared by the Yours and Following
/// shelf providers. Wraps the in-memory item list with the offset +
/// pagination flags needed to lazy-load 10 lists at a time.
///
/// Held inside an `AsyncNotifier<PagedShelfState>` so the outer
/// `AsyncValue.loading` covers the initial fetch (skeleton row) while
/// `isLoadingMore` is an internal flag that never tears the shelf down
/// to skeletons during pagination.
@immutable
class PagedShelfState {
  /// Visible items already shown to the user. Filtered (auto-lists +
  /// tombstones) and deduped by id.
  final List<UserList> items;

  /// Raw fetched count across all pages. Advances by `response.items.length`
  /// per page (not by the post-filter `items.length`), so filtered or
  /// tombstoned rows don't get re-fetched on the next page boundary.
  final int nextOffset;

  /// `false` once a page returned `items.length < pageSize`. Subsequent
  /// `loadMore` calls no-op.
  final bool hasMore;

  /// `true` while a `loadMore` / `retryLoadMore` fetch is in flight.
  /// The outer `AsyncValue` stays `AsyncData` throughout — we never flip
  /// back to `loading` mid-scroll.
  final bool isLoadingMore;

  /// Captures the last `loadMore` failure. Auto-fire blocks while this
  /// is non-null; the only way to clear it is `retryLoadMore`, which
  /// resets it explicitly before delegating.
  final Object? loadMoreError;

  const PagedShelfState({
    required this.items,
    required this.nextOffset,
    required this.hasMore,
    required this.isLoadingMore,
    required this.loadMoreError,
  });

  /// Empty state seed — useful in tests and for first-mount fallback.
  const PagedShelfState.empty()
    : items = const [],
      nextOffset = 0,
      hasMore = false,
      isLoadingMore = false,
      loadMoreError = null;

  /// `loadMoreError` follows the standard nullable-field-via-flag
  /// pattern: pass `clearLoadMoreError: true` to force it to `null`,
  /// or pass a non-null `loadMoreError` to set it.
  PagedShelfState copyWith({
    List<UserList>? items,
    int? nextOffset,
    bool? hasMore,
    bool? isLoadingMore,
    Object? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return PagedShelfState(
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

/// Internal result type for the drain loop. Not exported.
@immutable
class PagedDrainResult {
  /// Sum of raw `response.items.length` across all fetched pages.
  final int rawCount;

  /// Items the user actually sees after client-side filtering.
  final List<UserList> visibleItems;

  /// `false` once a page returned `items.length < pageSize` — end of stream.
  final bool hasMore;

  const PagedDrainResult({
    required this.rawCount,
    required this.visibleItems,
    required this.hasMore,
  });
}
