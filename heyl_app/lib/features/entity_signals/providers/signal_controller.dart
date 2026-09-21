import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/datasources/api/signal_api.dart';
import '../../../data/models/entity_signal.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/utils/settling_value.dart';
import 'feed_signal_seeds.dart';

/// Family key: one controller per (entity type, entity id).
typedef SignalKey = ({SignalEntityType type, String id});

/// Immutable view state for the signal chips of one entity.
class SignalControllerState {
  final EntitySignal signal;

  /// Initial GET in flight (chips render disabled until first load).
  final bool loading;

  /// A write is in the air, or one is queued behind it. Not a tap-blocker:
  /// taps are always accepted and converge — this is for callers that must not
  /// treat the painted taste as confirmed yet.
  final bool mutating;

  /// Whether [signal] is a **full** `SignalOut` rather than just a taste.
  ///
  /// False for a feed-seeded controller (PROD-4027): the feed's `signals` map
  /// carries sentiment only, by design, so `wantToGo`, `went` and the going
  /// axis are all at their defaults and mean nothing. Any surface that reads an
  /// axis other than [EntitySignal.taste] must call
  /// [SignalController.ensureHydrated] first. Today that is exactly one widget:
  /// `EventReminderBellButton`, which reads `hasGoing`.
  final bool hydrated;

  final Object? error;

  const SignalControllerState({
    required this.signal,
    this.loading = false,
    this.mutating = false,
    this.hydrated = false,
    this.error,
  });

