import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../shared/widgets/soko_chat_timings.dart';
import '../models/onboarding_chat_models.dart';

typedef OnboardingDelay = Future<void> Function(Duration duration);

/// Resolves when a content carousel's real data has loaded, so the "searching…"
/// label can linger for the actual fetch instead of a fixed guess. Returns null
/// when a content id has nothing to await (a static shelf) — the controller
/// then falls back to a fixed beat. Keyed by [OnboardingTurnSpec.contentId].
typedef OnboardingContentReady = Future<void>? Function(String contentId);

const _unset = Object();

@immutable
class OnboardingChatState {
  const OnboardingChatState({
    this.snapshot,
    this.turns = const [],
    this.isLoading = false,
    this.isTyping = false,
    this.searchingLabel,
    this.isSaving = false,
    this.isAwaitingInput = false,
    this.isAwaitingConsent = false,
    this.reduceMotion = false,
    this.pendingAnswer,
    this.submissionError,
    this.editingSubturnId,
  });

  final OnboardingSnapshot? snapshot;
  final List<OnboardingDeliveredTurn> turns;
  final bool isLoading;
  final bool isTyping;

  /// When non-null, the transcript shows a pulsing "searching…" progress label
  /// in place of the typing dots — a chat-like pause before a content carousel.
  /// Mutually exclusive with [isTyping] (message vs. content turn).
  final String? searchingLabel;
  final bool isSaving;
  final bool isAwaitingInput;

  /// Paused at a `gatesDelivery` turn (the rituals delivery-consent): the rest
  /// of the subturn is held until the user answers via the bottom composer.
  /// Distinct from [isAwaitingInput] so the identity-step composers stay hidden
  /// while only the consent chips should show.
  final bool isAwaitingConsent;
  final bool reduceMotion;
  final OnboardingAnswer? pendingAnswer;
  final Object? submissionError;

  /// Non-null while the user is correcting an already-answered identity subturn
  /// (name or city) in place — the composer for this subturn re-opens even
  /// though the flow's cursor has moved past it. Distinct from
  /// [pendingAnswer]/[isAwaitingInput] so the normal forward flow is untouched.
  final OnboardingSubturnId? editingSubturnId;

  bool get canSubmit =>
      snapshot != null &&
      !snapshot!.isComplete &&
      isAwaitingInput &&
      !isSaving &&
      pendingAnswer == null;

  bool get isEditing => editingSubturnId != null;

  /// Gate for the in-place edit composer's submit — mirrors [canSubmit] but for
  /// the correction path (the edited subturn is not the flow's current cursor).
  bool get canSubmitEdit => isEditing && !isSaving && pendingAnswer == null;

  OnboardingChatState copyWith({
    Object? snapshot = _unset,
    List<OnboardingDeliveredTurn>? turns,
    bool? isLoading,
    bool? isTyping,
    Object? searchingLabel = _unset,
    bool? isSaving,
    bool? isAwaitingInput,
    bool? isAwaitingConsent,
    bool? reduceMotion,
    Object? pendingAnswer = _unset,
    Object? submissionError = _unset,
    Object? editingSubturnId = _unset,
  }) => OnboardingChatState(
    snapshot: identical(snapshot, _unset)
        ? this.snapshot
        : snapshot as OnboardingSnapshot?,
    turns: turns ?? this.turns,
    isLoading: isLoading ?? this.isLoading,
    isTyping: isTyping ?? this.isTyping,
    searchingLabel: identical(searchingLabel, _unset)
        ? this.searchingLabel
        : searchingLabel as String?,
    isSaving: isSaving ?? this.isSaving,
    isAwaitingInput: isAwaitingInput ?? this.isAwaitingInput,
    isAwaitingConsent: isAwaitingConsent ?? this.isAwaitingConsent,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    pendingAnswer: identical(pendingAnswer, _unset)
        ? this.pendingAnswer
        : pendingAnswer as OnboardingAnswer?,
    submissionError: identical(submissionError, _unset)
        ? this.submissionError
        : submissionError,
    editingSubturnId: identical(editingSubturnId, _unset)
        ? this.editingSubturnId
        : editingSubturnId as OnboardingSubturnId?,
  );
}

