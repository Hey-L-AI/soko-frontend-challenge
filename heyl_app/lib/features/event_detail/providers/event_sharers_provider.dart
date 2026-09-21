import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/datasources/api/detail_api.dart';
import '../../../data/models/social_proof.dart';
import '../../../providers/api_provider.dart';

/// Paginated state for an event's full sharer list — backs the "and others"
/// popup (PROD-3162 / PROD-3163). One instance per event id, auto-disposed
/// when the sheet closes.
@immutable
class EventSharersState {
  final List<SharedByUser> items;
  final int total;
  final bool isLoading;
  final bool hasMore;
  final Object? error;

  const EventSharersState({
    this.items = const [],
    this.total = 0,
    this.isLoading = false,
    this.hasMore = true,
    this.error,
  });

  /// True before the first page has resolved (nothing to show yet, no error).
  bool get isInitialLoad => items.isEmpty && isLoading && error == null;

  EventSharersState copyWith({
    List<SharedByUser>? items,
    int? total,
    bool? isLoading,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) {
    return EventSharersState(
      items: items ?? this.items,
      total: total ?? this.total,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Fetches successive pages of `GET /app/events/{id}/shared-by`, accumulating
/// into [EventSharersState]. Kicks off the first page on construction; the
/// sheet calls [loadMore] as the list scrolls near its end.
class EventSharersNotifier extends StateNotifier<EventSharersState> {
  final DetailApi _detailApi;
  final String _eventId;
  int _offset = 0;

  static const int _pageSize = 20;

  EventSharersNotifier(this._detailApi, this._eventId)
    : super(const EventSharersState()) {
    loadMore();
  }

  Future<void> loadMore() async {
    if (state.isLoading || !state.hasMore) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final page = await _detailApi.getEventSharedBy(
        _eventId,
        limit: _pageSize,
        offset: _offset,
      );
      _offset = page.nextOffset ?? (_offset + page.items.length);
      state = state.copyWith(
        items: [...state.items, ...page.items],
        total: page.total,
        isLoading: false,
        hasMore: page.hasMore,
      );
    } catch (e) {
      debugPrint('Failed to load sharers for $_eventId: $e');
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  /// Retry after an error, without resetting already-loaded pages.
  Future<void> retry() => loadMore();
}

final eventSharersProvider = StateNotifierProvider.autoDispose
    .family<EventSharersNotifier, EventSharersState, String>(
      (ref, eventId) =>
          EventSharersNotifier(ref.watch(detailApiProvider), eventId),
    );
