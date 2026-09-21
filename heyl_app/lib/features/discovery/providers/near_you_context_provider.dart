import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../../core/services/location_service.dart';
import '../../../data/models/models.dart';
import '../../../providers/location_provider.dart';
import '../../../providers/resolved_search_location_provider.dart';

/// Whether the Near You shelf is rendering content around the user's actual
/// location or around the city they picked.
enum NearYouMode { nearYou, around }

@immutable
class NearYouContext {
  final NearYouMode mode;
  final double latitude;
  final double longitude;

  /// Picker city name — set only when [mode] is [NearYouMode.around]. Carried
  /// for the Sentry resolution breadcrumb / request logging and the truthful
  /// city-aware shelf title.
  final String? cityName;

  /// Whether a non-centroid context can use the generic "Near you" copy.
  /// `around` contexts always use a truthful city-aware copy, even
  /// when the IP city happens to match the picker.
  final bool displayNearYou;

  /// True only when the device supplied a location accurate enough to use as
  /// the user's actual position. An explicit city pick may still resolve in
  /// [NearYouMode.around] with this true, so the location CTA must not key off
  /// [mode] alone.
  final bool hasPreciseLocation;

  /// PROD-2878 — sentinel state for the "we have location permission but the
  /// current fix is still coarse and the picker is auto-resolved" case.
  /// Shelves treat this as "hold the loading state, don't hit the feed
  /// endpoint" so users don't see venues anchored on the picker centroid
  /// (which for Lisbon auto-scope is Marquês de Pombal) while the acquisition
  /// pipeline warms up. The [latitude] / [longitude] fields carry the picker
  /// centroid so consumers that read them (breadcrumbs) still have something
  /// meaningful, but they must NOT be sent to the feed endpoint.
  final bool awaitingPreciseFix;

  const NearYouContext({
    required this.mode,
    required this.latitude,
    required this.longitude,
    this.cityName,
    required this.displayNearYou,
    this.hasPreciseLocation = false,
    this.awaitingPreciseFix = false,
  });

  /// The city-only state shown in the Discovery CTA mockup: content can be
  /// useful around the picker city, but we cannot state its exact distance
  /// from the user.
  bool get shouldShowLocationCta =>
      mode == NearYouMode.around && !hasPreciseLocation && !awaitingPreciseFix;

