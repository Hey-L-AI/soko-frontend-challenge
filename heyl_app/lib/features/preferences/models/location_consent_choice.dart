// PROD-2303 step 7 — picker-sheet domain model. The Settings row collapses
// (server consent × OS permission) into three user-facing radio options; this
// enum + helper compute which options to show per platform.
//
// Platform matrix (locked in design review Q1 / 2026-05-30):
//   iOS:     precise / approximate / off  (mirrors Apple's "Precise" toggle)
//   Android: precise / off                (no OS coarse-only level)
//   Web:     precise / approximate / off  (approximate = consent on, IP only)

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

enum LocationConsentChoice { precise, approximate, off }

/// Returns the radios the picker sheet should render for the running
/// platform. Caller passes this into the sheet — the sheet itself never
/// branches on platform.
List<LocationConsentChoice> availableLocationConsentChoices() {
  if (kIsWeb) {
    return const [
      LocationConsentChoice.precise,
      LocationConsentChoice.approximate,
      LocationConsentChoice.off,
    ];
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return const [LocationConsentChoice.precise, LocationConsentChoice.off];
  }
  // iOS (and any other native).
  return const [
    LocationConsentChoice.precise,
    LocationConsentChoice.approximate,
    LocationConsentChoice.off,
  ];
}

/// Platform string sent to the backend as `location_opt_in_platform`. Matches
/// the values PROD-2304 standardized on for the Siga + Location-Ask flows.
String? currentPlatformConsentTag() {
  if (kIsWeb) return 'web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.android:
      return 'android';
    default:
      return null;
  }
}
