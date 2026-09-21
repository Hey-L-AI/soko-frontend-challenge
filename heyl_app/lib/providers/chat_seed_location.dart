import 'dart:async';

import '../data/models/location_snapshot.dart';
import '../data/models/resolved_search_location.dart';

/// The maximum time a first chat send may wait for optional C enrichment.
///
/// The shared resolver can make remote geo calls (for example, boundary
/// enrichment). Those calls improve a new session's precision, but must never
/// make the person wait to send their first message. A timeout falls back to
/// the established device location U, then the backend default.
const chatSeedResolutionTimeout = Duration(seconds: 2);

/// Turns the single resolved Search Center (C) into a concrete point for
/// `SessionCreateRequest.initial_location`, or falls back to the device fix
/// (U) when C has no centre.
///
/// Priority:
///   1. resolved C with coordinates → its canonical centroid + hierarchy
///   2. device / IP location (U) → the raw fix
///   3. null → the backend applies its own default (e.g. Lisbon)
///
/// The resolver owns all scope branching and Google-city coordinate resolution.
/// A country-only or still-unresolvable C has no lat/lon, so it cannot seed a
/// [LocationSnapshot] and falls back to U. This keeps new chat sessions aligned
/// with the picker, shelves, and map without chat reimplementing their logic.
///
/// Pure and dependency-free so the conversion is unit-testable.
LocationSnapshot? resolveChatSeedLocation({
  required ResolvedSearchLocation? searchCenter,
  required LocationSnapshot? lastLocation,
  DateTime Function()? now,
}) {
  if (searchCenter?.hasCenter == true) {
    return LocationSnapshot(
      lat: searchCenter!.centerLat!,
      lon: searchCenter.centerLon!,
      source: LocationSource.manualMapPin,
      capturedAt: (now?.call() ?? DateTime.now()).toUtc(),
      // `label` carries the full hierarchy for area picks. City name remains
      // a useful fallback for older or minimally-resolved responses.
      city: searchCenter.label ?? searchCenter.cityName,
      country: searchCenter.countryCode,
    );
  }
  // Country-only or coordinate-less C → fall back to the device fix.
  return lastLocation;
}

/// Resolves a chat seed within the first-send latency budget.
///
/// Resolver failures and timeouts deliberately share the same U/default
/// fallback. The underlying resolver may finish later and continue to serve
/// picker and Discovery consumers, but it no longer holds session creation.
Future<LocationSnapshot?> resolveChatSeedLocationWithinBudget({
  required Future<ResolvedSearchLocation> searchCenter,
  required LocationSnapshot? lastLocation,
  Duration timeout = chatSeedResolutionTimeout,
  DateTime Function()? now,
}) async {
  try {
    final resolved = await searchCenter.timeout(timeout);
    return resolveChatSeedLocation(
      searchCenter: resolved,
      lastLocation: lastLocation,
      now: now,
    );
  } on TimeoutException {
    return resolveChatSeedLocation(
      searchCenter: null,
      lastLocation: lastLocation,
      now: now,
    );
  } catch (_) {
    return resolveChatSeedLocation(
      searchCenter: null,
      lastLocation: lastLocation,
      now: now,
    );
  }
}
