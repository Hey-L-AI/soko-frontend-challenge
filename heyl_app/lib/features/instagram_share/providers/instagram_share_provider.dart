import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/datasources/api/instagram_share_api.dart';
import '../../../data/datasources/api/instagram_share_failure.dart';
import '../../../data/models/instagram_share.dart';
import '../../../providers/api_provider.dart';
import 'instagram_share_polling_provider.dart';

/// State for an Instagram share submission.
class InstagramShareState {
  final bool isSubmitting;
  final ShareSubmitResponse? result;
  final InstagramShareFailure? error;

  const InstagramShareState({
    this.isSubmitting = false,
    this.result,
    this.error,
  });

  InstagramShareState copyWith({
    bool? isSubmitting,
    ShareSubmitResponse? result,
    bool clearResult = false,
    InstagramShareFailure? error,
    bool clearError = false,
  }) {
    return InstagramShareState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
      result: clearResult ? null : (result ?? this.result),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Notifier for submitting Instagram URLs.
class InstagramShareNotifier extends StateNotifier<InstagramShareState> {
  final InstagramShareApi _api;
  final Ref _ref;

  InstagramShareNotifier(this._api, this._ref)
      : super(const InstagramShareState());

  /// Submit an Instagram URL for scraping.
  ///
  /// Returns the [ShareSubmitResponse] on success, or null on failure
  /// (error stored in state). Refuses with [InstagramShareWaitForPrevious]
  /// if another submission is already pending/processing — the user must
  /// wait for that share to reach a terminal state before sending another.
  Future<ShareSubmitResponse?> submit(String url, {String? listId}) async {
    final polling = _ref.read(instagramSharePollingProvider);
    if (polling.isProcessing) {
      state = state.copyWith(
        isSubmitting: false,
        clearResult: true,
        error: const InstagramShareWaitForPrevious(),
      );
      return null;
    }

    state = state.copyWith(
      isSubmitting: true,
      clearError: true,
      clearResult: true,
    );

    try {
      final result = await _api.submitShare(url, listId: listId);
      state = state.copyWith(isSubmitting: false, result: result);
      return result;
    } on InstagramShareFailure catch (e) {
      state = state.copyWith(isSubmitting: false, error: e);
      return null;
    } catch (_) {
      state = state.copyWith(
        isSubmitting: false,
        error: const InstagramShareUnknown(),
      );
      return null;
    }
  }

  /// Clear error state (e.g., after showing a snackbar).
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  /// Reset to initial state.
  void reset() {
    state = const InstagramShareState();
  }
}

/// Provider for Instagram share submission.
final instagramShareProvider =
    StateNotifierProvider<InstagramShareNotifier, InstagramShareState>((ref) {
      final api = ref.watch(instagramShareApiProvider);
      return InstagramShareNotifier(api, ref);
    });
