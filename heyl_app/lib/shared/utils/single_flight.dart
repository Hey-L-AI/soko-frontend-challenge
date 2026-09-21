/// Runs an async action, **dropping** any call that arrives while one is
/// already in flight.
library;

import 'settling_value.dart' show SettlingValue;

///
/// The case this exists for: a tap handler that awaits something before it
/// opens a route. Any await between the tap and the `push` is a window in
/// which a second tap starts a second, independent run — and both eventually
/// push, stacking duplicate routes on top of each other.
///
/// Dropping is deliberate, and is not the only option. There are three:
///
/// - **drop** — here. The second call resolves to `null` and nothing happens.
/// - **share** — hand later callers the first run's result (what
///   `PushPermissionService` does with a `Completer`).
/// - **queue the last one** — see [SettlingValue]. Paint the second tap, send
///   it once the first answers.
///
/// Share when callers only read the result; drop when they *act* on it. A
/// picker's callers commit the pick — publishing a new search centre and
/// persisting it to the active chat — so sharing would run that commit once per
/// tap for a single user choice. Queue when the second tap is the user changing
/// their mind and losing it loses an instruction: a follow button, a thumb.
///
/// Dropped calls resolve to `null`, which every picker call site already
/// handles as "the user cancelled", so the second tap is a no-op rather than
/// an error anyone has to think about.
///
/// Not a lock: there is no queue and no fairness. It is a latch that is held
/// for exactly as long as the action runs, and it is released in a `finally`
/// so a throwing action cannot wedge it closed — a stuck latch would make the
/// guarded affordance permanently dead, which is worse than the duplicate it
/// prevents.
class SingleFlight {
  bool _busy = false;

  /// True while an action is running. Useful for disabling the affordance.
  bool get isBusy => _busy;

  /// Runs [action] and returns its result, or returns `null` immediately if a
  /// previous run has not finished. Exceptions propagate to the caller that
  /// started the run, after releasing the latch.
  Future<T?> run<T>(Future<T?> Function() action) async {
    if (_busy) return null;
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }
}
