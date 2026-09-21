import 'package:collection/collection.dart';

import '../../../data/datasources/interfaces/api_interfaces.dart';
import '../../../data/models/onboarding_state_models.dart';
import '../models/onboarding_chat_models.dart';

const _deepEquals = DeepCollectionEquality();

/// Production [OnboardingProgressStore] backed by `GET`/`PUT
/// /api/v1/app/onboarding/state` (PROD-3882 / BE-1).
///
/// The backend persists at STEP granularity (`identity`, `vibe`, …) with a
/// free-form answer object per step and — by design — does not track subturns
/// or enforce ordering ("resumability is client-driven"). This adapter owns the
/// subturn↔step mapping: it reconstructs a subturn-level [OnboardingSnapshot] by
/// replaying the client [OnboardingStateGraph] over the answers the server
/// recorded, and on save it accumulates the current step's sub-answers and
/// upserts them idempotently.
///
/// Answer serialization: each subturn writes one key into its step's answer
/// object (see [_answerKey]) — the two backend examples (`identity:
/// {display_name}`, `vibe: {picks}`) are honoured; the object is otherwise
/// client-owned free-form until BE-3 consumes it.
class ApiOnboardingProgressStore implements OnboardingProgressStore {
  ApiOnboardingProgressStore({
    required IOnboardingStateApi api,
    String version = defaultVersion,
    this.interimCompleteAfterSubturn,
    this.displayTextFor,
    this.readCachedBranch,
    this.writeCachedBranch,
  }) : _api = api,
       _version = version;

  /// PROD-4394 D4: durable client-side fallback for the resolved branch. Past
  /// `identity.extra` the resume graph REQUIRES a branch; the in-memory
  /// `_lastBranchWire` fallback dies with the process, so a server envelope
  /// that ever fails to echo `branch` used to loop the user on "anything
  /// else?" forever after an app restart. The screen wires these to
  /// SharedPreferences; tests may leave them null (memory-only, old
  /// behaviour).
  final String? Function()? readCachedBranch;
  final void Function(String wireId)? writeCachedBranch;

  /// Onboarding flow version stamped on every PUT (matches the spec example).
  static const String defaultVersion = 'chat-v1';

  /// Formats the transcript bubble text when hydrating a saved answer on resume
  /// (the server only stores the raw `value`). Lets the interests step render
  /// its human labels instead of the persisted ids. Null → `value.toString()`.
  final String Function(OnboardingSubturnId subturnId, Object? value)?
  displayTextFor;

  /// INTERIM (remove when FE-3/4/5 land): when the answer for this subturn is
  /// saved, immediately `PUT step=complete` so onboarding finishes at the end
  /// of the only built step (identity). Lets the non-dismissible gate release
  /// during pre-release testing without the vibe/zines/profile/rituals steps.
  final OnboardingSubturnId? interimCompleteAfterSubturn;

  final IOnboardingStateApi _api;
  final String _version;

  /// Loss-free copy of the server's per-step answer objects, so a save that
  /// overwrites `answers[step]` preserves keys this client doesn't model.
  final Map<String, Map<String, dynamic>> _rawAnswersByStep = {};

  /// The snapshot from the most recent server sync (load/save), returned when a
  /// re-save is a pure no-op so the caller still gets the current state without
  /// a redundant round-trip. See the dirty-check in [saveAnswer].
  OnboardingSnapshot? _lastSnapshot;

  /// Whether the last [_ingestInner] walked the whole graph — i.e. every answer
  /// the flow needs is recorded. NOT the same as completion, which only the
  /// server's `onboarding_complete` decides. Set on every ingest; read by [load]
  /// to detect (and repair) the two-PUT completion having half-landed.
  bool _walkReachedEnd = false;

