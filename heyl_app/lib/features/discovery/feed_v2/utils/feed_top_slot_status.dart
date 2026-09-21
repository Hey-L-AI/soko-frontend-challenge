import '../../../daily_drop/providers/daily_drop_provider.dart';
import '../../../weekly_bundle/providers/weekly_bundle_provider.dart';

/// Whether a top-slot card will be on the page, keyed off the same provider
/// state the card's own section reads.
enum FeedTopSlotStatus {
  /// Still in flight. The section is drawing a skeleton and holding layout.
  resolving,

  /// The section will draw a card.
  visible,

  /// The section will collapse to zero height.
  hidden,
}

// **These mirror the section widgets' own `_buildBody` branch tables.**
//
// The carousel has to know how many cards it will end up with *before* it can
// choose a width mode, and a section that collapses to `SizedBox.shrink()`
// still occupies its slot in a horizontal list — so the membership decision
// cannot be deferred to the child.
//
// That makes these a **second copy of a decision**, which is the risk worth
// naming: change `daily_drop_section.dart` or `weekly_bundle_section.dart`
// without changing these and the carousel will reserve a slot for a card that
// never draws, or drop one that does. `feed_top_slot_status_test.dart` pins
// every branch against the section it mirrors; if these ever earn a third
// caller, push the decision down into the sections and have both read it.

/// Mirrors `DailyDropSection._buildBody`.
///
/// [profilingFinishedLocally] is the render-time safety net that section
/// applies: the FE knows profiling is done while the BE still says
/// `cta_profiling`, so it holds a skeleton rather than showing a stale CTA.
FeedTopSlotStatus dailyDropTopSlotStatus(
  DailyDropState state, {
  required bool profilingFinishedLocally,
}) {
  if (state.isUnsupportedCity) return FeedTopSlotStatus.hidden;

  if (state.isCtaProfiling) {
    return profilingFinishedLocally
        ? FeedTopSlotStatus.resolving
        : FeedTopSlotStatus.visible;
  }

  final drop = state.drop;
  if (drop == null) {
    // Both of these draw a real card, not a skeleton — the user is told what
    // is happening (PROD-3730), so they count as visible.
    if (state.isGenerating || state.hasTimedOut) {
      return FeedTopSlotStatus.visible;
    }
    if (state.hasError) return FeedTopSlotStatus.hidden;
    return FeedTopSlotStatus.resolving;
  }

  // The ready card no longer renders the cover or the title, so this guard is
  // now about whether the drop is *openable*, not whether it is drawable. Kept
  // as-is deliberately: relaxing which drops appear is a product change, not a
  // consequence of a restyle. See `daily_drop_section.dart`.
  if (!drop.hasRecommendation ||
      drop.title == null ||
      drop.coverImageUrl == null) {
    return FeedTopSlotStatus.hidden;
  }
  return FeedTopSlotStatus.visible;
}

/// Mirrors `WeeklyBundleSection._buildBody`.
FeedTopSlotStatus weeklyBundleTopSlotStatus(WeeklyBundleState state) {
  if (state.isUnsupportedCity) return FeedTopSlotStatus.hidden;

  final bundle = state.bundle;
  if (bundle == null) {
    // `isGenerating` hides here but shows for Daily Drop — not an
    // inconsistency to tidy up: the Weekly Bundle has no "we are working on it"
    // card, so there is nothing to show.
    if (state.hasError || state.isGenerating) return FeedTopSlotStatus.hidden;
    return FeedTopSlotStatus.resolving;
  }
  return bundle.isReady ? FeedTopSlotStatus.visible : FeedTopSlotStatus.hidden;
}
