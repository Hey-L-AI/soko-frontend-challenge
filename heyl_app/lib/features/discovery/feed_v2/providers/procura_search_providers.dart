// PROD-4081 / PROD-4179 — Procura's search state (D121–D123).
//
// **The third provider set, not a third widget.** `SearchOverlay`,
// `SearchResultsSection`, `ReadersSearchSection` and `DefaultContentSection`
// are all reused unchanged in behaviour; only the state they read is forked.
// Discovery (`search_*_provider.dart`) and the `/lists` hub
// (`lists_search_providers.dart`) already do exactly this, and this file is
// deliberately the same shape as the latter so the three read as one pattern.
//
// Why fork at all, when Procura and "Descobre a cidade" are the same search:
// sharing would make typing in one leave a query sitting in the other, and
// `searchOpenProvider` is a global flag that persists across navigation
// (`discovery_shell.dart:1261`). Two near-identical providers is the cheap side
// of that trade.
//
// **What is NOT forked:** the event/place facet filters
// (`eventTimeRangeProvider`, `eventFacetFilterProvider`,
// `placeTypeFacetFilterProvider`). D123 forks the *category*; the facets are
// the same search against the same endpoints, and `discoverySearchResultsProvider`
// watches them globally. The consequence is real though — `DiscoveryScreen`
// clears them when its overlay closes (`discovery_screen.dart:644`) so filters
// cannot outlive the search that set them, and the feed's `_exitProcura` has to
// do the same on the way out or a `Música` chip picked here silently filters
// Discovery afterwards. (Until PROD-4179 that job belonged to a pushed screen's
// `dispose`; leaving Procura mode is now an ordinary state change on the feed,
// which is a strictly easier place to get it right.)

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/search_category_provider.dart';

/// Debounced query typed on the Procura screen.
///
/// Fed by `SearchOverlay`'s own 600 ms debounce, exactly as Discovery's
/// `searchQueryProvider` is. Empty (or whitespace-only) means "no active
/// search" — the body reads that to fall back to the browse state.
final procuraSearchQueryProvider = StateProvider<String>((_) => '');

/// Selected category filter on the Procura screen, or **null for "all"**.
///
/// Reuses [DiscoverySearchCategory] rather than `FeedFilter`, which is what
/// makes the acceptance criterion *"selecting a filter here does not change the
/// feed's filter"* true **by construction** rather than by discipline: the
/// feed's selection lives in `feedFilterProvider`, over a different enum, and
/// nothing here can reach it.
///
/// **Nullable, defaults to null (unified-search):** the chips start deselected
/// and act as toggle filters over the grouped results — null shows every
/// category section, a selected chip narrows to that one, re-tapping clears it.
final procuraSearchCategoryProvider = StateProvider<DiscoverySearchCategory?>(
  (_) => null,
);

/// Pill order on the Procura screen.
///
/// The same four Discovery shows, in the same order. `leitores` is the fourth
/// and it is **enabled**: the ticket and D122 both say it renders disabled
/// "because no people search category exists", which is not true of the screen
/// being reused — `ReadersSearchSection` ships today and returns real users
/// with follow buttons. D122's reasoning ("a disabled tab over working
/// functionality is a regression dressed as consistency") argues for keeping
/// it; only its stated fact was wrong. Zé ruled: keep it working, label it
/// "Pessoas" — the label the feed's filter row already gives it, which is now
/// the only row that renders these categories.
const List<DiscoverySearchCategory> kProcuraCategoryOrder = [
  DiscoverySearchCategory.eventos,
  DiscoverySearchCategory.sitios,
  DiscoverySearchCategory.zines,
  DiscoverySearchCategory.leitores,
];
