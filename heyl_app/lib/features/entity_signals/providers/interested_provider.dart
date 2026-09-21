import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/entity_signal.dart';
import '../../../data/models/social_proof.dart';
import '../../../providers/api_provider.dart';

/// Family key: one paginated interested-people list per (entity type, id).
typedef InterestedKey = ({SignalEntityType type, String id});

/// Accumulated state of the "… têm interesse" popup's list.
class InterestedState {
  final List<InterestedUser> items;

  /// Offset for the next page = rows fetched so far.
  final int nextOffset;
  final bool hasMore;
  final bool isLoadingMore;

  /// Authoritative total from the server, which can exceed [items] length
  /// while paging — the header counts people, not loaded rows.
  final int total;

  const InterestedState({
    this.items = const [],
    this.nextOffset = 0,
    this.hasMore = true,
    this.isLoadingMore = false,
    this.total = 0,
  });

  InterestedState copyWith({
    List<InterestedUser>? items,
    int? nextOffset,
    bool? hasMore,
    bool? isLoadingMore,
    int? total,
  }) {
    return InterestedState(
      items: items ?? this.items,
      nextOffset: nextOffset ?? this.nextOffset,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      total: total ?? this.total,
    );
  }
}

/// Pages `GET /{events|places}/{id}/interested-by` for the popup.
///
/// `autoDispose`: the roster is viewer-relative and moves as people like, save
/// and unsave, so holding it past the sheet would serve a stale list.
class InterestedNotifier
    extends AutoDisposeFamilyAsyncNotifier<InterestedState, InterestedKey> {
  static const int _pageSize = 20;

  @override
  Future<InterestedState> build(InterestedKey arg) async {
    final page = await ref
        .watch(detailApiProvider)
        .getInterestedBy(arg.type, arg.id, limit: _pageSize);
    return InterestedState(
      items: page.items,
      nextOffset: page.nextOffset ?? page.items.length,
      hasMore: page.hasMore,
      total: page.total,
    );
  }

  Future<void> loadMore() async {
    final cur = state.valueOrNull;
    if (cur == null || !cur.hasMore || cur.isLoadingMore) return;
    state = AsyncData(cur.copyWith(isLoadingMore: true));
    try {
      final page = await ref
          .read(detailApiProvider)
          .getInterestedBy(
            arg.type,
            arg.id,
            limit: _pageSize,
            offset: cur.nextOffset,
          );
      final merged = [...cur.items, ...page.items];
      state = AsyncData(
        cur.copyWith(
          items: merged,
          nextOffset: page.nextOffset ?? merged.length,
          hasMore: page.hasMore,
          isLoadingMore: false,
          total: page.total,
        ),
      );
    } catch (_) {
      // A failed page leaves what's loaded on screen — the sheet is a
      // read-only roster, so silently stopping beats an error state that
      // hides the names already fetched.
      state = AsyncData(cur.copyWith(isLoadingMore: false, hasMore: false));
    }
  }
}

final interestedProvider = AsyncNotifierProvider.autoDispose
    .family<InterestedNotifier, InterestedState, InterestedKey>(
      InterestedNotifier.new,
    );
