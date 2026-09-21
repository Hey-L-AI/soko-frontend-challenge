import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// Compatibility projection of the canonical resolved search location.
/// New consumers should read [resolvedSearchLocationProvider] directly.
final discoveryCityProvider = FutureProvider<GeoCity?>((ref) async {
  return (await ref.watch(resolvedSearchLocationProvider.future)).city;
});

/// Whether the [discoveryCityProvider]-resolved city was picked automatically
/// (profile / IP cascade) rather than explicitly chosen by the user through
/// the picker. Mirrors the cascade in [discoveryCityProvider]; `null` when
/// there is no resolved city at all.
///
/// PROD-2878 — the Near-You resolver uses this to distinguish "user
/// explicitly picked Lisboa, so anchoring on its centroid is intentional"
/// from "we guessed Lisboa from the user's profile, but their coarse GPS is
/// still warming up — hold off and show a loading state until either a
/// precise fix arrives or a short timeout expires". Explicit picks skip the
/// wait; auto picks own it.
final discoveryCityIsAutoProvider = FutureProvider<bool?>((ref) async {
  final resolved = await ref.watch(resolvedSearchLocationProvider.future);
  if (resolved.city == null) return null;
  return !resolved.isExplicit;
});

/// Resolves the picker city to a `city_id` for endpoints that require it
/// (`/feed/highlighted`, `/feed/venues-with-events`). Returns null when the
/// picker has no city OR when the picker holds a Google `place_id` — those
/// endpoints reject non-local UUIDs, so the shelf should hide instead of
/// firing a guaranteed-400.
final discoveryCityIdProvider = FutureProvider<String?>((ref) async {
  return (await ref.watch(resolvedSearchLocationProvider.future)).cityId;
});

/// Lat/lon of the resolved picker city. For Google-sourced picks that
/// haven't been resolved yet, fires `/geo/cities/{id}` on demand. Returns
/// null when the picker has no city, or when resolution fails / yields
/// no coordinates.
///
/// Shared by all coord-driven shelves (Near You, list shelves) so the
/// resolve call happens at most once per picker change.
final pickerCityCoordsProvider = FutureProvider<({double lat, double lon})?>((
  ref,
) async {
  final resolved = await ref.watch(resolvedSearchLocationProvider.future);
  if (!resolved.hasCenter) return null;
  return (lat: resolved.centerLat!, lon: resolved.centerLon!);
});
