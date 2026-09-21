import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/utils/datetime_parsing.dart';
import '../../../data/models/chat_message.dart' show ItemSuggestion;
import '../../../data/models/entity_signal.dart';
import '../../../data/models/event_occurrence.dart';
import '../../../data/models/social/user_search_item.dart';
import '../../../data/models/user_profile.dart' show UserRole;
import '../../../data/models/vibe_candidate.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/account_provider.dart' show accountProvider;
import '../../../providers/api_provider.dart' show signalApiProvider;
import '../../../providers/auth_provider.dart'
    show currentUserProvider, isAuthenticatedProvider;
import '../../../shared/utils/share_helpers.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/chat_bar.dart';
import '../../auth/widgets/auth_language_button.dart';
import '../../entity_signals/providers/signal_controller.dart';
import '../../profile/providers/people_providers.dart';
import '../../profile/services/contact_sync_service.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_turn_entrance.dart';
import '../models/onboarding_chat_models.dart';
import '../widgets/onboarding_detail_page.dart';
import '../data/onboarding_hydrate_source.dart';
import '../data/onboarding_supported_cities.dart';
import '../providers/onboarding_chat_controller.dart';
import '../providers/onboarding_vibe_controller.dart';
import '../providers/onboarding_zines_controller.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../shared/widgets/place_event_search_overlay.dart';
import '../../../shared/widgets/search/unified_search_models.dart';
import '../../../shared/widgets/search/unified_search_overlay.dart';
import '../widgets/onboarding_continue_button.dart';
import '../widgets/onboarding_delivery_consent.dart';
import '../widgets/onboarding_edit_profile_page.dart';
import '../widgets/onboarding_follow_carousel.dart';
import '../widgets/onboarding_profile_card.dart';
import '../widgets/onboarding_rituals_carousel.dart';
import '../../../core/router/app_router.dart' show AppRoutes;
import '../widgets/onboarding_zines_carousel.dart';
import '../widgets/onboarding_extra_composer.dart';
import '../widgets/onboarding_interests_composer.dart';
import '../widgets/onboarding_location_composer.dart';
import '../widgets/onboarding_name_composer.dart';
import '../widgets/onboarding_not_local_composer.dart';
import '../widgets/onboarding_transcript.dart';
import '../widgets/onboarding_vibe_card.dart';
import '../widgets/onboarding_vibe_carousels.dart';

/// Where onboarding navigates once it completes. Defaults to home ("Continuar"),
/// but the rituals step's secondary CTAs set it to the map or chat before
/// finishing, so the completion listener (in `OnboardingChatScreen`) routes the
/// user straight to the surface they picked.
final onboardingExitDestinationProvider = StateProvider<String>(
  (_) => AppRoutes.home,
);

/// Injected copy for the unreachable foundation screen. The production caller
/// will map these fields from ARB getters after the es-MX portal export exists.
@immutable
class OnboardingIdentityNameCopy {
  const OnboardingIdentityNameCopy({
    required this.headerTitle,
    required this.stepLabel,
    required this.namePlaceholder,
    required this.persistenceError,
    required this.retryLabel,
    this.editAnswerLabel,
    this.cityPlaceholder,
    this.interestsConfirmLabel,
    this.interestsOptions,
    this.useMyLocationLabel,
    this.chooseLocationLabel,
    this.nameMaxLength,
    this.firstNamePlaceholder,
    this.surnamePlaceholder,
    this.extraYesLabel,
    this.extraNoLabel,
    this.extraPlaceholder,
    this.extraConfirmLabel,
    this.extraAck,
    this.vibeHeaderTitle,
    this.vibeContinueLabel,
    this.vibePlacesLabel,
    this.vibeEventsLabel,
    this.vibeErrorLabel,
    this.vibeSearchingPlaces,
    this.vibeSearchingEvents,
    this.vibeSharePlaceholder,
    this.vibeShareEmpty,
    this.zinesHeaderTitle,
    this.zinesSaveLabel,
    this.zinesSavedLabel,
    this.zinesErrorLabel,
    this.profileHeaderTitle,
    this.profileEditLaterLabel,
    this.profileEditCtaLabel,
    this.profileFindContactsLabel,
    this.profileContinueLabel,
    this.profileFollowsErrorLabel,
    this.ritualsHeaderTitle,
    this.ritualsCtaLabel,
    this.ritualsDailyTitle,
    this.ritualsDailySubtitle,
    this.ritualsWeeklyTitle,
    this.ritualsWeeklySubtitle,
    this.ritualsExploreMapLabel,
    this.ritualsChatLabel,
    this.notLocalHeaderTitle,
    this.notLocalFalaComigo,
    this.notLocalOrContinue,
  });

  final String headerTitle;
  final String stepLabel;
  final String namePlaceholder;
  final String persistenceError;
  final String retryLabel;

  /// PROD-4394 D1: secondary exit on the persistence-error card — clears the
  /// failed answer and re-opens the composer, so Retry (which can keep
  /// failing on the same payload) is never the ONLY way out. Null keeps the
  /// old retry-only card (test fixtures).
  final String? editAnswerLabel;

  // Optional identity-step-completion copy. When absent, that subturn shows no
  // composer (keeps the name-only foundation callers unchanged).
  final String? cityPlaceholder;
  final String? interestsConfirmLabel;
  final List<OnboardingInterestOption>? interestsOptions;

  // City-step location pills (GPS + picker).
  final String? useMyLocationLabel;
  final String? chooseLocationLabel;

  /// Hard cap on the name input (null = uncapped).
  final int? nameMaxLength;

  /// Name step two-field form placeholders (First name / Surname). When either
  /// is absent the name turn falls back to the single free-text composer.
  final String? firstNamePlaceholder;
  final String? surnamePlaceholder;

  // Optional "anything else?" (identity.extra) composer copy. When any is
  // absent, the extra composer is not shown.
  final String? extraYesLabel;
  final String? extraNoLabel;
  final String? extraPlaceholder;
  final String? extraConfirmLabel;

  /// Soko acknowledgement bubble shown after the user adds free text at
  /// `identity.extra` (not shown when they decline). Null → no ack.
  final String? extraAck;

  // Optional vibe step (`vibe.taste`) copy. When any is absent, the vibe
  // carousels composer is not shown (and the header stays on the identity copy).
  final String? vibeHeaderTitle;
  final String? vibeContinueLabel;
  final String? vibePlacesLabel;
  final String? vibeEventsLabel;
  final String? vibeErrorLabel;

  /// "Finding places/events for you…" — the searching text the shelf keeps
  /// showing if it mounts before its own fetch resolves (same strings the
  /// transcript loader uses).
  final String? vibeSearchingPlaces;
  final String? vibeSearchingEvents;

  // Optional vibe share (`vibe.share`) search copy.
  final String? vibeSharePlaceholder;
  final String? vibeShareEmpty;

  // Optional zines step (`zines.generated`) copy. When [zinesHeaderTitle] is
  // absent, the zines header/step-label branch stays on the identity copy.
  final String? zinesHeaderTitle;
  final String? zinesSaveLabel;
  final String? zinesSavedLabel;
  final String? zinesErrorLabel;

  // Optional profile step (`profile.card`/`profile.follows`, 4/5) copy.
  final String? profileHeaderTitle;
  final String? profileEditLaterLabel;
  final String? profileEditCtaLabel;
  final String? profileFindContactsLabel;
  final String? profileContinueLabel;
  final String? profileFollowsErrorLabel;

  // Optional rituals step (5/5) copy.
  final String? ritualsHeaderTitle;
  final String? ritualsCtaLabel;
  final String? ritualsDailyTitle;
  final String? ritualsDailySubtitle;
  final String? ritualsWeeklyTitle;
  final String? ritualsWeeklySubtitle;
  final String? ritualsExploreMapLabel;
  final String? ritualsChatLabel;

  // Optional not-local step (`not_local.choice`) copy. When any is absent, the
  // not-local composer is not shown.
  final String? notLocalHeaderTitle;
  final String? notLocalFalaComigo;
  final String? notLocalOrContinue;
}

/// Figma `7285:23262` foundation: fixed identity header, scripted transcript,
/// and the name composer. It is intentionally not registered in the router.
class OnboardingIdentityNameScreen extends ConsumerStatefulWidget {
  const OnboardingIdentityNameScreen({
    super.key,
    required this.controllerProvider,
    required this.copy,
    this.onExtraText,
    this.vibeVenuesProvider,
    this.vibeEventsProvider,
    this.zinesProvider,
    this.suggestedZinesProvider,
    this.onRestart,
    this.onSkip,
    this.isPreview = false,
    this.waitsForSession = false,
  });

  final StateNotifierProvider<OnboardingChatController, OnboardingChatState>
  controllerProvider;
  final OnboardingIdentityNameCopy copy;

  /// Hold the flow until a real (non-guest) session exists. True only for the
  /// API-backed production flow, whose `/onboarding/state` load 401s for guests
  /// (PROD-4582). The preview page runs on an in-memory store that never touches
  /// the API, so it must keep starting immediately, signed in or not.
  final bool waitsForSession;

  /// Screen-local per-shelf vibe providers (built + invalidated by the caller).
  /// Each carousel fires its own discovery call. When either is null, the vibe
  /// step shows no composer.
  final StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>?
  vibeVenuesProvider;
  final StateNotifierProvider<OnboardingVibeController, OnboardingVibeState>?
  vibeEventsProvider;

  /// Screen-local zines provider (built + invalidated by the caller). Null →
  /// the zines carousel/gate show no content.
  final StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>?
  zinesProvider;

  /// Screen-local provider for the "most-followed" second zines row on step 3
  /// (built + invalidated by the caller). Same controller type, sourced from
  /// popular public zines. Null → that row shows no content.
  final StateNotifierProvider<OnboardingZinesController, OnboardingZinesState>?
  suggestedZinesProvider;

  /// Best-effort side effect fired with the trimmed free text the user typed at
  /// the `identity.extra` step (production wires this to the memory tell-us
  /// endpoint). Never awaited by the composer, so a failure can't block the
  /// answer persistence that completes onboarding.
  final Future<void> Function(String text)? onExtraText;

