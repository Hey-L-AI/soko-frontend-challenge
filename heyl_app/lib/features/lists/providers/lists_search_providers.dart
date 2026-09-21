import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../discovery/providers/search_category_provider.dart';

/// Whether the `/lists` hub's search overlay is currently open.
///
/// Forked from `searchOpenProvider` (Discovery's equivalent) per the
/// PROD-1911 plan: typing on `/lists` must not bleed into `/discovery`'s
/// search state, and vice versa. Two near-identical providers is a small
/// price to pay for clean boundaries between surfaces.
final listsSearchOpenProvider = StateProvider<bool>((_) => false);

/// Debounced search query for the `/lists` hub. Mirrors
/// `searchQueryProvider` for Discovery but lives in its own provider so
/// the two pages don't interfere.
///
/// Empty string when not searching. The overlay pushes trimmed input
/// after a 600 ms debounce; consumers (`listsSearchResultsProvider`)
/// watch this directly.
final listsSearchQueryProvider = StateProvider<String>((_) => '');

/// Selected category for the `/lists` hub's search overlay. Forked from
/// `searchCategoryProvider` (Discovery's equivalent) so navigating
/// between the two surfaces doesn't carry stale category state.
///
/// Reuses [DiscoverySearchCategory] for the enum so there's no
/// behavioural drift between the two surfaces. The category tabs widget
/// itself is shared (`SearchCategoryTabs`); only the state provider
/// differs per page.
///
/// **v1 note:** the lists search results provider doesn't yet branch on
/// category — selecting Eventos / Sítios is visually-only for now. See
/// `lists_search_results_provider.dart`.
final listsSearchCategoryProvider = StateProvider<DiscoverySearchCategory>(
  (_) => DiscoverySearchCategory.zines,
);

/// Minimum query length before firing a request. Mirrors
/// `kDiscoverySearchMinQueryLength` — single-character queries return
/// too much noise.
const int kListsSearchMinQueryLength = 2;