  @override
  Future<OnboardingSnapshot> load() async {
    final snapshot = _ingest(await _api.getState());

    // PROD-4580 self-heal: every answer is recorded but the server never got the
    // `step=complete` PUT (the second of the two writes in [saveAnswer] — a
    // dropped connection between them is enough, and 22 users hit a transport
    // failure on an onboarding save in 30 days). Left alone this is a permanent
    // lockout, so re-send the completion PUT before handing the flow back. It is
    // idempotent per (user, step) and omits `answers`, so recorded answers are
    // preserved — a no-op for anyone who isn't in this state, and this branch is
    // unreachable for them.
    if (!_walkReachedEnd || snapshot.isComplete) return snapshot;
    try {
      return _ingest(
        await _api.putState(
          OnboardingStatePutDto(
            version: snapshot.version,
            step: OnboardingStepId.complete.wireId,
            branch: _lastBranchWire,
            selectedCity: _lastSelectedCity,
            completionPath: _lastCompletionPathWire,
          ),
        ),
      );
    } catch (_) {
      // Still offline / still failing: fall back to the parked snapshot, whose
      // cursor sits on the last answered subturn so the flow re-delivers that
      // step's finish CTAs and the user can complete by hand (or see the retry
      // card). Never a dead end.
      return snapshot;
    }
  }

  @override
  Future<OnboardingSnapshot> saveAnswer(OnboardingAnswer answer) async {
    final step = answer.subturnId.step;
    final stepWire = step.wireId;

    // City gate: when the answer resolves the branch (the city step, or a
    // not-local city switch), stamp it forward so every subsequent PUT carries
    // it and the graph can pass the `identity.extra → branch` decision.
    if (answer.branch != null) {
      _lastBranchWire = answer.branch!.wireId;
      writeCachedBranch?.call(answer.branch!.wireId);
    }
    if (answer.selectedCity != null) _lastSelectedCity = answer.selectedCity;
    if (answer.completionPath != null) {
      _lastCompletionPathWire = answer.completionPath!.wireId;
    }

    // Accumulate this sub-answer into the step's (loss-free) answer object.
    final stepAnswers = Map<String, dynamic>.from(
      _rawAnswersByStep[stepWire] ?? const {},
    );
    stepAnswers[_answerKey(answer.subturnId)] = answer.value;

    // Dirty-check: skip the PUT when this is a pure no-op re-save (a re-confirm
    // or a correction that left the value unchanged) with no branch/city/picked-
    // location/completion side-channel. Every answers-bearing PUT re-runs the
    // backend memory writer and re-chains the ~15-20s preliminary-zines Discovery
    // fan-out; the identity step alone is four sub-turns plus edits, so an
    // unchanged re-save is wasted work end-to-end. A genuine change (new interest,
    // edited free-text) still differs here and is sent. Returns the last synced
    // snapshot so the caller sees the same (already-advanced) state.
    final previousStepAnswers = _rawAnswersByStep[stepWire];
    final isNoOpResave =
        _lastSnapshot != null &&
        previousStepAnswers != null &&
        _deepEquals.equals(previousStepAnswers, stepAnswers) &&
        answer.branch == null &&
        answer.selectedCity == null &&
        answer.completionPath == null &&
        answer.selectedCityId == null &&
        answer.selectedLatitude == null &&
        answer.selectedLongitude == null &&
        !(interimCompleteAfterSubturn != null &&
            answer.subturnId == interimCompleteAfterSubturn);
    if (isNoOpResave) {
      return _lastSnapshot!;
    }

    final dto = await _api.putState(
      OnboardingStatePutDto(
        version: _version,
        step: stepWire,
        // Carry forward whatever branch/city/path we already know so an
        // idempotent PUT never blanks them. FE-3 sets these at the city branch.
        branch: _lastBranchWire,
        selectedCity: _lastSelectedCity,
        completionPath: _lastCompletionPathWire,
        // The PICKED location rides ONLY the answer that carries it (the city
        // choice), never carried forward — so the server re-resolves coverage
        // exactly once, on the city step, not on every subsequent PUT.
        selectedCityId: answer.selectedCityId,
        selectedLatitude: answer.selectedLatitude,
        selectedLongitude: answer.selectedLongitude,
        answers: stepAnswers,
      ),
    );
    final snapshot = _ingest(dto); // refresh caches from the saved step

    // Complete now when we reached the interim endpoint OR the answer itself
    // finishes onboarding (the not-local "Fala comigo" handoff stamps a
    // completion_path). A city switch instead flips the branch to supported
    // above, so its walk continues to the vibe step rather than completing.
    if ((interimCompleteAfterSubturn != null &&
            answer.subturnId == interimCompleteAfterSubturn) ||
        answer.completionPath != null) {
      final completeDto = await _api.putState(
        OnboardingStatePutDto(
          version: _version,
          step: OnboardingStepId.complete.wireId,
          branch: _lastBranchWire,
          selectedCity: _lastSelectedCity,
          completionPath: _lastCompletionPathWire,
        ),
      );
      return _ingest(completeDto);
    }
    return snapshot;
  }

