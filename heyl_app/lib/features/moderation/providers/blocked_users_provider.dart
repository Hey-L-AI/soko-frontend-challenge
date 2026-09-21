import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/datasources/interfaces/moderation_api.dart';
import '../../../data/models/moderation.dart';
import '../../../data/models/user_list.dart';
import '../../../providers/api_provider.dart';

class BlockedUsersState {
  final bool loading;
  final List<BlockedUser> blocks;

  /// User ids the viewer has blocked in this session but for which the
  /// authoritative `GET /blocks` row may not yet have been fetched.
  /// Combined with [blocks] via [blockedUserIds] so content surfaces
  /// can hide blocked users' content immediately on a successful block,
  /// without waiting for the next /blocks refresh.
  final Set<String> localBlocks;

  final Object? error;

  const BlockedUsersState({
    this.loading = false,
    this.blocks = const [],
    this.localBlocks = const {},
    this.error,
  });

  /// Union of server-confirmed and session-local blocks. Content
  /// filters should watch [blockedUserIdsProvider] (a derived selector)
  /// instead of this field directly, to avoid rebuilds on unrelated
  /// state changes (e.g. `loading` toggling).
  Set<String> get blockedUserIds => {
    for (final b in blocks) b.blockedUserId,
    ...localBlocks,
  };

  BlockedUsersState copyWith({
    bool? loading,
    List<BlockedUser>? blocks,
    Set<String>? localBlocks,
    Object? error,
    bool clearError = false,
  }) {
    return BlockedUsersState(
      loading: loading ?? this.loading,
      blocks: blocks ?? this.blocks,
      localBlocks: localBlocks ?? this.localBlocks,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// PROD-2264 — Owns the Blocked Users management screen's state.
/// [load] hydrates from `GET /blocks`; [unblock] does an optimistic
/// remove + `DELETE /blocks/{id}`, restoring the row on failure.
class BlockedUsersNotifier extends StateNotifier<BlockedUsersState> {
  final IModerationApi _api;

  BlockedUsersNotifier(this._api) : super(const BlockedUsersState());

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final blocks = await _api.listBlocks();
      // Drop any session-local entries the server now reflects so the
      // [blockedUserIds] union doesn't double-count them. Local-only
      // entries (just-blocked, not yet round-tripped) stay.
      final serverBlocked = {for (final b in blocks) b.blockedUserId};
      final remainingLocal = state.localBlocks
          .where((id) => !serverBlocked.contains(id))
          .toSet();
      state = state.copyWith(
        loading: false,
        blocks: blocks,
        localBlocks: remainingLocal,
      );
    } catch (e) {
      debugPrint('[BlockedUsers] load failed: $e');
      state = state.copyWith(loading: false, error: e);
    }
  }

  /// Records a successful block in the session-local set so any UI
  /// watching [blockedUserIdsProvider] hides the blocked user's content
  /// immediately, before /blocks is refetched. The entry is cleared by
  /// the next [load] once the server confirms it.
  void addLocalBlock(String blockedUserId) {
    if (state.localBlocks.contains(blockedUserId)) return;
    state = state.copyWith(localBlocks: {...state.localBlocks, blockedUserId});
  }

  /// Removes [blockId] from the local list optimistically and fires
  /// `DELETE /blocks/{id}`. Returns `true` on success and re-inserts
  /// the row on failure so the caller can show an error toast.
  Future<bool> unblock(String blockId) async {
    final previous = state.blocks;
    final removed = previous.where((b) => b.blockId == blockId).toList();
    state = state.copyWith(
      blocks: previous.where((b) => b.blockId != blockId).toList(),
    );
    try {
      await _api.unblock(blockId);
      return true;
    } catch (e) {
      debugPrint('[BlockedUsers] unblock failed: $e');
      // Re-insert the row at its original position so the user can retry.
      if (removed.isNotEmpty) {
        final restored = List<BlockedUser>.from(state.blocks);
        final originalIndex = previous.indexOf(removed.first);
        restored.insert(originalIndex.clamp(0, restored.length), removed.first);
        state = state.copyWith(blocks: restored, error: e);
      }
      return false;
    }
  }
}

final blockedUsersProvider =
    StateNotifierProvider<BlockedUsersNotifier, BlockedUsersState>((ref) {
      return BlockedUsersNotifier(ref.watch(moderationApiProvider));
    });

/// PROD-2264 — Derived selector exposing only the union of blocked user
/// ids for content-filtering call-sites. Watching this provider rebuilds
/// only when the underlying ids change, not when `loading` toggles or an
/// unrelated field of [BlockedUsersState] mutates.
final blockedUserIdsProvider = Provider<Set<String>>((ref) {
  return ref.watch(blockedUsersProvider).blockedUserIds;
});

/// PROD-2264 — Drops [UserList]s whose [UserList.ownerId] is in
/// [blockedIds]. Call sites watch [blockedUserIdsProvider] themselves
/// (so they rebuild when the set changes) and pipe items through this
/// helper before rendering. Returns the input identity-unchanged when
/// the block set is empty, so the no-blocks path is allocation-free.
List<UserList> filterByBlockedAuthors(
  List<UserList> items,
  Set<String> blockedIds,
) {
  if (blockedIds.isEmpty) return items;
  return items.where((l) => !blockedIds.contains(l.ownerId)).toList();
}