/// Delivers the deterministic onboarding transcript and serializes answer
/// persistence. The server-provided snapshot is authoritative for advancement.
class OnboardingChatController extends StateNotifier<OnboardingChatState> {
  OnboardingChatController({
    required OnboardingProgressStore progressStore,
    required OnboardingScript script,
    OnboardingDelay delay = Future<void>.delayed,
    OnboardingContentReady? contentReady,
  }) : _progressStore = progressStore,
       _script = script,
       _delay = delay,
       _contentReady = contentReady,
       super(const OnboardingChatState());

  static const bubbleEntranceDuration = sokoBubbleEntranceDuration;
  static const interTurnGap = Duration(milliseconds: 120);

  /// How long a freshly-delivered Soko line takes to "type out" (see
  /// [SokoTypewriterText]). Delivery holds for this after appending a message so
  /// the next turn — and the input unlock — don't race the type-out. Delegates
  /// to the shared [sokoTypewriterDuration] so onboarding + main chat match.
  static Duration typewriterDurationFor(String text) =>
      sokoTypewriterDuration(text);

  /// Extra beat after the last line finishes typing before the composer/CTAs
  /// unlock, so buttons land a moment after the text settles.
  /// PROD-4394 P0-1: 400 → 100 ms — per-subturn synthetic wait cut.
  static const typewriterSettleDelay = Duration(milliseconds: 100);

  /// Fixed "searching…" beat for a flagged content turn with nothing real to
  /// await (a static shelf) — a deliberate, chat-like "Soko is finding things"
  /// pause (see [OnboardingTurnSpec.searchingLabel]).
  /// PROD-4394 P0-1: 850 → 400 ms.
  static const contentSearchingDuration = Duration(milliseconds: 400);

  /// When a real load IS awaited, the label shows for at least this long (so an
  /// instant/cached load never flashes) and then until the fetch itself
  /// resolves. There is no artificial upper cap: every awaited fetch is
  /// self-bounding (the users/vibe GETs resolve or throw on the HTTP timeout;
  /// the zines controller polls a bounded budget then settles with cards, empty,
  /// or a terminal error), so the label — not a spinner — covers the whole wait,
  /// however long the real work takes.
  /// PROD-4394 P0-1: 600 → 150 ms — already-loaded content should not idle
  /// behind a synthetic floor.
  static const contentSearchingMinDuration = Duration(milliseconds: 150);

  final OnboardingProgressStore _progressStore;
  final OnboardingScript _script;
  final OnboardingDelay _delay;
  final OnboardingContentReady? _contentReady;

  bool _startInFlight = false;
  bool _started = false;
  bool _disposed = false;
  int _generation = 0;

  // Resume bookkeeping for a `gatesDelivery` pause: the full spec list, the
  // index to resume AT (the turn after the gate), and the delivery epoch that
  // owns the pause. Cleared once resumed.
  List<OnboardingTurnSpec>? _gateResumeSpecs;
  int _gateResumeIndex = 0;
  int _gateResumeToken = 0;

  // PROD-4394 P0-1: typing-dot floor 500 → 300 ms, cap 900 → 500 ms.
  @visibleForTesting
  static Duration typingDurationFor(String message) => Duration(
    milliseconds: (300 + message.runes.length * 4).clamp(300, 500).toInt(),
  );

  Future<void> start({bool reduceMotion = false}) async {
    if (_started || _startInFlight || _disposed) return;

    _startInFlight = true;
    final token = ++_generation;
    state = state.copyWith(
      isLoading: true,
      reduceMotion: reduceMotion,
      submissionError: null,
    );

    try {
      OnboardingSnapshot snapshot;
      try {
        snapshot = await _progressStore.load();
      } catch (_) {
        // PROD-4394 F3: one silent retry before the load-error card. The
        // observed resume failure (Sentry FLUTTER-1AM) is a 401 racing the
        // token refresh at cold start — by the second attempt the refreshed
        // token is in place and the saved checkpoint loads normally.
        if (!await _sleep(autoRetryDelay, token)) return;
        snapshot = await _progressStore.load();
      }
      if (!_isCurrent(token)) return;

      final hydratedTurns = <OnboardingDeliveredTurn>[];
      for (final subturn in snapshot.completedSubturns) {
        hydratedTurns.addAll(
          _script
              .turnsFor(subturn)
              .map(
                (spec) =>
                    OnboardingDeliveredTurn.fromSpec(spec, animate: false),
              ),
        );
        final answer = snapshot.answers[subturn];
        if (answer != null) {
          hydratedTurns.add(
            OnboardingDeliveredTurn.answer(answer, animate: false),
          );
        }
      }

      _started = true;
      state = state.copyWith(
        snapshot: snapshot,
        turns: List.unmodifiable(hydratedTurns),
        isLoading: false,
        isAwaitingInput: false,
      );

      if (!snapshot.isComplete) {
        await _deliverCurrentSubturn(token);
      }
    } catch (error, stack) {
      if (!_isCurrent(token)) return;
      _reportSubmissionError(error, stack, 'load');
      state = state.copyWith(isLoading: false, submissionError: error);
    } finally {
      _startInFlight = false;
    }
  }

