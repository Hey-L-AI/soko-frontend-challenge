import '../models/onboarding_chat_models.dart';

/// Ephemeral, client-only [OnboardingProgressStore] for the admin replay
/// preview. It never touches the network or disk: every instance starts a
/// fresh run from [OnboardingSubturnId.identityName], so navigating to the
/// preview route again replays the scripted foundation from the top.
///
/// This is deliberately NOT the production store. The durable, OpenAPI-backed
/// implementation (writing to `/api/v1/app/user_profiling/*`) lands with
/// PROD-3882; until then only the identity/name step has scripted content.
class InMemoryOnboardingProgressStore implements OnboardingProgressStore {
  InMemoryOnboardingProgressStore({this.version = 'preview-v1'});

  final String version;

  late OnboardingSnapshot _snapshot = OnboardingSnapshot.initial(
    version: version,
  );

  @override
  Future<OnboardingSnapshot> load() async => _snapshot;

  @override
  Future<OnboardingSnapshot> saveAnswer(OnboardingAnswer answer) async {
    // The real server picks the next subturn; here we mirror the pure
    // transition graph, always taking the supported/chat-handoff path so the
    // branch points never throw during a preview.
    final next =
        OnboardingStateGraph.next(
          answer.subturnId,
          branch: OnboardingBranch.supported,
          notLocalChoice: OnboardingNotLocalChoice.chatHandoff,
        ) ??
        OnboardingSubturnId.complete;

    _snapshot = OnboardingSnapshot(
      version: _snapshot.version,
      currentSubturnId: next,
      completedSubturns: [..._snapshot.completedSubturns, answer.subturnId],
      answers: {..._snapshot.answers, answer.subturnId: answer},
      branch: OnboardingBranch.supported,
      selectedCity: _snapshot.selectedCity,
      completionPath: _snapshot.completionPath,
      isComplete: next == OnboardingSubturnId.complete,
    );
    return _snapshot;
  }
}
