import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/action_bar_location_pill.dart';
import '../../../shared/widgets/search_category_tag_row.dart';
import '../../../shared/widgets/search_overlay.dart';
import '../../product_tour/providers/product_tour_keys_provider.dart';
import '../providers/search_category_provider.dart';
import '../providers/search_open_provider.dart';
import '../providers/search_query_provider.dart';
import '../providers/search_results_provider.dart'
    show kDiscoverySearchMinQueryLength;
import 'event_filters_bar.dart';
import 'place_filters_bar.dart';
import 'scroll_memory_observer.dart';

/// Discovery's search-overlay row — thin wrapper around the shared
/// [SearchOverlay] widget, plugged into Discovery's own state providers
/// (`searchOpenProvider`, `searchQueryProvider`, `searchCategoryProvider`)
/// and Discovery's placeholder hint.
///
/// The Lists hub has its own `ListsSearchOverlay` wrapper bound to the
/// forked `lists*` providers — see PROD-1911 plan § Phase 3. The visual
/// contract (input pill, centered Zines / Eventos / Sítios tabs, X
/// close, 600 ms debounce) lives in [SearchOverlay], so changes to the
/// chrome only land in one place.
///
/// PROD-2221 — Discovery keeps the location pill visible to the right
/// of the search input while the overlay is open ([inputTrailingBuilder]),
/// and the "All" category pill is removed (filter defaults to Zines).
///
/// Tour wiring — passes `keys.searchOverlayClose` to the X close
/// button so the tour cursor can find its position during the step 3
/// → step 4 transition (cursor clicks X to close the overlay).
class DiscoverySearchOverlay extends ConsumerWidget {
  const DiscoverySearchOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final tourKeys = ref.watch(productTourKeysProvider);
    // PROD-3533: AppsFlyer `af_search` signal. `searchQueryProvider` only
    // changes once the 600 ms debounce inside `SearchOverlay` settles, so
    // this fires once per submitted query (not per keystroke) — mirrors the
    // "outcome, not per-keystroke" modeling already used by
    // `map_area_searched`. Gated on the same minimum length that actually
    // triggers a fetch in `discoverySearchResultsProvider`, so a stray
    // 1-character pause isn't counted as a search.
    ref.listen<String>(searchQueryProvider, (previous, next) {
      final trimmed = next.trim();
      if (trimmed.length >= kDiscoverySearchMinQueryLength) {
        ref
            .read(unifiedAnalyticsProvider)
            .trackSearchSubmitted(searchTerm: trimmed, source: 'discovery');
      }
    });
    // PROD-2240 — on mobile (native iOS/Android + mobile-web user agents
    // surface as iOS/android via Flutter's defaultTargetPlatform), skip
    // the overlay's initial requestFocus so the soft keyboard doesn't
    // cover the default Zines/Sítios/Eventos content the user just
    // revealed by tapping the "Discover the city" pill. Desktop keeps
    // autofocus because no soft keyboard pops up.
    final isMobile =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    return SearchOverlay(
      openProvider: searchOpenProvider,
      queryProvider: searchQueryProvider,
      categoryProvider: searchCategoryProvider,
      hintText: l10n.discoveryActionBarSearchHint,
      includeAllCategory: false,
      // PROD-4081 — the shared Tag row: content-sized chips that scroll instead
      // of truncating, identical to the feed's filter row and Procura's. The
      // `/yours` hub and the profile's Saved tab keep the pills (they need the
      // "All" option this row has no concept of).
      categoryRowStyle: SearchCategoryRowStyle.tags,
      // `DiscoveryScreen` pads its column by 16; the row grows back out of
      // that so it can scroll to both viewport edges.
      categoryRowBleed: 16,
      // Discovery appends the people tab — labelled "Pessoas" by the Tag row,
      // which is now that category's only name.
      categoryOrder: kSearchCategoryTagOrder,
      autoFocus: !isMobile,
      // PROD-2221 — keep the location pill visible to the right of
      // the input. The builder hands the pill its responsive budget
      // so it can drop the map-pin / truncate the city when the row
      // is narrow.
      inputTrailingBuilder: (context, trailingMaxWidth) =>
          ActionBarLocationPill(availableWidth: trailingMaxWidth),
      closeButtonKey: tourKeys.searchOverlayClose,
      categoryChipKeys: {
        DiscoverySearchCategory.zines: tourKeys.discoverTabZines,
        DiscoverySearchCategory.eventos: tourKeys.discoverTabEventos,
        DiscoverySearchCategory.sitios: tourKeys.discoverTabSitios,
      },
      // Events-only filter strip (time range + categories). Rendered by
      // SearchOverlay only when the Events tab is active.
      eventFiltersBuilder: (context) => const EventFiltersBar(),
      // Places-only filter strip (place type facets). Rendered by
      // SearchOverlay only when the Places tab is active.
      placeFiltersBuilder: (context) => const PlaceFiltersBar(),
      // Tapping the input's X on an empty field closes the overlay and
      // returns to the home feed, restoring the scroll position captured
      // when search was opened (resetForSearch).
      onCloseWhenEmpty: () {
        ref.read(searchOpenProvider.notifier).state = false;
        ref.read(searchQueryProvider.notifier).state = '';
        discoveryFeedScroll.restoreAfterSearch();
      },
    );
  }
}
