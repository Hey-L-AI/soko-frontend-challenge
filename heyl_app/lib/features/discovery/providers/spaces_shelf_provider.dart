import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// State for the "Spaces" shelf (PT-PT: "Espaços", PROD-1553). Pagination
/// is append-only so the user's horizontal-scroll position survives the
/// trailing see-more press.
@immutable
class SpacesShelfState {
  final List<VenueWithEventsItem> items;
  final int total;
  final bool isInitialLoading;
  final bool isLoadingMore;
  final Object? error;

  /// Whether the user has a usable city_id. The shelf hides when this is
  /// false; we don't want to render an empty row for users without a
  /// resolved local city.
  final bool hasCity;

  const SpacesShelfState({
    this.items = const [],
    this.total = 0,
    this.isInitialLoading = true,
    this.isLoadingMore = false,
    this.error,
    this.hasCity = false,
  });

  bool get hasMore => items.length < total;

  SpacesShelfState copyWith({
    List<VenueWithEventsItem>? items,
    int? total,
    bool? isInitialLoading,
    bool? isLoadingMore,
    Object? error,
    bool clearError = false,
    bool? hasCity,
  }) {
    return SpacesShelfState(
      items: items ?? this.items,
      total: total ?? this.total,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      error: clearError ? null : (error ?? this.error),
      hasCity: hasCity ?? this.hasCity,
    );
  }
}

const int _kPageSize = 10;

class SpacesShelfNotifier extends StateNotifier<SpacesShelfState> {
  final Ref _ref;

  SpacesShelfNotifier(this._ref) : super(const SpacesShelfState()) {
    refresh();
  }

  Future<void> refresh() async {
    final cityId = (await _ref.read(
      resolvedSearchLocationProvider.future,
    )).cityId;
    if (cityId == null) {
      state = state.copyWith(
        isInitialLoading: false,
        hasCity: false,
        items: [],
        total: 0,
        clearError: true,
      );
      return;
    }
    state = state.copyWith(isInitialLoading: true, clearError: true);
    try {
      final response = await _ref
          .read(feedApiProvider)
          .getVenuesWithEventsFeed(
            cityId: cityId,
            locationSource: 'picker',
            limit: _kPageSize,
            offset: 0,
          );
      state = SpacesShelfState(
        items: response.items,
        total: response.total,
        isInitialLoading: false,
        hasCity: true,
      );
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 400 || code == 404) {
        // Google-sourced city or unknown UUID — hide the shelf instead of
        // surfacing an error.
        debugPrint('[Spaces] cityId=$cityId returned $code — hiding shelf');
        state = state.copyWith(
          isInitialLoading: false,
          hasCity: false,
          items: [],
          total: 0,
          clearError: true,
        );
        return;
      }
      state = state.copyWith(isInitialLoading: false, error: e, hasCity: true);
    } catch (e) {
      state = state.copyWith(isInitialLoading: false, error: e, hasCity: true);
    }
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore) return;
    final cityId = (await _ref.read(
      resolvedSearchLocationProvider.future,
    )).cityId;
    if (cityId == null) return;
    state = state.copyWith(isLoadingMore: true, clearError: true);
    try {
      final response = await _ref
          .read(feedApiProvider)
          .getVenuesWithEventsFeed(
            cityId: cityId,
            locationSource: 'picker',
            limit: _kPageSize,
            offset: state.items.length,
          );
      state = state.copyWith(
        items: [...state.items, ...response.items],
        total: response.total,
        isLoadingMore: false,
      );
    } catch (e) {
      state = state.copyWith(isLoadingMore: false, error: e);
    }
  }
}

final spacesShelfProvider =
    StateNotifierProvider.autoDispose<SpacesShelfNotifier, SpacesShelfState>((
      ref,
    ) {
      final notifier = SpacesShelfNotifier(ref);
      // Re-fetch when the resolved city changes (e.g. user updates their
      // profile city). The discovery_city_provider re-derives on auth state
      // changes; this listener picks up that derivation.
      ref.listen(
        resolvedSearchLocationProvider.select(
          (value) => value.valueOrNull?.cityId,
        ),
        (prev, next) {
          if (prev == next) return;
          notifier.refresh();
        },
      );
      return notifier;
    });