  /// Appends a user bubble immediately, then awaits durable persistence before
  /// delivering the next server-selected subturn.
  Future<bool> submitAnswer(OnboardingAnswer answer) async {
    final snapshot = state.snapshot;
    if (!state.canSubmit ||
        snapshot == null ||
        answer.subturnId != snapshot.currentSubturnId) {
      return false;
    }

    final answerTurn = OnboardingDeliveredTurn.answer(
      answer,
      animate: !state.reduceMotion,
      isPending: true,
    );
    state = state.copyWith(
      turns: List.unmodifiable([...state.turns, answerTurn]),
      isSaving: true,
      isAwaitingInput: false,
      pendingAnswer: answer,
      submissionError: null,
    );

    return _persistPendingAnswer();
  }

  Future<bool> retryPendingAnswer() async {
    if (state.pendingAnswer == null || state.isSaving || _disposed) {
      return false;
    }

    state = state.copyWith(
      isSaving: true,
      submissionError: null,
      turns: _markAnswerPending(true),
    );
    return _persistPendingAnswer();
  }

  /// Opens the in-place edit composer for an already-answered identity subturn
  /// (name or city). Allowed only while the flow is still inside the identity
  /// step — before the supported/unsupported branch forks (past
  /// `identity.extra`) and any downstream content is produced, so a correction
  /// is a pure re-save with no rewind. No-op otherwise.
  void beginEdit(OnboardingSubturnId subturnId) {
    final snapshot = state.snapshot;
    if (snapshot == null || snapshot.isComplete) return;
    // Only open when the flow is settled at a composer (nothing delivering or
    // saving), so bumping the delivery epoch in `submitCorrection` can't strand
    // a half-delivered subturn.
    if (!state.isAwaitingInput ||
        state.isSaving ||
        state.pendingAnswer != null) {
      return;
    }
    if (subturnId != OnboardingSubturnId.identityName &&
        subturnId != OnboardingSubturnId.identityCity) {
      return;
    }
    if (snapshot.currentSubturnId.step != OnboardingStepId.identity) return;
    // The subturn must actually have been answered already.
    if (!snapshot.answers.containsKey(subturnId)) return;
    state = state.copyWith(editingSubturnId: subturnId, submissionError: null);
  }

  void cancelEdit() {
    if (!state.isEditing) return;
    state = state.copyWith(editingSubturnId: null, submissionError: null);
  }

  /// Re-saves a correction to an already-answered identity subturn and replaces
  /// its user bubble text in place. Bypasses the current-cursor guard used by
  /// [submitAnswer]; because every later identity subturn is still answered (or
  /// still unanswered) exactly as before, the server's forward-replay keeps the
  /// same [OnboardingSnapshot.currentSubturnId], so nothing downstream is
  /// re-delivered.
  Future<bool> submitCorrection(OnboardingAnswer answer) async {
    final snapshot = state.snapshot;
    if (!state.canSubmitEdit ||
        snapshot == null ||
        answer.subturnId != state.editingSubturnId) {
      return false;
    }

    state = state.copyWith(isSaving: true, submissionError: null);

    final token = ++_generation;
    try {
      final next = await _progressStore.saveAnswer(answer);
      if (!_isCurrent(token)) return false;

      final id = 'answer:${answer.subturnId.wireId}';
      final turns = List<OnboardingDeliveredTurn>.unmodifiable([
        for (final turn in state.turns)
          if (turn.id == id) turn.copyWith(text: answer.displayText) else turn,
      ]);

      state = state.copyWith(
        snapshot: next,
        turns: turns,
        isSaving: false,
        editingSubturnId: null,
        submissionError: null,
      );
      return true;
    } catch (error, stack) {
      if (!_isCurrent(token)) return false;
      _reportSubmissionError(error, stack, 'save_correction');
      // Keep the editing target so the composer stays open for a retry/cancel.
      state = state.copyWith(isSaving: false, submissionError: error);
      return false;
    }
  }