  /// Admin/QA-only: resets the durable onboarding state and replays the flow
  /// from the top. When null, no restart affordance is shown. Wired by the
  /// production caller; surfaced as a top-right header button for admins only.
  final Future<void> Function()? onRestart;

  /// Admin/QA-only: marks onboarding complete server-side and leaves to the
  /// app (fast-forward past the flow). When null, no skip affordance is shown.
  /// Wired by the production caller; surfaced next to [onRestart] for admins.
  final Future<void> Function()? onSkip;

  /// Admin preview mode (ephemeral [InMemoryOnboardingProgressStore]). When true,
  /// the name step does NOT PATCH the real profile (`full_name`/handle) — a
  /// preview must never mutate the admin's own account. The production flow
  /// leaves this `false` so the typed name persists to the profile.
  final bool isPreview;

  @override
  ConsumerState<OnboardingIdentityNameScreen> createState() =>
      _OnboardingIdentityNameScreenState();
}

class _OnboardingIdentityNameScreenState
    extends ConsumerState<OnboardingIdentityNameScreen> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  bool _started = false;
  bool _hasText = false;

  /// The last subturn we emitted a `step_view` impression for. Guards against
  /// re-firing on every rebuild while a step waits for input — the impression
  /// fires once, when a NEW subturn finishes delivering and becomes interactive.
  OnboardingSubturnId? _impressionSubturn;

  /// The supported city highlighted on the not-local step, confirmed by its
  /// inline Continue button.
  OnboardingSupportedCity? _selectedNotLocalCity;

  /// Shared-element tag so the collapsed vibe search pill flies up into the
  /// opened search overlay (instead of the overlay just fading in over it).
  static const _vibeSearchHeroTag = 'onboarding-vibe-search';

  /// The vibe.share "picks": places/events the user liked in the search overlay,
  /// shown as a card row above the search input. Ordered by first-liked; taste
  /// keyed by the item's signal id so the row's 👍/👎 mirror the carousels.
  final List<ItemSuggestion> _searchPicks = [];
  final Map<String, SignalTaste> _searchPickTaste = {};

  /// Guards the one-shot resume rebuild of [_searchPicks] from the persisted
  /// `vibe.share` answer (fires once the loaded snapshot carries the picks).
  bool _searchPicksRestored = false;

  /// The signal endpoint target for a suggestion — null when it has no
  /// venue/event UUID (a Google-only place can't be signalled).
  (SignalEntityType, String)? _signalTargetFor(ItemSuggestion item) {
    final isEvent = item.type == 'event';
    final id = isEvent ? item.eventId : item.venueId;
    if (id == null || id.isEmpty) return null;
    return (isEvent ? SignalEntityType.event : SignalEntityType.venue, id);
  }

  /// Records a like reported by the search overlay into the picks row. Liking
  /// adds the card (taste=liked); un-liking removes it. The overlay already
  /// posted the signal, so this only tracks local state.
  void _onSearchLikeToggled(ItemSuggestion item, bool nowLiked) {
    final target = _signalTargetFor(item);
    if (target == null) return;
    final id = target.$2;
    setState(() {
      if (nowLiked) {
        if (!_searchPicks.any((i) => _signalTargetFor(i)?.$2 == id)) {
          _searchPicks.add(item);
        }
        _searchPickTaste[id] = SignalTaste.liked;
      } else {
        _searchPicks.removeWhere((i) => _signalTargetFor(i)?.$2 == id);
        _searchPickTaste.remove(id);
      }
    });
  }

  /// Toggles a 👍/👎 on a picks-row card — optimistic, POSTs, reconciles to the
  /// server sentiment (reverts on error). The card stays either way (a dislike
  /// marks it, it doesn't remove it), mirroring the vibe carousels.
  Future<void> _reactSearchPick(
    ItemSuggestion item,
    SignalAction action,
  ) async {
    final target = _signalTargetFor(item);
    if (target == null) return;
    final (type, id) = target;
    final previous = _searchPickTaste[id] ?? SignalTaste.none;
    final want = action == SignalAction.like
        ? SignalTaste.liked
        : SignalTaste.disliked;
    final predicted = previous == want ? SignalTaste.none : want;
    setState(() => _searchPickTaste[id] = predicted);
    try {
      final signal = await ref
          .read(signalApiProvider)
          .postSignal(
            type,
            id,
            action,
            provenance: SignalProvenance.onboardingSearch,
          );
      if (!mounted) return;
      setState(() => _searchPickTaste[id] = signal.taste);
    } catch (_) {
      if (!mounted) return;
      setState(() => _searchPickTaste[id] = previous);
    }
  }

  /// The ordered candidate ids persisted for a vibe shelf on resume, read from
  /// the saved `vibe.taste` answer ([key] = `venue_candidates` / `event_candidates`).
  /// Empty on a first visit (the shelf then fetches a fresh discovery batch).
  List<String> _persistedVibeCandidateIds(
    OnboardingChatState state,
    String key,
  ) {
    final value = state.snapshot?.answers[OnboardingSubturnId.vibeTaste]?.value;
    if (value is Map) {
      final list = value[key];
      if (list is List) {
        return [
          for (final e in list)
            if (e is String && e.isNotEmpty) e,
        ];
      }
    }
    return const [];
  }

  /// Whether the persisted `zines.generated` answer says the user kept the zine.
  Set<String> _persistedZineSavedIds(OnboardingChatState state) {
    final value =
        state.snapshot?.answers[OnboardingSubturnId.zinesGenerated]?.value;
    if (value is Map) {
      final ids = value['saved_list_ids'];
      if (ids is List) return ids.whereType<String>().toSet();
    }
    return const {};
  }

  /// Rebuilds a picks-row [ItemSuggestion] from a hydrated candidate (the inverse
  /// of [_pickCandidate]) — enough for the row's card, 👍/👎 target, and detail tap.
  ItemSuggestion _suggestionFromCandidate(VibeCandidate c) {
    final isEvent = c.type == VibeCandidateType.event;
    return ItemSuggestion(
      id: c.entityId,
      name: c.name,
      imageUrl: c.imageUrl,
      type: isEvent ? 'event' : 'place',
      eventId: isEvent ? c.entityId : null,
      venueId: isEvent ? null : c.entityId,
      category: c.subtitle.isEmpty ? null : c.subtitle,
    );
  }

  /// One-shot resume: hydrate the persisted `vibe.share` picks and rebuild the
  /// picks row (+ its taste map) so the cards and 👍/👎 reappear. Best-effort —
  /// a hydrate failure just leaves the row empty.
  Future<void> _restoreSearchPicks(List<dynamic> rawPicks) async {
    final refs = <OnboardingEntityRef>[];
    for (final p in rawPicks) {
      if (p is! Map) continue;
      final type = p['type'];
      final id = p['id'];
      if (type is String && id is String && id.isNotEmpty) {
        refs.add(OnboardingEntityRef(type: type, id: id));
      }
    }
    if (refs.isEmpty) return;
    try {
      final hydrated = await ref
          .read(onboardingHydrateApiProvider)
          .hydrate(refs);
      if (!mounted || hydrated.isEmpty) return;
      setState(() {
        for (final h in hydrated) {
          final item = _suggestionFromCandidate(h.candidate);
          final target = _signalTargetFor(item);
          if (target == null) continue;
          if (!_searchPicks.any((i) => _signalTargetFor(i)?.$2 == target.$2)) {
            _searchPicks.add(item);
          }
          _searchPickTaste[target.$2] = h.sentiment;
        }
      });
    } catch (_) {
      // Best-effort restore; leave the picks row as-is on failure.
    }
  }

  /// Maps a search suggestion to the vibe-card model so the picks row can reuse
  /// [OnboardingVibeCard] (image + 👍/👎 overlay + title/subtitle).
  VibeCandidate _pickCandidate(ItemSuggestion item) {
    final isEvent = item.type == 'event';
    DateTime? startsAt;
    if (isEvent) {
      final occ = item.occurrences.futureOnly();
      startsAt = occ.isNotEmpty
          ? occ.first.startAt
          : parseBackendDateTime(item.date);
    }
    return VibeCandidate(
      type: isEvent ? VibeCandidateType.event : VibeCandidateType.place,
      entityId: (isEvent ? item.eventId : item.venueId) ?? item.id,
      name: item.name,
      imageUrl: item.imageUrl,
      subtitle: item.category ?? '',
      startsAt: startsAt,
    );
  }

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onComposerChanged);
    _focusNode
      ..addListener(_onFocusChanged)
      ..onKeyEvent = _handleKeyEvent;
  }

  /// Hardware/web Enter (without Shift) sends the name, matching the main chat
  /// composer (`message_input.dart`). Shift+Enter still inserts a newline.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      final state = ref.read(widget.controllerProvider);
      final current = state.snapshot?.currentSubturnId;
      if (current == OnboardingSubturnId.identityName &&
          _hasText &&
          state.canSubmit) {
        _submitText(state, OnboardingSubturnId.identityName);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeStart();
  }

  /// Loads the flow, but ONLY once a real (non-guest) session exists.
  ///
  /// PROD-4582: `/onboarding/state` rejects guests outright — `401
  /// AUTH_TOKEN_INVALID, refreshable: false, "Guest sessions cannot access this
  /// endpoint"` (Sentry FLUTTER-1AM: 63 users). Every app carries a token since
  /// the guest bootstrap-mint (PROD-1979), so "has a token" is not "is signed
  /// in", and this screen used to fire `start()` from the first
  /// `didChangeDependencies` with no auth check at all. On a cold start into
  /// `/onboarding-chat` the gate returns null while the profile loads (the
  /// router reads null as "don't redirect"), so the screen mounts and loads
  /// against the guest JWT before sign-in has resolved.
  ///
  /// The controller's one silent retry (PROD-4394 F3) was built for a *token
  /// refresh* race and cannot help here: `refreshable: false` means there is
  /// nothing to refresh — only the real session arriving fixes it. So wait for
  /// it instead, and start the moment it lands (see the listener in [build]).
  void _maybeStart() {
    if (_started) return;
    if (widget.waitsForSession && !ref.read(isAuthenticatedProvider)) return;
    _started = true;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(widget.controllerProvider.notifier)
            .start(reduceMotion: reduceMotion),
      );
    });
  }

  void _onComposerChanged() {
    final hasText = _textController.text.trim().isNotEmpty;
    if (hasText != _hasText && mounted) setState(() => _hasText = hasText);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_onComposerChanged)
      ..dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  /// Fires the shared `onboarding_step` funnel event (Backend + PostHog) for
  /// every onboarding action. `step` = the subturn wire id; `action` describes
  /// the interaction (submitted / confirmed / thumb_up / see_more / …).
  void _trackStep(String step, String action) {
    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(step: step, action: action);
  }

  /// Opens a searched place/event's read-only (sandbox) detail — same push as a
  /// vibe carousel card (root navigator, over the onboarding gate).
  ///
  /// The detail's 👍/👎 write to the shared [signalControllerProvider], not this
  /// screen's local [_searchPickTaste]. So on return we re-sync the pick's taste
  /// from that shared store — otherwise a like made inside the detail wouldn't
  /// show on the pick card outside it (PROD onboarding QA: "that last pick when
  /// you search by name"). We hold the controller alive with [WidgetRef.listenManual]
  /// across the push (it's autoDispose and the detail is its only other listener),
  /// then read the reconciled taste back and mirror it into the picks state —
  /// promoting the item to a pick if it was newly liked in the detail.
  Future<void> _openSearchItemDetail(
    ItemSuggestion item, {
    bool fromSearch = false,
  }) async {
    final isEvent = item.type == 'event';
    final id = isEvent ? item.eventId : item.venueId;
    if (id == null || id.isEmpty) return;
    _trackStep('vibe.share', 'card_tap');

    final target = _signalTargetFor(item);
    final key = target == null ? null : (type: target.$1, id: target.$2);
    final tasteBefore = key == null
        ? SignalTaste.none
        : ref.read(signalControllerProvider(key)).signal.taste;
    final sub = key == null
        ? null
        : ref.listenManual(signalControllerProvider(key), (_, __) {});
    try {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => OnboardingDetailPage(
            type: isEvent ? VibeCandidateType.event : VibeCandidateType.place,
            entityId: id,
          ),
        ),
      );
      if (!mounted || key == null || target == null) return;
      final taste = ref.read(signalControllerProvider(key)).signal.taste;
      setState(() {
        _searchPickTaste[target.$2] = taste;
        // A like made inside the detail should surface the item as a pick.
        final alreadyPicked = _searchPicks.any(
          (i) => _signalTargetFor(i)?.$2 == target.$2,
        );
        if (taste == SignalTaste.liked && !alreadyPicked) {
          _searchPicks.add(item);
        }
      });
      // When opened from the search overlay, a *set* 👍/👎 auto-closes the detail
      // (the onboarding triage gesture). Close the search too so the user drops
      // back to the transcript with the pick recorded, mirroring `closeOnLike` —
      // rather than being stranded in the still-open overlay. A set sentiment is
      // liked/disliked and differs from the taste before opening; a manual
      // back-out (taste unchanged) or a toggle-off (→ none) leaves the search
      // open. Guarded on [fromSearch] because the picks-row entry point has no
      // overlay in the stack — popping there would close the onboarding screen.
      if (fromSearch &&
          (taste == SignalTaste.liked || taste == SignalTaste.disliked) &&
          taste != tasteBefore) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
    } finally {
      sub?.close();
    }
  }

  void _submitText(OnboardingChatState state, OnboardingSubturnId subturnId) {
    final text = _textController.text.trim();
    if (text.isEmpty || !state.canSubmit) return;
    _trackStep(subturnId.wireId, 'submitted');

    _textController.clear();
    _focusNode.unfocus();
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: subturnId,
              displayText: text,
              value: text,
            ),
          ),
    );
    // Single-field / hardware-Enter path for the name step also persists the
    // typed name to the real profile (see [_persistNameToProfile]).
    if (subturnId == OnboardingSubturnId.identityName) {
      _persistNameToProfile(text);
    }
  }

  /// Name step (two-field form): combine first + surname into the single
  /// `display_name` string the backend stores (`identity.name` → `display_name`).
  void _submitName(
    OnboardingChatState state,
    String firstName,
    String surname,
  ) {
    if (!state.canSubmit) return;
    final full = '$firstName $surname'.trim();
    if (full.isEmpty) return;
    _trackStep(OnboardingSubturnId.identityName.wireId, 'submitted');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.identityName,
              displayText: full,
              value: full,
            ),
          ),
    );
    // Persist the typed name to the REAL profile so the profile card (step 4/5)
    // and every other surface show it instead of falling back to the user UUID.
    // The onboarding-state answer above is a separate free-form blob that never
    // reaches `UserProfile.full_name`; PATCH /users/me/profile does — and the
    // backend auto-derives a name-based handle on the first `full_name`, fixing
    // the `@user…` handle too. Fire-and-forget (the card renders steps later);
    // never blocks onboarding progression, and skipped in admin preview so it
    // can't mutate the admin's own account.
    _persistNameToProfile(full);
  }

  /// Best-effort PATCH of the onboarding name onto the user's real profile.
  /// Swallows moderation rejections / network errors — the onboarding-state
  /// answer already persisted, so a failure here must not stall the flow.
  void _persistNameToProfile(String full) {
    if (widget.isPreview) return;
    unawaited(() async {
      try {
        await ref.read(accountProvider.notifier).updateName(full);
      } catch (_) {
        // Non-blocking: keep advancing onboarding regardless.
      }
    }());
  }

  /// Builds the `identity.city` answer from a picked location. The SERVER
  /// decides supported/unsupported against its per-city `discovery_enabled`
  /// gate — the client `branch` is only a hint the server overrides. This is
  /// what makes an uncovered pick reliably skip to `not_local` (the old
  /// client-side `?? true` GPS default failed open). A `gps:` sentinel isn't a
  /// real city_id, so send only the coords for it.
  OnboardingAnswer _cityAnswer(OnboardingCitySelection city) {
    final pickedCityId =
        (city.cityId != null && !city.cityId!.startsWith('gps:'))
        ? city.cityId
        : null;
    return OnboardingAnswer(
      subturnId: OnboardingSubturnId.identityCity,
      displayText: city.displayName,
      value: city.displayName,
      branch: city.supported
          ? OnboardingBranch.supported
          : OnboardingBranch.unsupported,
      selectedCity: city.displayName,
      selectedCityId: pickedCityId,
      selectedLatitude: city.latitude,
      selectedLongitude: city.longitude,
    );
  }

  void _submitCity(OnboardingChatState state, OnboardingCitySelection city) {
    if (!state.canSubmit) return;
    _trackStep('identity.city', city.supported ? 'submitted' : 'unsupported');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(_cityAnswer(city)),
    );
  }

  // ── In-place correction (tap an answered name/city bubble) ────────────────

  /// The current text of an answered subturn's user bubble, used to prefill the
  /// edit composer. Reads the delivered turn (whose text always matches what the
  /// user sees) rather than the snapshot answer (blank without `displayTextFor`).
  String? _answerBubbleText(
    OnboardingChatState state,
    OnboardingSubturnId subturnId,
  ) {
    final id = 'answer:${subturnId.wireId}';
    for (final turn in state.turns) {
      if (turn.id == id) return turn.text;
    }
    return null;
  }

  /// Splits a full name into (first, surname) on the first space — the inverse
  /// of the `'$first $surname'` join used when the name is submitted.
  (String, String) _splitName(String? full) {
    final trimmed = (full ?? '').trim();
    if (trimmed.isEmpty) return ('', '');
    final i = trimmed.indexOf(' ');
    if (i < 0) return (trimmed, '');
    return (trimmed.substring(0, i), trimmed.substring(i + 1).trim());
  }

  void _submitNameCorrection(
    OnboardingChatState state,
    String firstName,
    String surname,
  ) {
    if (!state.canSubmitEdit) return;
    final full = '$firstName $surname'.trim();
    if (full.isEmpty) return;
    _trackStep(OnboardingSubturnId.identityName.wireId, 'edited');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitCorrection(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.identityName,
              displayText: full,
              value: full,
            ),
          ),
    );
    // Keep the real profile in sync, exactly like the first-time submit.
    _persistNameToProfile(full);
  }

  void _submitCityCorrection(
    OnboardingChatState state,
    OnboardingCitySelection city,
  ) {
    if (!state.canSubmitEdit) return;
    _trackStep('identity.city', 'edited');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitCorrection(_cityAnswer(city)),
    );
  }

  /// Handles a tap on an answered name/city bubble: confirm intent, then open
  /// the in-place edit composer for that subturn.
  Future<void> _handleEditTap(OnboardingDeliveredTurn turn) async {
    final isName = turn.subturnId == OnboardingSubturnId.identityName;
    final confirmed = await _confirmEdit(context, isName: isName);
    if (!confirmed || !mounted) return;
    ref.read(widget.controllerProvider.notifier).beginEdit(turn.subturnId);
  }

  /// Small confirmation sheet before re-opening a composer. Returns true if the
  /// user chose "Change".
  Future<bool> _confirmEdit(
    BuildContext context, {
    required bool isName,
  }) async {
    final l10n = Lt.of(context);
    final title = isName
        ? l10n.onboardingChatEditNameTitle
        : l10n.onboardingChatEditLocationTitle;
    final body = isName
        ? l10n.onboardingChatEditNameBody
        : l10n.onboardingChatEditLocationBody;
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => DSSheetShell(
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: AppTheme.body(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sokoInk,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: AppTheme.body(
                  fontSize: 14,
                  color: AppColors.sokoShade3,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: BtSqIco(
                      icon: null,
                      label: l10n.onboardingChatEditCancel,
                      variant: BtSqIcoVariant.idle,
                      expand: true,
                      onTap: () => Navigator.of(sheetContext).pop(false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: BtSqIco(
                      icon: null,
                      label: l10n.onboardingChatEditConfirm,
                      variant: BtSqIcoVariant.pinkOutline,
                      expand: true,
                      onTap: () => Navigator.of(sheetContext).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return result ?? false;
  }

  void _submitInterests(
    OnboardingChatState state,
    List<OnboardingInterestOption> selected,
  ) {
    if (selected.isEmpty || !state.canSubmit) return;
    _trackStep('identity.interests', 'confirmed');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.identityInterests,
              displayText: selected.map((o) => o.label).join(', '),
              value: selected.map((o) => o.id).toList(growable: false),
            ),
          ),
    );
  }

  /// "Não" — end the identity.extra step without adding anything.
  void _submitExtraNo(OnboardingChatState state) {
    if (!state.canSubmit) return;
    _trackStep('identity.extra', 'declined');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.identityExtra,
              displayText: widget.copy.extraNoLabel ?? '',
              value: '',
            ),
          ),
    );
  }

  /// "Sim" → typed text → Continuar. Fires the best-effort tell-us side effect,
  /// then persists the answer (which is what actually advances/completes).
  void _submitExtraText(OnboardingChatState state, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !state.canSubmit) return;
    _trackStep('identity.extra', 'submitted');
    final onExtraText = widget.onExtraText;
    if (onExtraText != null) {
      unawaited(Future(() => onExtraText(trimmed)).catchError((_) {}));
    }
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.identityExtra,
              displayText: trimmed,
              value: trimmed,
              // Acknowledge the reply ("Great, thanks!") before the flow moves
              // on — declining ("Não") carries no ack.
              ackMessage: widget.copy.extraAck,
            ),
          ),
    );
  }

  /// Bottom-bar shell for a step's composer/CTA: the shared SafeArea insets plus
  /// an entrance animation so the input/buttons fade+slide in when they appear.
  /// Each step's composer mounts only once its Soko message finishes delivering
  /// (see `composerReady`), so the entrance plays right on cue; keying by
  /// [current] replays it for each step (the branch reuses the same element).
  /// Reduce-motion shows them already settled.
  /// Wraps an edit composer with a "Cancel" link so the user can back out of a
  /// correction without changing anything. No chrome when not editing.
  Widget _withEditChrome(
    BuildContext context, {
    required bool editing,
    required Widget child,
  }) {
    if (!editing) return child;
    final l10n = Lt.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                ref.read(widget.controllerProvider.notifier).cancelEdit(),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 8, top: 4),
              child: Text(
                l10n.onboardingChatEditCancel,
                style: AppTheme.body(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sokoPink,
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }

  Widget _composerShell(
    BuildContext context,
    OnboardingSubturnId? current, {
    required Widget child,
  }) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SokoTurnEntrance(
        key: ValueKey(current),
        animate: !reduceMotion,
        child: child,
      ),
    );
  }

  /// Releases the vibe delivery-gate so the search-reveal line, search field and
  /// Continue CTA land as soon as BOTH shelves have settled (loaded, errored, or
  /// empty) — regardless of whether the user has liked anything. Liking cards is
  /// encouraged (the glow nudge + "like at least one" copy) but OPTIONAL: hard-
  /// requiring a 👍 here stranded ~35% of users who reached 2/5 — they tapped
  /// cards (which open detail, not a like) and never saw a Continue (see
  /// project_vibe_step_like_gate_trap). No-op unless the flow is actually paused
  /// at the vibe gate. Idempotent — `resumeAfterGate` self-guards.
  void _maybeResumeVibeGate() {
    final state = ref.read(widget.controllerProvider);
    if (!state.isAwaitingConsent ||
        state.snapshot?.currentSubturnId != OnboardingSubturnId.vibeTaste) {
      return;
    }
    final venues = widget.vibeVenuesProvider != null
        ? ref.read(widget.vibeVenuesProvider!)
        : null;
    final events = widget.vibeEventsProvider != null
        ? ref.read(widget.vibeEventsProvider!)
        : null;
    // A shelf is "settled" once it has finished loading (with cards, empty, or an
    // error); a missing provider counts as settled too. Waiting for settle keeps
    // the "cards on screen first" pacing — the rest of the step then delivers on
    // the normal chat cadence — without gating advancement on a like.
    bool settled(OnboardingVibeState? s) => s == null || s.hasLoaded;
    if (settled(venues) && settled(events)) {
      ref.read(widget.controllerProvider.notifier).resumeAfterGate();
    }
  }

  /// Vibe step "Continuar": persist the thumbed picks (liked/disliked ids the
  /// carousels already sent to the signal endpoints) and advance.
  void _submitVibe(OnboardingChatState state) {
    if (!state.canSubmit) return;
    _trackStep('vibe.taste', 'continue');
    final venues = widget.vibeVenuesProvider;
    final events = widget.vibeEventsProvider;
    final venuesState = venues != null ? ref.read(venues) : null;
    final eventsState = events != null ? ref.read(events) : null;
    // Combine the thumbs from both shelves into the recorded vibe picks.
    final liked = [...?venuesState?.likedIds, ...?eventsState?.likedIds];
    final disliked = [
      ...?venuesState?.dislikedIds,
      ...?eventsState?.dislikedIds,
    ];
    // The search "favourites" now live on this same screen (merged from the old
    // vibeShare step): record their entity refs so resume can re-hydrate the
    // picks row (+ its 👍/👎). The bookmarks themselves are already persisted
    // server-side by the search rows' one-tap save.
    final picks = <Map<String, String>>[];
    for (final item in _searchPicks) {
      final target = _signalTargetFor(item);
      if (target == null) continue;
      picks.add({
        'type': target.$1 == SignalEntityType.event ? 'event' : 'place',
        'id': target.$2,
      });
    }
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.vibeTaste,
              displayText: '',
              // Persist the shown candidate ids (in order) alongside the thumbs
              // so resume re-hydrates the exact same carousels — see
              // `_persistedVibeCandidateIds` / OnboardingVibeShelf.
              value: {
                'liked': liked,
                'disliked': disliked,
                'venue_candidates': venuesState?.candidateIds ?? const [],
                'event_candidates': eventsState?.candidateIds ?? const [],
                'picks': picks,
              },
            ),
          ),
    );
  }

  /// Vibe share "Continuar": the bookmarks are already persisted server-side by
  /// the search rows' one-tap save; this advances the flow AND records the picked
  /// entity refs so resume can re-hydrate the picks row (+ its 👍/👎).
  void _submitVibeShare(OnboardingChatState state) {
    if (!state.canSubmit) return;
    _trackStep('vibe.share', 'continue');
    final picks = <Map<String, String>>[];
    for (final item in _searchPicks) {
      final target = _signalTargetFor(item);
      if (target == null) continue;
      picks.add({
        'type': target.$1 == SignalEntityType.event ? 'event' : 'place',
        'id': target.$2,
      });
    }
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.vibeShare,
              displayText: '',
              value: <String, dynamic>{'picks': picks},
            ),
          ),
    );
  }

  /// Zines "Continuar": each themed zine is saved (optionally) from its own
  /// preview sheet; this records which ones were kept and advances (→ complete).
  void _submitZines(OnboardingChatState state) {
    if (!state.canSubmit) return;
    final savedIds = widget.zinesProvider != null
        ? ref.read(widget.zinesProvider!).savedIds.toList()
        : const <String>[];
    _trackStep('zines.generated', 'continue');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.zinesGenerated,
              displayText: '',
              value: <String, dynamic>{
                'saved': savedIds.isNotEmpty,
                'saved_list_ids': savedIds,
              },
            ),
          ),
    );
  }

  /// Profile "Editar perfil": open the onboarding edit page (reuses the app's
  /// avatar/handle/name/bio flow), then advance the step.
  Future<void> _editProfile(OnboardingChatState state) async {
    if (!state.canSubmit) return;
    _trackStep('profile.card', 'edit');
    final saved = await openOnboardingEditProfile(context);
    if (!mounted) return;
    _submitProfileCard(
      ref.read(widget.controllerProvider),
      edited: saved == true,
    );
  }

  /// Profile card "Edito depois" / post-edit: record whether the user edited and
  /// advance to the follow suggestions.
  void _submitProfileCard(OnboardingChatState state, {required bool edited}) {
    if (!state.canSubmit) return;
    _trackStep('profile.card', edited ? 'edited' : 'edit_later');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.profileCard,
              displayText: '',
              value: <String, dynamic>{'edited': edited},
            ),
          ),
    );
  }

  /// Profile follows "Continuar": follows are persisted server-side per tap, so
  /// this just advances to the rituals close.
  void _submitProfileFollows(OnboardingChatState state) {
    if (!state.canSubmit) return;
    _trackStep('profile.follows', 'continue');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.profileFollows,
              displayText: '',
              value: const <String, dynamic>{},
            ),
          ),
    );
  }

  /// Rituals finish — the final answer. The store's interim-complete then PUTs
  /// `step=complete`; the completion listener routes to [destination] (home for
  /// "Continuar", the map for "Explora o mapa", chat for "Conversa comigo").
  void _submitRituals(
    OnboardingChatState state, {
    required String destination,
  }) {
    if (!state.canSubmit) return;
    ref.read(onboardingExitDestinationProvider.notifier).state = destination;
    // Distinguish which closing CTA finished onboarding: "Continuar" (home),
    // "Explora o mapa" (map), or "Conversa comigo" (chat) — the exit surface the
    // user chose is a signal we'd otherwise lose (all three used to be `finish`).
    final destinationKey = switch (destination) {
      AppRoutes.mapa => 'map',
      AppRoutes.chat => 'chat',
      _ => 'home',
    };
    _trackStep('rituals.ready', 'finish_$destinationKey');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.ritualsReady,
              displayText: '',
              value: const <String, dynamic>{},
            ),
          ),
    );
  }

  /// Not-local "Fala comigo": hand off to chat and finish onboarding via the
  /// minimal completion path (the gate releases; no further steps).
  void _submitChatHandoff(OnboardingChatState state) {
    if (!state.canSubmit) return;
    _trackStep('not_local.choice', 'chat_handoff');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.notLocalChoice,
              displayText: widget.copy.notLocalFalaComigo ?? '',
              value: 'chat_handoff',
              notLocalChoice: OnboardingNotLocalChoice.chatHandoff,
              completionPath: OnboardingCompletionPath.minimal,
            ),
          ),
    );
  }

  /// Not-local city switch: flip to a supported city so the flow rejoins the
  /// vibe step (the branch becomes supported at `identity.extra → branch`).
  void _submitCitySwitch(OnboardingChatState state, OnboardingSupportedCity c) {
    if (!state.canSubmit) return;
    _trackStep('not_local.choice', 'city_switch');
    unawaited(
      ref
          .read(widget.controllerProvider.notifier)
          .submitAnswer(
            OnboardingAnswer(
              subturnId: OnboardingSubturnId.notLocalChoice,
              displayText: c.label,
              value: 'city_switch',
              notLocalChoice: OnboardingNotLocalChoice.citySwitch,
              branch: OnboardingBranch.supported,
              selectedCity: c.name,
              // Send the switched city's centre so the server re-resolves it and
              // anchors the zines on the launch city — not the user's (unsupported)
              // device location. If a listed market isn't actually served
              // (`discovery_enabled=false`) the server keeps it unsupported.
              selectedLatitude: c.latitude,
              selectedLongitude: c.longitude,
            ),
          ),
    );
  }

  void _retry(OnboardingChatState state) {
    final controller = ref.read(widget.controllerProvider.notifier);
    if (state.pendingAnswer != null) {
      unawaited(controller.retryPendingAnswer());
    } else {
      unawaited(
        controller.start(
          reduceMotion: MediaQuery.of(context).disableAnimations,
        ),
      );
    }
  }

  /// Renders the not-local step's inline interactive content turns (delivered in
  /// succession like the messages): the "Fala comigo" handoff, the supported-city
  /// chips, and the full-width Continue. Interactive only while the step is the
  /// current one and awaiting input.
  Widget _buildContent(
    BuildContext context,
    OnboardingDeliveredTurn turn,
    OnboardingChatState state,
    OnboardingSubturnId? current,
  ) {
    final active =
        current == OnboardingSubturnId.notLocalChoice && state.canSubmit;

    // Action buttons (Continue / gates) belong to the CURRENT step only — once
    // the step is answered they'd otherwise linger as a dead, dimmed button in
    // the transcript history. Drop them; the carousels/search stay as history.
    const actionContentIds = <String>{
      notLocalContinueContentId,
      vibeContinueContentId,
      vibeShareContinueContentId,
      zinesGateContentId,
      profileEditGateContentId,
      // NB: profileFindContactsContentId is intentionally NOT dropped — once the
      // user syncs contacts, the matched-contacts carousel stays as history. The
      // section hides its own CTA/empty states when it's no longer interactive.
      profileFollowsContinueContentId,
      ritualsExitCtasContentId,
      ritualsFinishContentId,
    };
    if (turn.subturnId != current &&
        actionContentIds.contains(turn.contentId)) {
      return const SizedBox.shrink();
    }

    switch (turn.contentId) {
      case notLocalFalaComigoContentId:
        return OnboardingNotLocalFalaComigo(
          label: widget.copy.notLocalFalaComigo ?? '',
          enabled: active,
          onTap: () => _submitChatHandoff(state),
        );
      case notLocalCitiesContentId:
        return OnboardingNotLocalCities(
          selected: _selectedNotLocalCity,
          enabled: active,
          onSelected: (c) => setState(() => _selectedNotLocalCity = c),
        );
      case notLocalContinueContentId:
        final city = _selectedNotLocalCity;
        return OnboardingContinueButton(
          key: const Key('onboarding-not-local-continue'),
          label: widget.copy.vibeContinueLabel ?? '',
          enabled: active && city != null,
          onTap: () {
            if (city != null) _submitCitySwitch(state, city);
          },
        );
      case vibeSitiosContentId:
        final p = widget.vibeVenuesProvider;
        if (p == null) return const SizedBox.shrink();
        return OnboardingVibeShelf(
          provider: p,
          label: widget.copy.vibePlacesLabel ?? '',
          pillColor: AppColors.sokoVenue,
          errorLabel:
              widget.copy.vibeErrorLabel ?? widget.copy.persistenceError,
          retryLabel: widget.copy.retryLabel,
          searchingLabel: widget.copy.vibeSearchingPlaces ?? '',
          persistedCandidateIds: _persistedVibeCandidateIds(
            state,
            'venue_candidates',
          ),
        );
      case vibeEventosContentId:
        final p = widget.vibeEventsProvider;
        if (p == null) return const SizedBox.shrink();
        return OnboardingVibeShelf(
          provider: p,
          label: widget.copy.vibeEventsLabel ?? '',
          pillColor: AppColors.sokoEvent,
          errorLabel:
              widget.copy.vibeErrorLabel ?? widget.copy.persistenceError,
          retryLabel: widget.copy.retryLabel,
          searchingLabel: widget.copy.vibeSearchingEvents ?? '',
          persistedCandidateIds: _persistedVibeCandidateIds(
            state,
            'event_candidates',
          ),
        );
      case vibeContinueContentId:
        // The vibe.taste Continue renders inline as the transcript's last turn —
        // the same constant bottom distance and scroll-away behaviour as every
        // other step's action row (vibe.share, zines, profile, rituals). It is
        // ALWAYS shown: liking a card is encouraged (glow nudge + "like at least
        // one" copy) but optional. Requiring a 👍 to reveal it stranded ~35% of
        // users at 2/5 — see project_vibe_step_like_gate_trap. The empty-shelf
        // safeguard is subsumed: nothing gates advancement now.
        return OnboardingContinueButton(
          key: const Key('onboarding-vibe-confirm'),
          label: widget.copy.vibeContinueLabel ?? '',
          enabled: current == OnboardingSubturnId.vibeTaste && state.canSubmit,
          onTap: () => _submitVibe(state),
        );
      case vibeShareContentId:
        // The search input belongs to the active step only — once the user
        // continues past vibe.share it's dropped from history (the picks row
        // stays as a record of what they liked).
        final shareIsCurrent = turn.subturnId == current;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_searchPicks.isNotEmpty)
              _SearchPicksRow(
                items: _searchPicks,
                candidateOf: _pickCandidate,
                tasteOf: (item) =>
                    _searchPickTaste[_signalTargetFor(item)?.$2] ??
                    SignalTaste.none,
                onLike: (item) => _reactSearchPick(item, SignalAction.like),
                onDislike: (item) =>
                    _reactSearchPick(item, SignalAction.dislike),
                onTap: _openSearchItemDetail,
              ),
            if (_searchPicks.isNotEmpty && shareIsCurrent)
              const SizedBox(height: 12),
            if (shareIsCurrent)
              PlaceEventSearchTapField(
                key: const Key('onboarding-vibe-share-search'),
                hintText: widget.copy.vibeSharePlaceholder ?? '',
                heroTag: _vibeSearchHeroTag,
                onTap: () => openUnifiedSearchOverlay(
                  context,
                  hintText: widget.copy.vibeSharePlaceholder ?? '',
                  heroTag: _vibeSearchHeroTag,
                  emptyLabel: widget.copy.vibeShareEmpty,
                  // Onboarding add-ons on the shared overlay: like buttons, and
                  // a like completes the step (closeOnLike). Events/places open
                  // the onboarding detail (its triage gestures) via [onOpen];
                  // zines/people route normally.
                  showLike: true,
                  provenance: SignalProvenance.onboardingSearch,
                  closeOnLike: true,
                  onSearch: (_) => _trackStep('vibe.share', 'search'),
                  onLikeToggled: (row, liked) {
                    final item = row.payload;
                    if (item is! ItemSuggestion) return;
                    _trackStep('vibe.share', liked ? 'like' : 'unlike');
                    _onSearchLikeToggled(item, liked);
                  },
                  onOpen: (row) {
                    final item = row.payload;
                    if (item is ItemSuggestion &&
                        (row.category == SokoSearchCategory.events ||
                            row.category == SokoSearchCategory.venues)) {
                      _openSearchItemDetail(item, fromSearch: true);
                      return true;
                    }
                    return false; // zines / people route normally
                  },
                ),
              ),
          ],
        );
      case vibeShareContinueContentId:
        return OnboardingContinueButton(
          key: const Key('onboarding-vibe-share-confirm'),
          label: widget.copy.vibeContinueLabel ?? '',
          enabled: current == OnboardingSubturnId.vibeShare && state.canSubmit,
          onTap: () => _submitVibeShare(state),
        );
      case zinesCarouselContentId:
        final p = widget.zinesProvider;
        if (p == null) return const SizedBox.shrink();
        return OnboardingZinesShelf(
          provider: p,
          errorLabel:
              widget.copy.zinesErrorLabel ?? widget.copy.persistenceError,
          retryLabel: widget.copy.retryLabel,
          saveLabel: widget.copy.zinesSaveLabel ?? '',
          savedLabel: widget.copy.zinesSavedLabel ?? '',
          initiallySavedIds: _persistedZineSavedIds(state),
        );
      case zinesSuggestedCarouselContentId:
        final p = widget.suggestedZinesProvider;
        if (p == null) return const SizedBox.shrink();
        // The "most-followed" second row. Same shelf/card, sourced from popular
        // public zines; bookmark = follow. No saved-id seeding — followed zines
        // are excluded from the popular fetch on resume.
        return OnboardingZinesShelf(
          provider: p,
          errorLabel:
              widget.copy.zinesErrorLabel ?? widget.copy.persistenceError,
          retryLabel: widget.copy.retryLabel,
          saveLabel: widget.copy.zinesSaveLabel ?? '',
          savedLabel: widget.copy.zinesSavedLabel ?? '',
          analyticsStep: 'zines.suggested',
        );
      case zinesGateContentId:
        if (widget.zinesProvider == null) return const SizedBox.shrink();
        return _ZinesGate(
          continueLabel: widget.copy.vibeContinueLabel ?? '',
          enabled:
              current == OnboardingSubturnId.zinesGenerated && state.canSubmit,
          onContinue: () => _submitZines(state),
        );
      case profileCardContentId:
        return const OnboardingProfileCard();
      case profileEditGateContentId:
        return _ProfileEditGate(
          editLaterLabel: widget.copy.profileEditLaterLabel ?? '',
          editCtaLabel: widget.copy.profileEditCtaLabel ?? '',
          enabled:
              current == OnboardingSubturnId.profileCard && state.canSubmit,
          onEdit: () => _editProfile(state),
          onEditLater: () => _submitProfileCard(state, edited: false),
        );
      case profileFollowsCarouselContentId:
        return const OnboardingFollowCarousel();
      case profileFindContactsContentId:
        return _FindContactsSection(
          interactive: turn.subturnId == current,
          onStart: () => _trackStep('profile.follows', 'find_contacts'),
        );
      case profileFollowsContinueContentId:
        return OnboardingContinueButton(
          key: const Key('onboarding-profile-follows-confirm'),
          label: widget.copy.profileContinueLabel ?? '',
          enabled:
              current == OnboardingSubturnId.profileFollows && state.canSubmit,
          onTap: () => _submitProfileFollows(state),
        );
      case ritualsCoversContentId:
        return OnboardingRitualsCarousel(
          dailyTitle: widget.copy.ritualsDailyTitle ?? '',
          dailySubtitle: widget.copy.ritualsDailySubtitle ?? '',
          weeklyTitle: widget.copy.ritualsWeeklyTitle ?? '',
          weeklySubtitle: widget.copy.ritualsWeeklySubtitle ?? '',
        );
      case ritualsDeliveryConsentContentId:
        // The consent is a `gatesDelivery` turn: it renders in the pinned bottom
        // composer (see `showConsentComposer` below), never inline. It is not
        // appended to the transcript during delivery; this case only guards the
        // hydration edge (a completed rituals subturn replays every spec).
        return const SizedBox.shrink();
      case ritualsExitCtasContentId:
        return _RitualsExitCtas(
          exploreMapLabel: widget.copy.ritualsExploreMapLabel ?? '',
          chatLabel: widget.copy.ritualsChatLabel ?? '',
          enabled:
              current == OnboardingSubturnId.ritualsReady && state.canSubmit,
          onExploreMap: () =>
              _submitRituals(state, destination: AppRoutes.mapa),
          onChat: () => _submitRituals(state, destination: AppRoutes.chat),
        );
      case ritualsFinishContentId:
        return OnboardingContinueButton(
          key: const Key('onboarding-rituals-finish'),
          label: widget.copy.ritualsCtaLabel ?? '',
          enabled:
              current == OnboardingSubturnId.ritualsReady && state.canSubmit,
          onTap: () => _submitRituals(state, destination: AppRoutes.home),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// The step the header should render. Normally the current subturn's step, but
  /// once the snapshot is `complete` we fall back to the last real completed
  /// step so the header doesn't flash back to identity/"1/5" during the
  /// completion navigation (see the call site for the full rationale).
  OnboardingStepId _resolveHeaderStep(OnboardingSnapshot? snapshot) {
    final current = snapshot?.currentSubturnId;
    if (current != null && current != OnboardingSubturnId.complete) {
      return current.step;
    }
    for (final subturn
        in (snapshot?.completedSubturns ?? const <OnboardingSubturnId>[])
            .reversed) {
      if (subturn != OnboardingSubturnId.complete) return subturn.step;
    }
    return OnboardingStepId.identity;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(widget.controllerProvider);
    final snapshot = state.snapshot;
    final current = snapshot?.currentSubturnId;

    // On completion the snapshot's currentSubturnId flips to `complete`, whose
    // step (`OnboardingStepId.complete`) has no header treatment and would fall
    // through to the identity title + "1/5" — a visible flash back to step 1
    // while the completion navigation (which awaits a profile refresh so the
    // gate releases) is in flight. Pin the header to the last real step so the
    // final frame reads as the step the user actually finished on (rituals 5/5
    // for the full path, not-local 2/5 for the minimal chat-handoff path).
    final headerStep = _resolveHeaderStep(snapshot);

    // Vibe step: the flow is paused at the like-gate (isAwaitingConsent). Resume
    // it — delivering the search-reveal message + input + Continue — the moment
    // the user 👍 a carousel card, or immediately if there's nothing to like.
    // Only wire the shelf listeners while the vibe step is live, so we don't
    // instantiate (and eagerly fetch) the vibe providers on earlier steps.
    final venuesP = widget.vibeVenuesProvider;
    final eventsP = widget.vibeEventsProvider;
    if (current == OnboardingSubturnId.vibeTaste) {
      if (venuesP != null) {
        ref.listen(venuesP, (_, __) => _maybeResumeVibeGate());
      }
      if (eventsP != null) {
        ref.listen(eventsP, (_, __) => _maybeResumeVibeGate());
      }
    }
    // PROD-4582: the session can arrive after this screen mounts (cold start
    // into `/onboarding-chat` renders while the profile is still loading, and
    // the Google hand-off on Android returns through a paused app). Start the
    // flow the moment a real, non-guest session exists — loading any earlier
    // hits `/onboarding/state` with the guest JWT and 401s unrecoverably.
    if (widget.waitsForSession) {
      ref.listen(isAuthenticatedProvider, (_, __) => _maybeStart());
    }

    // Also re-check the moment the gate itself is reached (e.g. shelves already
    // loaded empty before the pause), not only on a later like.
    ref.listen(widget.controllerProvider.select((s) => s.isAwaitingConsent), (
      _,
      awaiting,
    ) {
      if (awaiting) _maybeResumeVibeGate();
    });

    // Step impression: fire `step_view` once per subturn, the moment it finishes
    // delivering and becomes interactive (isAwaitingInput). This is the funnel's
    // per-step denominator — drop-off AT a step vs. before reaching it — which
    // the action/submit events alone can't measure. Resume lands awaiting on the
    // current subturn, so it correctly registers as an impression too.
    if (snapshot != null &&
        current != null &&
        (state.isAwaitingInput || state.isAwaitingConsent) &&
        !snapshot.isComplete &&
        current != _impressionSubturn) {
      _impressionSubturn = current;
      _trackStep(current.wireId, 'step_view');
    }

    // Resume: once the loaded snapshot carries saved search picks, re-hydrate
    // them (once) so the picks row + 👍/👎 reappear. Picks now ride on the
    // merged `vibeTaste` answer; fall back to the legacy `vibeShare` answer for
    // anyone who onboarded before the merge.
    if (!_searchPicksRestored) {
      final shareValue =
          snapshot?.answers[OnboardingSubturnId.vibeTaste]?.value is Map &&
              (snapshot?.answers[OnboardingSubturnId.vibeTaste]?.value
                      as Map)['picks']
                  is List
          ? snapshot?.answers[OnboardingSubturnId.vibeTaste]?.value
          : snapshot?.answers[OnboardingSubturnId.vibeShare]?.value;
      if (shareValue is Map && shareValue['picks'] is List) {
        _searchPicksRestored = true;
        final rawPicks = shareValue['picks'] as List;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _restoreSearchPicks(rawPicks);
        });
      }
    }
    // Only reveal the input/options once Soko's message for this subturn has
    // finished delivering (isAwaitingInput) — receive the message, THEN offer
    // the reply.
    final composerReady =
        state.isAwaitingInput &&
        state.pendingAnswer == null &&
        state.submissionError == null;

    // While correcting an already-answered name/city bubble, the composer for
    // the EDITED subturn re-opens (overriding the flow cursor). Otherwise the
    // composer follows `current` once its message has delivered.
    final editing = state.editingSubturnId;
    final composerTarget = editing ?? (composerReady ? current : null);
    final canSubmitTarget = editing != null
        ? state.canSubmitEdit
        : state.canSubmit;

    // Whether the identity step is still open — gates the tap-to-edit affordance
    // so name/city can only be corrected before the branch forks (past extra)
    // and downstream content is produced.
    final editWindowOpen =
        current?.step == OnboardingStepId.identity &&
        !(snapshot?.isComplete ?? false);

    // Name → two-field form (First name / Surname); city → location pills
    // (GPS / picker); interests → grid. The single-field chat bar is a fallback
    // for foundation callers that don't supply the form placeholders.
    final showNameComposer =
        composerTarget == OnboardingSubturnId.identityName &&
        widget.copy.firstNamePlaceholder != null &&
        widget.copy.surnamePlaceholder != null;

    final showTextComposer =
        composerTarget == OnboardingSubturnId.identityName && !showNameComposer;

    final showLocationComposer =
        composerTarget == OnboardingSubturnId.identityCity &&
        widget.copy.useMyLocationLabel != null &&
        widget.copy.chooseLocationLabel != null;

    final interestsOptions = widget.copy.interestsOptions;
    final interestsConfirm = widget.copy.interestsConfirmLabel;
    final showInterestsComposer =
        composerReady &&
        current == OnboardingSubturnId.identityInterests &&
        interestsOptions != null &&
        interestsConfirm != null;

    final extraYes = widget.copy.extraYesLabel;
    final extraNo = widget.copy.extraNoLabel;
    final extraPlaceholder = widget.copy.extraPlaceholder;
    final extraConfirm = widget.copy.extraConfirmLabel;
    final showExtraComposer =
        composerReady &&
        current == OnboardingSubturnId.identityExtra &&
        extraYes != null &&
        extraNo != null &&
        extraPlaceholder != null &&
        extraConfirm != null;

    // Rituals delivery-consent: the transcript is PAUSED at the consent gate
    // (isAwaitingConsent), so the Yes/No chips show in the pinned bottom
    // composer like the other chat-step inputs. Answering resumes the
    // transcript ("You're ready!" + finish CTAs) via `resumeAfterGate`.
    final showConsentComposer =
        state.isAwaitingConsent &&
        current == OnboardingSubturnId.ritualsReady &&
        extraYes != null &&
        extraNo != null;

    return Scaffold(
      backgroundColor: AppColors.sokoPaper,
      body: SafeArea(
        // Centre + cap the onboarding at the app-wide 480-px content column on
        // desktop (full-bleed below 600 px), matching auth/discovery/detail.
        child: PageContent(
          child: Column(
            children: [
              _IdentityHeader(
                copy: widget.copy,
                step: headerStep,
                onRestart: widget.onRestart,
                onSkip: widget.onSkip,
              ),
              Expanded(
                child: state.isLoading && state.turns.isEmpty
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.sokoPink,
                        ),
                      )
                    : OnboardingTranscript(
                        turns: state.turns,
                        isTyping: state.isTyping,
                        searchingLabel: state.searchingLabel,
                        contentBuilder: (ctx, turn) =>
                            _buildContent(ctx, turn, state, current),
                        // Tap-to-edit the name/city bubbles, but only while the
                        // identity step is still open and nothing is mid-flight.
                        onEditAnswer: (editWindowOpen && composerReady)
                            ? _handleEditTap
                            : null,
                      ),
              ),
              if (state.submissionError != null && !state.isEditing)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    children: [
                      Text(
                        widget.copy.persistenceError,
                        textAlign: TextAlign.center,
                        style: AppTheme.body(
                          fontSize: 14,
                          color: AppColors.sokoInk,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SokoCtaButton(
                        key: const Key('onboarding-retry'),
                        label: widget.copy.retryLabel,
                        onPressed: state.isSaving ? null : () => _retry(state),
                        loading: state.isSaving,
                        expand: false,
                      ),
                      // PROD-4394 D1: the card must never be terminal — a
                      // second exit re-opens the composer with the failed
                      // answer cleared, so a payload the server keeps
                      // rejecting can be adjusted instead of retried forever.
                      if (widget.copy.editAnswerLabel != null &&
                          state.pendingAnswer != null) ...[
                        const SizedBox(height: 6),
                        TextButton(
                          key: const Key('onboarding-edit-answer'),
                          onPressed: state.isSaving
                              ? null
                              : () => ref
                                    .read(widget.controllerProvider.notifier)
                                    .dismissSubmissionError(),
                          child: Text(
                            widget.copy.editAnswerLabel!,
                            style: AppTheme.body(
                              fontSize: 14,
                              color: AppColors.sokoInk,
                            ).copyWith(decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              else if (showNameComposer)
                _composerShell(
                  context,
                  composerTarget,
                  child: _withEditChrome(
                    context,
                    editing: editing == OnboardingSubturnId.identityName,
                    child: IgnorePointer(
                      ignoring: !canSubmitTarget,
                      child: AnimatedOpacity(
                        opacity: canSubmitTarget ? 1 : 0.65,
                        duration:
                            OnboardingChatController.bubbleEntranceDuration,
                        child: OnboardingNameComposer(
                          // Keyed so switching into/out of the prefilled edit
                          // form rebuilds the fields with the seeded values.
                          key: ValueKey(
                            'name-composer-${editing == OnboardingSubturnId.identityName}',
                          ),
                          firstNamePlaceholder:
                              widget.copy.firstNamePlaceholder!,
                          surnamePlaceholder: widget.copy.surnamePlaceholder!,
                          confirmLabel: widget.copy.interestsConfirmLabel ?? '',
                          maxLength: widget.copy.nameMaxLength,
                          enabled: canSubmitTarget,
                          initialFirstName:
                              editing == OnboardingSubturnId.identityName
                              ? _splitName(
                                  _answerBubbleText(
                                    state,
                                    OnboardingSubturnId.identityName,
                                  ),
                                ).$1
                              : null,
                          initialSurname:
                              editing == OnboardingSubturnId.identityName
                              ? _splitName(
                                  _answerBubbleText(
                                    state,
                                    OnboardingSubturnId.identityName,
                                  ),
                                ).$2
                              : null,
                          onConfirm: (first, surname) =>
                              editing == OnboardingSubturnId.identityName
                              ? _submitNameCorrection(state, first, surname)
                              : _submitName(state, first, surname),
                        ),
                      ),
                    ),
                  ),
                )
              else if (showTextComposer)
                _composerShell(
                  context,
                  composerTarget,
                  child: IgnorePointer(
                    ignoring: !canSubmitTarget,
                    child: AnimatedOpacity(
                      opacity: canSubmitTarget ? 1 : 0.65,
                      duration: OnboardingChatController.bubbleEntranceDuration,
                      child: ChatBarTopRow(
                        controller: _textController,
                        focusNode: _focusNode,
                        placeholder: widget.copy.namePlaceholder,
                        hasText: _hasText,
                        voiceEnabled: false,
                        sendEnabled: canSubmitTarget,
                        isLoading: state.isSaving,
                        autofocus: true,
                        maxLength: widget.copy.nameMaxLength,
                        onSend: () => _submitText(state, current!),
                        onMicTap: () async {},
                      ),
                    ),
                  ),
                )
              else if (showLocationComposer)
                _composerShell(
                  context,
                  composerTarget,
                  child: _withEditChrome(
                    context,
                    editing: editing == OnboardingSubturnId.identityCity,
                    child: OnboardingLocationComposer(
                      useMyLocationLabel: widget.copy.useMyLocationLabel!,
                      chooseLocationLabel: widget.copy.chooseLocationLabel!,
                      enabled: canSubmitTarget,
                      onSelected: (selection) =>
                          editing == OnboardingSubturnId.identityCity
                          ? _submitCityCorrection(state, selection)
                          : _submitCity(state, selection),
                    ),
                  ),
                )
              else if (showInterestsComposer)
                _composerShell(
                  context,
                  current,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.5,
                    ),
                    child: SingleChildScrollView(
                      child: OnboardingInterestsComposer(
                        options: interestsOptions,
                        confirmLabel: interestsConfirm,
                        enabled: state.canSubmit,
                        onConfirm: (selected) =>
                            _submitInterests(state, selected),
                      ),
                    ),
                  ),
                )
              else if (showExtraComposer)
                _composerShell(
                  context,
                  current,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.5,
                    ),
                    child: SingleChildScrollView(
                      child: OnboardingExtraComposer(
                        yesLabel: extraYes,
                        noLabel: extraNo,
                        placeholder: extraPlaceholder,
                        confirmLabel: extraConfirm,
                        enabled: state.canSubmit,
                        onNo: () => _submitExtraNo(state),
                        onSubmitText: (text) => _submitExtraText(state, text),
                      ),
                    ),
                  ),
                )
              else if (showConsentComposer)
                _composerShell(
                  context,
                  current,
                  child: OnboardingDeliveryConsent(
                    yesLabel: extraYes,
                    noLabel: extraNo,
                    onAnswered: () => ref
                        .read(widget.controllerProvider.notifier)
                        .resumeAfterGate(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The zines step's gate — just "Continuar". Saving is per-zine, done from each
/// cover's preview sheet (the row of themed zines), so the gate no longer owns a
/// single whole-zine save button.
class _ZinesGate extends StatelessWidget {
  const _ZinesGate({
    required this.continueLabel,
    required this.enabled,
    required this.onContinue,
  });

  final String continueLabel;
  final bool enabled;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return OnboardingContinueButton(
      key: const Key('onboarding-zines-confirm'),
      label: continueLabel,
      enabled: enabled,
      onTap: onContinue,
    );
  }
}

/// The vibe.share picks row: the places/events the user liked in the search,
/// shown above the search input as 105-wide vibe cards with 👍/👎 (same as the
/// carousels). Horizontal-scrolls when the picks overflow.
class _SearchPicksRow extends StatelessWidget {
  const _SearchPicksRow({
    required this.items,
    required this.candidateOf,
    required this.tasteOf,
    required this.onLike,
    required this.onDislike,
    required this.onTap,
  });

  final List<ItemSuggestion> items;
  final VibeCandidate Function(ItemSuggestion) candidateOf;
  final SignalTaste Function(ItemSuggestion) tasteOf;
  final void Function(ItemSuggestion) onLike;
  final void Function(ItemSuggestion) onDislike;
  final void Function(ItemSuggestion) onTap;

  @override
  Widget build(BuildContext context) {
    // Content-height (not the fixed 226 the vibe carousels use): a shared pick
    // is usually a single card with a short name and no subtitle, so a fixed
    // row height left dead space below it. A Row sizes to the tallest card.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < items.length; index++) ...[
            if (index > 0) const SizedBox(width: 10),
            OnboardingVibeCard(
              candidate: candidateOf(items[index]),
              taste: tasteOf(items[index]),
              onLike: () => onLike(items[index]),
              onDislike: () => onDislike(items[index]),
              onTap: () => onTap(items[index]),
            ),
          ],
        ],
      ),
    );
  }
}

/// The profile card's action row: "Edito depois" (skip) + "Editar perfil" (edit
/// photo/name/handle/bio). Both advance the step; edit opens the editor first.
class _ProfileEditGate extends StatelessWidget {
  const _ProfileEditGate({
    required this.editLaterLabel,
    required this.editCtaLabel,
    required this.enabled,
    required this.onEdit,
    required this.onEditLater,
  });

  final String editLaterLabel;
  final String editCtaLabel;
  final bool enabled;
  final VoidCallback onEdit;
  final VoidCallback onEditLater;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.5,
        duration: const Duration(milliseconds: 150),
        child: Row(
          children: [
            Expanded(
              child: BtSqIco(
                key: const Key('onboarding-profile-edit-later'),
                icon: null,
                label: editLaterLabel,
                variant: BtSqIcoVariant.idle,
                expand: true,
                height: 44,
                onTap: onEditLater,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: BtSqIco(
                key: const Key('onboarding-profile-edit'),
                icon: Icons.edit_outlined,
                label: editCtaLabel,
                // Pink outline at rest, pink fill on hover/press (design-system
                // "pink is the interaction accent, not a default fill").
                variant: BtSqIcoVariant.pinkOutline,
                expand: true,
                height: 44,
                onTap: onEdit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Encontra os teus contactos" button — native only (contact sync isn't
/// available on web, so the button is hidden there).
/// The onboarding "Encontra os teus contactos" affordance (Figma `7285:24221`):
/// a pink CTA that requests the OS Contacts permission and matches the address
/// book against Soko users **inline in the step** — matched people appear as
/// follow cards right below, so the user follows friends without leaving
/// onboarding. Native-only (contacts are unavailable on web).
class _FindContactsSection extends ConsumerStatefulWidget {
  const _FindContactsSection({required this.onStart, this.interactive = true});

  /// Fired the first time the user taps to begin a sync (step analytics).
  final VoidCallback onStart;

  /// Whether this section's step is still the current one. Once the flow moves
  /// on it stays as history showing the matched-contacts results, but with no
  /// CTA/empty/denied states (those collapse to nothing).
  final bool interactive;

  @override
  ConsumerState<_FindContactsSection> createState() =>
      _FindContactsSectionState();
}

enum _ContactsPhase { idle, loading, results, denied, empty }

class _FindContactsSectionState extends ConsumerState<_FindContactsSection> {
  _ContactsPhase _phase = _ContactsPhase.idle;
  ContactSyncResult? _result;

  @override
  void initState() {
    super.initState();
    // Restore a sync already completed this session (e.g. returning to the
    // step) so the matches stay visible instead of resetting to the button.
    final cached = ref.read(contactSyncCacheProvider);
    if (cached != null) {
      _result = cached;
      _phase = _resolve(cached);
    }
  }

  static _ContactsPhase _resolve(ContactSyncResult r) {
    switch (r.status) {
      case ContactSyncStatus.ok:
        final has =
            (r.matches?.items.isNotEmpty ?? false) || r.invitable.isNotEmpty;
        return has ? _ContactsPhase.results : _ContactsPhase.empty;
      case ContactSyncStatus.empty:
        return _ContactsPhase.empty;
      case ContactSyncStatus.permissionDenied:
        return _ContactsPhase.denied;
      case ContactSyncStatus.unsupported:
        return _ContactsPhase.idle;
    }
  }

  Future<void> _sync() async {
    if (_phase == _ContactsPhase.loading) return;
    widget.onStart();
    setState(() => _phase = _ContactsPhase.loading);
    final analytics = ref.read(unifiedAnalyticsProvider);
    analytics.trackContactSync(status: 'started');
    try {
      final result = await ref.read(contactSyncServiceProvider).sync();
      if (!mounted) return;
      analytics.trackContactSync(
        status: switch (result.status) {
          ContactSyncStatus.ok => 'completed',
          ContactSyncStatus.permissionDenied => 'permission_denied',
          ContactSyncStatus.empty => 'empty',
          ContactSyncStatus.unsupported => 'failed',
        },
        matchCount: result.matches?.items.length,
        contactCount:
            result.invitable.length + (result.matches?.items.length ?? 0),
      );
      // Cache a successful read so revisiting the step doesn't re-prompt.
      if (result.status == ContactSyncStatus.ok) {
        ref.read(contactSyncCacheProvider.notifier).store(result);
      }
      setState(() {
        _phase = _resolve(result);
        _result = result;
      });
    } catch (_) {
      if (mounted) setState(() => _phase = _ContactsPhase.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    final l10n = Lt.of(context);
    final result = _result;
    final matches = result?.matches?.items ?? const <UserSearchItem>[];
    final hasInvitable = result?.invitable.isNotEmpty ?? false;
    final onResults = _phase == _ContactsPhase.results;
    final onEmpty = _phase == _ContactsPhase.empty;

    // Once the step is answered, this lingers as history: keep the matched
    // results (they read as a saved carousel) but drop the CTA / empty / denied
    // states so no dead button or message is left behind.
    if (!widget.interactive && !onResults) return const SizedBox.shrink();

    final children = <Widget>[];

    final isLoading = _phase == _ContactsPhase.loading;

    // The find CTA — shown until a successful match list replaces it. While the
    // lookup runs a spinner replaces the icon inside the button and the label
    // swaps to "…searching" (taps no-op) so the pending state reads in place.
    if (!onResults) {
      children.add(
        Align(
          alignment: Alignment.centerRight,
          child: BtSqIco(
            key: const Key('onboarding-find-contacts'),
            icon: Icons.person_add_alt_1_outlined,
            label: isLoading
                ? l10n.onboardingChatContactsSearching
                : l10n.onboardingChatProfileFindContacts,
            loading: isLoading,
            // Pink outline at rest, pink fill on hover/press (matches the
            // profile "Editar perfil" CTA — pink is the interaction accent).
            variant: BtSqIcoVariant.pinkOutline,
            height: 40,
            onTap: isLoading ? () {} : _sync,
          ),
        ),
      );
    }

    if (_phase == _ContactsPhase.denied) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.onboardingChatContactsPermissionDenied,
                  style: AppTheme.body(
                    fontSize: 13,
                    color: AppColors.sokoShade3,
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(contactSyncServiceProvider).openSettings(),
                child: Text(
                  l10n.onboardingChatContactsOpenSettings,
                  style: AppTheme.body(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (onResults && matches.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Text(
            l10n.onboardingChatContactsFromYourContacts,
            style: AppTheme.body(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      );
      children.add(
        OnboardingFollowList(
          items: matches,
          // Local address-book names → each matched card shows its "known as"
          // (same map the profile contact-matches screen resolves against).
          hashToName: result?.hashToName,
        ),
      );
    }

    if (onEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            l10n.onboardingChatContactsNoneFound,
            style: AppTheme.body(fontSize: 13, color: AppColors.sokoShade3),
          ),
        ),
      );
    }

    // Invite candidates → one share entry, on either result surface.
    if ((onResults || onEmpty) && hasInvitable) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: BtSqIco(
              icon: Icons.ios_share,
              label: l10n.onboardingChatContactsInvite,
              variant: BtSqIcoVariant.normal,
              height: 40,
              onTap: () {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackInviteShared(source: 'contact_match');
                shareItem(
                  context: context,
                  ref: ref,
                  title: l10n.inviteShareMessageTitle,
                  url: ApiConstants.appInstallUrl,
                );
              },
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// The rituals step's two secondary exit CTAs (Figma `7285:24374`): stacked,
/// right-aligned outline buttons — "Explora o mapa" and "Conversa comigo".
/// Each finishes onboarding and routes to that surface.
class _RitualsExitCtas extends StatelessWidget {
  const _RitualsExitCtas({
    required this.exploreMapLabel,
    required this.chatLabel,
    required this.enabled,
    required this.onExploreMap,
    required this.onChat,
  });

  final String exploreMapLabel;
  final String chatLabel;
  final bool enabled;
  final VoidCallback onExploreMap;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.5,
        duration: const Duration(milliseconds: 150),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            BtSqIco(
              key: const Key('onboarding-rituals-explore-map'),
              icon: Icons.map_outlined,
              label: exploreMapLabel,
              variant: BtSqIcoVariant.idle,
              height: 40,
              onTap: onExploreMap,
            ),
            const SizedBox(height: 6),
            BtSqIco(
              key: const Key('onboarding-rituals-chat'),
              icon: Icons.chat_bubble_outline,
              label: chatLabel,
              variant: BtSqIcoVariant.idle,
              height: 40,
              onTap: onChat,
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentityHeader extends ConsumerWidget {
  const _IdentityHeader({
    required this.copy,
    required this.step,
    this.onRestart,
    this.onSkip,
  });

  final OnboardingIdentityNameCopy copy;
  final OnboardingStepId step;

  /// Admin/QA-only restart handler; when null (or the user isn't an admin) no
  /// restart button is shown.
  final Future<void> Function()? onRestart;

  /// Admin/QA-only skip handler; when null (or the user isn't an admin) no skip
  /// button is shown. Marks onboarding complete server-side and leaves to the
  /// app — the fast-forward counterpart to [onRestart].
  final Future<void> Function()? onSkip;

  /// Title + "N/5" for the current step. Vibe and not-local both swap the
  /// header and sit at step 2/5 (they're the two branches out of identity);
  /// zines is 3/5.
  bool get _isVibe => step == OnboardingStepId.vibe;
  bool get _isNotLocal => step == OnboardingStepId.notLocal;
  bool get _isZines => step == OnboardingStepId.zines;
  bool get _isProfile => step == OnboardingStepId.profile;
  bool get _isRituals => step == OnboardingStepId.rituals;
  String get _title {
    if (_isVibe && copy.vibeHeaderTitle != null) return copy.vibeHeaderTitle!;
    if (_isNotLocal && copy.notLocalHeaderTitle != null) {
      return copy.notLocalHeaderTitle!;
    }
    if (_isZines && copy.zinesHeaderTitle != null) {
      return copy.zinesHeaderTitle!;
    }
    if (_isProfile && copy.profileHeaderTitle != null) {
      return copy.profileHeaderTitle!;
    }
    if (_isRituals && copy.ritualsHeaderTitle != null) {
      return copy.ritualsHeaderTitle!;
    }
    return copy.headerTitle;
  }

  String get _stepLabel {
    if (_isRituals) return '5/5';
    if (_isProfile) return '4/5';
    if (_isZines) return '3/5';
    if (_isVibe || _isNotLocal) return '2/5';
    return copy.stepLabel;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Admin/QA-only: restart + skip affordances in the top-right corner.
    // Non-admins (and callers that pass no handler) see nothing — the title
    // stays centred. Read the admin role once and gate both buttons on it.
    final isAdmin = ref.watch(currentUserProvider)?.role == UserRole.admin;
    final showRestart = onRestart != null && isAdmin;
    final showSkip = onSkip != null && isAdmin;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Centred title (Figma `7285:23292`). No back affordance: onboarding
          // is a forward-only chat flow — the PopScope makes it
          // non-dismissible, so a back arrow would only ever be inert. The
          // admin restart affordance (right) is the only header control.
          SizedBox(
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Language switcher pinned top-left, mirroring the admin
                // restart on the right. Reuses the canonical auth-funnel
                // picker (globe + locale code) so onboarding matches the
                // login/discovery language affordance.
                const Align(
                  alignment: Alignment.centerLeft,
                  child: AuthLanguageButton(),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    _title,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: AppTheme.displayPrimary(
                      fontSize: 32,
                      fontWeight: FontWeight.w400,
                      height: 1,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ),
                if (showRestart || showSkip)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showSkip)
                          GestureDetector(
                            key: const Key('onboarding-admin-skip'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => onSkip!(),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 12),
                              child: Tooltip(
                                message: 'Skip onboarding (admin)',
                                child: Icon(
                                  Icons.skip_next,
                                  size: 24,
                                  color: AppColors.sokoInk,
                                ),
                              ),
                            ),
                          ),
                        if (showRestart)
                          GestureDetector(
                            key: const Key('onboarding-admin-restart'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => onRestart!(),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 12),
                              child: Tooltip(
                                message: 'Restart onboarding (admin)',
                                child: Icon(
                                  Icons.restart_alt,
                                  size: 24,
                                  color: AppColors.sokoInk,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _stepLabel,
            textAlign: TextAlign.center,
            style: AppTheme.body(
              fontSize: 18,
              fontWeight: FontWeight.w300,
              height: 1,
              color: AppColors.sokoInk,
            ).copyWith(letterSpacing: -0.36),
          ),
        ],
      ),
    );
  }
}