  SignalControllerState copyWith({
    EntitySignal? signal,
    bool? loading,
    bool? mutating,
    bool? hydrated,
    Object? error,
    bool clearError = false,
  }) {
    return SignalControllerState(
      signal: signal ?? this.signal,
      loading: loading ?? this.loading,
      mutating: mutating ?? this.mutating,
      hydrated: hydrated ?? this.hydrated,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the signal state for one entity.
///
/// Two values, not one. [_truth] is the last signal the SERVER confirmed.
/// [SignalControllerState.signal] is what the screen shows. They differ on
/// `taste` alone, and only while the user's tap is outrunning the round-trip —
/// every other axis is grafted from [_truth] untouched.
///
/// The rule that falls out: **the server corrects the screen everywhere except
/// the axis the user is actively driving.** A read that departed before the
/// last tap fills the other axes and leaves `taste` alone.
///
/// Fires NO client analytics: every signal write endpoint logs
/// `entity_signal_changed` server-side, so this controller stays silent to
/// avoid double-counting (the going path already did — now all axes match).
class SignalController extends StateNotifier<SignalControllerState> {
  final SignalApi _api;
  final SignalEntityType _type;
  final String _id;

  /// Called after a chip tap settles, so surfaces that LIST signals (the profile
  /// Saved tab's liked items) can refetch. The controllers are per-entity and
  /// autoDispose, so a list has nothing to watch otherwise — and un-liking from
  /// a detail page pushed over the profile would leave a stale row behind.
  final void Function()? _onChanged;

  /// Called with the authoritative taste after any successful write, so the
  /// feed's seed store stops holding a value the user has already changed.
  ///
  /// Without this the seed is a *stale* answer that still suppresses the GET:
  /// like a card, scroll until this autoDispose controller is collected, scroll
  /// back, and the new controller reads the pre-tap seed and silently reverts
  /// the thumb the user just set.
  final void Function(SignalTaste)? _onWrite;

  /// [seed] is the caller's taste as the Discovery feed already reported it
  /// (PROD-4027). When present the initial GET is **skipped entirely** — that
  /// is the whole point of the ticket: the feed response already answered the
  /// question, so re-asking once per card is the architecture working against
  /// itself, and the chips no longer pop in a beat after the page paints.
  ///
  /// A seed IS server truth for taste, so it initialises [_truth]. It says
  /// nothing about the other axes, so a seeded controller is NOT
  /// [SignalControllerState.hydrated] — callers needing another axis call
  /// [ensureHydrated].
  SignalController(
    SignalApi api,
    SignalEntityType type,
    String id, {
    SignalTaste? seed,
    void Function()? onChanged,
    void Function(SignalTaste)? onWrite,
  }) : _api = api,
       _type = type,
       _id = id,
       _onChanged = onChanged,
       _onWrite = onWrite,
       _truth = EntitySignal.empty(
         type,
         id,
       ).withTaste(seed ?? SignalTaste.none),
       _taste = SettlingValue<SignalTaste>(seed ?? SignalTaste.none),
       super(
         SignalControllerState(
           signal: EntitySignal.empty(
             type,
             id,
           ).withTaste(seed ?? SignalTaste.none),
           loading: seed == null,
         ),
       ) {
    if (seed == null) _load();
  }

  /// The taste axis and its settling machinery — stamping, the one-slot intent
  /// queue, and one-write-at-a-time. See [SettlingValue].
  final SettlingValue<SignalTaste> _taste;

  /// The last full signal the server confirmed. `_taste.truth` is its taste;
  /// this carries the other axes, so a refresh can fill them without ever
  /// touching the thumb.
  EntitySignal _truth;

  /// The provenance to send with the queued intent. Not part of the settling
  /// contract — it is a label on the write, not a value being converged.
  String? _pendingProvenance;

  Future<void> _load() async {
    // Stamp the read with the intent it departed under. Arrival order is not
    // evidence of freshness: `ensureHydrated` fires from a post-frame callback
    // while the thumbs are already tappable (they render from the seed, not
    // gated on `loading`), so a GET spanning a tap is ordinary, not theoretical.
    final departedAt = _taste.seq;
    try {
      final signal = await _api.getSignal(_type, _id);
      if (!mounted) return;
      // A tap happened after this read left, or a write is still out. Either
      // way its `taste` predates the user's intent — take every other axis and
      // leave that one alone.
      final tasteIsCurrent = _taste.accepts(departedAt);
      if (tasteIsCurrent) _taste.adopt(signal.taste);
      _truth = signal.withTaste(_taste.truth);
      state = SignalControllerState(
        signal: _truth.withTaste(
          tasteIsCurrent ? signal.taste : state.signal.taste,
        ),
        hydrated: true,
        mutating: _taste.settling,
      );
      // A fresh GET is the newest thing the server has told us, so the seed
      // store must learn from it too — otherwise hydration corrects this
      // controller while a stale seed re-asserts itself on the next mount.
      if (tasteIsCurrent) _onWrite?.call(signal.taste);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(loading: false, error: e);
    }
  }

  /// Fetches the full `SignalOut` if this controller only holds a feed seed.
  ///
  /// Idempotent and safe to call on every mount: a controller that already
  /// holds a full signal, or has a GET in flight, does nothing.
  ///
  /// Call it from the widget that reads the non-taste axis, not from the screen
  /// hosting it. A screen-level call instantiates the controller for every
  /// visitor — including signed-out ones, for whom `signalThumbCells` avoids
  /// touching it precisely so no request fires.
  Future<void> ensureHydrated() async {
    if (state.hydrated || state.loading) return;
    state = state.copyWith(loading: true, clearError: true);
    await _load();
  }

  /// Adopt the signal returned by a reminder-config write. The picker PUTs
  /// `/events/{id}/reminders` (the going writer, events only), and the resolved
  /// signal comes back in the response — so we seed state from it without an
  /// extra GET. Deliberately fires no client analytics: the reminders endpoint
  /// logs `entity_signal_changed` server-side, so logging here would double-count.
  void applyGoing(EntitySignal signal) {
    _taste.supersede(signal.taste);
    _truth = signal;
    state = SignalControllerState(signal: signal, hydrated: true);
    _onWrite?.call(signal.taste);
  }

  /// Apply a chip tap. Paints the predicted taste instantly, then converges to
  /// the server.
  ///
  /// **Never drops a tap.** A tap made while an earlier write is still out
  /// paints immediately and is queued; [_drain] sends it once the first write
  /// answers. The returned future completes when the queue is empty, so a
  /// caller awaiting it sees the settled state.
  ///
  /// [provenance] is an optional surface-attribution label (see
  /// [SignalProvenance]) recorded server-side (last-write-wins).
  Future<void> apply(SignalAction action, {String? provenance}) async {
    _pendingProvenance = provenance;
    final desired = _taste.intend(_predictTaste(state.signal.taste, action));
    // Optimistic: paint the new taste now, before the round-trip.
    state = state.copyWith(
      signal: state.signal.withTaste(desired),
      mutating: true,
      clearError: true,
    );
    await _taste.drain(
      write: (from, to) async {
        final signal = await _api.postSignal(
          _type,
          _id,
          _actionToReach(from, to)!,
          provenance: _pendingProvenance,
        );
        _truth = signal;
        return signal.taste;
      },
      // Fires even when this autoDispose controller is already gone: the seed
      // store outlives it, and a write that landed must be recorded or a stale
      // seed reverts the tap on the next mount.
      onWrote: (_) => _onWrite?.call(_truth.taste),
      onSettled: (_) {
        // The server wins, including when it disagrees with the prediction. The
        // POST returns a full `SignalOut`, so one write hydrates a seeded
        // controller — still no GET.
        state = SignalControllerState(signal: _truth, hydrated: true);
        _onChanged?.call();
      },
      onFailed: (error, _) {
        // Nothing landed — fall back to what the server last confirmed.
        state = state.copyWith(signal: _truth, mutating: false, error: error);
      },
      isAlive: () => mounted,
    );
    if (mounted && state.mutating && !_taste.settling) {
      state = state.copyWith(mutating: false);
    }
  }

  /// The toggle the server will apply, mirrored client-side for the optimistic
  /// paint: re-tapping the held sentiment clears it; otherwise it takes.
  static SignalTaste _predictTaste(SignalTaste current, SignalAction action) {
    switch (action) {
      case SignalAction.like:
        return current == SignalTaste.liked
            ? SignalTaste.none
            : SignalTaste.liked;
      case SignalAction.dislike:
        return current == SignalTaste.disliked
            ? SignalTaste.none
            : SignalTaste.disliked;
    }
  }

  /// The single action that moves the server from [from] to [to], or null when
  /// it is already there. Always one hop: the endpoint toggles, so clearing a
  /// held sentiment means re-sending that same sentiment.
  static SignalAction? _actionToReach(SignalTaste from, SignalTaste to) {
    if (from == to) return null;
    switch (to) {
      case SignalTaste.liked:
        return SignalAction.like;
      case SignalTaste.disliked:
        return SignalAction.dislike;
      case SignalTaste.none:
        // `from` cannot be `none` here — that is the equality case above.
        return from == SignalTaste.liked
            ? SignalAction.like
            : SignalAction.dislike;
    }
  }
}

/// Bumped whenever any chip tap lands. A counter, not the changed entity: the
/// only listener is a list that refetches wholesale, and carrying the entity id
/// would imply a precision nothing uses.
final signalRevisionProvider = StateProvider<int>((ref) => 0);

final signalControllerProvider = StateNotifierProvider.family
    .autoDispose<SignalController, SignalControllerState, SignalKey>((
      ref,
      key,
    ) {
      // `read`, not `watch`: a later feed page merging its own seeds must not
      // tear down and rebuild live controllers — which would discard an
      // in-flight write and re-fire the GET this ticket exists to remove.
      final seed = ref.read(feedSignalSeedsProvider)[key];
      return SignalController(
        ref.watch(signalApiProvider),
        key.type,
        key.id,
        seed: seed,
        onChanged: () => ref.read(signalRevisionProvider.notifier).state++,
        onWrite: (taste) =>
            ref.read(feedSignalSeedsProvider.notifier).recordWrite(key, taste),
      );
    });
