import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ingest/ingest_list_fan_out.dart';
import '../../../core/ingest/ingest_polling_controller.dart';
import '../../../core/services/app_group_bridge.dart';
import '../../../core/services/storage_service.dart';
import '../../../data/datasources/api/instagram_share_api.dart';
import '../../../data/models/instagram_share.dart';
import '../../../providers/api_provider.dart';

/// Polling interval while there are active (non-terminal) shares.
const _pollInterval = Duration(seconds: 5);

/// How long to keep showing a completed share before auto-dismissing.
const _completedDisplayDuration = Duration(seconds: 30);

/// Stop trying to rehydrate a persisted share older than this — anything still
/// pending after a few minutes is almost certainly stale (browser closed,
/// crashed, etc.) and surfacing its banner on a fresh app open is just noise.
const _rehydrateMaxAge = Duration(minutes: 30);

/// State for the Instagram share polling banner.
class InstagramSharePollingState {
  /// The submitted share id currently being polled.
  final String? sharedPostId;

  /// The list id this share was submitted into, if any. When set, the
  /// banner's "Ver" CTA opens the ingested item in this list's context.
  /// When null (chat / native share), the banner falls back to finding the
  /// auto-created "From Instagram" list by name.
  final String? targetListId;

  /// The most recent non-terminal share (pending/processing), or the most
  /// recently completed one (for the "ready" banner).
  final SharedPostOut? activeShare;

  /// True while the initial fetch is in progress.
  final bool isLoading;

  /// True when the user has manually dismissed the banner.
  final bool dismissed;

  const InstagramSharePollingState({
    this.sharedPostId,
    this.targetListId,
    this.activeShare,
    this.isLoading = false,
    this.dismissed = false,
  });

  InstagramSharePollingState copyWith({
    String? sharedPostId,
    bool clearSharedPostId = false,
    String? targetListId,
    bool clearTargetListId = false,
    SharedPostOut? activeShare,
    bool clearActiveShare = false,
    bool? isLoading,
    bool? dismissed,
  }) {
    return InstagramSharePollingState(
      sharedPostId: clearSharedPostId
          ? null
          : (sharedPostId ?? this.sharedPostId),
      targetListId: clearTargetListId
          ? null
          : (targetListId ?? this.targetListId),
      activeShare: clearActiveShare ? null : (activeShare ?? this.activeShare),
      isLoading: isLoading ?? this.isLoading,
      dismissed: dismissed ?? this.dismissed,
    );
  }

  /// Whether the banner should be visible.
  bool get shouldShow => !dismissed && activeShare != null;

  /// Whether the active share is still being processed.
  bool get isProcessing =>
      activeShare != null &&
      (activeShare!.isPending || activeShare!.isProcessing);

  /// Whether the active share has completed successfully.
  bool get isCompleted => activeShare != null && activeShare!.isCompleted;

  /// Whether the active share produced entities the user should see.
  /// Covers both `completed` AND `pending_review` shares with non-empty
  /// `event_ids` (PROD-1728: events are created even when the venue can't
  /// be resolved, so the FE must surface them and refresh the list).
  bool get producedEntities =>
      activeShare != null && activeShare!.producedEntities;

  /// Whether the active share is in a terminal state but did NOT produce
  /// any entities (failed, irrelevant, past_event, or empty pending_review).
  bool get isFailed => activeShare?.isFailed ?? false;
}

