import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';

/// Predefined "when" ranges for the events search filters. Deliberately a
/// small fixed set (no calendar picker). [anytime] is the cleared state.
enum EventTimeRange { anytime, today, tomorrow, weekend, thisWeek, thisMonth }

/// Visible event category facets for the Discovery filter chips (PROD-2369).
///
/// The backend owns the taxonomy: this fetches `GET /app/events/category-facets`
/// and returns only the chips meant to be rendered (`visible_in_filters`),
/// ordered by `sort_order`. The frontend never owns the category list/grouping.
/// Labels are localized client-side via [CategoryFacet.labelKey]/ARB (the
/// backend ships English-only `label` as a fallback), so this provider is
/// locale-independent. Selection sends [CategoryFacet.id]s back to the search
/// endpoint via `eventFacetFilterProvider`.
final eventCategoryFacetsProvider = FutureProvider<List<CategoryFacet>>((
  ref,
) async {
  final api = ref.watch(searchApiProvider);
  final facets = await api.getCategoryFacets();
  final visible = facets.where((f) => f.visibleInFilters).toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return visible;
});

/// Selected "when" range for the events search filters. Single-select;
/// defaults to [EventTimeRange.anytime] (no time scoping).
final eventTimeRangeProvider = StateProvider<EventTimeRange>(
  (ref) => EventTimeRange.anytime,
);

/// Selected event category facet ids for the events search filters.
/// Multi-select (OR/union logic, matching the backend `facets` semantics);
/// empty means "all categories". Holds [CategoryFacet.id] values (e.g.
/// `"music"`), which are sent verbatim to `POST /app/events/search`.
final eventFacetFilterProvider = StateProvider<Set<String>>(
  (ref) => const <String>{},
);
