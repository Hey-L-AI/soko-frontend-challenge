import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Result of a location permission check
enum LocationPermissionStatus {
  granted,
  denied,
  deniedForever,
  serviceDisabled,
  timeout,
  webUnsupported,
  unknownError,
}

/// Result of getting device location
class LocationResult {
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final String? errorMessage;
  final LocationPermissionStatus? permissionStatus;
  final bool isWebPlatform;

  const LocationResult({
    this.latitude,
    this.longitude,
    this.accuracy,
    this.errorMessage,
    this.permissionStatus,
    this.isWebPlatform = false,
  });

  bool get isSuccess => latitude != null && longitude != null;
}

/// Service for device GPS location using geolocator package
class LocationService {
  /// Maximum age for cached location to be considered valid (10 minutes)
  static const _maxCachedLocationAge = Duration(minutes: 10);

  /// Whether the platform supports opening system settings
  /// Returns false on web (where openAppSettings/openLocationSettings are no-ops)
  bool get canOpenSettings => !kIsWeb;

  /// Check if location services are enabled
  Future<bool> isLocationServiceEnabled() async {
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (e) {
      debugPrint('[LocationService] isLocationServiceEnabled error: $e');
      // On web, this may throw if geolocation is not supported
      return false;
    }
  }

  /// Check current permission status without requesting
  Future<LocationPermissionStatus> checkPermission() async {
    try {
      if (!await isLocationServiceEnabled()) {
        return LocationPermissionStatus.serviceDisabled;
      }

      final permission = await Geolocator.checkPermission();
      return _mapPermission(permission);
    } catch (e) {
      debugPrint('[LocationService] checkPermission error: $e');
      if (kIsWeb) {
        return LocationPermissionStatus.webUnsupported;
      }
      return LocationPermissionStatus.unknownError;
    }
  }

  /// Request location permission
  Future<LocationPermissionStatus> requestPermission() async {
    try {
      if (!await isLocationServiceEnabled()) {
        return LocationPermissionStatus.serviceDisabled;
      }

      final permission = await Geolocator.requestPermission();
      return _mapPermission(permission);
    } catch (e) {
      debugPrint('[LocationService] requestPermission error: $e');
      if (kIsWeb) {
        return LocationPermissionStatus.webUnsupported;
      }
      return LocationPermissionStatus.unknownError;
    }
  }

