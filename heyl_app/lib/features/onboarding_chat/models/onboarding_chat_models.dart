import 'package:flutter/foundation.dart';

/// Stable, server-addressable onboarding steps.
///
/// Display numbers are deliberately not encoded here: both [vibe] and
/// [notLocal] are presented as step 2/5, while persistence and analytics use
/// these IDs.
enum OnboardingStepId {
  identity('identity'),
  vibe('vibe'),
  notLocal('not_local'),
  zines('zines'),
  profile('profile'),
  rituals('rituals'),
  complete('complete');

  const OnboardingStepId(this.wireId);

  final String wireId;
}

/// Stable subturn IDs for the deterministic onboarding conversation.
enum OnboardingSubturnId {
  identityName('identity.name', OnboardingStepId.identity),
  identityCity('identity.city', OnboardingStepId.identity),
  identityInterests('identity.interests', OnboardingStepId.identity),
  identityExtra('identity.extra', OnboardingStepId.identity),
  vibeTaste('vibe.taste', OnboardingStepId.vibe),
  vibeShare('vibe.share', OnboardingStepId.vibe),
  notLocalChoice('not_local.choice', OnboardingStepId.notLocal),
  chatHandoff('chat_handoff', OnboardingStepId.notLocal),
  citySwitch('city_switch', OnboardingStepId.notLocal),
  zinesGenerated('zines.generated', OnboardingStepId.zines),
  zinesSuggested('zines.suggested', OnboardingStepId.zines),
  profileCard('profile.card', OnboardingStepId.profile),
  profileFollows('profile.follows', OnboardingStepId.profile),
  ritualsIntro('rituals.intro', OnboardingStepId.rituals),
  ritualsReady('rituals.ready', OnboardingStepId.rituals),
  complete('complete', OnboardingStepId.complete);

  const OnboardingSubturnId(this.wireId, this.step);

  final String wireId;
  final OnboardingStepId step;
}

enum OnboardingBranch {
  supported('supported'),
  unsupported('unsupported');

  const OnboardingBranch(this.wireId);

  final String wireId;
}

enum OnboardingCompletionPath {
  full('full'),
  minimal('minimal');

  const OnboardingCompletionPath(this.wireId);

  final String wireId;
}

enum OnboardingNotLocalChoice { chatHandoff, citySwitch }

/// Pure transition graph shared by persistence mapping and controller tests.
///
/// This graph does not prescribe an API representation. The server remains
/// authoritative and returns the next [OnboardingSnapshot] after each save.
abstract final class OnboardingStateGraph {
  static OnboardingSubturnId? next(
    OnboardingSubturnId current, {
    OnboardingBranch? branch,
    OnboardingNotLocalChoice? notLocalChoice,
  }) {
    return switch (current) {
      OnboardingSubturnId.identityName => OnboardingSubturnId.identityCity,
      OnboardingSubturnId.identityCity => OnboardingSubturnId.identityInterests,
      OnboardingSubturnId.identityInterests =>
        OnboardingSubturnId.identityExtra,
      OnboardingSubturnId.identityExtra => switch (branch) {
        OnboardingBranch.supported => OnboardingSubturnId.vibeTaste,
        OnboardingBranch.unsupported => OnboardingSubturnId.notLocalChoice,
        null => throw StateError(
          'A supported/unsupported branch is required after identity.extra.',
        ),
      },
      OnboardingSubturnId.notLocalChoice => switch (notLocalChoice) {
        OnboardingNotLocalChoice.chatHandoff => OnboardingSubturnId.chatHandoff,
        OnboardingNotLocalChoice.citySwitch => OnboardingSubturnId.citySwitch,
        null => throw StateError(
          'A not-local choice is required after not_local.choice.',
        ),
      },
      OnboardingSubturnId.chatHandoff => OnboardingSubturnId.complete,
      OnboardingSubturnId.citySwitch => OnboardingSubturnId.vibeTaste,
      // The "share a favourite" search now lives ON the vibeTaste screen (its
      // carousels + search + gated Continue are one beat), so vibeTaste advances
      // straight to zines. `vibeShare` is kept in the graph as an unreachable
      // pass-through so any pre-merge cursor still resolves forward on resume.
      OnboardingSubturnId.vibeTaste => OnboardingSubturnId.zinesGenerated,
      OnboardingSubturnId.vibeShare => OnboardingSubturnId.zinesGenerated,
      // `zinesSuggested` and `ritualsIntro` are future placeholders with no UI
      // yet — skip straight past them so every reachable subturn has a way to
      // advance (a message-only subturn would strand the flow).
      OnboardingSubturnId.zinesGenerated => OnboardingSubturnId.profileCard,
      OnboardingSubturnId.zinesSuggested => OnboardingSubturnId.profileCard,
      OnboardingSubturnId.profileCard => OnboardingSubturnId.profileFollows,
      OnboardingSubturnId.profileFollows => OnboardingSubturnId.ritualsReady,
      OnboardingSubturnId.ritualsIntro => OnboardingSubturnId.ritualsReady,
      OnboardingSubturnId.ritualsReady => OnboardingSubturnId.complete,
      OnboardingSubturnId.complete => null,
    };
  }
}