  String? _lastBranchWire;
  String? _lastSelectedCity;
  String? _lastCompletionPathWire;

  /// Fold a server DTO into a subturn-level [OnboardingSnapshot], refresh the
  /// loss-free answer cache, and remember the result for the [saveAnswer]
  /// no-op-resave short-circuit.
  OnboardingSnapshot _ingest(OnboardingStateDto dto) {
    final snapshot = _ingestInner(dto);
    _lastSnapshot = snapshot;
    return snapshot;
  }

  OnboardingSnapshot _ingestInner(OnboardingStateDto dto) {
    final version = dto.version ?? _version;
    final inner = dto.state;

    // Clear before the early returns below: a stale `true` carried over from a
    // previous ingest would make [load] fire a completion PUT against a state
    // that has no answers at all — re-completing the admin "replay onboarding"
    // reset the instant it was performed.
    _walkReachedEnd = false;

    // Never-advanced envelope: fresh start, unless the user is grandfathered
    // complete (existing onboarded / WhatsApp users → onboarding_complete=true).
    if (inner == null) {
      _rawAnswersByStep.clear();
      _lastBranchWire = dto.branch;
      _lastSelectedCity = dto.selectedCity;
      _lastCompletionPathWire = null;
      if (dto.complete) {
        return OnboardingSnapshot(
          version: version,
          currentSubturnId: OnboardingSubturnId.complete,
          isComplete: true,
        );
      }
      return OnboardingSnapshot.initial(version: version);
    }

    // Refresh the loss-free per-step answer cache.
    _rawAnswersByStep
      ..clear()
      ..addAll({
        for (final entry in inner.answers.entries)
          if (entry.value is Map)
            entry.key: Map<String, dynamic>.from(entry.value as Map),
      });

    // Fall back to the branch the client computed at the city step: the backend
    // may not echo it back, but the graph still needs it to leave identity.extra.
    final branch = _branchFromWire(
      inner.branch ?? dto.branch ?? _lastBranchWire ?? readCachedBranch?.call(),
    );
    final selectedCity = inner.selectedCity ?? dto.selectedCity;
    final completionPath = _completionPathFromWire(inner.completionPath);
    _lastBranchWire = branch?.wireId ?? inner.branch ?? dto.branch;
    if (_lastBranchWire != null) writeCachedBranch?.call(_lastBranchWire!);
    _lastSelectedCity = selectedCity;
    _lastCompletionPathWire = inner.completionPath;

    // Rebuild domain answers from the per-step objects: for each step, for each
    // of its subturns, if the step object carries that subturn's key, record it.
    final answers = <OnboardingSubturnId, OnboardingAnswer>{};
    for (final subturn in OnboardingSubturnId.values) {
      final stepObj = _rawAnswersByStep[subturn.step.wireId];
      if (stepObj == null) continue;
      final key = _answerKey(subturn);
      if (!stepObj.containsKey(key)) continue;
      final value = stepObj[key];
      answers[subturn] = OnboardingAnswer(
        subturnId: subturn,
        // Never `.toString()` a structured value into a bubble — that leaks raw
        // JSON (e.g. the vibe map) on resume. Callers map known answers via
        // `displayTextFor`; anything unmapped renders as an empty (skipped)
        // bubble rather than JSON.
        displayText: displayTextFor?.call(subturn, value) ?? '',
        value: value,
      );
    }

    // Replay the client graph over recorded answers to find the resume point:
    // walk from the first subturn while each is answered, stopping at the first
    // unanswered subturn or an unresolvable branch point.
    final completed = <OnboardingSubturnId>[];
    final notLocalChoice = _notLocalChoiceFrom(answers);
    var cursor = OnboardingSubturnId.identityName;
    while (answers.containsKey(cursor)) {
      completed.add(cursor);
      OnboardingSubturnId? next;
      try {
        next = OnboardingStateGraph.next(
          cursor,
          branch: branch,
          notLocalChoice: notLocalChoice,
        );
      } on StateError {
        // Branch/choice not yet resolvable — resume here.
        break;
      }
      if (next == null) {
        cursor = OnboardingSubturnId.complete;
        break;
      }
      cursor = next;
    }

    // PROD-4580: completion is SERVER-authoritative (`onboarding_complete`, which
    // only `PUT step=complete` flips), never inferred from the walk. Finishing is
    // two sequential PUTs — the answers, then `step=complete` (see [saveAnswer])
    // — and the old `|| cursor == complete` treated the FIRST one landing as
    // "done". When the second didn't land, the client believed onboarding was
    // finished while the router gate (which reads `/auth/me.onboarding_complete`)
    // knew it wasn't: the screen dropped its finish CTAs and composer, the gate
    // bounced every escape, and the user was locked out of the app permanently —
    // across reinstalls, since the state is server-side. Hit by a real user.
    //
    // The walk reaching the end is still meaningful — every answer the graph
    // needs is recorded — so keep it, but as a RECONCILE signal
    // ([_walkReachedEnd], consumed by [load]) rather than as completion itself.
    _walkReachedEnd = cursor == OnboardingSubturnId.complete;
    final isComplete = dto.complete;

    // Every answer is in but the server hasn't confirmed completion: park the
    // cursor on the last answered subturn instead of `complete` and drop it from
    // `completed`, so the flow RE-DELIVERS that step and its finish CTAs come
    // back. Tapping one re-runs both PUTs (the `interimCompleteAfterSubturn`
    // carve-out in [saveAnswer]'s dirty-check stops the re-save being
    // short-circuited as a no-op). Without this the user sits on `complete` with
    // nothing to tap — the deadlock above.
    if (_walkReachedEnd && !isComplete && completed.isNotEmpty) {
      cursor = completed.removeLast();
    }

    return OnboardingSnapshot(
      version: version,
      currentSubturnId: cursor,
      completedSubturns: List.unmodifiable(completed),
      answers: Map.unmodifiable(answers),
      branch: branch,
      selectedCity: selectedCity,
      completionPath: completionPath,
      isComplete: isComplete,
    );
  }