/// Notifier that polls for Instagram share status updates.
///
/// PROD-2404: the polling/timer mechanics live in [IngestPollingController]
/// (shared with the new contributions flow) and the list-refresh fan-out
/// is centralized in [refreshAffectedLists]. The notifier owns the
/// state shape + IG-specific persistence + iOS App Group handoff.
class InstagramSharePollingNotifier
    extends StateNotifier<InstagramSharePollingState> {
  final InstagramShareApi _api;
  final Ref _ref;
  late final IngestPollingController<SharedPostOut> _controller;

  InstagramSharePollingNotifier(this._api, this._ref)
    : super(const InstagramSharePollingState()) {
    _controller = IngestPollingController<SharedPostOut>(
      pollInterval: _pollInterval,
      completedDisplayDuration: _completedDisplayDuration,
      fetch: _api.getShare,
      onUpdate: _handleUpdate,
      onTerminal: _handleTerminal,
      onAutoDismiss: _handleAutoDismiss,
    );
  }

  /// Start polling after a new share was submitted.
  ///
  /// [listId] is the user list this share was submitted into, if any. When
  /// set, the banner uses it as the origin context when opening the ingested
  /// item's detail.
  void startPolling(String sharedPostId, {String? listId}) {
    // Dedupe: re-running on the same id while already polling — or after
    // we've already applied a terminal state — would clear `activeShare`
    // and the share-result sheet would have nothing to open.
    if (_controller.activeJobId == sharedPostId &&
        (_controller.isPolling || state.activeShare?.isTerminal == true)) {
      return;
    }
    state = state.copyWith(
      sharedPostId: sharedPostId,
      targetListId: listId,
      clearTargetListId: listId == null,
      clearActiveShare: true,
      isLoading: true,
      dismissed: false,
    );
    _persist(sharedPostId, listId);
    _controller.start(sharedPostId);
  }

  /// Start polling when the submit response represents a post share.
  void startPollingForResult(ShareSubmitResponse result, {String? listId}) {
    final sharedPostId = result.sharedPostId;
    if (!result.isPost || sharedPostId == null) return;
    startPolling(sharedPostId, listId: listId);
  }

  /// Resume polling for a share persisted from a previous session, if any.
  /// Safe to call repeatedly — no-ops while a share is already being tracked.
  void rehydrate() {
    if (_controller.activeJobId != null) return;
    final saved = _ref.read(storageServiceProvider).loadActiveInstagramShare();
    if (saved == null) return;
    if (DateTime.now().difference(saved.savedAt) > _rehydrateMaxAge) {
      _clearPersisted();
      return;
    }
    startPolling(saved.sharedPostId, listId: saved.listId);
  }

  /// Apply a fully-resolved terminal share that the iOS Share Extension
  /// already polled to completion. Skips network polling entirely; the
  /// banner reflects the terminal state immediately, and the host app's
  /// fast-path opens the detail / review sheet on top.
  void applyTerminalFromExtension(SharedPostOut share, {String? listId}) {
    state = state.copyWith(
      sharedPostId: share.id,
      targetListId: listId,
      clearTargetListId: listId == null,
      isLoading: false,
      dismissed: false,
    );
    _controller.applyTerminal(share);
  }

  /// Dismiss the banner manually.
  void dismiss() {
    _controller.stop();
    state = state.copyWith(dismissed: true);
    _clearPersisted();
  }

  void _handleUpdate(SharedPostOut share) {
    if (!mounted) return;
    final previous = state.activeShare;
    // Refresh on first transition into ANY entity-producing state — both
    // `completed` (venue resolved) and `pending_review` with non-empty
    // event_ids (post-PROD-1728: backend creates events even when venue
    // resolution is deferred to manual curation, and they're already
    // added to "From Instagram"). Without this, pending_review shares
    // would silently leave the list stale until the next refresh.
    final justProduced =
        share.producedEntities &&
        (previous == null || !previous.producedEntities);

    state = state.copyWith(activeShare: share, isLoading: false);

    if (justProduced) {
      // ignore: discarded_futures
      _refreshLists(share);
    }
  }

  void _handleTerminal(SharedPostOut share) {
    // _handleUpdate already drove the list-refresh fan-out via its
    // transition check (covers both poll-path and applyTerminal-path). No
    // additional terminal-side effect needed; persistence is cleared by
    // _handleAutoDismiss on the timer.
  }

  void _handleAutoDismiss() {
    if (mounted) {
      state = state.copyWith(dismissed: true);
    }
    _clearPersisted();
  }

  Future<void> _refreshLists(SharedPostOut share) async {
    final targetListId = state.targetListId;
    await refreshAffectedLists(
      _ref,
      targetListId: targetListId,
      shouldInclude: (list) => list.isFromInstagramShare,
    );
  }

  void _persist(String sharedPostId, String? listId) {
    // Fire-and-forget — failure to persist isn't fatal, the banner just
    // won't survive a refresh in that case.
    // ignore: discarded_futures
    _ref
        .read(storageServiceProvider)
        .saveActiveInstagramShare(sharedPostId: sharedPostId, listId: listId);
  }

  void _clearPersisted() {
    // ignore: discarded_futures
    _ref.read(storageServiceProvider).clearActiveInstagramShare();
    // Also wipe the iOS App Group handoff keys so a stale `share.in_flight.v1`
    // doesn't resurrect this banner on the next cold launch / foreground via
    // `_consumeShareInFlightFromAppGroup`. No-op on non-iOS.
    // ignore: discarded_futures
    AppGroupBridge.instance.clearShareKeys();
  }

  @visibleForTesting
  bool get isPolling => _controller.isPolling;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// Provider for Instagram share polling.
final instagramSharePollingProvider =
    StateNotifierProvider<
      InstagramSharePollingNotifier,
      InstagramSharePollingState
    >((ref) {
      final api = ref.watch(instagramShareApiProvider);
      return InstagramSharePollingNotifier(api, ref);
    });
