import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ingest/ingest_list_fan_out.dart';
import '../../../core/ingest/ingest_polling_controller.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../data/datasources/api/contributions_api.dart';
import '../../../data/models/event_contribution.dart';
import '../../../providers/api_provider.dart';

/// Polling cadence — matches the IG-share flow (PROD-2404 decision: align
/// with IG over the ticket's literal "every 2s" AC bullet).
const _pollInterval = Duration(seconds: 5);

/// How long to keep showing a terminal contribution before auto-dismissing
/// the banner.
const _completedDisplayDuration = Duration(seconds: 30);

/// Stop rehydrating a persisted contribution older than this — anything
/// still pending after a few minutes on a fresh app open is almost certainly
/// stale (browser closed, app crashed) and surfacing its banner is noise.
const _rehydrateMaxAge = Duration(minutes: 30);

/// State for the photo-contribution polling banner.
class ContributionPollingState {
  /// The contribution id currently being polled.
  final String? contributionId;

  /// The most recent contribution row (non-terminal while polling, terminal
  /// once `extracted` or `failed` arrives).
  final EventContributionOut? activeContribution;

  /// True while the initial fetch is in progress.
  final bool isLoading;

  /// True when the user has manually dismissed the banner or the auto-
  /// dismiss timer fired.
  final bool dismissed;

  const ContributionPollingState({
    this.contributionId,
    this.activeContribution,
    this.isLoading = false,
    this.dismissed = false,
  });

  ContributionPollingState copyWith({
    String? contributionId,
    bool clearContributionId = false,
    EventContributionOut? activeContribution,
    bool clearActiveContribution = false,
    bool? isLoading,
    bool? dismissed,
  }) {
    return ContributionPollingState(
      contributionId: clearContributionId
          ? null
          : (contributionId ?? this.contributionId),
      activeContribution: clearActiveContribution
          ? null
          : (activeContribution ?? this.activeContribution),
      isLoading: isLoading ?? this.isLoading,
      dismissed: dismissed ?? this.dismissed,
    );
  }

  /// Whether the banner should be visible.
  bool get shouldShow => !dismissed && activeContribution != null;

  /// Active contribution is still being processed.
  bool get isProcessing =>
      activeContribution != null &&
      (activeContribution!.isPending || activeContribution!.isProcessing);

  /// Active contribution produced events the user should see.
  bool get producedEntities => activeContribution?.producedEntities ?? false;

  /// Active contribution reached a terminal state without producing events.
  bool get isFailed => activeContribution?.isFailed ?? false;
}

