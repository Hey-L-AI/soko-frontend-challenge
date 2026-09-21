import 'package:flutter/widgets.dart';

import '../../../l10n/generated/l10n.dart';
import 'memory_family_label.dart';

/// Returns the Soko-voice sub-header for one twin dimension (e.g.
/// `cuisine.preferred` → "adoras" in PT-PT, "you love" in EN). The header
/// is the conversational opener that precedes the observation chips for
/// that dimension, so the page reads like Soko narrating the user back to
/// themselves instead of a flat tag list.
///
/// Unknown dimension names fall back to the family label (so a new
/// dimension we haven't named won't render as an empty header).
String memoryDimensionHeader(BuildContext context, String dimensionName) {
  final l10n = Lt.of(context);
  switch (dimensionName) {
    case 'cuisine.preferred':
      return l10n.memoryHeaderCuisinePrefer;
    case 'cuisine.avoided':
      return l10n.memoryHeaderCuisineAvoid;
    case 'dietary.restriction':
      return l10n.memoryHeaderDietaryRestriction;
    case 'dietary.preferred':
      return l10n.memoryHeaderDietaryPrefer;
    case 'vibe.preferred':
      return l10n.memoryHeaderVibePrefer;
    case 'vibe.avoided':
      return l10n.memoryHeaderVibeAvoid;
    case 'venue_type.preferred':
      return l10n.memoryHeaderVenueTypePrefer;
    case 'venue_type.avoided':
      return l10n.memoryHeaderVenueTypeAvoid;
    case 'amenities.preferred':
      return l10n.memoryHeaderAmenityPrefer;
    case 'amenities.required':
      return l10n.memoryHeaderAmenityRequire;
    case 'meal_period.preferred':
      return l10n.memoryHeaderMealPeriodPrefer;
    case 'occasion.preferred':
      return l10n.memoryHeaderOccasionPrefer;
    case 'quality_bar.preferred':
      return l10n.memoryHeaderQualityBarPrefer;
    case 'service_format.preferred':
      return l10n.memoryHeaderServiceFormatPrefer;
    case 'accessibility.requirement':
      return l10n.memoryHeaderAccessibilityRequire;
    case 'event_category.preferred':
      return l10n.memoryHeaderEventCategoryPrefer;
    case 'event_sub_category.preferred':
      return l10n.memoryHeaderEventSubCategoryPrefer;
    case 'budget.tier':
      return l10n.memoryHeaderBudgetTier;
    case 'budget.ceiling':
      return l10n.memoryHeaderBudgetCeiling;
    case 'location.home':
      return l10n.memoryHeaderLocationHome;
    case 'area.frequent':
      return l10n.memoryHeaderAreaFrequent;
    case 'audience.preferred':
      return l10n.memoryHeaderAudiencePrefer;
    case 'companions.named':
      return l10n.memoryHeaderCompanionsNamed;
    case 'known_venues.preferred':
      return l10n.memoryHeaderKnownVenuePrefer;
    case 'known_venues.avoided':
      return l10n.memoryHeaderKnownVenueAvoid;
    case 'known_events.preferred':
      return l10n.memoryHeaderKnownEventPrefer;
    case 'party.typical_size':
      return l10n.memoryHeaderPartySize;
    default:
      // Fall back to the family's label so a not-yet-mapped dimension
      // still renders something sensible.
      final family = dimensionName.split('.').first;
      return memoryFamilyLabel(context, family).toLowerCase();
  }
}
