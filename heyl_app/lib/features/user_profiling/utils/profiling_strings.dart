import 'package:flutter/widgets.dart';

import '../../../l10n/generated/l10n.dart';

/// Lookup helpers for the V6 vibe/profiling flow's dynamic string keys.
///
/// The backend catalog (and the persona-id enum) ship STRING keys like
/// `personaOnboardingMorningTitle` / `personaOnboardingActivityExplore` /
/// `curious_cosmopolitan`. Generated `Lt` accessors are named methods, so we
/// switch through this fixed map to get from a runtime key to the matching
/// Lt accessor. Non-dynamic call sites should use `Lt.of(context).<key>`
/// directly — only the catalog-driven and persona-driven sites need this.
///
/// PROD-2319 — replaced the previous `UserProfilingDevStrings.resolve(key)`
/// stopgap with ARB-backed lookups.
String profilingString(BuildContext context, String key) {
  final l = Lt.of(context);
  switch (key) {
    // Step titles
    case 'personaOnboardingMorningTitle':
      return l.personaOnboardingMorningTitle;
    case 'personaOnboardingActivityTitle':
      return l.personaOnboardingActivityTitle;
    case 'personaOnboardingFoodTitle':
      return l.personaOnboardingFoodTitle;
    case 'personaOnboardingNightTitle':
      return l.personaOnboardingNightTitle;
    case 'personaOnboardingInterestsTitle':
      return l.personaOnboardingInterestsTitle;

    // Vibe option labels
    case 'personaOnboardingMorningPasteis':
      return l.personaOnboardingMorningPasteis;
    case 'personaOnboardingMorningCafe':
      return l.personaOnboardingMorningCafe;
    case 'personaOnboardingMorningMarket':
      return l.personaOnboardingMorningMarket;
    case 'personaOnboardingActivityExplore':
      return l.personaOnboardingActivityExplore;
    case 'personaOnboardingActivitySocial':
      return l.personaOnboardingActivitySocial;
    case 'personaOnboardingActivityOutdoors':
      return l.personaOnboardingActivityOutdoors;
    case 'personaOnboardingFoodTasca':
      return l.personaOnboardingFoodTasca;
    case 'personaOnboardingFoodStreet':
      return l.personaOnboardingFoodStreet;
    case 'personaOnboardingFoodSeafood':
      return l.personaOnboardingFoodSeafood;
    case 'personaOnboardingNightBeach':
      return l.personaOnboardingNightBeach;
    case 'personaOnboardingNightWine':
      return l.personaOnboardingNightWine;
    case 'personaOnboardingNightBairro':
      return l.personaOnboardingNightBairro;

    // Interest chip labels
    case 'personaOnboardingHikesNature':
      return l.personaOnboardingHikesNature;
    case 'personaOnboardingSportsFitness':
      return l.personaOnboardingSportsFitness;
    case 'personaOnboardingPartiesNightlife':
      return l.personaOnboardingPartiesNightlife;
    case 'personaOnboardingLiveMusic':
      return l.personaOnboardingLiveMusic;
    case 'personaOnboardingArtExhibitions':
      return l.personaOnboardingArtExhibitions;
    case 'personaOnboardingDesignCulture':
      return l.personaOnboardingDesignCulture;
    case 'personaOnboardingLocalEats':
      return l.personaOnboardingLocalEats;
    case 'personaOnboardingCoffeeSpots':
      return l.personaOnboardingCoffeeSpots;
    case 'personaOnboardingSocialPlans':
      return l.personaOnboardingSocialPlans;
    case 'personaOnboardingMarketsVintage':
      return l.personaOnboardingMarketsVintage;
    case 'personaOnboardingFamilyFriendly':
      return l.personaOnboardingFamilyFriendly;
    case 'personaOnboardingGivingBack':
      return l.personaOnboardingGivingBack;
  }
  // Unknown catalog key — backend drift. Show the raw key so it's visible
  // in QA rather than silently rendering empty.
  return '[$key]';
}

/// Resolve a persona's display name from its stable backend id (e.g.
/// `curious_cosmopolitan`). Wire-format `name_key`/`description_key` has
/// drifted across spec versions; the id is the documented enum, so it's
/// the stable axis to switch on.
String profilingPersonaName(BuildContext context, String personaId) {
  final l = Lt.of(context);
  switch (personaId) {
    case 'conscious_outdoors':
      return l.personaOnboardingPersonaConsciousOutdoorsName;
    case 'local_at_heart':
      return l.personaOnboardingPersonaLocalAtHeartName;
    case 'curious_cosmopolitan':
      return l.personaOnboardingPersonaCuriousCosmopolitanName;
    case 'golden_age':
      return l.personaOnboardingPersonaGoldenAgeName;
    case 'quality_seeker':
      return l.personaOnboardingPersonaQualitySeekerName;
  }
  return '[$personaId]';
}

String profilingPersonaDescription(BuildContext context, String personaId) {
  final l = Lt.of(context);
  switch (personaId) {
    case 'conscious_outdoors':
      return l.personaOnboardingPersonaConsciousOutdoorsDescription;
    case 'local_at_heart':
      return l.personaOnboardingPersonaLocalAtHeartDescription;
    case 'curious_cosmopolitan':
      return l.personaOnboardingPersonaCuriousCosmopolitanDescription;
    case 'golden_age':
      return l.personaOnboardingPersonaGoldenAgeDescription;
    case 'quality_seeker':
      return l.personaOnboardingPersonaQualitySeekerDescription;
  }
  return '[$personaId]';
}