  /// Reports a swallowed onboarding persistence failure to Sentry so the
  /// otherwise-invisible "something went wrong" retry state is measurable. Tags
  /// the operation and, for a Dio failure, the transport error type + status
  /// code so timeout vs 5xx vs connection error can be told apart. The UI still
  /// shows the same retry card — this only adds visibility.
  void _reportSubmissionError(Object error, StackTrace stack, String op) {
    unawaited(
      Sentry.captureException(
        error,
        stackTrace: stack,
        withScope: (scope) {
          scope.setTag('onboarding.op', op);
          // PROD-4580: which step failed. Without this a `save_answer` failure
          // is unattributable — diagnosing the rituals-step completion deadlock
          // meant reading a user's DB row because Sentry couldn't say where the
          // 22 save failures in the window actually landed.
          final step =
              state.pendingAnswer?.subturnId.wireId ??
              state.snapshot?.currentSubturnId.wireId;
          if (step != null) scope.setTag('onboarding.step', step);
          if (error is DioException) {
            scope.setTag('onboarding.dio_type', error.type.name);
            final code = error.response?.statusCode;
            if (code != null) scope.setTag('onboarding.status', '$code');
          }
        },
      ),
    );
  }

  /// One silent retry beat before the error card surfaces (PROD-4394 D2/P1-11)
  /// — most persistence failures are transient blips; a 2s automatic second
  /// attempt clears them without the user ever seeing the card.
  static const autoRetryDelay = Duration(seconds: 2);

  /// Abandons a failed answer: clears the error + pending answer, removes the
  /// stranded user bubble, and re-opens the composer so the user can adjust
  /// what they typed instead of being locked into Retry (PROD-4394 D1 — the
  /// error card was terminal: no skip, back swallowed, non-admins had zero
  /// exit).
  void dismissSubmissionError() {
    final pending = state.pendingAnswer;
    if (state.submissionError == null || state.isSaving) return;
    final turns = pending == null
        ? state.turns
        : List<OnboardingDeliveredTurn>.unmodifiable([
            for (final turn in state.turns)
              if (turn.id != 'answer:${pending.subturnId.wireId}') turn,
          ]);
    state = state.copyWith(
      turns: turns,
      pendingAnswer: null,
      submissionError: null,
      isAwaitingInput: true,
    );
  }

  Future<bool> _persistPendingAnswer() async {
    final answer = state.pendingAnswer;
    final previousSubturn = state.snapshot?.currentSubturnId;
    if (answer == null || previousSubturn == null) return false;

    final token = ++_generation;
    try {
      OnboardingSnapshot snapshot;
      try {
        snapshot = await _progressStore.saveAnswer(answer);
      } catch (_) {
        // PROD-4394 D2/P1-11: one silent retry before surfacing the card.
        if (!await _sleep(autoRetryDelay, token)) return false;
        snapshot = await _progressStore.saveAnswer(answer);
      }
      if (!_isCurrent(token)) return false;

      state = state.copyWith(
        snapshot: snapshot,
        isSaving: false,
        pendingAnswer: null,
        submissionError: null,
        turns: _markAnswerPending(false),
      );

      if (!snapshot.isComplete &&
          snapshot.currentSubturnId != previousSubturn) {
        // Optional acknowledgement bubble (e.g. "Great, thanks!" after the user
        // adds free text at identity.extra) lands before the next subturn.
        final ack = answer.ackMessage;
        if (ack != null && ack.isNotEmpty) {
          await _deliverAck(ack, answer.subturnId, token);
          if (!_isCurrent(token)) return false;
        }
        await _deliverCurrentSubturn(token);
      } else if (!snapshot.isComplete) {
        state = state.copyWith(isAwaitingInput: true);
      }
      return true;
    } catch (error, stack) {
      if (!_isCurrent(token)) return false;
      _reportSubmissionError(error, stack, 'save_answer');
      state = state.copyWith(
        isSaving: false,
        isAwaitingInput: false,
        submissionError: error,
        turns: _markAnswerPending(false),
      );
      return false;
    }
  }