  /// Get current location.
  ///
  /// When [silent] is `false` (default) and the current permission is `denied`,
  /// this triggers the OS permission prompt — appropriate for user-initiated
  /// flows (Siga Continue, "share location" CTAs).
  ///
  /// When [silent] is `true`, a `denied` permission short-circuits to a denied
  /// [LocationResult] without prompting — required for the
  /// `_initializeIfPermitted` / `_acquireStabilizedLocation` path so an app
  /// boot doesn't surprise the user with the OS dialog before they've tapped
  /// any consent CTA. (On mobile web the Permissions API often reports
  /// `denied` immediately after a page refresh even when the user previously
  /// granted; without `silent`, that false-negative produced an unsolicited
  /// prompt — see the cached-location branches in `_initializeIfPermitted`.)
  Future<LocationResult> getCurrentLocation({bool silent = false}) async {
    try {
      // Check if location services are enabled
      if (!await isLocationServiceEnabled()) {
        return LocationResult(
          errorMessage: kIsWeb
              ? 'Location services are disabled in your browser.'
              : 'Location services are disabled. Please enable them in settings.',
          permissionStatus: LocationPermissionStatus.serviceDisabled,
          isWebPlatform: kIsWeb,
        );
      }

      // PROD-3123 — Only gate on the permission API on NATIVE, where it's
      // reliable. On web the Permissions API is unreliable: iOS Safari/Chrome
      // report `denied` from `navigator.permissions.query({name:'geolocation'})`
      // even when `getCurrentPosition()` would return a precise fix. Trusting
      // it made every mobile-web user fall back to IP geolocation. On web we
      // therefore skip the gate and let `getCurrentPosition()` be the real
      // arbiter — it returns a fix when the browser has actually granted (no
      // prompt), shows the browser's own prompt when in the prompt state, and
      // throws on a genuine denial (handled by the catch below → the caller's
      // IP fallback).
      if (!kIsWeb) {
        // Check current permission
        var permission = await Geolocator.checkPermission();

        // Request if not granted — but only when this call was triggered by a
        // user action. Silent callers must not pop the OS dialog.
        if (permission == LocationPermission.denied && !silent) {
          permission = await Geolocator.requestPermission();
        }

        // Handle denied scenarios
        if (permission == LocationPermission.denied) {
          return const LocationResult(
            errorMessage: 'Location permission denied.',
            permissionStatus: LocationPermissionStatus.denied,
            isWebPlatform: false,
          );
        }

        if (permission == LocationPermission.deniedForever) {
          return const LocationResult(
            errorMessage:
                'Location permission permanently denied. Please enable in app settings.',
            permissionStatus: LocationPermissionStatus.deniedForever,
            isWebPlatform: false,
          );
        }
      }

      // Permission granted (or web, where getCurrentPosition arbitrates) -
      // get position
      // Use platform-specific settings to prevent caching
      final LocationSettings settings;
      if (kIsWeb) {
        // On web, set maximumAge to 0 to force fresh GPS reading (no cache)
        settings = WebSettings(
          accuracy: LocationAccuracy.high,
          maximumAge: Duration.zero, // Force fresh position, don't use cached
          timeLimit: const Duration(seconds: 15),
        );
      } else {
        settings = const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      );

      return LocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        permissionStatus: LocationPermissionStatus.granted,
        isWebPlatform: kIsWeb,
      );
    } on TimeoutException catch (_) {
      return LocationResult(
        errorMessage:
            'Location request timed out. Please ensure you have a clear view of the sky or try again.',
        permissionStatus: LocationPermissionStatus.timeout,
        isWebPlatform: kIsWeb,
      );
    } on PermissionDeniedException catch (_) {
      // PROD-3123 — on web we skip the Permissions-API gate and let
      // getCurrentPosition() arbitrate, so a genuine denial surfaces here.
      // Map it to `denied` (not `webUnsupported`) so callers show the right UI.
      return LocationResult(
        errorMessage: kIsWeb
            ? 'Location permission was blocked in your browser. Please enable it in your browser settings.'
            : 'Location permission denied.',
        permissionStatus: LocationPermissionStatus.denied,
        isWebPlatform: kIsWeb,
      );
    } catch (e) {
      debugPrint('[LocationService] getCurrentLocation error: $e');
      // Check if this might be a web-specific unsupported error
      if (kIsWeb) {
        return LocationResult(
          errorMessage:
              'Unable to get your location. Your browser may not support location services.',
          permissionStatus: LocationPermissionStatus.webUnsupported,
          isWebPlatform: true,
        );
      }
      return LocationResult(
        errorMessage: 'Failed to get location: ${e.toString()}',
        permissionStatus: LocationPermissionStatus.unknownError,
        isWebPlatform: false,
      );
    }
  }

  /// Check if user has granted precise location access.
  /// Returns true for precise, false for approximate/reduced.
  /// On web, this API is not supported — always returns true
  /// (caller should infer from accuracy value instead).
  Future<bool> isPreciseLocationEnabled() async {
    if (kIsWeb) return true; // Web: infer from accuracy value
    try {
      final status = await Geolocator.getLocationAccuracy();
      return status == LocationAccuracyStatus.precise;
    } catch (e) {
      debugPrint('[LocationService] getLocationAccuracy failed: $e');
      return true; // Assume precise if check fails
    }
  }

  /// Request temporary precise location on iOS.
  /// No-op on other platforms.
  Future<void> requestTemporaryPreciseLocation() async {
    if (kIsWeb) return;
    try {
      await Geolocator.requestTemporaryFullAccuracy(
        purposeKey: 'PlaceDiscovery',
      );
    } catch (e) {
      debugPrint('[LocationService] requestTemporaryFullAccuracy failed: $e');
    }
  }

  /// Open app settings (for when permission is permanently denied)
  /// Returns false on web where this operation is not supported
  Future<bool> openAppSettings() async {
    if (kIsWeb) {
      // Cannot open settings on web - geolocator returns true but does nothing
      return false;
    }
    return await Geolocator.openAppSettings();
  }

  /// Open location settings (for when service is disabled)
  /// Returns false on web where this operation is not supported
  Future<bool> openLocationSettings() async {
    if (kIsWeb) {
      // Cannot open settings on web - geolocator returns true but does nothing
      return false;
    }
    return await Geolocator.openLocationSettings();
  }

  /// Get last known position from cache (instant, no GPS acquisition)
  /// Returns null if no cached position exists or if it's older than maxAge
  /// Note: Not supported on web - will return null
  Future<Position?> getLastKnownPosition({Duration? maxAge}) async {
    if (kIsWeb) return null; // Not supported on web

    try {
      final position = await Geolocator.getLastKnownPosition();
      if (position == null) return null;

      // Check staleness - Position.timestamp indicates when GPS fix was acquired
      final age = DateTime.now().difference(position.timestamp);
      final effectiveMaxAge = maxAge ?? _maxCachedLocationAge;

      if (age > effectiveMaxAge) {
        debugPrint(
          '[LocationService] Cached location too old: ${age.inMinutes} min',
        );
        return null;
      }

      return position;
    } catch (e) {
      debugPrint('[LocationService] getLastKnownPosition error: $e');
      return null;
    }
  }

  LocationPermissionStatus _mapPermission(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.always:
      case LocationPermission.whileInUse:
        return LocationPermissionStatus.granted;
      case LocationPermission.denied:
        return LocationPermissionStatus.denied;
      case LocationPermission.deniedForever:
        return LocationPermissionStatus.deniedForever;
      case LocationPermission.unableToDetermine:
        return LocationPermissionStatus.denied;
    }
  }
}

/// Provider for LocationService
final locationServiceProvider = Provider<LocationService>((ref) {
  return LocationService();
});