  /// One JSON key per subturn inside its step's answer object. `identity.name`
  /// maps to `display_name` to match the backend example; the rest use the
  /// wireId's trailing segment (e.g. `identity.city` → `city`).
  static String _answerKey(OnboardingSubturnId subturn) {
    if (subturn == OnboardingSubturnId.identityName) return 'display_name';
    final parts = subturn.wireId.split('.');
    return parts.length > 1 ? parts.last : subturn.wireId;
  }

  static OnboardingBranch? _branchFromWire(String? wire) => switch (wire) {
    'supported' => OnboardingBranch.supported,
    'unsupported' => OnboardingBranch.unsupported,
    _ => null,
  };

  static OnboardingCompletionPath? _completionPathFromWire(String? wire) =>
      switch (wire) {
        'full' => OnboardingCompletionPath.full,
        'minimal' => OnboardingCompletionPath.minimal,
        _ => null,
      };

  /// Derive the not-local branch choice from which follow-up subturn the server
  /// already has an answer for, so the graph walk can pass the unsupported
  /// branch point on resume.
  static OnboardingNotLocalChoice? _notLocalChoiceFrom(
    Map<OnboardingSubturnId, OnboardingAnswer> answers,
  ) {
    if (answers.containsKey(OnboardingSubturnId.chatHandoff)) {
      return OnboardingNotLocalChoice.chatHandoff;
    }
    if (answers.containsKey(OnboardingSubturnId.citySwitch)) {
      return OnboardingNotLocalChoice.citySwitch;
    }
    return null;
  }
}
