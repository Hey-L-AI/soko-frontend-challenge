import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/ip_geolocation_service.dart';
import '../core/services/location_service.dart';
import '../core/services/storage_service.dart';
import '../core/services/unified_analytics_service.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import '../data/models/location_snapshot.dart';
import '../data/repositories/country_repository.dart';
import 'api_provider.dart';
import 'auth_provider.dart';
import 'detected_country_provider.dart';
import 'location_consent_state_provider.dart';
import 'preferences_provider.dart';

/// Accuracy ceiling (metres) at/above which a location fix is treated as
/// "approximate" rather than "precise" everywhere in the app. Single source of
/// truth: mirrored by [LocationState.isApproximate], the acquisition state
/// machine's precise-fix check, and Near-You's `kNearYouMinAccuracyM`. A
/// device/network fix reporting accuracy worse than this (e.g. WiFi/IP-based
/// first GPS, PROD-2055/PROD-2878) must not be trusted as a precise location.
const double kLocationApproxAccuracyThresholdMeters = 500.0;

/// Location sharing mode
enum LocationSharingMode {
  /// Location not being shared
  disabled,

  /// One-time share completed
  once,

  /// Continuous foreground sharing
  always,
}

/// State for location sharing
class LocationState {
  final bool isSharing;
  final bool isInitializing;
  final LocationSnapshot? lastLocation;
  final String? error;
  final LocationPermissionStatus? permissionStatus;
  final LocationSharingMode sharingMode;
  final DateTime? lastUpdateTime;

  /// ISO-3166-1 alpha-2 country code resolved by the backend from the last
  /// GPS update (from [LocationUpdateResponse.country]). Null until the first
  /// successful backend roundtrip or when resolution failed. Used by the
  /// add-to-list scope picker for pre-selection (PROD-1326).
  final String? resolvedCountryCode;

  /// City name resolved by the backend from the last GPS update. Null when
  /// the backend couldn't resolve (e.g. out-of-range coords) or before the
  /// first successful update.
  final String? resolvedCityName;

  /// Neighbourhood / parish name resolved by the backend from the last GPS
  /// update (`UserLocationOut.neighborhood`, from its canonical admin-boundary
  /// reverse geocode). Finer than [resolvedCityName]; null when the boundary
  /// data has no parish for the coords (thinner outside PT/BR launch markets).
  /// Surfaced by the admin location-debug panel; consumers fall back to city.
  final String? resolvedNeighborhood;

  const LocationState({
    this.isSharing = false,
    this.isInitializing = false,
    this.lastLocation,
    this.error,
    this.permissionStatus,
    this.sharingMode = LocationSharingMode.disabled,
    this.lastUpdateTime,
    this.resolvedCountryCode,
    this.resolvedCityName,
    this.resolvedNeighborhood,
  });

  LocationState copyWith({
    bool? isSharing,
    bool? isInitializing,
    LocationSnapshot? lastLocation,
    String? error,
    LocationPermissionStatus? permissionStatus,
    LocationSharingMode? sharingMode,
    DateTime? lastUpdateTime,
    String? resolvedCountryCode,
    String? resolvedCityName,
    String? resolvedNeighborhood,
    bool clearError = false,
    bool clearLocation = false,
    bool clearResolvedAdmin = false,
  }) {
    return LocationState(
      isSharing: isSharing ?? this.isSharing,
      isInitializing: isInitializing ?? this.isInitializing,
      lastLocation: clearLocation ? null : (lastLocation ?? this.lastLocation),
      error: clearError ? null : (error ?? this.error),
      permissionStatus: permissionStatus ?? this.permissionStatus,
      sharingMode: sharingMode ?? this.sharingMode,
      lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
      resolvedCountryCode: clearResolvedAdmin
          ? null
          : (resolvedCountryCode ?? this.resolvedCountryCode),
      resolvedCityName: clearResolvedAdmin
          ? null
          : (resolvedCityName ?? this.resolvedCityName),
      resolvedNeighborhood: clearResolvedAdmin
          ? null
          : (resolvedNeighborhood ?? this.resolvedNeighborhood),
    );
  }

  /// Whether we have a location to display
  bool get hasLocation => lastLocation != null;

  /// Whether location sharing is active (once or always)
  bool get isLocationEnabled => sharingMode != LocationSharingMode.disabled;

  /// Accuracy threshold: above this, location is considered approximate
  static const double _approximateThresholdMeters =
      kLocationApproxAccuracyThresholdMeters;

  /// Whether current location is approximate (imprecise source — IP / inferred
  /// `memory_fact` / backend-only / unknown — or poor GPS accuracy). PROD-4486:
  /// keys on [LocationSource.isImpreciseSource], not `ip_approx` alone.
  bool get isApproximate =>
      lastLocation != null &&
      (lastLocation!.source.isImpreciseSource ||
          (lastLocation!.accuracyM != null &&
              lastLocation!.accuracyM! > _approximateThresholdMeters));

  /// Whether current location is precise (GPS-based with good accuracy)
  bool get isPrecise => lastLocation != null && !isApproximate;

  /// Whether we're on a non-device fallback (user hasn't granted GPS, disabled
  /// sharing, or the only fix is an imprecise source). PROD-4486: fail-closed —
  /// any imprecise source (IP, inferred `memory_fact`, backend-only, unknown)
  /// counts, so the ~9 `!isIpFallback` "we have a real device fix" call sites
  /// (blue dot, map seed, enable-location CTA) never treat an inferred centroid
  /// as GPS. An explicit `manual_map_pin` is NOT imprecise and keeps its
  /// existing authoritative treatment.
  bool get isIpFallback =>
      lastLocation != null &&
      (lastLocation!.source.isImpreciseSource ||
          sharingMode == LocationSharingMode.disabled);

  /// Whether GPS is active but accuracy is poor (not IP fallback)
  bool get isGpsApproximate => isApproximate && !isIpFallback;
}

