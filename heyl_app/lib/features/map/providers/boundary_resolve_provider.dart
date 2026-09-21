import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';

/// Resolves a tapped map coordinate to its containing neighborhood boundary
/// via `GET /geo/boundary/at` (PROD-3109). Returns null when no boundary
/// contains the point (ocean / gap / non-PT) — the picker then falls back to a
/// plain point + default radius.
///
/// **Not `autoDispose`.** The picker resolves imperatively with
/// `ref.read(boundaryResolveProvider(arg).future)`, which retains no listener —
/// an autoDispose entry would be torn down the instant `read` returns, firing
/// `onDispose` and cancelling the in-flight request before it resolves (every
/// tap would then silently fall back to a point). Latest-tap-wins is enforced
/// by the picker's own tap-sequence guard, not by request cancellation. Family
/// entries are keyed by the exact tapped coordinate, so they don't collide
/// across taps; the handful per session is negligible.
final boundaryResolveProvider =
    FutureProvider.family<GeoBoundary?, ({double lat, double lng})>((
      ref,
      arg,
    ) async {
      final api = ref.watch(geoApiProvider);
      return api.resolveBoundaryAt(lat: arg.lat, lng: arg.lng);
    });