@immutable
class OnboardingAnswer {
  const OnboardingAnswer({
    required this.subturnId,
    required this.displayText,
    required this.value,
    this.branch,
    this.selectedCity,
    this.notLocalChoice,
    this.completionPath,
    this.ackMessage,
    this.selectedCityId,
    this.selectedLatitude,
    this.selectedLongitude,
  });

  final OnboardingSubturnId subturnId;

  /// Human-readable representation rendered in the user bubble.
  final String displayText;

  /// Domain answer payload. The eventual OpenAPI adapter owns wire mapping.
  final Object? value;

  /// City-gate metadata. When this answer resolves the supported/unsupported
  /// branch (the city step, or a not-local city switch), the store stamps
  /// [branch] + [selectedCity] onto the PUT so the graph can advance past the
  /// `identity.extra → branch` decision. Null on answers that don't touch it.
  final OnboardingBranch? branch;
  final String? selectedCity;

  /// The PICKED location for the city step, sent to the server so it resolves
  /// coverage authoritatively (against `discovery_enabled`) and sets the branch
  /// itself — the client no longer decides supported/unsupported. `selectedCityId`
  /// is a seeded-city UUID (picker); GPS / area picks send only the coords. Null
  /// on every answer that isn't a city choice.
  final String? selectedCityId;
  final double? selectedLatitude;
  final double? selectedLongitude;

  /// Resolves the `not_local.choice` fork ([OnboardingNotLocalChoice.chatHandoff]
  /// = "Fala comigo"; [OnboardingNotLocalChoice.citySwitch] = pick a supported
  /// city). Null on every other answer.
  final OnboardingNotLocalChoice? notLocalChoice;

  /// Completion path stamped when this answer finishes onboarding
  /// (`minimal` for the chat handoff). Null otherwise.
  final OnboardingCompletionPath? completionPath;

  /// Optional Soko acknowledgement bubble delivered right after this answer
  /// persists and before the next subturn's turns (e.g. a "Great, thanks!"
  /// after the user adds free text at `identity.extra`). Purely presentational
  /// and client-owned — never persisted. Null → no ack bubble.
  final String? ackMessage;
}

@immutable
class OnboardingSnapshot {
  const OnboardingSnapshot({
    required this.version,
    required this.currentSubturnId,
    this.completedSubturns = const [],
    this.answers = const {},
    this.branch,
    this.selectedCity,
    this.completionPath,
    this.isComplete = false,
  });

  factory OnboardingSnapshot.initial({required String version}) =>
      OnboardingSnapshot(
        version: version,
        currentSubturnId: OnboardingSubturnId.identityName,
      );

  final String version;
  final OnboardingSubturnId currentSubturnId;

