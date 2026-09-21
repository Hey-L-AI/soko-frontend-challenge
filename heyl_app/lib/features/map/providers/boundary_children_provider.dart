import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';

/// Fetches a city-level boundary's child neighbourhoods (freguesias) via
/// `GET /geo/boundary/{id}/children`, for the picker's tap-to-drill layer.
/// Returns an empty list for a leaf boundary or a country with no finer tier.
///
/// **Not `autoDispose`** — mirrors [boundaryResolveProvider]: the picker reads
/// it imperatively (`ref.read(boundaryChildrenProvider(arg).future)`), which
/// retains no listener, so an autoDispose entry would tear down and cancel the
/// in-flight request the instant `read` returns. Keeping it alive also caches
/// each city's children so re-entering the same city doesn't refetch. Family
/// entries are keyed by (id, countryCode, parentName) with record value
/// equality — one entry per city.
final boundaryChildrenProvider =
    FutureProvider.family<
      List<GeoBoundary>,
      ({String id, String countryCode, String? parentName, String locale})
    >((ref, arg) async {
      final api = ref.watch(geoApiProvider);
      return api.boundaryChildren(
        id: arg.id,
        countryCode: arg.countryCode,
        parentName: arg.parentName,
        locale: arg.locale,
      );
    });