  /// Delivers a single one-off Soko acknowledgement bubble (typing indicator +
  /// bubble), mirroring [_deliverFrom]'s message cadence. Used for
  /// [OnboardingAnswer.ackMessage]; the bubble is transient history, not part of
  /// any subturn's script.
  Future<void> _deliverAck(
    String message,
    OnboardingSubturnId subturnId,
    int token,
  ) async {
    if (!_isCurrent(token) || message.isEmpty) return;

    if (!state.reduceMotion) {
      state = state.copyWith(isTyping: true);
      if (!await _sleep(typingDurationFor(message), token)) return;
      state = state.copyWith(isTyping: false);
    }

    final ackTurn = OnboardingDeliveredTurn(
      id: 'ack:${subturnId.wireId}',
      subturnId: subturnId,
      actor: OnboardingTurnActor.soko,
      kind: OnboardingTurnKind.message,
      text: message,
      animate: !state.reduceMotion,
    );
    state = state.copyWith(turns: List.unmodifiable([...state.turns, ackTurn]));

    if (!state.reduceMotion) {
      if (!await _sleep(bubbleEntranceDuration, token)) return;
      await _sleep(interTurnGap, token);
    }
  }

  Future<void> _deliverCurrentSubturn(int token) async {
    final snapshot = state.snapshot;
    if (snapshot == null || snapshot.isComplete || !_isCurrent(token)) return;

    final specs = _script.turnsFor(snapshot.currentSubturnId);
    if (specs.isEmpty) {
      state = state.copyWith(
        isAwaitingInput: true,
        isTyping: false,
        searchingLabel: null,
      );
      return;
    }

    state = state.copyWith(isAwaitingInput: false);
    await _deliverFrom(specs, 0, token);
  }

  /// Delivers [specs] from [start], honouring a `gatesDelivery` turn by pausing
  /// (without rendering it inline) until [resumeAfterGate] continues the rest.
  Future<void> _deliverFrom(
    List<OnboardingTurnSpec> specs,
    int start,
    int token,
  ) async {
    for (var i = start; i < specs.length; i++) {
      if (!_isCurrent(token)) return;
      final spec = specs[i];

      // Gate: hold the remaining turns until the user answers this content
      // (surfaced in the bottom composer, not the transcript). Resume AT the
      // next turn so the gate turn itself is never appended to the transcript.
      if (spec.gatesDelivery) {
        _gateResumeSpecs = specs;
        _gateResumeIndex = i + 1;
        _gateResumeToken = token;
        state = state.copyWith(
          isTyping: false,
          searchingLabel: null,
          isAwaitingConsent: true,
        );
        return;
      }

      if (!state.reduceMotion &&
          spec.kind == OnboardingTurnKind.message &&
          spec.actor == OnboardingTurnActor.soko) {
        state = state.copyWith(isTyping: true);
        if (!await _sleep(typingDurationFor(spec.text ?? ''), token)) return;
        state = state.copyWith(isTyping: false);
      } else if (!state.reduceMotion &&
          spec.kind == OnboardingTurnKind.content &&
          spec.searchingLabel != null) {
        // Content carousels get a pulsing "searching…" beat instead of typing
        // dots, held until the shelf's real data loads (see _awaitContentReady),
        // so they arrive one at a time — a paced chat, not a wall of cards. This
        // also serializes the vibe step's two carousels: Places fully loads and
        // shows before the Events beat even begins.
        state = state.copyWith(searchingLabel: spec.searchingLabel);
        if (!await _awaitContentReady(spec.contentId, token)) return;
        state = state.copyWith(searchingLabel: null);
      }

      state = state.copyWith(
        turns: List.unmodifiable([
          ...state.turns,
          OnboardingDeliveredTurn.fromSpec(spec, animate: !state.reduceMotion),
        ]),
      );

      if (!state.reduceMotion) {
        // Hold for the type-out on Soko messages so the next turn — and the
        // final input unlock — don't appear while the line is still typing.
        final postAppend =
            spec.kind == OnboardingTurnKind.message &&
                spec.actor == OnboardingTurnActor.soko
            ? typewriterDurationFor(spec.text ?? '')
            : bubbleEntranceDuration;
        if (!await _sleep(postAppend, token)) return;
        if (!await _sleep(interTurnGap, token)) return;
      }
    }

    if (_isCurrent(token)) {
      // A beat after the last line finishes typing before the composer/CTAs
      // unlock, so buttons land a moment after the text settles.
      if (!state.reduceMotion) {
        if (!await _sleep(typewriterSettleDelay, token)) return;
      }
      state = state.copyWith(
        isTyping: false,
        searchingLabel: null,
        isAwaitingInput: true,
      );
    }
  }