/// Notifier for location state
///
/// Implements smart location tracking with:
/// - Initial stabilization (verifies GPS accuracy on startup)
/// - Movement detection (only updates when user moves significantly)
/// - Separate thresholds for UI updates vs backend updates
/// - Immediate refresh on app resume
///
/// See docs/features/user-location.md for detailed documentation.
class LocationNotifier extends StateNotifier<LocationState>
    with WidgetsBindingObserver {
  final LocationService _locationService;
  final ILocationApi _locationApi;
  final UnifiedAnalyticsService _analytics;
  final StorageService _storageService;
  final IpGeolocationService _ipGeolocationService;

  Timer? _updateTimer;

  // ============ Configuration Constants ============
  // See docs/features/user-location.md for explanation of these values

  /// How often to poll for location updates while app is active
  static const _pollInterval = Duration(seconds: 20);

  /// Maximum cache age for using cached location for fly-in animation
  /// Older cache will wait for fresh GPS before showing map
  static const _maxCacheAgeForFlyIn = Duration(minutes: 10);

  /// Duration to block UI updates during fly-in animation (timer-based approach)
  /// Covers flyTo 4s + easeTo 4s + 500ms delay + buffer
  static const _animationBlockDuration = Duration(milliseconds: 9000);

  /// Delay between stabilization checks
  static const _stabilizationDelay = Duration(seconds: 3);

  /// Maximum number of stabilization attempts
  static const _maxStabilizationAttempts = 3;

  /// GPS is considered "stable" if consecutive readings are within this radius
  static const _stabilizationRadiusMeters = 50.0;

  /// PROD-2878 — accuracy ceiling (metres) below which a fix is trusted as
  /// "precise" for the acquisition state machine. Mirrors
  /// [LocationState._approximateThresholdMeters] and
  /// `near_you_context_provider.dart` `kNearYouMinAccuracyM` so all three
  /// layers agree on what "approximate" means. Guards two paths that used to
  /// let a coarse WiFi/IP-based first fix (Lisbon → Marquês de Pombal centroid,
  /// wrapped as `device_gps` with `accuracy_m ≈ 5000 m`) win permanently:
  /// (a) `_acquireStabilizedLocation` no longer declares stabilization on
  /// coarse-coarse convergence, and (b) `_updateLocation` allows a precise fix
  /// to displace a cached coarse fix even below the 30 m movement gate.
  static const _preciseAccuracyThresholdMeters =
      kLocationApproxAccuracyThresholdMeters;

  /// Minimum movement required to update the UI (prevents map jitter)
  static const _minMovementForUiUpdateMeters = 30.0;

  /// Minimum movement required to send update to backend (saves bandwidth)
  static const _minMovementForBackendMeters = 50.0;

  /// Maximum time before sending a backend heartbeat even without movement.
  /// Keeps the backend's captured_at timestamp fresh for the chatbot.
  static const _maxBackendStaleness = Duration(minutes: 10);

  // ============ State Tracking ============

  /// Last location sent to backend (may differ from UI location)
  LocationSnapshot? _lastBackendLocation;

  /// Admin-only diagnostics — the last snapshot we believe the backend has
  /// (the value the AI resolves "near me" against for authenticated users).
  /// Exposed read-only so the admin location-debug panel can surface drift
  /// between the live device fix ([LocationState.lastLocation]) and what the
  /// server last received. Not persisted; seeded from the server read-back
  /// ([_readBackServerLocation]) on boot/resume, then advanced by each PUT.
  LocationSnapshot? get lastBackendLocation => _lastBackendLocation;

  /// Time of last SUCCESSFUL backend API call. Drives the 5-second explicit
  /// share gate; distinct from [_lastBackendAttemptTime].
  DateTime? _lastApiCallTime;

  /// Time of the last backend PUT *attempt* (stamped before the call, so a
  /// FAILED attempt still counts). The staleness heartbeat is computed from
  /// this — not [_lastApiCallTime] — so a cold start whose first PUT failed
  /// still re-tries at the heartbeat cadence instead of (a) never, because
  /// `_lastApiCallTime` stayed null, or (b) every 20 s poll. (Codex Phase 2.)
  DateTime? _lastBackendAttemptTime;

  /// Injectable clock for backend-timing decisions (staleness, dedup, the 5 s
  /// share gate). Defaults to [DateTime.now]; tests pass a fake clock to
  /// exercise the 10-minute heartbeat deterministically.
  final DateTime Function() _now;

  /// Monotonic counter bumped after every SUCCESSFUL backend PUT (i.e. once
  /// `_lastBackendLocation` has actually advanced — never on a mere attempt).
  /// The boot/resume server read-back captures this before its `await` and only
  /// seeds `_lastBackendLocation` if it hasn't changed — so a slow
  /// `GET /me/location` can't clobber a fresher local PUT that landed while it
  /// was in flight. Bumping on success only means a FAILED PUT leaves the
  /// server read-back as the best available truth.
  int _backendSyncSeq = 0;

  /// PROD-3580 — bumped by [resetAccountScopedBackendState]. Every authenticated
  /// PUT captures it before its `await` and drops its post-await bookkeeping if
  /// it moved, so a request issued under account A cannot re-establish A's
  /// backend belief (and A's dedup suppression) after B has taken over. The
  /// epoch-guard pattern from
  /// `docs/learnings/account-switch-stale-inflight-write-needs-epoch-guard.md`.
  int _accountEpoch = 0;

  /// Monotonic id for each `_readBackServerLocation()` call. Boot and resume
  /// both fire the read-back unawaited, so two `GET /me/location`s can overlap;
  /// a result is dropped if a NEWER read-back has already applied
  /// ([_readBackAppliedSeq]), so an out-of-order older GET can't overwrite a
  /// fresher read-back — while a newer read-back that fails/returns null does
  /// NOT suppress an older successful one ("newest successful wins").
  int _readBackSeq = 0;
  int _readBackAppliedSeq = 0;

  /// PROD-2303 — dedup key for `_tryUpdateBackend` so the same logical fix
  /// arriving twice (e.g. boot fallback + a Settings-toggle re-evaluation in
  /// the same minute) doesn't burn a duplicate PUT. Key is
  /// `(source, lat·round(3), lon·round(3))` paired with the timestamp of
  /// the last successful PUT. 3-decimal rounding ≈ 111m precision so GPS
  /// jitter doesn't bypass; 5-minute window matches `_maxBackendStaleness`.
  ({LocationSource source, double latR3, double lonR3, DateTime ts})?
  _lastPutKey;
  static const Duration _putDedupWindow = Duration(minutes: 5);

  /// How long [requestPermissionOnly] will wait for the `PUT /me/location` that
  /// names the fix when `awaitResolvedAdmin` is set. Deliberately far below the
  /// client's 20 s `ApiConstants.defaultTimeout`: the only caller is a tap in
  /// onboarding, where a coarser label beats a long spinner. The PUT is not
  /// cancelled when this elapses.
  static const Duration _resolvedAdminWaitBudget = Duration(seconds: 3);

  /// Dedup key for the tagged `current` slot specifically — stamped ONLY when
  /// `_updateLocation` actually writes `updateTaggedLocation('current', …)`,
  /// never by the untagged-only `_tryUpdateBackend`. The auth-transition force
  /// sync dedups on THIS, not `_lastPutKey`: a recent untagged-only PUT (e.g.
  /// `requestPermissionOnly`) must NOT suppress the forced tagged-current write
  /// the sync exists to make.
  ({LocationSource source, double latR3, double lonR3, DateTime ts})?
  _lastTaggedSyncKey;

  /// Whether we're currently in the middle of a location fetch
  bool _isFetching = false;

  /// Whether we've already logged accuracy status this session
  bool _hasLoggedAccuracy = false;

  /// Pending location stored during fly-in animation (applied after animation completes)
  LocationSnapshot? _pendingLocation;

  /// Whether a forced backend update was requested during animation blocking
  bool _pendingForceBackendUpdate = false;

  /// Whether fly-in animation is in progress (blocks UI updates during animation)
  bool _animationInProgress = false;

  /// Timer that ends the animation blocking period
  Timer? _animationBlockTimer;

  LocationNotifier(
    this._locationService,
    this._locationApi,
    this._analytics,
    this._storageService,
    this._ipGeolocationService, {
    bool Function()? isAuthenticatedFn,
    bool Function()? isConsentResolvedFn,
    bool Function()? hasLocationConsentFn,
    DateTime Function()? nowFn,
  }) : _isAuthenticatedFn = isAuthenticatedFn ?? (() => true),
       _isConsentResolvedFn = isConsentResolvedFn,
       _hasLocationConsentFn = hasLocationConsentFn ?? (() => false),
       _now = nowFn ?? DateTime.now,
       super(const LocationState()) {
    WidgetsBinding.instance.addObserver(this);
    // Check permission on initialization
    _initializeIfPermitted();
  }

  /// PROD-2303 step 5 — Reads `locationConsentResolvedProvider` at PUT time
  /// so we can defer `/me/location` writes while preferences are still
  /// loading. Optional for backward-compat with existing test fixtures:
  /// when `null`, the gate is open (legacy behavior). The provider wires it
  /// to `() => ref.read(locationConsentResolvedProvider)`.
  final bool Function()? _isConsentResolvedFn;

  /// PROD-3123 — whether the user has opted into location (server
  /// `location_opt_in == true`). Gates the WEB-only GPS probe on boot/resume:
  /// on web the Permissions API is unreliable, so we attempt `getCurrentPosition`
  /// even when `checkPermission()` reports non-granted — but ONLY for a user who
  /// already opted in (they went through the app's location ask, so the browser
  /// is already granted and no unsolicited prompt fires). Defaults to `false`
  /// (conservative: no probe/prompt) when not injected. Wired by the factory to
  /// `() => ref.read(preferencesProvider).preferences?.locationOptIn == true`.
  final bool Function() _hasLocationConsentFn;

  /// PROD-2303 step 5 — set whenever `_tryUpdateBackend` short-circuited on
  /// the consent gate. Cleared on every successful PUT. The
  /// `ref.listen(locationConsentStateProvider)` wired in
  /// [locationProvider]'s factory checks this on Unknown → known transitions
  /// and flushes the pending snapshot.
  LocationSnapshot? _pendingBackendUpdate;

  /// PROD-2303 — Resolves to `true` when the session has a real user, `false`
  /// for guest sessions (`accessToken != null && isAuthenticated == false`).
  /// `_tryUpdateBackend` short-circuits when this returns `false` so we don't
  /// burn requests on `PUT /me/location` calls that 401 for guest tokens.
  /// Defaults to `() => true` so existing tests + production code paths that
  /// don't yet thread the auth signal still behave as before.
  final bool Function() _isAuthenticatedFn;

  // ============ Distance Calculation ============

  /// PROD-2303 — round a coordinate to 3 decimals (~111m precision) for the
  /// PUT dedup key. Constant-time, no allocation.
  static double _roundTo3(double v) => (v * 1000).roundToDouble() / 1000;

  /// Calculate distance between two points using Haversine formula
  /// Returns distance in meters
  static double _calculateDistanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusMeters = 6371000.0;

    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadiusMeters * c;
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180;

  /// PROD-2878 — whether a snapshot reports precise-enough accuracy to be
  /// trusted as an authoritative fix. IP-approximate is always imprecise (no
  /// on-device accuracy metric); GPS/network snapshots must report
  /// `accuracy_m ≤ _preciseAccuracyThresholdMeters` (500 m). Mirrors the
  /// `_isImpreciseForNearYou` gate in `near_you_context_provider.dart`.
  static bool _isPreciseFix(LocationSnapshot snapshot) {
    // PROD-4486: any imprecise source (IP, inferred memory_fact, backend-only,
    // unknown) is never a precise fix — it carries no trustworthy accuracy.
    if (snapshot.source.isImpreciseSource) return false;
    final acc = snapshot.accuracyM;
    return acc != null && acc <= _preciseAccuracyThresholdMeters;
  }

  /// Check if new location is significantly different from reference location
  bool _hasMovedSignificantly(
    LocationSnapshot newLocation,
    LocationSnapshot? referenceLocation,
    double thresholdMeters,
  ) {
    if (referenceLocation == null) return true;

    final distance = _calculateDistanceMeters(
      referenceLocation.lat,
      referenceLocation.lon,
      newLocation.lat,
      newLocation.lon,
    );

    return distance >= thresholdMeters;
  }

  // ============ Initialization ============

  /// Seed `_lastBackendLocation` from the server (`GET /me/location`) so the
  /// app's model of what the backend has — the value the AI resolves "near me"
  /// against for authenticated users — is a fact, not a local-cache assumption.
  ///
  /// Auth-only (guest tokens 401 on `/me/location`). Fire-and-forget from
  /// boot/resume so a slow request never blocks the map dot. No-op when the
  /// server has no record yet (leaves `_lastBackendLocation` null so the first
  /// device fix PUTs). A `null`/error result never overwrites existing state.
  ///
  /// NOTE: `getLocation()` returns the latest record regardless of tag, so this
  /// does NOT repair a stale tagged `current` slot — that needs a tagged
  /// read-back (tracked separately). See the read-back fix context doc.
  Future<void> _readBackServerLocation() async {
    if (!_isAuthenticatedFn()) return;

    // Boot and resume both fire this unawaited, so two GETs can be in flight at
    // once. Tag each with a monotonic id and drop this result if a NEWER
    // read-back has already applied — so an out-of-order older GET can't
    // overwrite a fresher read-back, while a newer read-back that fails does
    // not suppress this (older) successful one.
    final int readBackId = ++_readBackSeq;

    try {
      // Capture the sync sequence before awaiting so a PUT that lands mid-flight
      // (which advances `_lastBackendLocation` to something fresher) wins.
      final seqAtStart = _backendSyncSeq;
      final LocationSnapshot? serverSnapshot = await _locationApi.getLocation();
      if (serverSnapshot == null) return;
      if (readBackId < _readBackAppliedSeq) return; // a newer read-back applied
      if (_backendSyncSeq != seqAtStart) return; // a fresher PUT already landed

      _lastBackendLocation = serverSnapshot;
      _readBackAppliedSeq = readBackId;
      debugPrint(
        '[LocationNotifier] Seeded backend location from server read-back: '
        '${serverSnapshot.lat}, ${serverSnapshot.lon}',
      );
    } catch (e) {
      // Non-critical — the local cache / next device fix still drives the map;
      // a failed read just means we keep the existing backend-location belief.
      debugPrint('[LocationNotifier] Server read-back failed: $e');
    }
  }

  /// Check if permission is already granted and load location without prompting
  Future<void> _initializeIfPermitted() async {
    // Set initializing immediately so UI shows loading state
    state = state.copyWith(isInitializing: true);

    // Learn real server-side location up front (auth users only) so the
    // backend-sync gate compares against server truth, not the local cache.
    // Fire-and-forget — must not block the boot path / map dot.
    unawaited(_readBackServerLocation());

    final status = await _locationService.checkPermission();
    state = state.copyWith(permissionStatus: status);

    // Try our storage cache first for instant display on web refresh
    final storageCached = _storageService.loadCachedLocation();
    final cacheAge = _storageService.getCachedLocationAge();
    final isCacheFresh = cacheAge != null && cacheAge < _maxCacheAgeForFlyIn;

    debugPrint('[LocationNotifier] Cache age: $cacheAge, fresh: $isCacheFresh');

    // If user explicitly disabled location sharing, respect that preference
    if (_storageService.isLocationSharingDisabled()) {
      debugPrint(
        '[LocationNotifier] Location sharing disabled by user preference',
      );
      await setIpApproxLocation();
      state = state.copyWith(isInitializing: false);
      return;
    }

    // PROD-3123 — WEB is handled first and entirely on its own, because
    // `checkPermission()` is unreliable on web: iOS Safari/Chrome report
    // 'denied' via the Permissions API even when getCurrentPosition() would
    // return a precise fix (and can lag a real grant). So on web we IGNORE
    // `status` and let getCurrentPosition() arbitrate — but ONLY when the user
    // has opted into location, so we never fire an unsolicited browser prompt
    // before the app's own location ask. An opted-in user is already granted at
    // the browser level, so no prompt appears. `sharingMode: always` (which
    // drives the resume re-poll) is likewise gated on opt-in.
    if (kIsWeb) {
      final consented = _hasLocationConsentFn();
      if (storageCached != null) {
        // Show the cached fix immediately (map dot); refresh via GPS only when
        // opted in. Cache seeds `lastLocation`, never `_lastBackendLocation`
        // (that comes from the server read-back).
        state = state.copyWith(
          lastLocation: storageCached,
          sharingMode: consented
              ? LocationSharingMode.always
              : LocationSharingMode.disabled,
          permissionStatus: LocationPermissionStatus.granted,
          isInitializing: false,
        );
        if (consented) {
          if (isCacheFresh) {
            _startAnimationBlockPeriod();
          }
          _acquireStabilizedLocation();
        }
      } else if (consented) {
        // No cache, opted in — probe real GPS, IP fallback on genuine failure.
        state = state.copyWith(sharingMode: LocationSharingMode.always);
        await _acquireStabilizedLocation();
        if (!state.hasLocation) {
          await setIpApproxLocation();
        }
        state = state.copyWith(isInitializing: false);
      } else {
        // No cache, not opted in — IP fallback. The app's location-ask CTA
        // triggers GPS later via a user gesture; `retryWebGpsAfterConsent()`
        // covers the case where opt-in resolves after this boot.
        await setIpApproxLocation();
        state = state.copyWith(isInitializing: false);
      }
      return;
    }

    // === NATIVE (Permissions API is reliable — gate on `status`) ===
    if (status == LocationPermissionStatus.granted) {
      if (storageCached != null && isCacheFresh) {
        // Fresh cache - use immediately for fly-in animation
        state = state.copyWith(
          lastLocation: storageCached,
          sharingMode: LocationSharingMode.always,
          isInitializing: false, // Show map immediately with cached location
        );
        // NB: cache seeds `lastLocation` (the map dot) but NOT
        // `_lastBackendLocation` — that is the server's belief, seeded by
        // `_readBackServerLocation()`, never by the local cache.

        // Start animation blocking period (GPS updates stored as pending)
        _startAnimationBlockPeriod();

        // Get fresh GPS in background (won't interrupt animation)
        _acquireStabilizedLocation();
      } else if (storageCached != null) {
        // Stale cache - keep initializing state until we get fresh GPS
        // Set sharingMode upfront so the UI toggle reflects the correct state
        state = state.copyWith(sharingMode: LocationSharingMode.always);

        // Get fresh stabilized location (blocks until complete)
        await _acquireStabilizedLocation();
        state = state.copyWith(isInitializing: false);
      } else {
        // No cache - try Geolocator's cached position (works on native, not web)
        // Set sharingMode upfront so the UI toggle reflects the correct state
        state = state.copyWith(sharingMode: LocationSharingMode.always);
        final cached = await _locationService.getLastKnownPosition();
        if (cached != null) {
          final snapshot = LocationSnapshot.fromGps(
            lat: cached.latitude,
            lon: cached.longitude,
            accuracy: cached.accuracy,
          );
          state = state.copyWith(lastLocation: snapshot);
          // `_lastBackendLocation` is seeded from the server read-back, not
          // this device-cached position.
        }

        // Get fresh stabilized location
        await _acquireStabilizedLocation();
        state = state.copyWith(isInitializing: false);
      }
    } else {
      // Native, no permission and no usable cache — fall back to IP geolocation.
      await setIpApproxLocation();
      state = state.copyWith(isInitializing: false);
    }
  }

  /// Start the animation blocking period (prevents UI updates during fly-in)
  void _startAnimationBlockPeriod() {
    _animationInProgress = true;
    _pendingLocation = null;
    _pendingForceBackendUpdate = false;
    debugPrint('[LocationNotifier] Animation blocking started');

    _animationBlockTimer?.cancel();
    _animationBlockTimer = Timer(_animationBlockDuration, () {
      _animationInProgress = false;
      debugPrint('[LocationNotifier] Animation blocking ended');

      // Apply pending location if any
      if (_pendingLocation != null) {
        debugPrint(
          '[LocationNotifier] Applying pending location after animation',
        );
        _updateLocation(
          _pendingLocation!,
          forceBackendUpdate: _pendingForceBackendUpdate,
        );
        _pendingLocation = null;
        _pendingForceBackendUpdate = false;
      }
    });
  }

  // ============ Stabilization Logic ============

  /// Acquire a stabilized location by checking multiple times
  /// This handles GPS "warm-up" where the first reading can be inaccurate
  Future<void> _acquireStabilizedLocation() async {
    LocationSnapshot? previousReading;
    int attempts = 0;

    while (attempts < _maxStabilizationAttempts) {
      attempts++;

      // Silent: this runs from `_initializeIfPermitted` (app boot / page
      // refresh on web), which has no user consent gesture behind it. If
      // the OS permission is denied we must NOT pop the native dialog —
      // explicit consent is gathered later via Siga / SokoLocationAsk.
      final result = await _locationService.getCurrentLocation(silent: true);

      if (!result.isSuccess) {
        debugPrint(
          '[LocationNotifier] Stabilization failed: ${result.errorMessage}',
        );

        // On web with cached location, start periodic updates to retry
        if (kIsWeb && state.hasLocation) {
          state = state.copyWith(sharingMode: LocationSharingMode.always);
          _startPeriodicUpdates();
        }
        return;
      }

      final currentReading = LocationSnapshot.fromGps(
        lat: result.latitude!,
        lon: result.longitude!,
        accuracy: result.accuracy,
      );

      // Check if stabilized (within threshold of previous reading AND
      // reporting a precise accuracy). PROD-2878: two consecutive coarse
      // readings within 50 m used to declare stabilization — but browser
      // WiFi/IP fixes cluster tightly on the city centroid (Marquês de
      // Pombal in Lisbon) so the loop locked onto the wrong spot. Requiring
      // `accuracy_m ≤ 500 m` on the current reading keeps the loop polling
      // until GPS actually warms up. When all attempts are coarse we still
      // fall through to the exhaustion path below — the state carries the
      // last coarse reading, but Layer 2 (accuracy-improvement override in
      // `_updateLocation`) will replace it on the first precise poll.
      if (previousReading != null && _isPreciseFix(currentReading)) {
        final distance = _calculateDistanceMeters(
          previousReading.lat,
          previousReading.lon,
          currentReading.lat,
          currentReading.lon,
        );

        if (distance <= _stabilizationRadiusMeters) {
          await _updateLocation(currentReading, forceBackendUpdate: true);
          _startPeriodicUpdates();
          return;
        }
      }

      // Update UI with current reading (even if not stabilized yet). Do NOT
      // force a backend write for this intermediate warm-up reading: a coarse
      // first fix (IP/WiFi centroid) that will be superseded by the precise fix
      // seconds later shouldn't spend an untagged+tagged PUT pair. The gate below
      // still covers the cases that matter — a cold start (isBackendStale, no PUT
      // yet this session) writes the first fix, and a precise fix over a coarse
      // backend location forces a PUT via isBackendAccuracyUpgrade (PROD-2878).
      await _updateLocation(currentReading);

      previousReading = currentReading;

      // Wait before next check (unless this is the last attempt)
      if (attempts < _maxStabilizationAttempts) {
        await Future.delayed(_stabilizationDelay);
      }
    }

    _startPeriodicUpdates();
  }

  // ============ Location Updates ============

  /// Update location state and optionally send to backend
  /// Respects movement thresholds to avoid unnecessary updates
  /// During animation blocking period, stores location as pending instead
  Future<void> _updateLocation(
    LocationSnapshot newLocation, {
    bool forceBackendUpdate = false,
  }) async {
    // During fly-in animation, store as pending and update cache
    if (_animationInProgress) {
      debugPrint(
        '[LocationNotifier] Animation in progress - storing as pending',
      );
      _pendingLocation = newLocation;
      _pendingForceBackendUpdate =
          _pendingForceBackendUpdate || forceBackendUpdate;
      // Still save to storage so location is available on next app start
      await _storageService.saveCachedLocation(newLocation);
      return;
    }

    final currentLocation = state.lastLocation;

    // PROD-2878 — an accuracy upgrade over a cached coarse fix must always
    // win, regardless of how far the reported coords moved. Without this a
    // precise GPS fix landing ~20 m from a stuck coarse WiFi fix at the
    // Marquês de Pombal centroid is rejected by the 30 m movement gate and
    // the coarse coord persists in state + cache forever (only manual
    // location-sharing reset clears it). Applies to both the UI-state write
    // below and the backend PUT further down.
    final isAccuracyUpgrade =
        currentLocation != null &&
        !_isPreciseFix(currentLocation) &&
        _isPreciseFix(newLocation);

    // Check if we should update UI
    final shouldUpdateUi =
        isAccuracyUpgrade ||
        _hasMovedSignificantly(
          newLocation,
          currentLocation,
          _minMovementForUiUpdateMeters,
        );

    if (shouldUpdateUi || currentLocation == null) {
      state = state.copyWith(
        lastLocation: newLocation,
        lastUpdateTime: DateTime.now(),
        permissionStatus: LocationPermissionStatus.granted,
        sharingMode: LocationSharingMode.always,
      );

      // Log accuracy status once per session on first location
      if (!_hasLoggedAccuracy && newLocation.accuracyM != null) {
        final isPrecise =
            newLocation.accuracyM! <= LocationState._approximateThresholdMeters;
        _logAccuracyStatus(
          isPrecise: isPrecise,
          accuracyM: newLocation.accuracyM,
        );
      }

      // Save to storage for instant display on web refresh
      await _storageService.saveCachedLocation(newLocation);
    }

    // Check if we should update backend.
    //
    // Staleness is measured from the last backend PUT *attempt*, not the last
    // success: a cold start whose first PUT failed leaves `_lastApiCallTime`
    // null, and gating on that made `isBackendStale` false forever — the
    // backend stayed pinned to a stale/absent location until the user moved or
    // resumed. A null attempt-time (no PUT tried yet this session) counts as
    // stale so the first fix establishes the backend record; once an attempt is
    // stamped, a failed PUT still throttles the retry to the heartbeat cadence
    // instead of every poll. (Codex Phase 2.)
    final now = _now();
    final isBackendStale =
        _lastBackendAttemptTime == null ||
        now.difference(_lastBackendAttemptTime!) > _maxBackendStaleness;

    // PROD-2878 — a precise fix over a coarse cached backend location must
    // also force a PUT, so the server-side tagged `current` slot (which
    // drives Near-You ranking when no picker is set) corrects instead of
    // sticking at the coarse city centroid.
    final isBackendAccuracyUpgrade =
        _lastBackendLocation != null &&
        !_isPreciseFix(_lastBackendLocation!) &&
        _isPreciseFix(newLocation);

    final shouldUpdateBackend =
        forceBackendUpdate ||
        isBackendStale ||
        isBackendAccuracyUpgrade ||
        _hasMovedSignificantly(
          newLocation,
          _lastBackendLocation,
          _minMovementForBackendMeters,
        );

    if (shouldUpdateBackend) {
      try {
        // Stamp the attempt BEFORE the call so a failed PUT still throttles the
        // staleness heartbeat (no 20 s retry storm during a backend outage).
        _lastBackendAttemptTime = now;
        // PROD-3580 — this PUT belongs to whoever is signed in NOW.
        final epoch = _accountEpoch;
        final request = LocationUpdateRequest.fromSnapshot(newLocation);
        // Fail-closed (PROD-4486): a non-submittable provenance (backend-only /
        // unknown) must never be re-sent. Device / IP fixes always convert, so
        // this only guards against a stray read-back snapshot leaking into a PUT.
        if (request == null) {
          debugPrint(
            '[LocationNotifier] Skipping backend PUT — non-submittable source '
            '${newLocation.source.toJson()}',
          );
          return;
        }
        final response = await _locationApi.updateLocation(request);
        // The account changed while this was in flight: the record it created
        // belongs to the departed user, so none of the bookkeeping below is
        // true for the current one.
        if (epoch != _accountEpoch) return;
        _lastApiCallTime = now;
        _lastBackendLocation = newLocation;
        // A PUT actually landed and advanced our belief — bump the sync
        // sequence so an in-flight server read-back drops its now-stale value.
        // (Bump on SUCCESS only; a failed attempt leaves the server read as the
        // best available truth.)
        _backendSyncSeq++;
        // Share the dedup key with `_tryUpdateBackend` so a forced auth-sync and
        // onboarding's `requestPermissionOnly` suppress each other's duplicate.
        _lastPutKey = _putKeyFor(newLocation, now);

        // Capture the resolved admin context (country ISO + city name) from
        // the backend's response — used by the add-to-list scope picker
        // for pre-selection (PROD-1326). Backend resolves via PostGIS →
        // Google reverse geocode, so this works globally. Silently ignore
        // when either field is missing — pre-selection just won't fire.
        final resolvedCountry = response.country;
        final resolvedCity = response.city;
        if (resolvedCountry != null ||
            resolvedCity != null ||
            response.neighborhood != null) {
          state = state.copyWith(
            resolvedCountryCode: resolvedCountry?.toUpperCase(),
            resolvedCityName: resolvedCity,
            resolvedNeighborhood: response.neighborhood,
          );
        }

        // Also update tagged "current" location alongside every untagged
        // backend write — i.e. on significant movement (>50 m) and the 10-min
        // heartbeat, not just forced updates (first GPS fix, app resume) and
        // accuracy upgrades (PROD-2878). The backend prioritizes tagged
        // "current" for suggestion/recommendation queries, so leaving it gated
        // to force/accuracy-upgrade let it stick on a stale city while the map
        // pin + untagged history advanced during foreground travel (PROD-3053).
        // This runs inside `shouldUpdateBackend` after a successful untagged
        // PUT, so it inherits the same dedup/throttle cadence (PROD-2303) and
        // never fires an extra round-trip.
        try {
          await _locationApi.updateTaggedLocation('current', request);
          if (epoch != _accountEpoch) return;
          // Record that tagged `current` was actually written, so the
          // auth-transition force sync dedups only against a real tagged write.
          _lastTaggedSyncKey = _putKeyFor(newLocation, now);
        } catch (e) {
          debugPrint('[LocationNotifier] Tagged location update failed: $e');
          // Non-critical — untagged update already succeeded
        }
      } catch (e) {
        debugPrint('[LocationNotifier] Backend update failed: $e');
        // Don't fail - will retry on next update
      }
    }
  }

  /// Poll for location update (called by periodic timer, app-resume, and the
  /// stabilization-failure fallback in `_acquireStabilizedLocation`). No user
  /// gesture sits behind these calls, so it must not pop the OS permission
  /// dialog on a `denied` status — otherwise an app resume or periodic refresh
  /// would silently re-prompt.
  Future<void> _pollLocation({bool forceBackendUpdate = false}) async {
    if (_isFetching) return;

    _isFetching = true;

    try {
      final result = await _locationService.getCurrentLocation(silent: true);

      if (result.isSuccess) {
        final snapshot = LocationSnapshot.fromGps(
          lat: result.latitude!,
          lon: result.longitude!,
          accuracy: result.accuracy,
        );

        await _updateLocation(snapshot, forceBackendUpdate: forceBackendUpdate);
      }
    } catch (e) {
      debugPrint('[LocationNotifier] Poll error: $e');
    } finally {
      _isFetching = false;
    }
  }

  // ============ Accuracy Tracking ============

  /// Log accuracy status analytics event (once per session)
  void _logAccuracyStatus({required bool isPrecise, double? accuracyM}) {
    if (_hasLoggedAccuracy) return;
    _hasLoggedAccuracy = true;

    final platform = kIsWeb
        ? 'web'
        : defaultTargetPlatform == TargetPlatform.iOS
        ? 'ios'
        : 'android';

    _analytics.trackLocationAccuracyStatus(
      isPrecise: isPrecise,
      accuracyMeters: accuracyM ?? 0,
      platform: platform,
    );
  }

  /// Request temporary precise location (iOS only).
  /// Call when user performs an action that benefits from precision.
  Future<void> requestTemporaryPreciseLocation() async {
    await _locationService.requestTemporaryPreciseLocation();
    // Re-poll to get updated location with potentially better accuracy
    await _pollLocation();
  }

  // ============ Periodic Updates ============

  void _startPeriodicUpdates() {
    _stopPeriodicUpdates();
    _updateTimer = Timer.periodic(_pollInterval, (_) {
      _pollLocation();
    });
  }

  void _stopPeriodicUpdates() {
    _updateTimer?.cancel();
    _updateTimer = null;
  }

  // ============ App Lifecycle ============

  @override
  void dispose() {
    _stopPeriodicUpdates();
    _animationBlockTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    switch (lifecycleState) {
      case AppLifecycleState.resumed:
        _onAppResumed();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        if (state.sharingMode == LocationSharingMode.always) {
          _stopPeriodicUpdates();
        }
        break;
    }
  }

  /// Handle app resume - immediately fetch fresh location
  Future<void> _onAppResumed() async {
    // Re-sync our belief of server-side location on resume (auth users only).
    // Another device may have updated it, or a prior PUT may have failed while
    // backgrounded. Fire-and-forget so it never blocks the resume path.
    unawaited(_readBackServerLocation());

    // Re-check permission (user might have revoked in settings).
    //
    // PROD-3123 — NATIVE ONLY. On web the Permissions API is unreliable (iOS
    // Safari/Chrome report `denied` even when getCurrentPosition() would
    // succeed), so acting on this `status` here would downgrade a good GPS fix
    // to IP and clear the cache on every tab/app resume — re-introducing the
    // exact bug this fix removes. On web we skip the check and just re-poll
    // below (which on web goes straight to getCurrentPosition and arbitrates).
    if (!kIsWeb) {
      final status = await _locationService.checkPermission();
      if (status != state.permissionStatus) {
        final previousStatus = state.permissionStatus;
        state = state.copyWith(permissionStatus: status);
        if (status != LocationPermissionStatus.granted) {
          _stopPeriodicUpdates();
          // Fall back to IP geolocation instead of clearing location entirely
          await setIpApproxLocation();
          _storageService.clearCachedLocation();
          return;
        }
        // Permission changed from denied → granted (user enabled in Settings).
        // Auto-enable GPS sharing to update map badges, banners, and toggle.
        if (previousStatus != null &&
            previousStatus != LocationPermissionStatus.granted) {
          await enableAlwaysShare();
          return;
        }
      }
    }

    // Immediately fetch fresh location if sharing is enabled
    if (state.sharingMode == LocationSharingMode.always) {
      await _pollLocation(forceBackendUpdate: true);
      _startPeriodicUpdates();
    }
  }

  // ============ Public API ============

  /// Set approximate location via IP geolocation.
  /// Used when user skips GPS permission or GPS is unavailable.
  /// Falls back to locale-based defaults if IP geolocation fails.
  Future<bool> setIpApproxLocation() async {
    try {
      final result = await _ipGeolocationService.detectLocation();
      if (result == null) {
        debugPrint(
          '[LocationNotifier] IP geolocation unresolved; leaving location '
          'unset (no UI-locale guess)',
        );
        return _handleIpUnresolved();
      }

      // PROD-2303 step 6 — propagate ipapi's city + country resolution into
      // the snapshot so the PUT body carries them through to the backend.
      // The IP service returns ISO alpha-2 (e.g. "PT"); resolve via
      // `CountryRepository` for the full name (e.g. "Portugal"). Falls back
      // to the raw code if the country isn't in the catalog.
      final resolvedCountry =
          CountryRepository.findByIsoCode(result.countryCode)?.name ??
          result.countryCode;
      final snapshot = LocationSnapshot.fromIpApprox(
        lat: result.latitude,
        lon: result.longitude,
        city: result.city,
        country: resolvedCountry,
      );

      state = state.copyWith(
        lastLocation: snapshot,
        lastUpdateTime: DateTime.now(),
        sharingMode: LocationSharingMode.disabled,
        isInitializing: false,
      );

      // Send to backend
      _tryUpdateBackend(snapshot);

      _analytics.trackLocationIpFallback(
        city: result.city,
        countryCode: result.countryCode,
      );

      return true;
    } catch (e) {
      debugPrint(
        '[LocationNotifier] IP geolocation failed: $e; leaving location '
        'unset (no UI-locale guess)',
      );
      return _handleIpUnresolved();
    }
  }

  /// Fallback when IP geolocation fails entirely (all providers unreachable).
  ///
  /// PROD-4278 — we deliberately DO NOT infer a physical location here. The
  /// previous implementation mapped the device UI-language locale
  /// (`platformDispatcher.locale.countryCode`) to a hardcoded city centroid,
  /// which put e.g. a Mexican user on a Spanish-Spain phone in Madrid and one
  /// on an English phone in New York. UI language is not a location signal, and
  /// the seeded centroid was then synced to the backend as the user's location,
  /// corrupting their feed / "near me".
  ///
  /// With no GPS and no IP result we simply have no location: leave
  /// `lastLocation` unset (so nothing bogus is PUT to the backend) and let the
  /// map fall back to its own default camera. Returns false — nothing resolved.
  bool _handleIpUnresolved() {
    state = state.copyWith(
      sharingMode: LocationSharingMode.disabled,
      isInitializing: false,
    );

    _analytics.trackLocationIpUnresolved();

    return false;
  }

  /// Share location once
  Future<bool> shareOnce() async {
    final success = await _shareLocationInternal();
    if (success) {
      state = state.copyWith(sharingMode: LocationSharingMode.once);
      _analytics.trackLocationShared(mode: 'once');
    }
    return success;
  }

  /// Enable "share always" mode - starts foreground location updates
  Future<bool> enableAlwaysShare() async {
    final success = await _shareLocationInternal();
    if (success) {
      state = state.copyWith(sharingMode: LocationSharingMode.always);
      _storageService.saveLocationSharingDisabled(false);
      _startPeriodicUpdates();
      _analytics.trackLocationSharingEnabled();
    }
    return success;
  }

  /// Disable "share always" mode - stops GPS updates and falls back to IP
  Future<void> disableAlwaysShare() async {
    _stopPeriodicUpdates();
    _lastBackendLocation = null;
    _storageService.clearCachedLocation();
    _storageService.saveLocationSharingDisabled(true);
    _analytics.trackLocationSharingDisabled();

    // Set disabled immediately so the UI toggle reflects the change,
    // regardless of whether the IP fallback request succeeds.
    state = state.copyWith(sharingMode: LocationSharingMode.disabled);

    // Fall back to IP geolocation so the map still shows a usable location
    await setIpApproxLocation();
  }

  /// Legacy method - delegates to shareOnce for backwards compatibility
  Future<bool> shareLocation() => shareOnce();

  /// Request location permission and enable always-share mode.
  ///
  /// [awaitResolvedAdmin] makes the `PUT /me/location` that follows the fix
  /// part of this future instead of fire-and-forget, so
  /// [LocationState.resolvedCityName] / [LocationState.resolvedNeighborhood]
  /// describe the fix just taken by the time the caller resumes. Callers that
  /// only need the permission outcome must leave it `false`: awaiting the PUT
  /// puts a network round-trip on the caller's path.
  ///
  /// The wait is bounded by [_resolvedAdminWaitBudget], not the API client's
  /// 20 s timeout — see the call site.
  ///
  /// Onboarding's city step needs it (`OnboardingLocationComposer`). It labels
  /// the answer bubble from the resolved admin context, and without the await
  /// it read whatever a PREVIOUS write left behind — in practice the boot
  /// `ip_approx` PUT, which sends a client-supplied city and so never runs the
  /// backend resolver (it carries no neighbourhood at all for ~2 in 3 rows on
  /// production). That is why the step showed a bare "Lisboa" where the GPS
  /// fix resolves to "Alvalade, Lisboa".
  Future<LocationPermissionStatus> requestPermissionOnly({
    bool awaitResolvedAdmin = false,
  }) async {
    if (state.isSharing) {
      return state.permissionStatus ?? LocationPermissionStatus.denied;
    }

    state = state.copyWith(isSharing: true, clearError: true);

    try {
      final result = await _locationService.getCurrentLocation();

      if (result.permissionStatus != null) {
        state = state.copyWith(permissionStatus: result.permissionStatus);
      }

      if (result.isSuccess) {
        final snapshot = LocationSnapshot.fromGps(
          lat: result.latitude!,
          lon: result.longitude!,
          accuracy: result.accuracy,
        );

        state = state.copyWith(
          isSharing: false,
          lastLocation: snapshot,
          lastUpdateTime: DateTime.now(),
          permissionStatus: LocationPermissionStatus.granted,
          sharingMode: LocationSharingMode.always,
        );

        _storageService.saveLocationSharingDisabled(false);
        await _storageService.saveCachedLocation(snapshot);
        // `_tryUpdateBackend` swallows its own failures, so awaiting it cannot
        // turn a backend problem into a failed permission request — the worst
        // case is the caller resuming with the resolved admin context it would
        // have had anyway.
        //
        // Bounded by [_resolvedAdminWaitBudget]: the API client's timeout is 20 s
        // (`ApiConstants.defaultTimeout`), and this await sits on the onboarding
        // city tap, which showed its answer instantly before. Inheriting the full
        // 20 s would trade a slightly coarser label for a 20-second spinner on the
        // step PROD-4394 is trying to speed up. On timeout the PUT stays in flight
        // (nothing is cancelled — it still lands, still updates state, still
        // benefits the next read); we just stop waiting and the caller falls back
        // to the city-only label.
        if (awaitResolvedAdmin) {
          await _tryUpdateBackend(
            snapshot,
          ).timeout(_resolvedAdminWaitBudget, onTimeout: () {});
        } else {
          _tryUpdateBackend(snapshot);
        }
        _startPeriodicUpdates();
        _analytics.trackLocationSharingEnabled();

        return LocationPermissionStatus.granted;
      }

      state = state.copyWith(isSharing: false);
      return result.permissionStatus ?? LocationPermissionStatus.denied;
    } catch (e) {
      state = state.copyWith(isSharing: false);
      return state.permissionStatus ?? LocationPermissionStatus.denied;
    }
  }

  /// PROD-2303 step 5 — re-run the deferred PUT decision after the consent
  /// gate transitions Unknown → known. Wired from `locationProvider`'s
  /// factory via `ref.listen(locationConsentStateProvider)`. No-op if there's
  /// nothing pending. Public so the listener can call it without exposing
  /// `_tryUpdateBackend`.
  Future<void> flushPendingBackendUpdate() async {
    final pending = _pendingBackendUpdate;
    if (pending == null) return;
    _pendingBackendUpdate = null;
    await _tryUpdateBackend(pending);
  }

  /// PROD-3123 — web-only. Boot reads `location_opt_in` synchronously, but
  /// preferences load async, so an opted-in user whose prefs hadn't loaded yet
  /// falls through to the IP fallback at boot. Wired from the factory's
  /// `locationConsentResolvedProvider` listener: once consent resolves to
  /// opted-in, acquire the real GPS fix we skipped. No-op on native, when the
  /// user hasn't opted in, or when we already hold a precise fix.
  Future<void> retryWebGpsAfterConsent() async {
    if (!kIsWeb) return;
    if (!_hasLocationConsentFn()) return;

    // Enable sharing so app-resume re-polls, even if we already hold a fix that
    // boot showed with `sharingMode: disabled` (opt-in wasn't loaded yet).
    if (state.sharingMode != LocationSharingMode.always) {
      state = state.copyWith(sharingMode: LocationSharingMode.always);
      _startPeriodicUpdates();
    }

    // Already precise → no immediate re-fetch needed (sharing/polling is now on).
    if (state.isPrecise) return;

    await _acquireStabilizedLocation();
    if (state.hasLocation) {
      _startPeriodicUpdates();
    } else {
      await setIpApproxLocation();
    }
  }

  /// PROD-4083 — best-effort upgrade of a coarse GPS/network fix to a precise
  /// one via a single silent high-accuracy read. Safe to call unattended from
  /// the feed: it NEVER pops an OS permission or accuracy dialog (the silent
  /// primitives pass `silent: true`), and it reuses every existing gate so it
  /// can't storm reads or burn redundant backend PUTs.
  ///
  /// No-op when we already hold a precise fix, a read is already in flight, the
  /// current fix is an IP fallback (a silent GPS read can't help), the fix is
  /// not a coarse *GPS* reading, or (web) the user hasn't opted in.
  ///
  /// Note this cannot upgrade an iOS "Precise Location: Off" (reduced-accuracy)
  /// fix — only the system full-accuracy dialog can, and we deliberately don't
  /// auto-fire that here (it would re-create the "keeps asking" nagging).
  Future<void> refineCoarseFixIfPossible() async {
    if (state.isPrecise || _isFetching) return;
    if (!state.isGpsApproximate) return;
    if (kIsWeb) {
      // retryWebGpsAfterConsent already guards on consent + isPrecise and reads
      // silently; on native it is a no-op, so branch here for the native path.
      await retryWebGpsAfterConsent();
      return;
    }
    await _pollLocation();
  }

  /// Dedup key for a snapshot at [now] — `(source, ~111 m-rounded coords, ts)`.
  ({LocationSource source, double latR3, double lonR3, DateTime ts}) _putKeyFor(
    LocationSnapshot snapshot,
    DateTime now,
  ) => (
    source: snapshot.source,
    latR3: _roundTo3(snapshot.lat),
    lonR3: _roundTo3(snapshot.lon),
    ts: now,
  );

  /// Whether [snapshot] at [now] matches [lastKey] (same source + rounded
  /// coords) within the dedup window.
  bool _isDuplicateOf(
    ({LocationSource source, double latR3, double lonR3, DateTime ts})? lastKey,
    LocationSnapshot snapshot,
    DateTime now,
  ) {
    if (lastKey == null) return false;
    final k = _putKeyFor(snapshot, now);
    return lastKey.source == k.source &&
        lastKey.latR3 == k.latR3 &&
        lastKey.lonR3 == k.lonR3 &&
        now.difference(lastKey.ts) < _putDedupWindow;
  }

  /// Push the current device fix to the backend, bypassing the movement/
  /// staleness gate (untagged + tagged `current`), so the server is fresh
  /// before the first authenticated "near me". Wired from `locationProvider`'s
  /// factory on the guest→auth transition. Auth-gated and no-op without a known
  /// location; deduped against a very recent PUT so it can't double-write with
  /// onboarding's `requestPermissionOnly`.
  Future<void> forceBackendSyncCurrentLocation() async {
    if (!_isAuthenticatedFn()) return;
    final loc = state.lastLocation;
    if (loc == null) return;
    // Dedup on the TAGGED-current key, not the untagged `_lastPutKey`: a recent
    // untagged-only PUT (e.g. onboarding's `requestPermissionOnly`) must not
    // suppress the tagged-current write this sync exists to make.
    if (_isDuplicateOf(_lastTaggedSyncKey, loc, _now())) {
      debugPrint('[LocationNotifier] Force sync deduped (recent tagged PUT)');
      return;
    }
    await _updateLocation(loc, forceBackendUpdate: true);
  }

  /// Best-effort backend update - doesn't throw on failure
  Future<void> _tryUpdateBackend(LocationSnapshot snapshot) async {
    // PROD-2303 — Guest sessions own a valid `accessToken` but
    // `isAuthenticated == false`. `/me/location` returns 401 for guest
    // tokens; the silent catch below would swallow it, burning a request and
    // surfacing nothing in logs. Gate at entry so the request is never made.
    if (!_isAuthenticatedFn()) {
      return;
    }

    // PROD-2303 step 5 — defer PUTs while consent is still loading. Without
    // this, the boot path's IP-approx detection races `preferencesProvider`
    // and writes a `/me/location` record before we know whether the user has
    // even opted in. The pending snapshot is stashed; the listener wired in
    // `locationProvider`'s factory calls [flushPendingBackendUpdate] when
    // consent transitions from unresolved to resolved.
    final isConsentResolved = _isConsentResolvedFn?.call() ?? true;
    if (!isConsentResolved) {
      _pendingBackendUpdate = snapshot;
      debugPrint(
        '[LocationNotifier] PUT deferred: consent unresolved, stashing '
        '${snapshot.source.name} snapshot for later flush',
      );
      return;
    }

    final now = _now();

    // PROD-2303 — dedup. Drop the call when the same (source, rounded coords)
    // PUT just landed within the dedup window.
    if (_isDuplicateOf(_lastPutKey, snapshot, now)) {
      debugPrint(
        '[LocationNotifier] PUT dedup: skipping ${snapshot.source.name} '
        '@(${_roundTo3(snapshot.lat)}, ${_roundTo3(snapshot.lon)})',
      );
      return;
    }

    try {
      // Stamp the attempt before the call (see `_updateLocation`).
      _lastBackendAttemptTime = now;
      // PROD-3580 — account epoch, see `_updateLocation`.
      final epoch = _accountEpoch;
      final request = LocationUpdateRequest.fromSnapshot(snapshot);
      // Fail-closed (PROD-4486) — see `_updateLocation`.
      if (request == null) {
        debugPrint(
          '[LocationNotifier] Skipping backend PUT — non-submittable source '
          '${snapshot.source.toJson()}',
        );
        return;
      }
      final response = await _locationApi.updateLocation(request);
      if (epoch != _accountEpoch) return;
      _lastApiCallTime = now;
      _lastBackendLocation = snapshot;
      // Bump on SUCCESS only (see `_updateLocation`) so an in-flight read-back
      // drops its now-stale value; a failed attempt keeps the server read.
      _backendSyncSeq++;
      _lastPutKey = _putKeyFor(snapshot, now);
      // Same resolved-admin capture as _updateLocation — see PROD-1326.
      if (response.country != null ||
          response.city != null ||
          response.neighborhood != null) {
        state = state.copyWith(
          resolvedCountryCode: response.country?.toUpperCase(),
          resolvedCityName: response.city,
          resolvedNeighborhood: response.neighborhood,
        );
      }
    } catch (_) {
      // Silently fail - will retry on next periodic update
    }
  }

  /// Internal: share current location to backend
  Future<bool> _shareLocationInternal() async {
    if (state.isSharing) return false;

    state = state.copyWith(isSharing: true, clearError: true);

    try {
      final result = await _locationService.getCurrentLocation();

      if (!result.isSuccess) {
        state = state.copyWith(
          isSharing: false,
          error: result.errorMessage,
          permissionStatus: result.permissionStatus,
        );
        return false;
      }

      final snapshot = LocationSnapshot.fromGps(
        lat: result.latitude!,
        lon: result.longitude!,
        accuracy: result.accuracy,
      );

      // Always send to backend for explicit share actions
      final now = _now();
      if (_lastApiCallTime == null ||
          now.difference(_lastApiCallTime!) > const Duration(seconds: 5)) {
        // Stamp the attempt before the call (see `_updateLocation`).
        _lastBackendAttemptTime = now;
        // PROD-3580 — account epoch, see `_updateLocation`.
        final epoch = _accountEpoch;
        final request = LocationUpdateRequest.fromSnapshot(snapshot);
        // Fail-closed (PROD-4486): only PUT a client-submittable provenance.
        // An explicit GPS share always converts; guard is defensive.
        if (request != null) {
          await _locationApi.updateLocation(request);
          if (epoch == _accountEpoch) {
            _lastApiCallTime = now;
            _lastBackendLocation = snapshot;
            // Bump on SUCCESS only (see `_updateLocation`).
            _backendSyncSeq++;
          }
        }
      }

      state = state.copyWith(
        isSharing: false,
        lastLocation: snapshot,
        lastUpdateTime: DateTime.now(),
        permissionStatus: LocationPermissionStatus.granted,
      );

      await _storageService.saveCachedLocation(snapshot);

      return true;
    } catch (e) {
      debugPrint('[LocationNotifier] Share failed: $e');
      state = state.copyWith(
        isSharing: false,
        error: 'Failed to share location: ${e.toString()}',
      );
      return false;
    }
  }

  /// Check permission status (without requesting)
  Future<LocationPermissionStatus> checkPermission() async {
    final status = await _locationService.checkPermission();
    state = state.copyWith(permissionStatus: status);
    return status;
  }

  /// Whether the platform supports opening system settings
  bool get canOpenSettings => _locationService.canOpenSettings;

  /// Open app settings (for when permission is permanently denied)
  Future<bool> openAppSettings() async {
    return await _locationService.openAppSettings();
  }

  /// Open location settings (for when service is disabled)
  Future<bool> openLocationSettings() async {
    return await _locationService.openLocationSettings();
  }

  /// Open settings based on current permission status.
  /// Opens app settings for permission changes (grant or revoke),
  /// or location settings when the service itself is disabled.
  Future<void> openSettings() async {
    if (state.permissionStatus == LocationPermissionStatus.serviceDisabled) {
      await openLocationSettings();
    } else {
      await openAppSettings();
    }
  }

  /// Clear error
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  /// PROD-3580 — drops everything this notifier holds that belongs to the
  /// **account** rather than the device. Called by `purgeUserScopedState` on
  /// every identity change (sign-out, sign-in, direct A→B switch alike).
  ///
  /// Two things in here are account data, not device data:
  ///
  ///   * [_lastBackendLocation] (+ the attempt/dedup bookkeeping around it) —
  ///     the app's belief about what the server holds for the *signed-in
  ///     user*, seeded by `GET /me/location` in [_readBackServerLocation] and
  ///     advanced by each authenticated PUT. Carried across an A→B switch it
  ///     suppresses B's first `PUT /me/location` for up to
  ///     [_maxBackendStaleness] (nothing has "moved", nothing is "stale"), so
  ///     the server holds no `current` location for B while B's authenticated
  ///     "near me" resolves against it. It also drives the admin
  ///     location/chat debug panels, which would report A's server location
  ///     to B.
  ///   * [LocationState.resolvedCountryCode] / [LocationState.resolvedCityName]
  ///     / [LocationState.resolvedNeighborhood] — the backend's reverse
  ///     geocode of that account's write.
  ///
  /// The device fix, permission status and sharing mode are deliberately
  /// untouched: they belong to the device and must survive an account switch.
  /// That asymmetry is why `locationProvider` is not in `userScopedProviders`
  /// — invalidating it would dispose the whole notifier, dropping the GPS
  /// subscription, the permission state and the PROD-3123 web-probe gating.
  /// See the PROD-2065 boundary in
  /// `docs/platform/cross-account-state-isolation.md`.
  ///
  /// Do NOT re-wire this to a `user?.id` listener in the provider factory: the
  /// cold-start `null → A` hydration would fire it and wipe the boot read-back
  /// seed, because `isAuthenticated` flips true (and the read-back runs) before
  /// `/auth/me` populates the identity. `_IdentityWatcher` already holds a
  /// grace period open for exactly that transition.
  void resetAccountScopedBackendState() {
    // Retires every request already in flight for the departing account:
    // each authenticated PUT captures [_accountEpoch] before its `await` and
    // drops its post-await bookkeeping if this moved, so A's response cannot
    // re-establish A's backend belief — and A's dedup suppression — after B
    // has taken over.
    _accountEpoch++;
    _lastBackendLocation = null;
    _lastBackendAttemptTime = null;
    _lastApiCallTime = null;
    _lastPutKey = null;
    _lastTaggedSyncKey = null;
    // A PUT deferred because the DEPARTED account's consent hadn't resolved
    // (PROD-2303). Leaving it queued means the next account's consent flip
    // runs `flushPendingBackendUpdate()` and sends a snapshot captured during
    // someone else's session — re-populating exactly the bookkeeping above.
    // The live device fix is untouched, so the next real update re-derives it.
    _pendingBackendUpdate = null;
    // Same for a `GET /me/location` still in flight: [_readBackServerLocation]
    // captures this counter before its await and discards its result if it
    // moved.
    _backendSyncSeq++;
    if (state.resolvedCountryCode != null ||
        state.resolvedCityName != null ||
        state.resolvedNeighborhood != null) {
      state = state.copyWith(clearResolvedAdmin: true);
    }
  }
}