  /// Ordered completed subturns, preserving transcript order across resume.
  final List<OnboardingSubturnId> completedSubturns;
  final Map<OnboardingSubturnId, OnboardingAnswer> answers;
  final OnboardingBranch? branch;
  final String? selectedCity;
  final OnboardingCompletionPath? completionPath;
  final bool isComplete;
}

/// Durable persistence boundary. Only a generated OpenAPI implementation may
/// be registered in production once PROD-3882 lands.
abstract interface class OnboardingProgressStore {
  Future<OnboardingSnapshot> load();

  /// Saves one answer idempotently and returns the authoritative server state.
  Future<OnboardingSnapshot> saveAnswer(OnboardingAnswer answer);
}

enum OnboardingTurnActor { soko, user }

enum OnboardingTurnKind { message, content }

@immutable
class OnboardingTurnSpec {
  const OnboardingTurnSpec.message({
    required this.id,
    required this.subturnId,
    required this.actor,
    required this.text,
  }) : kind = OnboardingTurnKind.message,
       contentId = null,
       searchingLabel = null,
       gatesDelivery = false;

  const OnboardingTurnSpec.content({
    required this.id,
    required this.subturnId,
    required this.contentId,
    this.searchingLabel,
    this.gatesDelivery = false,
  }) : kind = OnboardingTurnKind.content,
       actor = OnboardingTurnActor.soko,
       text = null;

  final String id;
  final OnboardingSubturnId subturnId;
  final OnboardingTurnActor actor;
  final OnboardingTurnKind kind;
  final String? text;
  final String? contentId;

  /// When set, the transcript shows a pulsing "searching…" progress label (via
  /// `SearchStatusIndicator`) for a short beat BEFORE this content turn is
  /// appended — a chat-like "Soko is finding things" pause ahead of a carousel.
  /// Only meaningful on content turns; null → the turn appears with no pause.
  final String? searchingLabel;

  /// When true, transcript delivery PAUSES before this turn and waits for the
  /// user to act on it before delivering the rest of the subturn. The gate turn
  /// itself is NOT rendered inline — it surfaces in the pinned bottom composer
  /// (see the screen's `showConsentComposer`). Used by the rituals
  /// delivery-consent so "You're ready!" only appears once the user answers.
  final bool gatesDelivery;
}

/// Content-turn ids for the not-local step's inline interactive turns (rendered
/// by the screen's `contentBuilder`, delivered in succession like messages).
const String notLocalFalaComigoContentId = 'not_local.fala_comigo';
const String notLocalCitiesContentId = 'not_local.cities';
const String notLocalContinueContentId = 'not_local.continue';

/// Content-turn ids for the vibe step's inline carousels + Continue, delivered
/// in succession like messages and rendered by the screen's `contentBuilder`.
const String vibeSitiosContentId = 'vibe.sitios';
const String vibeEventosContentId = 'vibe.eventos';
const String vibeContinueContentId = 'vibe.continue';

/// Zero-render marker that gates the vibe step: delivery pauses here until the
/// user 👍 a carousel card (the screen calls `resumeAfterGate`), so the search
/// reveal message + input + Continue only land after a like.
const String vibeLikeGateContentId = 'vibe.like_gate';

// vibe.share step: a search-a-place/event-and-bookmark surface + its Continue.
const String vibeShareContentId = 'vibe.share.search';
const String vibeShareContinueContentId = 'vibe.share.continue';

// zines.generated step (3/5): a preview carousel of the generated zine's
// places/events + the save-this-zine + Continue gate.
const String zinesCarouselContentId = 'zines.generated.carousel';
// Second row on step 3: the most-followed public zines ("some you might like").
const String zinesSuggestedCarouselContentId = 'zines.generated.suggested';
const String zinesGateContentId = 'zines.generated.gate';

// profile.card step (4/5): the profile card preview + edit/skip gate.
const String profileCardContentId = 'profile.card.card';
const String profileEditGateContentId = 'profile.card.gate';

// profile.follows step (4/5 cont.): follow-people carousel + find-contacts +
// Continue.
const String profileFollowsCarouselContentId = 'profile.follows.carousel';
const String profileFindContactsContentId = 'profile.follows.contacts';
const String profileFollowsContinueContentId = 'profile.follows.continue';