  /// Resumes delivery after the user answers a `gatesDelivery` turn (the rituals
  /// delivery-consent). Delivers the held remainder of the subturn ("You're
  /// ready!" + the exit/finish CTAs), then awaits input. No-op unless currently
  /// paused at a gate for the live delivery epoch.
  void resumeAfterGate() {
    if (!state.isAwaitingConsent) return;
    final specs = _gateResumeSpecs;
    final index = _gateResumeIndex;
    final token = _gateResumeToken;
    if (specs == null || !_isCurrent(token)) return;

    _gateResumeSpecs = null;
    state = state.copyWith(isAwaitingConsent: false);
    unawaited(_deliverFrom(specs, index, token));
  }

  /// Re-translate already-delivered Soko message bubbles in place when the
  /// locale changes. [textById] maps each Soko message turn's stable id to its
  /// new-locale text (see [OnboardingScript.messageTextById]). User answer
  /// bubbles and content turns are left untouched; re-mapped turns render whole
  /// (`animate: false`) so the typewriter never replays the history.
  void retranslate(Map<String, String> textById) {
    if (textById.isEmpty || state.turns.isEmpty) return;
    var changed = false;
    final next = <OnboardingDeliveredTurn>[];
    for (final turn in state.turns) {
      final newText =
          turn.kind == OnboardingTurnKind.message &&
              turn.actor == OnboardingTurnActor.soko
          ? textById[turn.id]
          : null;
      if (newText != null && newText != turn.text) {
        changed = true;
        next.add(turn.copyWith(text: newText, animate: false));
      } else {
        next.add(turn);
      }
    }
    if (changed) state = state.copyWith(turns: List.unmodifiable(next));
  }

  List<OnboardingDeliveredTurn> _markAnswerPending(bool pending) =>
      List.unmodifiable([
        for (final turn in state.turns)
          if (turn.id == 'answer:${state.pendingAnswer?.subturnId.wireId}')
            turn.copyWith(isPending: pending)
          else
            turn,
      ]);

  Future<bool> _sleep(Duration duration, int token) async {
    await _delay(duration);
    return _isCurrent(token);
  }

  /// Holds the "searching…" label for a content carousel. When a real load is
  /// wired for [contentId], waits for it (min beat so it never flashes, capped
  /// so a hung fetch can't stall); otherwise a fixed beat. Returns whether this
  /// delivery epoch is still current.
  Future<bool> _awaitContentReady(String? contentId, int token) async {
    final ready = contentId == null ? null : _contentReady?.call(contentId);
    if (ready == null) return _sleep(contentSearchingDuration, token);
    // Hold the label at least the min beat, then until the fetch resolves —
    // just wait for the GET. No artificial cap: the awaited future is always
    // self-bounding (HTTP timeout / bounded zines polling), so a slow shelf
    // keeps its "searching…" label instead of cutting over to a spinner.
    await Future.wait<void>([
      _delay(contentSearchingMinDuration),
      ready.catchError((Object _) {}),
    ]);
    return _isCurrent(token);
  }

  bool _isCurrent(int token) => !_disposed && token == _generation;

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    super.dispose();
  }
}

/// Creates an injectable provider without registering a production store.
/// FE-2 can expose a globally wired provider after the OpenAPI adapter exists.
StateNotifierProvider<OnboardingChatController, OnboardingChatState>
createOnboardingChatProvider({
  required OnboardingProgressStore progressStore,
  required OnboardingScript script,
  OnboardingDelay delay = Future<void>.delayed,
  OnboardingContentReady? contentReady,
}) => StateNotifierProvider<OnboardingChatController, OnboardingChatState>(
  (ref) => OnboardingChatController(
    progressStore: progressStore,
    script: script,
    delay: delay,
    contentReady: contentReady,
  ),
);
