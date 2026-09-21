import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ingest_job.dart';

/// Generic polling + auto-dismiss controller for long-running ingest jobs.
///
/// Owns ONLY the time-dependent mechanics (`Timer.periodic` poll loop +
/// post-terminal auto-dismiss `Timer`). Feature-specific state mutation,
/// persistence, and fan-out live in the caller (typically a `StateNotifier`)
/// and are wired in via the constructor callbacks.
///
/// Shared by `instagram_share_polling_provider.dart` and the new
/// `contribution_polling_provider.dart` (PROD-2404). When adding a third
/// consumer, that's the signal that `submit-gate` and lifecycle-resume should
/// also be generalized.
class IngestPollingController<TJob extends IngestJob> {
  IngestPollingController({
    required this.pollInterval,
    required this.completedDisplayDuration,
    required this.fetch,
    required this.onUpdate,
    required this.onTerminal,
    required this.onAutoDismiss,
  });

  /// Cadence between polls while the active job is non-terminal.
  final Duration pollInterval;

  /// How long the caller wants to keep showing a terminal job before
  /// the auto-dismiss callback fires.
  final Duration completedDisplayDuration;

  /// Network call that fetches the latest [TJob] for a given job id.
  /// Errors are caught — transient failures keep the loop alive.
  final Future<TJob> Function(String jobId) fetch;

  /// Fired every time a poll completes successfully (pending, processing,
  /// AND terminal — terminal updates fire both [onUpdate] AND [onTerminal]).
  /// Caller uses this to update its observable state.
  final void Function(TJob job) onUpdate;

  /// Fired once when the active job transitions into a terminal state.
  /// Caller uses this to fire side effects (list refresh, persistence
  /// clear) that should run exactly once per job.
  final void Function(TJob job) onTerminal;

  /// Fired after [completedDisplayDuration] elapses on a terminal job.
  /// Caller uses this to hide the banner / clear persisted state.
  final void Function() onAutoDismiss;

  Timer? _pollTimer;
  Timer? _autoDismissTimer;
  String? _activeJobId;
  bool _disposed = false;

  /// Job id the controller is currently polling, or `null` if idle.
  String? get activeJobId => _activeJobId;

  /// Whether the periodic poll timer is currently active.
  bool get isPolling => _pollTimer?.isActive == true;

  /// Start polling [jobId]. Returns `true` if polling started, `false` if
  /// the call was a no-op (controller disposed, or already polling the
  /// same id).
  ///
  /// Starting with a different id while polling cancels the previous loop
  /// and begins a new one for the new id. The first poll fires immediately
  /// (the first periodic tick is scheduled `pollInterval` later).
  bool start(String jobId) {
    if (_disposed) return false;
    if (_activeJobId == jobId && _pollTimer?.isActive == true) {
      return false;
    }
    _activeJobId = jobId;
    _cancelTimers();
    // Fire immediately so the caller sees status without a full interval wait.
    // ignore: discarded_futures
    _poll();
    _pollTimer = Timer.periodic(pollInterval, (_) => _poll());
    return true;
  }

  /// Apply a job that the caller already knows is terminal (e.g. the iOS
  /// share-extension fast-path that polled to completion out-of-process).
  /// Cancels polling, fires [onUpdate] + [onTerminal], schedules auto-dismiss
  /// when the job is genuinely terminal. Non-terminal applications are
  /// surfaced via [onUpdate] only — no terminal callback, no auto-dismiss.
  void applyTerminal(TJob job) {
    if (_disposed) return;
    _activeJobId = job.jobId;
    _cancelTimers();
    onUpdate(job);
    if (job.isTerminal) {
      onTerminal(job);
      _scheduleAutoDismiss();
    }
  }

  /// Stop polling and forget the active job id without firing any callbacks.
  /// The caller is responsible for clearing its own observable state.
  void stop() {
    _cancelTimers();
    _activeJobId = null;
  }

  /// Permanently release timers. After dispose, [start] returns `false` and
  /// no callbacks fire.
  void dispose() {
    _disposed = true;
    _cancelTimers();
    _activeJobId = null;
  }

  Future<void> _poll() async {
    final id = _activeJobId;
    if (id == null || _disposed) return;
    try {
      final job = await fetch(id);
      // Bail if the controller was disposed mid-await, or if the active job
      // changed (start(otherId) raced with this in-flight fetch).
      if (_disposed || _activeJobId != id) return;
      onUpdate(job);
      if (job.isTerminal) {
        _pollTimer?.cancel();
        _pollTimer = null;
        onTerminal(job);
        _scheduleAutoDismiss();
      }
    } catch (e) {
      debugPrint('[IngestPollingController] Poll error for $id: $e');
      // Transient errors keep the loop alive.
    }
  }

  void _scheduleAutoDismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = Timer(completedDisplayDuration, () {
      if (_disposed) return;
      onAutoDismiss();
    });
  }

  void _cancelTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
  }
}