// rituals step (5/5): the daily/weekly covers, the two secondary exit CTAs
// (map / chat), and the closing "Continuar" CTA that completes onboarding.
const String ritualsCoversContentId = 'rituals.covers';
// Inline Yes/No consent for push + email + SMS marketing, delivered right after
// the delivery-ask message. "Yes" opts into all applicable channels and fires
// the OS push prompt; "No" records an explicit opt-out. Replaces the old
// auto-fired OS prompt on the covers carousel.
const String ritualsDeliveryConsentContentId = 'rituals.delivery_consent';
const String ritualsExitCtasContentId = 'rituals.exits';
const String ritualsFinishContentId = 'rituals.finish';

/// Declarative turn catalog. Later frontend tickets add their content turns
/// without changing delivery mechanics or stable state IDs.
@immutable
class OnboardingScript {
  OnboardingScript(Map<OnboardingSubturnId, List<OnboardingTurnSpec>> turns)
    : _turns = Map<OnboardingSubturnId, List<OnboardingTurnSpec>>.unmodifiable({
        for (final entry in turns.entries)
          entry.key: List<OnboardingTurnSpec>.unmodifiable(entry.value),
      });

  factory OnboardingScript.identityName({
    required String greeting,
    required String askName,
  }) => OnboardingScript({
    OnboardingSubturnId.identityName: [
      OnboardingTurnSpec.message(
        id: 'identity.name.greeting',
        subturnId: OnboardingSubturnId.identityName,
        actor: OnboardingTurnActor.soko,
        text: greeting,
      ),
      OnboardingTurnSpec.message(
        id: 'identity.name.ask',
        subturnId: OnboardingSubturnId.identityName,
        actor: OnboardingTurnActor.soko,
        text: askName,
      ),
    ],
  });

