/// One value the screen paints optimistically, with a server behind it.
///
/// The third strategy for a re-entrant tap handler, alongside [SingleFlight]'s
/// two: **drop** the second call, **share** the first call's result, or — here —
/// **queue the last one**. Drop when a second run would duplicate a side effect
/// nobody asked for. Queue when the second tap is the user changing their mind,
/// and losing it is losing an instruction.
///
/// It holds two things, and the whole design is in the gap between them:
///
/// - [truth] — the last value the SERVER confirmed.
/// - the caller's own displayed value, which [truth] may only correct while the
///   user is not actively driving it.
///
/// Three rules follow.
///
/// **Reads are stamped on departure.** Take [seq] before a read leaves; pass it
/// back to [accepts] on arrival. An answer that left before the last tap is
/// older than the user's intent whatever order it lands in, so it may fill the
/// axes nobody is touching and must not move this one.
///
/// **A tap is never dropped.** [intend] always records. A tap arriving mid-write
/// overwrites the queued one — only the newest intent matters, so the queue is
/// one slot deep and never a backlog.
///
/// **One write at a time, computed from [truth].** [drain] sends the queued
/// intent only after the previous write answers, and hands `write` the value the
/// server actually confirmed rather than the optimistic guess. That matters most
/// when the endpoint takes a VERB (`like`, which toggles) instead of a target
/// state: two of those in flight would apply in whatever order the server
/// happened to process them.
library;

import 'single_flight.dart' show SingleFlight;

class SettlingValue<T> {
  SettlingValue(T truth) : _truth = truth;

  T _truth;
  int _seq = 0;
  T? _pending;
  bool _writing = false;

  /// The last value the server confirmed.
  T get truth => _truth;

  /// Bumped by every [intend]. Stamp an outbound read with this.
  int get seq => _seq;

  /// Whether a write is in the air or queued behind one.
  bool get settling => _writing || _pending != null;

  /// Whether an inbound read stamped [departedAt] may still move the displayed
  /// value. False once a tap has happened since it left, or while a write is
  /// out — in both cases the read predates the user's intent.
  bool accepts(int departedAt) => departedAt == _seq && !_writing;

  /// Adopt a value the server reported without a tap behind it (a refresh).
  /// Does not touch [seq]: a read is not an intent.
  void adopt(T serverValue) => _truth = serverValue;

  /// Adopt a value some OTHER write confirmed — a second endpoint that resolves
  /// this same axis. Bumps [seq] like a tap, because a read already in flight
  /// is now stale, but queues nothing: there is nothing left to send.
  void supersede(T serverValue) {
    _seq++;
    _truth = serverValue;
  }

  /// Record what the user just asked for, and return it so the caller can paint
  /// it in the same breath. Overwrites any queued intent.
  T intend(T desired) {
    _seq++;
    _pending = desired;
    return desired;
  }

  /// Send queued intents, one at a time, until none is left.
  ///
  /// Returns as soon as a write is already draining — the running loop picks up
  /// what [intend] just queued, so a caller may always `intend` then `drain`.
  ///
  /// [write] moves the server from the confirmed value to the target and returns
  /// what it confirmed. [onWrote] fires for every landed write **even when
  /// [isAlive] is false**: the write reached the server, so an app-wide store
  /// must record it whether or not the widget that started it still exists.
  /// [onSettled] fires only when a write lands with nothing newer queued — the
  /// one moment the screen may adopt server truth. [onFailed] fires once if a
  /// write throws, and the queue is dropped.
  Future<void> drain({
    required Future<T> Function(T from, T to) write,
    required void Function(T truth) onSettled,
    required void Function(Object error, T truth) onFailed,
    void Function(T truth)? onWrote,
    bool Function()? isAlive,
  }) async {
    if (_writing) return;
    _writing = true;
    try {
      while (_pending != null) {
        final target = _pending as T;
        _pending = null;
        if (target == _truth) {
          // The server already holds what the user asked for.
          if (isAlive?.call() ?? true) onSettled(_truth);
          continue;
        }
        _truth = await write(_truth, target);
        onWrote?.call(_truth);
        if (!(isAlive?.call() ?? true)) return;
        // A tap landed while this was in the air. Its paint is newer than this
        // answer, so leave the screen alone and go send it.
        if (_pending != null) continue;
        onSettled(_truth);
      }
    } catch (error) {
      _pending = null;
      if (isAlive?.call() ?? true) onFailed(error, _truth);
    } finally {
      _writing = false;
    }
  }
}
