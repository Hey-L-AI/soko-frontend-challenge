import '../../../l10n/generated/l10n.dart';
import '../widgets/onboarding_interests_composer.dart';

/// The 12 identity-step interests from Figma `7285:23320`.
///
/// Ids MUST match the backend interest taxonomy (`INTEREST_LABELS` /
/// `INTEREST_TEXT` in `heyl/core/user_profiling/mapping.py`): they are sent
/// verbatim in `PUT /onboarding/state` `answers[...].interests` and the server
/// rejects any id it does not recognize (dropping onboarding memory facts and
/// the preliminary discovery zines). Previously these were client-defined
/// snake_case placeholders, which the backend silently discarded (PROD-3882).
///
/// The **ids** are the stable source of truth (order + backend taxonomy); the
/// display **labels** are localized via ARB (`onboardingInterest*`) and resolved
/// per-locale in [onboardingInterestOptions], so a language switch re-labels them.
const List<String> kOnboardingInterestIds = [
  'hikes-nature',
  'sports-fitness',
  'parties-nightlife',
  'live-music',
  'art-exhibitions',
  'design-culture',
  'local-eats',
  'coffee-spots',
  'social-plans',
  'markets-vintage',
  'kid-friendly',
  'giving-back',
];

/// Localized display label for an interest id.
String onboardingInterestLabel(Lt l10n, String id) => switch (id) {
  'hikes-nature' => l10n.onboardingInterestHikesNature,
  'sports-fitness' => l10n.onboardingInterestSportsFitness,
  'parties-nightlife' => l10n.onboardingInterestPartiesNightlife,
  'live-music' => l10n.onboardingInterestLiveMusic,
  'art-exhibitions' => l10n.onboardingInterestArtExhibitions,
  'design-culture' => l10n.onboardingInterestDesignCulture,
  'local-eats' => l10n.onboardingInterestLocalEats,
  'coffee-spots' => l10n.onboardingInterestCoffeeSpots,
  'social-plans' => l10n.onboardingInterestSocialPlans,
  'markets-vintage' => l10n.onboardingInterestMarketsVintage,
  'kid-friendly' => l10n.onboardingInterestKidFriendly,
  'giving-back' => l10n.onboardingInterestGivingBack,
  _ => id,
};

/// Builds the composer options with localized labels, in the fixed id order.
List<OnboardingInterestOption> onboardingInterestOptions(Lt l10n) => [
  for (final id in kOnboardingInterestIds)
    OnboardingInterestOption(id: id, label: onboardingInterestLabel(l10n, id)),
];

/// English labels for context-less callers (the hardcoded-English preview page /
/// tests) that can't reach an [Lt]. Kept in sync with `intl_en.arb`.
const Map<String, String> kOnboardingInterestLabelsEn = {
  'hikes-nature': 'Hiking & nature',
  'sports-fitness': 'Sports & fitness',
  'parties-nightlife': 'Parties & nightlife',
  'live-music': 'Live music & concerts',
  'art-exhibitions': 'Art & exhibitions',
  'design-culture': 'Culture, design & architecture',
  'local-eats': 'Local bites',
  'coffee-spots': 'Cafés',
  'social-plans': 'Social moments',
  'markets-vintage': 'Markets & vintage',
  'kid-friendly': 'Family activities',
  'giving-back': 'Volunteering & community',
};

/// English-only options for context-less callers (preview / tests).
List<OnboardingInterestOption> onboardingInterestOptionsEn() => [
  for (final id in kOnboardingInterestIds)
    OnboardingInterestOption(id: id, label: kOnboardingInterestLabelsEn[id]!),
];
