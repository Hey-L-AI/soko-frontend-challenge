import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/discovery_facets.dart';
import '../../../providers/api_provider.dart';

/// PROD-2735 — the two-layer facet catalog (`GET /discovery/facets`) backing
/// the Tema picker. autoDispose so it refreshes when the map page is left.
final discoveryFacetsProvider = FutureProvider.autoDispose<DiscoveryFacets>((
  ref,
) async {
  return ref.read(mapApiProvider).getDiscoveryFacets();
});
