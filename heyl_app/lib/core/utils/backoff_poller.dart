import 'dart:async';

/// Polling helper used by Daily Drop and Weekly Bundle providers while the
/// BE generates a recommendation. Schedule:
/// - polls fire at t = 1 s, 3 s, 6 s, then every 5 s
/// - hard cap at 2 minutes elapsed; calls [onTimeout] once if reached
/// - [poll] returns `true` to stop polling, `false` to continue
class BackoffPoller {
  static const _backoffSchedule = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
  ];
  static const _steadyInterval = Duration(seconds: 5);
  static const _maxDuration = Duration(minutes: 2);

  Timer? _timer;
  int _count = 0;
  DateTime? _startedAt;

  bool get isRunning => _startedAt != null;

  void start({
    required Future<bool> Function() poll,
    required void Function() onTimeout,
  }) {
    stop();
    _count = 0;
    _startedAt = DateTime.now();
    _scheduleNext(poll: poll, onTimeout: onTimeout);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
  }

  void _scheduleNext({
    required Future<bool> Function() poll,
    required void Function() onTimeout,
  }) {
    final startedAt = _startedAt;
    if (startedAt == null) return;
    if (DateTime.now().difference(startedAt) >= _maxDuration) {
      stop();
      onTimeout();
      return;
    }
    final delay = _count < _backoffSchedule.length
        ? _backoffSchedule[_count]
        : _steadyInterval;
    _timer = Timer(delay, () async {
      _count++;
      bool stopRequested;
      try {
        stopRequested = await poll();
      } catch (_) {
        stopRequested = false;
      }
      if (stopRequested) {
        stop();
        return;
      }
      _scheduleNext(poll: poll, onTimeout: onTimeout);
    });
  }
}