  /// PROD-2878 — construct the awaiting-precise-fix sentinel from the
  /// auto-resolved picker so consumers still see the picker city name /
  /// centroid for breadcrumbs, while shelves suppress the feed request.
  factory NearYouContext.awaiting({
    required GeoCity picker,
    required ({double lat, double lon}) pickerCoords,
  }) {
    return NearYouContext(
      mode: NearYouMode.around,
      latitude: pickerCoords.lat,
      longitude: pickerCoords.lon,
      cityName: picker.name,
      displayNearYou: true,
      awaitingPreciseFix: true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NearYouContext &&
          other.mode == mode &&
          other.latitude == latitude &&
          other.longitude == longitude &&
          other.cityName == cityName &&
          other.displayNearYou == displayNearYou &&
          other.hasPreciseLocation == hasPreciseLocation &&
          other.awaitingPreciseFix == awaitingPreciseFix;

  @override
  int get hashCode => Object.hash(
    mode,
    latitude,
    longitude,
    cityName,
    displayNearYou,
    hasPreciseLocation,
    awaitingPreciseFix,
  );
}

/// PROD-4083 — whether the Discovery "enable location" CTA should render.
///
/// [NearYouContext.shouldShowLocationCta] keys off fix *precision* only, so it
/// stays true for a user whose OS permission is granted but whose fix is merely
/// coarse (accuracy > 500 m). That user saw the "Location sharing disabled →
/// Enable location" card even though the arrow was active — and the button
/// (`requestPermissionOnly`) can't re-prompt a granted permission, so it was a
/// dead end with false copy.
///
/// Gate on permission too: only surface the CTA when sharing GPS would actually
/// change something — permission not granted, or an IP-only fallback. When the
/// OS is already handing us a device fix (even a coarse one), suppress it.
/// Mirrors chat's `_shouldShowLocationSuggestion` (chat_screen.dart).
bool shouldShowNearYouLocationCta({
  required NearYouContext? context,
  required LocationState location,
}) {
  if (context?.shouldShowLocationCta != true) return false;
  final sharingDeviceFix =
      location.permissionStatus == LocationPermissionStatus.granted &&
      !location.isIpFallback;
  return !sharingDeviceFix;
}

/// Threshold below which the picker city and the user's GPS coord are
/// treated as the same place. Inside the radius the shelf renders as
/// "Near You" against the user's coords; outside it, "Around `<city>`"
/// against the picker centroid.
const double kNearYouRadiusKm = 25.0;

/// PROD-2884: minimum fix accuracy (metres) for a snapshot to anchor Near-You
/// distance ranking. A coarse fix — e.g. the browser's first WiFi/IP-based
/// geolocation sample, which in Lisbon lands at Marquês de Pombal and is
/// reported as `device_gps` with a large `accuracy_m` — must NOT drive the
/// feed, or the backend faithfully centres it on a city centroid the user
/// isn't at. Mirrors `LocationState`'s 500 m "approximate" threshold: if we'd
/// badge the fix "Approx.", we don't rank on it. `ip_approx` (which carries no
/// accuracy) is always imprecise (PROD-2055).
///
/// Sourced from the app-wide [kLocationApproxAccuracyThresholdMeters] so all
/// three layers (LocationState, the acquisition state machine, Near-You) can
/// never drift apart.
const double kNearYouMinAccuracyM = kLocationApproxAccuracyThresholdMeters;

/// Whether [s] is too imprecise to anchor Near-You distance ranking. Coarse
/// fixes are excluded from *ranking* but still passed (as `rawActual`) to the
/// resolution breadcrumb so Sentry keeps reporting `actual_source` /
/// `actual_accuracy_m` for affected users.
bool _isImpreciseForNearYou(LocationSnapshot? s) {
  if (s == null) return false;
  // PROD-4486: IP, inferred memory_fact, backend-only and unknown sources carry
  // no accuracy and can never anchor Near-You ranking.
  if (s.source.isImpreciseSource) return true;
  final acc = s.accuracyM;
  return acc != null && acc > kNearYouMinAccuracyM;
}

/// PROD-2878 — how long the resolver keeps the shelf in the awaiting-
/// precise-fix state before giving up and falling back to the picker
/// centroid. Matches the "user grants permission → GPS chip warms up →
/// first precise poll" wall-clock envelope on iOS Safari/Arc (typically
/// ≤ 6-10 s of coarse WiFi fixes followed by a precise fix, sometimes
/// longer). After the timeout we surface *something* — the picker centroid,
/// even if it's the Marquês de Pombal misfire — rather than an indefinite
/// skeleton, per the design decision on PROD-2878.
const Duration kNearYouAwaitingPreciseFixTimeout = Duration(seconds: 15);

/// PROD-2878 — timestamp of when we first observed the "coarse fix + auto
/// picker" state for the current session. `null` means we're not currently
/// waiting. Cleared whenever we exit the awaiting state (precise fix
/// arrives, picker changes, etc.) so a *new* coarse-lock later in the
/// session gets its own 15-s budget rather than reusing the earlier one.
final _nearYouAwaitingSinceProvider = StateProvider<DateTime?>((_) => null);

/// PROD-2878 — reset the awaiting-precise-fix stamp if any is set. Called from
/// every resolver path that isn't returning an awaiting sentinel, so a stale
/// deadline from an earlier re-run can't short-circuit a subsequent
/// coarse-lock into the immediate picker-centroid fallback.
void _clearAwaitingStamp(Ref ref) {
  if (ref.read(_nearYouAwaitingSinceProvider) != null) {
    ref.read(_nearYouAwaitingSinceProvider.notifier).state = null;
  }
}

/// Derived view over [locationProvider] — exposes only the current
/// [LocationSnapshot] so tests can stub the user's location without
/// constructing a full [LocationNotifier]. Production behaviour is
/// unchanged: the provider rebuilds whenever the underlying location
/// state changes.
final currentLocationSnapshotProvider = Provider<LocationSnapshot?>(
  (ref) => ref.watch(locationProvider).lastLocation,
);

/// Resolved input for `/feed/near-you` — coords + mode + display city name.
///
/// Returns null when neither the picker nor GPS has produced a coord
/// (cold start, location denied, no IP signal); the shelf hides.
///
/// In [NearYouMode.nearYou] the coords are the user's actual location.
/// In [NearYouMode.around] they are the picker centroid; Google-sourced
/// picker picks are resolved on demand via `/geo/cities/{id}` when their
/// lat/lon haven't been populated yet.
final nearYouContextProvider = FutureProvider<NearYouContext?>((ref) async {
  final searchLocation = await ref.watch(resolvedSearchLocationProvider.future);
  final picker = searchLocation.city;
  final pickerIsAuto = picker == null ? null : !searchLocation.isExplicit;
  final pickerCoords = searchLocation.center;
  final rawActual = ref.watch(currentLocationSnapshotProvider);
  // PROD-2055: `ip_approx` snapshots sit at the IP-detected city centroid and
  // must not drive Near-You distance sorting. PROD-2884: extend that to any
  // coarse fix (accuracy > `kNearYouMinAccuracyM`) — a WiFi/IP-based first GPS
  // sample lands at Marquês de Pombal and would otherwise anchor the feed on
  // central Lisbon. Both are treated as "no precise location" for ranking while
  // still passing the raw snapshot to [_logResolution] so the Sentry breadcrumb
  // keeps reporting `actual_source` / `actual_accuracy_m` for affected users.
  final actual = _isImpreciseForNearYou(rawActual) ? null : rawActual;

  // PROD-2878 — distinguish "coarse GPS fix, more may come" from a source with
  // no acquisition to upgrade. Only a real on-device fix is worth waiting on.
  // Applied below when `actual == null && picker != null` to gate a short
  // loading state instead of falling straight through to the picker-centroid
  // fallback (which, for Lisbon auto-scope, is Marquês de Pombal — the exact
  // wrong spot the reporter saw). Cleared to `false` when no signal is present.
  //
  // PROD-4486: gate on [isDeviceFix], not `!= ip_approx`. An inferred
  // `memory_fact` (or migration/whatsapp/unknown) is not a warming-up GPS chip,
  // so the shelf must fall back immediately rather than wait 15 s for a precise
  // fix that will never arrive.
  final isCoarseButAwaitable =
      rawActual != null &&
      rawActual.source.isDeviceFix &&
      _isImpreciseForNearYou(rawActual);

  if (pickerCoords == null && actual == null) {
    _clearAwaitingStamp(ref);
    _logResolution(
      resolved: null,
      picker: null,
      actual: rawActual,
      distKm: null,
    );
    return null;
  }

  if (pickerCoords == null) {
    _clearAwaitingStamp(ref);
    final resolved = NearYouContext(
      mode: NearYouMode.nearYou,
      latitude: actual!.lat,
      longitude: actual.lon,
      displayNearYou: true,
      hasPreciseLocation: true,
    );
    _logResolution(
      resolved: resolved,
      picker: null,
      actual: rawActual,
      distKm: null,
    );
    return resolved;
  }

  if (actual == null) {
    // PROD-2878 — before falling back to the picker centroid, check if we're
    // waiting on a precise fix that may still arrive. Only relevant when the
    // picker was auto-resolved (an explicit user pick means "show me this
    // city's centroid — Marquês is what I asked for"); auto-picker
    // Lisboa + coarse GPS = the reporter's scenario, and we hide behind a
    // short loading state instead of showing wrong venues.
    if (isCoarseButAwaitable && pickerIsAuto == true && picker != null) {
      final awaitingSinceNotifier = ref.read(
        _nearYouAwaitingSinceProvider.notifier,
      );
      var awaitingSince = ref.read(_nearYouAwaitingSinceProvider);
      awaitingSince ??= DateTime.now();
      awaitingSinceNotifier.state = awaitingSince;
      final elapsed = DateTime.now().difference(awaitingSince);
      final remaining = kNearYouAwaitingPreciseFixTimeout - elapsed;
      if (!remaining.isNegative) {
        // Schedule a re-eval so we transition out of the awaiting state
        // even if no new location snapshot arrives before the deadline. The
        // resolver re-runs and falls through to the picker-centroid path
        // below once the timer fires.
        final timer = Timer(remaining, () {
          // ignore: invalid_use_of_protected_member — provider self-invalidation
          // is the intended mechanism to re-evaluate on a wall-clock deadline.
          ref.invalidateSelf();
        });
        ref.onDispose(timer.cancel);
        final resolved = NearYouContext.awaiting(
          picker: picker,
          pickerCoords: pickerCoords,
        );
        _logResolution(
          resolved: resolved,
          picker: picker,
          pickerCoords: pickerCoords,
          actual: rawActual,
          distKm: null,
        );
        return resolved;
      }
      // Timeout expired — clear the timestamp so a *later* re-lock in the
      // same session gets a fresh 15-s budget, then fall through to the
      // existing picker-centroid fallback below.
      awaitingSinceNotifier.state = null;
    } else {
      // Not in the awaiting-eligible state — reset any prior stamp so a
      // subsequent coarse-lock later in the session doesn't reuse an old
      // deadline that's already elapsed.
      _clearAwaitingStamp(ref);
    }

    // Ranking ignores ip_approx, but the title should still read "Near you"
    // when the IP-detected location is the picked city itself.
    final ipAtPicker =
        rawActual != null &&
        rawActual.source == LocationSource.ipApprox &&
        _haversineKm(
              pickerCoords.lat,
              pickerCoords.lon,
              rawActual.lat,
              rawActual.lon,
            ) <=
            kNearYouRadiusKm;
    final resolved = NearYouContext(
      mode: NearYouMode.around,
      latitude: pickerCoords.lat,
      longitude: pickerCoords.lon,
      cityName: picker?.name ?? searchLocation.cityName,
      displayNearYou: ipAtPicker,
    );
    _logResolution(
      resolved: resolved,
      picker: picker,
      pickerCoords: pickerCoords,
      actual: rawActual,
      distKm: null,
    );
    return resolved;
  }

  // PROD-2878 — a precise fix (or an ipApprox with picker present, or no
  // picker) means we're out of the awaiting state. Clear any prior stamp.
  _clearAwaitingStamp(ref);

  final distKm = _haversineKm(
    pickerCoords.lat,
    pickerCoords.lon,
    actual.lat,
    actual.lon,
  );
  if (distKm <= kNearYouRadiusKm) {
    // Inside the "same place" radius. For an *auto-resolved* location we snap
    // to the user's precise GPS coord ("you're basically here — rank from where
    // you actually are"). But an *explicit* pick (map/city) is a deliberate
    // "search here" and must anchor on the pick even when it's only a few km
    // from the live fix — PROD-3320: picking Estrela while standing in Carnide
    // (~5 km) silently fell back to the GPS coord and showed Carnide venues
    // under a "Perto de Estrela" header. A map-pin still counts as "near you",
    // so `displayNearYou` stays true and the shelf keeps titling "Perto de
    // <pick>"; only the ranking coords change to the picked centroid.
    final resolved = searchLocation.isExplicit
        ? NearYouContext(
            mode: NearYouMode.around,
            latitude: pickerCoords.lat,
            longitude: pickerCoords.lon,
            cityName: picker?.name ?? searchLocation.cityName,
            displayNearYou: true,
            hasPreciseLocation: true,
          )
        : NearYouContext(
            mode: NearYouMode.nearYou,
            latitude: actual.lat,
            longitude: actual.lon,
            displayNearYou: true,
            hasPreciseLocation: true,
          );
    _logResolution(
      resolved: resolved,
      picker: picker,
      pickerCoords: pickerCoords,
      actual: rawActual,
      distKm: distKm,
    );
    return resolved;
  }
  final resolved = NearYouContext(
    mode: NearYouMode.around,
    latitude: pickerCoords.lat,
    longitude: pickerCoords.lon,
    cityName: picker?.name ?? searchLocation.cityName,
    displayNearYou: false,
    hasPreciseLocation: true,
  );
  _logResolution(
    resolved: resolved,
    picker: picker,
    pickerCoords: pickerCoords,
    actual: rawActual,
    distKm: distKm,
  );
  return resolved;
});

/// Emits a Sentry breadcrumb capturing how the Near-You search center was
/// resolved — picker vs GPS, the actual coords sent, and the source of the
/// user's location snapshot (GPS, IP-approx, etc.). PROD-2052: lets us
/// disambiguate frontend center bugs from backend distance bugs in prod.
void _logResolution({
  required NearYouContext? resolved,
  required GeoCity? picker,
  ({double lat, double lon})? pickerCoords,
  required LocationSnapshot? actual,
  required double? distKm,
}) {
  final data = <String, dynamic>{
    'resolved_mode': resolved?.mode.name,
    'resolved_latitude': resolved?.latitude,
    'resolved_longitude': resolved?.longitude,
    'resolved_city_name': resolved?.cityName,
    'resolved_display_near_you': resolved?.displayNearYou,
    'resolved_has_precise_location': resolved?.hasPreciseLocation,
    // PROD-2878 — surfaced so we can watch how often shelves sit in the
    // loading state waiting for a precise fix, and how often the 15-s
    // timeout falls through to the picker-centroid fallback anyway.
    'resolved_awaiting_precise_fix': resolved?.awaitingPreciseFix,
    'picker_present': picker != null,
    'picker_name': picker?.name,
    'picker_is_google_sourced': picker?.isGoogleSourced,
    'picker_lat': pickerCoords?.lat,
    'picker_lon': pickerCoords?.lon,
    'actual_present': actual != null,
    'actual_lat': actual?.lat,
    'actual_lon': actual?.lon,
    'actual_source': actual?.source.toJson(),
    'actual_accuracy_m': actual?.accuracyM,
    'picker_to_actual_km': distKm,
    'near_you_radius_km': kNearYouRadiusKm,
  };
  final message = resolved == null
      ? 'Near-You context: hidden (no picker, no location)'
      : resolved.awaitingPreciseFix
      ? 'Near-You context: awaiting precise fix (auto picker=${resolved.cityName})'
      : 'Near-You context resolved (mode=${resolved.mode.name})';
  debugPrint('[NearYouContext] $message $data');
  Sentry.addBreadcrumb(
    Breadcrumb(
      message: message,
      category: 'discovery.near_you',
      type: 'info',
      data: data,
    ),
  );
}

/// Emits a Sentry breadcrumb at the moment a Near-You shelf fires its
/// `/feed/near-you/*` request — proves the coords carried by [NearYouContext]
/// reach the wire unchanged (PROD-2052). Pair with the resolution breadcrumb
/// to detect any drift between decision and dispatch.
void logNearYouRequest({
  required String endpoint,
  required NearYouContext context,
  required int limit,
  required int offset,
}) {
  final data = <String, dynamic>{
    'endpoint': endpoint,
    'mode': context.mode.name,
    'latitude': context.latitude,
    'longitude': context.longitude,
    'city_name': context.cityName,
    'limit': limit,
    'offset': offset,
  };
  debugPrint('[NearYouRequest] GET $endpoint $data');
  Sentry.addBreadcrumb(
    Breadcrumb(
      message: 'GET $endpoint',
      category: 'discovery.near_you',
      type: 'http',
      data: data,
    ),
  );
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