/// Polls `GET /api/v1/app/contributions/events/{id}` for an in-flight
/// photo→event contribution submitted via [ContributionsApi.submitContribution].
///
/// Wraps the shared [IngestPollingController] (Phase 1 of PROD-2404) — the
/// timer + auto-dismiss mechanics live there. This notifier owns the state
/// shape + persistence + the per-flow list-refresh fan-out predicate.
class ContributionPollingNotifier
    extends StateNotifier<ContributionPollingState> {
  final ContributionsApi _api;
  final Ref _ref;
  late final IngestPollingController<EventContributionOut> _controller;

  ContributionPollingNotifier(this._api, this._ref)
    : super(const ContributionPollingState()) {
    _controller = IngestPollingController<EventContributionOut>(
      pollInterval: _pollInterval,
      completedDisplayDuration: _completedDisplayDuration,
      fetch: _api.getContribution,
      onUpdate: _handleUpdate,
      onTerminal: _handleTerminal,
      onAutoDismiss: _handleAutoDismiss,
    );
  }

  /// Start polling after a new contribution was submitted (202).
  void startPolling(String contributionId) {
    // Dedupe: re-running on the same id while already polling — or after
    // we've already applied a terminal state — would clear `activeContribution`
    // and the result sheet would have nothing to open.
    if (_controller.activeJobId == contributionId &&
        (_controller.isPolling ||
            state.activeContribution?.isTerminal == true)) {
      return;
    }
    state = state.copyWith(
      contributionId: contributionId,
      clearActiveContribution: true,
      isLoading: true,
      dismissed: false,
    );
    _persist(contributionId);
    _controller.start(contributionId);
  }

  /// Convenience: hand off from the submit response (which is the same
  /// shape as a poll row — the backend returns `EventContributionOut` with
  /// `status='pending'` on the 202).
  void startPollingForResult(EventContributionOut result) {
    startPolling(result.id);
  }

  /// Resume polling for a contribution persisted from a previous session,
  /// if any. Safe to call repeatedly — no-ops while a contribution is
  /// already being tracked, drops stale persistence (>30 min).
  void rehydrate() {
    if (_controller.activeJobId != null) return;
    final saved = _ref.read(storageServiceProvider).loadActiveContribution();
    if (saved == null) return;
    if (DateTime.now().difference(saved.savedAt) > _rehydrateMaxAge) {
      _clearPersisted();
      return;
    }
    startPolling(saved.contributionId);
  }

  /// Dismiss the banner manually.
  void dismiss() {
    _controller.stop();
    state = state.copyWith(dismissed: true);
    _clearPersisted();
  }

  void _handleUpdate(EventContributionOut contribution) {
    if (!mounted) return;
    final previous = state.activeContribution;
    final justProduced =
        contribution.producedEntities &&
        (previous == null || !previous.producedEntities);

    state = state.copyWith(activeContribution: contribution, isLoading: false);

    if (justProduced) {
      // ignore: discarded_futures
      _refreshLists();
    }
  }

  void _handleTerminal(EventContributionOut contribution) {
    // _handleUpdate's transition check already drives the list-refresh
    // fan-out. Persistence is cleared by the auto-dismiss callback.
    // Emit terminal analytics from here — the sheet used to do it via a
    // `ref.listen`, but PROD-2404 closes the sheet on submit so the
    // listener wouldn't fire. The provider is the natural owner of the
    // state transition.
    final analytics = _ref.read(unifiedAnalyticsProvider);
    if (contribution.producedEntities) {
      analytics.trackPhotoContributionSuccess(
        contributionId: contribution.id,
        eventCount: contribution.eventIds.length,
      );
    } else if (contribution.isFailed) {
      analytics.trackPhotoContributionFailure(
        contributionId: contribution.id,
        failureCategory: contribution.failureCategory?.name ?? 'unhandled',
      );
    }
  }

  void _handleAutoDismiss() {
    if (mounted) {
      state = state.copyWith(dismissed: true);
    }
    _clearPersisted();
  }

  /// Refresh the lists hub + the per-list items of every
  /// `system_kind='user_contributions'` list so the new event surfaces in
  /// "As minhas contribuições" without a manual pull-to-refresh.
  ///
  /// Failures are swallowed — a list-refresh hiccup must not derail the
  /// polling banner (the user still sees the success state; the next time
  /// the lists hub mounts it'll fetch fresh anyway).
  Future<void> _refreshLists() async {
    try {
      await refreshAffectedLists(
        _ref,
        shouldInclude: (list) => list.isUserContributions,
      );
    } catch (e) {
      debugPrint('[ContributionPolling] _refreshLists failed: $e');
    }
  }

  void _persist(String contributionId) {
    // Fire-and-forget — failure to persist isn't fatal, the banner just
    // won't survive a refresh in that case.
    // ignore: discarded_futures
    _ref
        .read(storageServiceProvider)
        .saveActiveContribution(contributionId: contributionId);
  }

  void _clearPersisted() {
    // ignore: discarded_futures
    _ref.read(storageServiceProvider).clearActiveContribution();
  }

  @visibleForTesting
  bool get isPolling => _controller.isPolling;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// Provider for the photo-contribution polling banner.
final contributionPollingProvider =
    StateNotifierProvider<
      ContributionPollingNotifier,
      ContributionPollingState
    >((ref) {
      final api = ref.watch(contributionsApiProvider);
      return ContributionPollingNotifier(api, ref);
    });
