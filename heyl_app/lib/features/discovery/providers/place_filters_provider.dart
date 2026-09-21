import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';

/// Visible place type facets for the Discovery Places filter chips
/// (PROD-2369).
///
/// The backend owns the venue type taxonomy: this fetches
/// `GET /app/places/type-facets`, returns only chips meant to be rendered, and
/// orders them by `sort_order`. The frontend sends selected [PlaceTypeFacet.id]
/// values back to place search as `facets`.
final placeTypeFacetsProvider = FutureProvider<List<PlaceTypeFacet>>((
  ref,
) async {
  final api = ref.watch(searchApiProvider);
  final facets = await api.getPlaceTypeFacets();
  final visible = facets.where((f) => f.visibleInFilters).toList()
    ..sort(
      (a, b) => (a.sortOrder ?? 1 << 30).compareTo(b.sortOrder ?? 1 << 30),
    );
  return visible;
});

/// Selected place type facet ids for Discovery Places search. Multi-select
/// OR/union logic, matching backend `facets` semantics; empty means all types.
final placeTypeFacetFilterProvider = StateProvider<Set<String>>(
  (ref) => const <String>{},
);