  /// Full identity step (Figma `7285:23262`): name → city → interests → extra,
  /// plus the unsupported-city `not_local.choice` turns (Figma "Não sou local
  /// ainda") delivered when the selected city has no Soko coverage.
  factory OnboardingScript.identity({
    required String greeting,
    required String askName,
    required String askCity,
    required String askInterests,
    required String interestsHint,
    required String askExtra,
    String? extraExamples,
    String? notLocalKnowWhere,
    String? notLocalNotYet,
    String? notLocalExplore,
    String? notLocalOrContinue,
    String? vibeIntro,
    String? vibeAsk,
    String? vibeGate,
    String? vibeSearchReveal,
    String? vibeSearchingPlaces,
    String? vibeSearchingEvents,
    String? vibeShareIntro,
    String? zinesIntro,
    String? zinesSaveHint,
    String? zinesMadeForYou,
    String? zinesSearching,
    String? zinesSuggestedIntro,
    String? zinesSuggestedSearching,
    String? profileIntro,
    String? profileFollowsIntro,
    String? profileFollowsSearching,
    String? ritualsIntro,
    String? ritualsBody,
    String? ritualsSearching,
    String? ritualsDeliveryAsk,
    String? ritualsReadyMsg,
  }) => OnboardingScript({
    OnboardingSubturnId.identityName: [
      OnboardingTurnSpec.message(
        id: 'identity.name.greeting',
        subturnId: OnboardingSubturnId.identityName,
        actor: OnboardingTurnActor.soko,
        text: greeting,
      ),
      OnboardingTurnSpec.message(
        id: 'identity.name.ask',
        subturnId: OnboardingSubturnId.identityName,
        actor: OnboardingTurnActor.soko,
        text: askName,
      ),
    ],
    OnboardingSubturnId.identityCity: [
      OnboardingTurnSpec.message(
        id: 'identity.city.ask',
        subturnId: OnboardingSubturnId.identityCity,
        actor: OnboardingTurnActor.soko,
        text: askCity,
      ),
    ],
    OnboardingSubturnId.identityInterests: [
      OnboardingTurnSpec.message(
        id: 'identity.interests.ask',
        subturnId: OnboardingSubturnId.identityInterests,
        actor: OnboardingTurnActor.soko,
        text: askInterests,
      ),
      OnboardingTurnSpec.message(
        id: 'identity.interests.hint',
        subturnId: OnboardingSubturnId.identityInterests,
        actor: OnboardingTurnActor.soko,
        text: interestsHint,
      ),
    ],
    OnboardingSubturnId.identityExtra: [
      OnboardingTurnSpec.message(
        id: 'identity.extra.ask',
        subturnId: OnboardingSubturnId.identityExtra,
        actor: OnboardingTurnActor.soko,
        // The examples ride INSIDE the question ("Mais alguma coisa…? Por
        // exemplo, …") — one message, so people know the kind of thing to say.
        text: extraExamples == null ? askExtra : '$askExtra $extraExamples',
      ),
    ],
    // Unsupported-city branch: the "Não sou local ainda" intro. Only seeded
    // when the copy is supplied (production always supplies it; the name-only
    // foundation tests don't).
    if (notLocalKnowWhere != null &&
        notLocalNotYet != null &&
        notLocalExplore != null &&
        notLocalOrContinue != null)
      OnboardingSubturnId.notLocalChoice: [
        OnboardingTurnSpec.message(
          id: 'not_local.choice.know_where',
          subturnId: OnboardingSubturnId.notLocalChoice,
          actor: OnboardingTurnActor.soko,
          text: notLocalKnowWhere,
        ),
        OnboardingTurnSpec.message(
          id: 'not_local.choice.not_yet',
          subturnId: OnboardingSubturnId.notLocalChoice,
          actor: OnboardingTurnActor.soko,
          text: notLocalNotYet,
        ),
        OnboardingTurnSpec.message(
          id: 'not_local.choice.explore',
          subturnId: OnboardingSubturnId.notLocalChoice,
          actor: OnboardingTurnActor.soko,
          text: notLocalExplore,
        ),
        // Interactive content, delivered in succession like the messages: the
        // "Fala comigo" handoff, then the "or continue…" line, the city chips,
        // and the full-width Continue. Rendered by the screen's contentBuilder.
        const OnboardingTurnSpec.content(
          id: 'not_local.choice.fala_comigo',
          subturnId: OnboardingSubturnId.notLocalChoice,
          contentId: notLocalFalaComigoContentId,
        ),
        OnboardingTurnSpec.message(
          id: 'not_local.choice.or_continue',
          subturnId: OnboardingSubturnId.notLocalChoice,
          actor: OnboardingTurnActor.soko,
          text: notLocalOrContinue,
        ),
        const OnboardingTurnSpec.content(
          id: 'not_local.choice.cities',
          subturnId: OnboardingSubturnId.notLocalChoice,
          contentId: notLocalCitiesContentId,
        ),
        const OnboardingTurnSpec.content(
          id: 'not_local.choice.continue',
          subturnId: OnboardingSubturnId.notLocalChoice,
          contentId: notLocalContinueContentId,
        ),
      ],
    // Supported-city branch: the "Qual é a tua vibe" intro. Seeded only when
    // the copy is supplied.
    if (vibeIntro != null && vibeAsk != null)
      OnboardingSubturnId.vibeTaste: [
        OnboardingTurnSpec.message(
          id: 'vibe.taste.intro',
          subturnId: OnboardingSubturnId.vibeTaste,
          actor: OnboardingTurnActor.soko,
          text: vibeIntro,
        ),
        OnboardingTurnSpec.message(
          id: 'vibe.taste.ask',
          subturnId: OnboardingSubturnId.vibeTaste,
          actor: OnboardingTurnActor.soko,
          text: vibeAsk,
        ),
        // Carousels + Continue delivered in succession like messages (rendered
        // by the screen's contentBuilder).
        OnboardingTurnSpec.content(
          id: 'vibe.taste.sitios',
          subturnId: OnboardingSubturnId.vibeTaste,
          contentId: vibeSitiosContentId,
          searchingLabel: vibeSearchingPlaces,
        ),
        OnboardingTurnSpec.content(
          id: 'vibe.taste.eventos',
          subturnId: OnboardingSubturnId.vibeTaste,
          contentId: vibeEventosContentId,
          searchingLabel: vibeSearchingEvents,
        ),
        // Encourage (not require) a thumb-up on a card or a search favourite —
        // the taste signal is optional. Continue is shown regardless.
        if (vibeGate != null)
          OnboardingTurnSpec.message(
            id: 'vibe.taste.gate',
            subturnId: OnboardingSubturnId.vibeTaste,
            actor: OnboardingTurnActor.soko,
            text: vibeGate,
          ),
        // Pause only until BOTH shelves have settled (loaded/empty/errored), so
        // the cards get a beat on screen before the rest delivers — NOT until a
        // like (`_maybeResumeVibeGate` resumes on settle; requiring a 👍 stranded
        // ~35% of users at 2/5 — see project_vibe_step_like_gate_trap).
        const OnboardingTurnSpec.content(
          id: 'vibe.taste.like_gate',
          subturnId: OnboardingSubturnId.vibeTaste,
          contentId: vibeLikeGateContentId,
          gatesDelivery: true,
        ),
        // After the cards settle: "and you can even search your own favourites
        // too" → reveal the search input → reveal Continue.
        if (vibeSearchReveal != null)
          OnboardingTurnSpec.message(
            id: 'vibe.taste.search_reveal',
            subturnId: OnboardingSubturnId.vibeTaste,
            actor: OnboardingTurnActor.soko,
            text: vibeSearchReveal,
          ),
        const OnboardingTurnSpec.content(
          id: 'vibe.taste.search',
          subturnId: OnboardingSubturnId.vibeTaste,
          contentId: vibeShareContentId,
        ),
        const OnboardingTurnSpec.content(
          id: 'vibe.taste.continue',
          subturnId: OnboardingSubturnId.vibeTaste,
          contentId: vibeContinueContentId,
        ),
      ],
    // Vibe share (2/5 cont.): "share a place/event you love" search + save.
    if (vibeShareIntro != null)
      OnboardingSubturnId.vibeShare: [
        OnboardingTurnSpec.message(
          id: 'vibe.share.intro',
          subturnId: OnboardingSubturnId.vibeShare,
          actor: OnboardingTurnActor.soko,
          text: vibeShareIntro,
        ),
        const OnboardingTurnSpec.content(
          id: 'vibe.share.search',
          subturnId: OnboardingSubturnId.vibeShare,
          contentId: vibeShareContentId,
        ),
        const OnboardingTurnSpec.content(
          id: 'vibe.share.continue',
          subturnId: OnboardingSubturnId.vibeShare,
          contentId: vibeShareContinueContentId,
        ),
      ],
    // Zines (3/5, Figma 7285:23913): "I've got curated zines made for you" —
    // intro bubbles, a preview carousel of the generated zine's places/events,
    // then a save-the-whole-zine + Continue gate. Seeded only when copy exists.
    if (zinesIntro != null && zinesSaveHint != null && zinesMadeForYou != null)
      OnboardingSubturnId.zinesGenerated: [
        OnboardingTurnSpec.message(
          id: 'zines.generated.intro',
          subturnId: OnboardingSubturnId.zinesGenerated,
          actor: OnboardingTurnActor.soko,
          text: zinesIntro,
        ),
        OnboardingTurnSpec.message(
          id: 'zines.generated.hint',
          subturnId: OnboardingSubturnId.zinesGenerated,
          actor: OnboardingTurnActor.soko,
          text: zinesSaveHint,
        ),
        OnboardingTurnSpec.message(
          id: 'zines.generated.made',
          subturnId: OnboardingSubturnId.zinesGenerated,
          actor: OnboardingTurnActor.soko,
          text: zinesMadeForYou,
        ),
        OnboardingTurnSpec.content(
          id: 'zines.generated.carousel',
          subturnId: OnboardingSubturnId.zinesGenerated,
          contentId: zinesCarouselContentId,
          searchingLabel: zinesSearching,
        ),
        // Second row (same step): "and here are some you might like" → the
        // most-followed public zines. Delivered as its own message + content
        // turn so the engine paces it AFTER the generated row (typing beat →
        // message → searching beat → cards), mirroring the vibe step's two
        // carousels. Seeded only when its copy exists.
        if (zinesSuggestedIntro != null) ...[
          OnboardingTurnSpec.message(
            id: 'zines.generated.suggested_intro',
            subturnId: OnboardingSubturnId.zinesGenerated,
            actor: OnboardingTurnActor.soko,
            text: zinesSuggestedIntro,
          ),
          OnboardingTurnSpec.content(
            id: 'zines.generated.suggested',
            subturnId: OnboardingSubturnId.zinesGenerated,
            contentId: zinesSuggestedCarouselContentId,
            searchingLabel: zinesSuggestedSearching,
          ),
        ],
        const OnboardingTurnSpec.content(
          id: 'zines.generated.gate',
          subturnId: OnboardingSubturnId.zinesGenerated,
          contentId: zinesGateContentId,
        ),
      ],
    // Profile card (4/5, Figma 7285:24113): "you have a profile now" — the
    // card (avatar + name + handle) and an edit/skip gate.
    if (profileIntro != null)
      OnboardingSubturnId.profileCard: [
        OnboardingTurnSpec.message(
          id: 'profile.card.intro',
          subturnId: OnboardingSubturnId.profileCard,
          actor: OnboardingTurnActor.soko,
          text: profileIntro,
        ),
        const OnboardingTurnSpec.content(
          id: 'profile.card.card',
          subturnId: OnboardingSubturnId.profileCard,
          contentId: profileCardContentId,
        ),
        const OnboardingTurnSpec.content(
          id: 'profile.card.gate',
          subturnId: OnboardingSubturnId.profileCard,
          contentId: profileEditGateContentId,
        ),
      ],
    // Profile follows (4/5 cont., Figma 7285:24202): follow-people carousel +
    // find-contacts + Continue.
    if (profileFollowsIntro != null)
      OnboardingSubturnId.profileFollows: [
        OnboardingTurnSpec.message(
          id: 'profile.follows.intro',
          subturnId: OnboardingSubturnId.profileFollows,
          actor: OnboardingTurnActor.soko,
          text: profileFollowsIntro,
        ),
        OnboardingTurnSpec.content(
          id: 'profile.follows.carousel',
          subturnId: OnboardingSubturnId.profileFollows,
          contentId: profileFollowsCarouselContentId,
          searchingLabel: profileFollowsSearching,
        ),
        const OnboardingTurnSpec.content(
          id: 'profile.follows.contacts',
          subturnId: OnboardingSubturnId.profileFollows,
          contentId: profileFindContactsContentId,
        ),
        const OnboardingTurnSpec.content(
          id: 'profile.follows.continue',
          subturnId: OnboardingSubturnId.profileFollows,
          contentId: profileFollowsContinueContentId,
        ),
      ],
    // Rituals (5/5, Figma 7285:24308): "É isso!" → "Agora tenho isto para ti"
    // → the daily/weekly covers → the delivery ask → "Estás pronto!" → the two
    // exit CTAs (map / chat) → the "Continuar" finish CTA that completes.
    if (ritualsIntro != null && ritualsBody != null)
      OnboardingSubturnId.ritualsReady: [
        OnboardingTurnSpec.message(
          id: 'rituals.ready.intro',
          subturnId: OnboardingSubturnId.ritualsReady,
          actor: OnboardingTurnActor.soko,
          text: ritualsIntro,
        ),
        OnboardingTurnSpec.message(
          id: 'rituals.ready.body',
          subturnId: OnboardingSubturnId.ritualsReady,
          actor: OnboardingTurnActor.soko,
          text: ritualsBody,
        ),
        OnboardingTurnSpec.content(
          id: 'rituals.ready.covers',
          subturnId: OnboardingSubturnId.ritualsReady,
          contentId: ritualsCoversContentId,
          searchingLabel: ritualsSearching,
        ),
        if (ritualsDeliveryAsk != null)
          OnboardingTurnSpec.message(
            id: 'rituals.ready.delivery_ask',
            subturnId: OnboardingSubturnId.ritualsReady,
            actor: OnboardingTurnActor.soko,
            text: ritualsDeliveryAsk,
          ),
        // The Yes/No consent chips answer the delivery ask. This turn GATES
        // delivery: the transcript pauses here (chips surface in the bottom
        // composer) until the user answers, so "You're ready!" and the finish
        // CTAs below only appear afterwards.
        if (ritualsDeliveryAsk != null)
          const OnboardingTurnSpec.content(
            id: 'rituals.ready.delivery_consent',
            subturnId: OnboardingSubturnId.ritualsReady,
            contentId: ritualsDeliveryConsentContentId,
            gatesDelivery: true,
          ),
        if (ritualsReadyMsg != null)
          OnboardingTurnSpec.message(
            id: 'rituals.ready.ready',
            subturnId: OnboardingSubturnId.ritualsReady,
            actor: OnboardingTurnActor.soko,
            text: ritualsReadyMsg,
          ),
        const OnboardingTurnSpec.content(
          id: 'rituals.ready.exits',
          subturnId: OnboardingSubturnId.ritualsReady,
          contentId: ritualsExitCtasContentId,
        ),
        const OnboardingTurnSpec.content(
          id: 'rituals.finish',
          subturnId: OnboardingSubturnId.ritualsReady,
          contentId: ritualsFinishContentId,
        ),
      ],
  });

