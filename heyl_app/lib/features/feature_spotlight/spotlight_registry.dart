import 'models/spotlight_definition.dart';

/// Compile-time spotlight registry (PROD-2808).
///
/// The Flutter binary is the sole source of truth for the spotlight
/// catalog — the backend (PROD-2809) has no catalog and accepts any
/// well-formed `feature_id` it hasn't seen before. Adding, removing, or
/// renaming a spotlight is a Flutter-only change.
///
/// Instances are wired into their target screens via `SpotlightTrigger`.
/// Adding a new spotlight is a three-step change:
///   1. Add a `SpotlightDefinition` entry here (id must match
///      `^[a-z0-9][a-z0-9_-]{0,99}$` — enforced by the registry test).
///   2. Add ARB keys in `intl_en.arb` + translations.
///   3. Wrap the target UI with `SpotlightTrigger(featureId: '<id>')`.
const Map<String, SpotlightDefinition> kFeatureSpotlights = {
  'reminders_v1': SpotlightDefinition(
    id: 'reminders_v1',
    surface: 'event_detail',
    titleKey: 'spotlightRemindersV1Title',
    bodyKey: 'spotlightRemindersV1Body',
    ctaLabelKey: 'spotlightRemindersV1Cta',
  ),
  'ig_share_v1': SpotlightDefinition(
    id: 'ig_share_v1',
    surface: 'list_page',
    titleKey: 'spotlightIgShareV1Title',
    bodyKey: 'spotlightIgShareV1Body',
    ctaLabelKey: 'spotlightIgShareV1Cta',
  ),
  // Social-profile pilot: introduce the Profile tab on the home surface —
  // "this is your profile" + a mutual-follow Soko card. Fires before
  // map_page_v1 (which gates behind this being seen for users who have the
  // profile slot). Only mounts on the admin profile nav slot today.
  'profile_v1': SpotlightDefinition(
    id: 'profile_v1',
    surface: 'discovery',
    titleKey: 'spotlightProfileV1Title',
    bodyKey: 'spotlightProfileV1Body',
    ctaLabelKey: 'spotlightProfileV1Cta',
  ),
  // PROD-3133: teach existing users about the Map page now that its
  // Discovery entry button is open to everyone (was admin-only).
  'map_page_v1': SpotlightDefinition(
    id: 'map_page_v1',
    surface: 'discovery',
    titleKey: 'spotlightMapPageV1Title',
    bodyKey: 'spotlightMapPageV1Body',
    ctaLabelKey: 'spotlightMapPageV1Cta',
  ),
};

SpotlightDefinition? spotlightForId(String featureId) =>
    kFeatureSpotlights[featureId];
