import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/exceptions/api_exceptions.dart';
import '../../../data/datasources/api/contributions_api.dart';
import '../../../data/models/event_contribution.dart';
import '../../../providers/api_provider.dart';
import 'contribution_polling_provider.dart';

/// Client-side gate exception: the user tried to submit a new contribution
/// while a previous one is still being polled to terminal. UI displays a
/// "wait for your last submission to finish" message and offers to focus
/// the existing in-flight banner.
class ContributionWaitForPreviousException extends ApiException {
  ContributionWaitForPreviousException()
    : super('A previous contribution is still being processed.');
}

/// State for a photo-contribution submission.
class ContributionSubmitState {
  /// True while the POST is in flight.
  final bool isSubmitting;

  /// 202 response from the most recent successful submit, or null.
  final EventContributionOut? result;

  /// Last error from the submit path. Either a typed [ApiException] from the
  /// central error interceptor ([ContentBlockedException],
  /// [ImageModerationUnavailableException], [ValidationException], etc.) or
  /// the local [ContributionWaitForPreviousException] gate.
  final Object? error;

  const ContributionSubmitState({
    this.isSubmitting = false,
    this.result,
    this.error,
  });

  ContributionSubmitState copyWith({
    bool? isSubmitting,
    EventContributionOut? result,
    bool clearResult = false,
    Object? error,
    bool clearError = false,
  }) {
    return ContributionSubmitState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
      result: clearResult ? null : (result ?? this.result),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Notifier for submitting a photo→event contribution.
///
/// Submits to `POST /api/v1/app/contributions/events`, gates against an
/// already-in-flight contribution, and on success hands the returned
/// `EventContributionOut` (with `status='pending'`) off to the
/// [contributionPollingProvider] so the in-app banner picks up from there.
class ContributionSubmitNotifier
    extends StateNotifier<ContributionSubmitState> {
  final ContributionsApi _api;
  final Ref _ref;

  ContributionSubmitNotifier(this._api, this._ref)
    : super(const ContributionSubmitState());

  /// Submit a picked image for event extraction.
  ///
  /// Returns the 202 [EventContributionOut] on success, or `null` on failure
  /// (error stored in state). Refuses with
  /// [ContributionWaitForPreviousException] when the polling banner is
  /// still active for an earlier submission — the user must wait for that
  /// one to reach a terminal state.
  Future<EventContributionOut?> submit({
    required Uint8List bytes,
    required String filename,
    required String contentType,
    required String city,
    required String country,
    String? note,
    String? venueId,
    String? link,
  }) async {
    final polling = _ref.read(contributionPollingProvider);
    if (polling.isProcessing) {
      state = state.copyWith(
        isSubmitting: false,
        clearResult: true,
        error: ContributionWaitForPreviousException(),
      );
      return null;
    }

    state = state.copyWith(
      isSubmitting: true,
      clearError: true,
      clearResult: true,
    );

    try {
      final result = await _api.submitContribution(
        bytes: bytes,
        filename: filename,
        contentType: contentType,
        city: city,
        country: country,
        note: note,
        venueId: venueId,
        link: link,
      );
      // Kick the polling banner off the returned id (the 202 body is the
      // same shape as a poll row, with `status='pending'`).
      _ref
          .read(contributionPollingProvider.notifier)
          .startPollingForResult(result);
      state = state.copyWith(isSubmitting: false, result: result);
      return result;
    } catch (e) {
      state = state.copyWith(isSubmitting: false, error: e);
      return null;
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  void reset() {
    state = const ContributionSubmitState();
  }
}

/// Provider for the contribution submit state.
final contributionSubmitProvider =
    StateNotifierProvider<ContributionSubmitNotifier, ContributionSubmitState>((
      ref,
    ) {
      final api = ref.watch(contributionsApiProvider);
      return ContributionSubmitNotifier(api, ref);
    });
