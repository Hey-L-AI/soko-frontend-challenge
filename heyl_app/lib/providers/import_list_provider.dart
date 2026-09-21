import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/storage_service.dart';
import '../core/services/unified_analytics_service.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import '../data/models/import_job.dart';
import 'api_provider.dart';
import 'lists_provider.dart';

/// State for an active Google Maps import job
class ImportListState {
  /// The current job ID being polled
  final String? jobId;

  /// URL that was submitted (for retry)
  final String? url;

  /// Custom list name (for retry and display)
  final String? listName;

  /// Current job status
  final ImportJobStatus? status;

  /// Progress info (when processing)
  final ImportProgress? progress;

  /// Result info (when completed)
  final ImportJobResult? result;

  /// Stable error code surfaced to the UI (when failed): `'invalid_url'`,
  /// `'rate_limited'`, `'backend'`, or `'unknown'`. The UI maps these to copy.
  final String? error;

  /// Backend-provided human message, used only when [error] is `'backend'`
  /// (an unrecognized structured `error_code`) so we can fall back to the
  /// server's `detail.message` instead of a generic string (PROD-2426).
  final String? errorMessage;

  /// Whether the initial submit is in progress
  final bool isSubmitting;

  const ImportListState({
    this.jobId,
    this.url,
    this.listName,
    this.status,
    this.progress,
    this.result,
    this.error,
    this.errorMessage,
    this.isSubmitting = false,
  });

  ImportListState copyWith({
    String? jobId,
    String? url,
    String? listName,
    ImportJobStatus? status,
    ImportProgress? progress,
    ImportJobResult? result,
    String? error,
    String? errorMessage,
    bool? isSubmitting,
  }) {
    return ImportListState(
      jobId: jobId ?? this.jobId,
      url: url ?? this.url,
      listName: listName ?? this.listName,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      result: result ?? this.result,
      error: error ?? this.error,
      errorMessage: errorMessage ?? this.errorMessage,
      isSubmitting: isSubmitting ?? this.isSubmitting,
    );
  }

  /// Whether an import is actively in progress (queued or processing)
  bool get isActive =>
      jobId != null &&
      (status == ImportJobStatus.queued ||
          status == ImportJobStatus.processing);

  /// Whether the import has completed (successfully or with partial success)
  bool get isCompleted => status == ImportJobStatus.completed;

  /// Whether the import failed
  bool get isFailed => status == ImportJobStatus.failed;

  /// Whether there's any import state to show (active, completed, or failed)
  bool get hasJob => jobId != null;

  /// Display name for the import (custom name or placeholder)
  String get displayName => listName ?? url ?? 'Importing...';

  /// Progress fraction (0.0 to 1.0)
  double get progressFraction {
    if (status == ImportJobStatus.queued) return 0.0;
    if (status == ImportJobStatus.completed) return 1.0;
    return progress?.fraction ?? 0.0;
  }
}

/// Notifier that manages Google Maps import state and polling
class ImportListNotifier extends StateNotifier<ImportListState> {
  final IListsApi _api;
  final Ref _ref;
  final StorageService _storage;
  Timer? _pollTimer;

  ImportListNotifier(this._api, this._ref, this._storage)
    : super(const ImportListState()) {
    _restoreFromStorage();
  }

  /// Restore an in-progress import job from storage (survives page refresh)
  Future<void> _restoreFromStorage() async {
    final stored = _storage.loadActiveImportJob();
    if (stored == null) return;

    final jobId = stored['jobId'];
    final url = stored['url'];
    if (jobId == null || jobId.isEmpty) {
      await _storage.clearActiveImportJob();
      return;
    }

    debugPrint(
      '[ImportListNotifier] Restoring import job from storage: $jobId',
    );

    state = ImportListState(
      jobId: jobId,
      url: url,
      listName: stored['listName'],
      status: ImportJobStatus.queued,
    );

    // Start polling — first poll will get real status from backend
    _startPolling();
  }

  /// Start a new import job
  Future<void> startImport(String url, {String? listName}) async {
    // Cancel any existing polling
    _cancelPolling();

    state = ImportListState(url: url, listName: listName, isSubmitting: true);

    try {
      final response = await _api.importGoogleMapsList(url, listName: listName);

      // Persist job data so it survives page refreshes
      await _storage.saveActiveImportJob(
        jobId: response.jobId,
        url: url,
        listName: listName,
      );

      state = state.copyWith(
        jobId: response.jobId,
        status: ImportJobStatus.queued,
        isSubmitting: false,
      );

      // Track import start (PostHog)
      _ref.read(unifiedAnalyticsProvider).trackListImportStart(url: url);

      // Start polling
      _startPolling();
    } catch (e) {
      debugPrint('[ImportListNotifier] Failed to start import: $e');
      final (code, message) = _mapError(e);
      state = state.copyWith(
        isSubmitting: false,
        error: code,
        errorMessage: message,
        status: ImportJobStatus.failed,
      );
    }
  }