  final Map<OnboardingSubturnId, List<OnboardingTurnSpec>> _turns;

  List<OnboardingTurnSpec> turnsFor(OnboardingSubturnId subturnId) =>
      _turns[subturnId] ?? const [];

  /// Every Soko message turn's text keyed by its stable turn id. Used to
  /// re-translate already-delivered bubbles when the locale changes: rebuild the
  /// script in the new locale, then map delivered turns back by id.
  Map<String, String> messageTextById() => {
    for (final specs in _turns.values)
      for (final spec in specs)
        if (spec.kind == OnboardingTurnKind.message &&
            spec.actor == OnboardingTurnActor.soko &&
            spec.text != null)
          spec.id: spec.text!,
  };
}

@immutable
class OnboardingDeliveredTurn {
  const OnboardingDeliveredTurn({
    required this.id,
    required this.subturnId,
    required this.actor,
    required this.kind,
    required this.animate,
    this.text,
    this.contentId,
    this.isPending = false,
  });

  factory OnboardingDeliveredTurn.fromSpec(
    OnboardingTurnSpec spec, {
    required bool animate,
  }) => OnboardingDeliveredTurn(
    id: spec.id,
    subturnId: spec.subturnId,
    actor: spec.actor,
    kind: spec.kind,
    text: spec.text,
    contentId: spec.contentId,
    animate: animate,
  );

  factory OnboardingDeliveredTurn.answer(
    OnboardingAnswer answer, {
    required bool animate,
    bool isPending = false,
  }) => OnboardingDeliveredTurn(
    id: 'answer:${answer.subturnId.wireId}',
    subturnId: answer.subturnId,
    actor: OnboardingTurnActor.user,
    kind: OnboardingTurnKind.message,
    text: answer.displayText,
    animate: animate,
    isPending: isPending,
  );

  final String id;
  final OnboardingSubturnId subturnId;
  final OnboardingTurnActor actor;
  final OnboardingTurnKind kind;
  final String? text;
  final String? contentId;
  final bool animate;
  final bool isPending;

  OnboardingDeliveredTurn copyWith({
    bool? isPending,
    String? text,
    bool? animate,
  }) => OnboardingDeliveredTurn(
    id: id,
    subturnId: subturnId,
    actor: actor,
    kind: kind,
    text: text ?? this.text,
    contentId: contentId,
    animate: animate ?? this.animate,
    isPending: isPending ?? this.isPending,
  );
}
