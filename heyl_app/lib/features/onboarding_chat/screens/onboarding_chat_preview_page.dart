import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/in_memory_onboarding_progress_store.dart';
import '../data/onboarding_interest_catalog.dart';
import '../models/onboarding_chat_models.dart';
import '../providers/onboarding_chat_controller.dart';
import 'onboarding_identity_name_screen.dart';

/// Admin-only preview of the scripted onboarding chat foundation.
///
/// Mirrors the client-side `[admin] Replay tour` action: it launches the
/// scripted animation backed by an ephemeral [InMemoryOnboardingProgressStore],
/// so each visit replays from the top. Reachable only through the admin-gated
/// menu row. Copy is inline English — this is a debug surface, like the other
/// `[admin]` rows; localization ships with the real wiring (PROD-3882), which
/// also builds the steps beyond identity/name.
class OnboardingChatPreviewPage extends ConsumerStatefulWidget {
  const OnboardingChatPreviewPage({super.key});

  @override
  ConsumerState<OnboardingChatPreviewPage> createState() =>
      _OnboardingChatPreviewPageState();
}

class _OnboardingChatPreviewPageState
    extends ConsumerState<OnboardingChatPreviewPage> {
  // A fresh provider per mount = replay from the top on every visit.
  late final _provider = createOnboardingChatProvider(
    progressStore: InMemoryOnboardingProgressStore(),
    script: OnboardingScript.identity(
      greeting: "Hey — I'm Soko, your local guide.",
      askName: "First things first — what should I call you?",
      askCity: 'Good to meet you. Which neighbourhood do you call home?',
      askInterests: 'Now — what are you into?',
      interestsHint:
          'Pick at least 3 so I can read your taste. No judgement on the guilty pleasures.',
      askExtra: 'One last thing — anything else I should know about you?',
    ),
  );

  final _copy = OnboardingIdentityNameCopy(
    headerTitle: 'Who are you',
    stepLabel: '1/5',
    namePlaceholder: 'Type your name…',
    cityPlaceholder: 'Your neighbourhood & city',
    interestsConfirmLabel: 'Continue',
    interestsOptions: onboardingInterestOptionsEn(),
    useMyLocationLabel: 'My location',
    chooseLocationLabel: 'Choose a location',
    nameMaxLength: 40,
    firstNamePlaceholder: 'First name',
    surnamePlaceholder: 'Surname',
    extraYesLabel: 'Yes',
    extraNoLabel: 'No',
    extraPlaceholder: 'Tell me a little more about you…',
    extraConfirmLabel: 'Continue',
    extraAck: 'Got it — thanks.',
    vibeSearchingPlaces: 'Finding places for you…',
    vibeSearchingEvents: 'Finding events for you…',
    persistenceError: "Something went wrong. Let's try that again.",
    retryLabel: 'Retry',
  );

  // The container outlives this element, so it (not `ref`, which is illegal in
  // dispose) is what we invalidate through to release the ephemeral controller
  // and stop any in-flight scripted timers when the admin leaves the preview.
  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    _container?.invalidate(_provider);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OnboardingIdentityNameScreen(
    controllerProvider: _provider,
    copy: _copy,
    isPreview: true,
  );
}