/// Provider for location state
/// Read-only seam over [locationProvider] exposing the full [LocationState].
/// Lets other providers (and their tests) depend on the resolved location
/// without constructing a full [LocationNotifier] — override this with a plain
/// [LocationState] in tests. Mirrors `currentLocationSnapshotProvider`, which
/// exposes only the snapshot; consumers needing `isPrecise` / consent-derived
/// getters read this instead.
final locationStateProvider = Provider<LocationState>(
  (ref) => ref.watch(locationProvider),
);

final locationProvider = StateNotifierProvider<LocationNotifier, LocationState>(
  (ref) {
    final locationService = ref.watch(locationServiceProvider);
    final locationApi = ref.watch(locationApiProvider);
    final analytics = ref.watch(unifiedAnalyticsProvider);
    final storageService = ref.watch(storageServiceProvider);
    final ipGeolocationService = ref.watch(ipGeolocationServiceProvider);
    final notifier = LocationNotifier(
      locationService,
      locationApi,
      analytics,
      storageService,
      ipGeolocationService,
      // PROD-2303 — gate `_tryUpdateBackend` on real auth so guest sessions
      // don't fire `PUT /me/location` and 401 silently.
      isAuthenticatedFn: () => ref.read(isAuthenticatedProvider),
      // PROD-2303 step 5 — gate `_tryUpdateBackend` on consent resolution.
      // Boot-path IP-approx detection races `preferencesProvider`; without
      // this, we PUT before knowing whether the user has even opted in.
      isConsentResolvedFn: () => ref.read(locationConsentResolvedProvider),
      // PROD-3123 — gate the web-only GPS probe on the user having opted into
      // location, so boot/resume never fires an unsolicited browser prompt.
      hasLocationConsentFn: () =>
          ref.read(preferencesProvider).preferences?.locationOptIn == true,
    );

    // PROD-2303 step 5 — flush the deferred boot PUT once consent resolves.
    // `_tryUpdateBackend` stashes the snapshot while
    // `locationConsentResolvedProvider` is `false`; this listener flushes
    // it on the false → true transition so the backend record catches up
    // without waiting for the next stabilization or grant action.
    ref.listen<bool>(locationConsentResolvedProvider, (prev, next) {
      if (prev == false && next == true) {
        // ignore: unawaited_futures
        notifier.flushPendingBackendUpdate();
        // PROD-3123 — web boot reads opt-in synchronously but preferences load
        // async; if we fell back to IP because opt-in hadn't loaded, acquire
        // the real GPS fix now that consent resolved (no-op on native / when
        // not opted in / when already precise).
        // ignore: unawaited_futures
        notifier.retryWebGpsAfterConsent();
      }
    });

    // Force-push the current device fix on the guest→auth transition so the
    // server (untagged + tagged `current`) is fresh before the first
    // authenticated "near me". Hook here — not in `auth_provider` — because the
    // notifier's own auth gate must already see `isAuthenticated == true` when
    // the sync fires, and that flag flips before this listener runs.
    ref.listen<bool>(isAuthenticatedProvider, (prev, next) {
      if (prev == false && next == true) {
        // ignore: unawaited_futures
        notifier.forceBackendSyncCurrentLocation();
      }
    });

    return notifier;
  },
);
