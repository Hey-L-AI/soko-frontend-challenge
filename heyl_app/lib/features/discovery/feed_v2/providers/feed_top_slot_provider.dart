// PROD-4081 — whether the ritual-card slot will draw anything, as a provider.
//
// `FeedTopCards` has always computed this to decide between nothing / one card
// / a carousel. It is lifted here because a SECOND caller now needs the same
// answer: the rule Figma `7598-24580` draws between the ritual cards and the
// filter row has to disappear when there are no ritual cards — otherwise it
// lands directly under the scallop, and the page shows two dividers in a row
// with nothing between them.
//
// **One computation, two readers** — deliberately not two copies. The file this
// builds on already warns that its status helpers are "a second copy of a
// decision" mirroring the section widgets; a third copy, in the page, is
// exactly how the rule and the cards would come to disagree about whether the
// slot is empty.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../daily_drop/providers/daily_drop_provider.dart';
import '../../../user_profiling/providers/user_profiling_gate_provider.dart';
import '../../../weekly_bundle/providers/weekly_bundle_provider.dart';
import '../utils/feed_top_slot_status.dart';

/// The two ritual slots' statuses, in page order.
typedef FeedTopSlotStatuses = ({
  FeedTopSlotStatus dailyDrop,
  FeedTopSlotStatus weekly,
});

final feedTopSlotStatusesProvider = Provider<FeedTopSlotStatuses>((ref) {
  final dailyDropState = ref.watch(dailyDropProvider);
  return (
    dailyDrop: dailyDropTopSlotStatus(
      dailyDropState,
      // Read **only** in the profiling window, exactly as
      // `DailyDropSection._buildBody` does — watching it unconditionally would
      // put `sharedPreferencesProvider` in this provider's dependencies for
      // every user, to answer a question that only matters while the backend is
      // returning `cta_profiling`.
      profilingFinishedLocally: dailyDropState.isCtaProfiling
          ? ref.watch(hasFinishedUserProfilingLocallyProvider)
          : false,
    ),
    weekly: weeklyBundleTopSlotStatus(ref.watch(weeklyBundleProvider)),
  );
});

/// Whether the top slot will put anything on the page.
///
/// `resolving` counts as content: the section holds layout with a skeleton, so
/// the rule belongs under it. Only `hidden` collapses.
final feedTopSlotHasContentProvider = Provider<bool>((ref) {
  final s = ref.watch(feedTopSlotStatusesProvider);
  return s.dailyDrop != FeedTopSlotStatus.hidden ||
      s.weekly != FeedTopSlotStatus.hidden;
});