  /// Adopt an import job that was already created elsewhere and start polling.
  ///
  /// The paste-a-link endpoint (`POST /places/resolve-url`) returns 202 + a
  /// `job_id` when the pasted URL is a shared list (PROD-3903). We already have
  /// the job, so we skip the POST that [startImport] does and go straight to
  /// polling — reusing the same persistence, progress, terminal handling, and
  /// the `NotificationHost` progress/success/failure UI. On failure,
  /// [retryImport] re-submits `url` via the async endpoint, which is fine.
  Future<void> adopt(
    String jobId, {
    required String url,
    String? listName,
  }) async {
    _cancelPolling();

    // Persist so it survives a page refresh, exactly like startImport.
    await _storage.saveActiveImportJob(
      jobId: jobId,
      url: url,
      listName: listName,
    );

    state = ImportListState(
      jobId: jobId,
      url: url,
      listName: listName,
      status: ImportJobStatus.queued,
    );

    _ref.read(unifiedAnalyticsProvider).trackListImportStart(url: url);

    _startPolling();
  }

  /// Retry the last failed import
  void retryImport() {
    final url = state.url;
    if (url != null) {
      startImport(url, listName: state.listName);
    }
  }

  /// Clear the import state (dismiss completed/failed job)
  void clear() {
    _cancelPolling();
    _storage.clearActiveImportJob();
    state = const ImportListState();
  }

  /// Start polling for job status
  void _startPolling() {
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _pollStatus(),
    );
    // Also poll immediately
    _pollStatus();
  }

  /// Cancel polling
  void _cancelPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Poll the job status once
  Future<void> _pollStatus() async {
    final jobId = state.jobId;
    if (jobId == null) {
      _cancelPolling();
      return;
    }

    try {
      final response = await _api.getImportJobStatus(jobId);

      state = state.copyWith(
        status: response.status,
        progress: response.progress,
        result: response.result,
        error: response.error,
      );

      // Stop polling if job is terminal
      if (response.isTerminal) {
        _cancelPolling();
        await _storage.clearActiveImportJob();

        // On completion, refresh the lists and track
        if (response.isCompleted) {
          _ref.read(listsProvider.notifier).loadLists();
        }
      }
    } catch (e) {
      debugPrint('[ImportListNotifier] Poll failed: $e');
      // If job not found (404), it likely expired in Redis — clear and reset
      final errorStr = e.toString();
      if (errorStr.contains('404') || errorStr.contains('Not Found')) {
        debugPrint('[ImportListNotifier] Job expired (404), clearing state');
        _cancelPolling();
        await _storage.clearActiveImportJob();
        state = const ImportListState();
      }
      // Otherwise don't stop polling on transient errors - just log and continue
    }
  }

  /// Map a thrown error to a stable UI code + optional backend message.
  ///
  /// The backend returns structured errors as `400 { detail: { error,
  /// error_code, message } }` (PROD-2426). The app's `ErrorInterceptor`
  /// stringifies `DioException.error`, but it preserves the raw body on
  /// `DioException.response`, so we read `detail.error_code` straight from
  /// there. Returns one of: `'invalid_url'`, `'rate_limited'`, `'backend'`
  /// (unrecognized structured code → surface `detail.message`), `'unknown'`.
  (String code, String? message) _mapError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      final detail = (data is Map<String, dynamic>) ? data['detail'] : null;
      final errorCode = (detail is Map<String, dynamic>)
          ? detail['error_code'] as String?
          : null;
      final message = (detail is Map<String, dynamic>)
          ? detail['message'] as String?
          : null;

      if (errorCode == 'INVALID_GOOGLE_MAPS_URL') {
        return ('invalid_url', null);
      }
      if (error.response?.statusCode == 429) {
        return ('rate_limited', null);
      }
      // Unknown structured code (future backend additions) — fall back to the
      // server-provided message so a new code never breaks the surface.
      if (errorCode != null && message != null) {
        return ('backend', message);
      }
    }

    // Legacy string-match for rate limiting. PROD-2427 will give 429 a
    // structured `RATE_LIMITED` code; delete this branch once that lands.
    final errorStr = error.toString();
    if (errorStr.contains('429') || errorStr.contains('Too Many')) {
      return ('rate_limited', null);
    }
    return ('unknown', null);
  }

  @override
  void dispose() {
    _cancelPolling();
    super.dispose();
  }
}

/// Provider for import list state
final importListProvider =
    StateNotifierProvider<ImportListNotifier, ImportListState>((ref) {
      final api = ref.watch(listsApiProvider);
      final storage = ref.watch(storageServiceProvider);
      return ImportListNotifier(api, ref, storage);
    });
