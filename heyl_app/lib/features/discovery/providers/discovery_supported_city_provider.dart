import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/resolved_search_location_provider.dart';

/// True when the user's currently-effective Discovery scope resolves to an
/// "open" city — one the backend marks as having curated content depth via its
/// per-city `discovery_enabled` flag, surfaced as `GeoCity.isOpen` (PROD-3675).
///
/// Drives whether `DiscoveryShell` renders the new-city expectation-setting
/// hero between the scallop and the action bar.
///
/// Returns `true` (supported → no hero) whenever openness is **unknown**:
///   - the scope is still resolving (cold start, auto-detect pending), so the
///     hero doesn't flash before we know the city; or
///   - the scope is country-only (no city); or
///   - the resolved city was seeded from a boundary/area resolve and so carries
///     no `is_open` flag (`GeoCity.isOpen == null`).
/// The hero appears only on an authoritative `is_open == false`.
final isCurrentCitySupportedProvider = Provider<bool>((ref) {
  final resolved = ref.watch(resolvedSearchLocationProvider).valueOrNull;
  return resolved?.city?.isOpen ?? true;
});
