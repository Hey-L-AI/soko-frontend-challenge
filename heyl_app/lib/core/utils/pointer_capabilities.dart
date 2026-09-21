import 'package:flutter/foundation.dart';

/// Whether this build should offer on-screen map zoom controls (+ / −).
///
/// The question is really "can the user pinch?", and the honest proxy is
/// **touch**, not screen size: a phone-sized browser window on a laptop still
/// has no pinch, and a full-screen phone browser has one.
///
/// - **Native iOS / Android**: false. Pinch-to-zoom is the platform gesture and
///   buttons would only cover the map.
/// - **Web on a mobile OS** (`defaultTargetPlatform` reports the *browser's* OS,
///   so a phone browser reads iOS/Android): false, same reason.
/// - **Web on a desktop OS**: true. Scroll-wheel zoom over an embedded map is
///   fiddly at best and is swallowed entirely when the map sits inside a
///   scrollable sheet — which is exactly where the location picker lives.
///
/// A touch-screen Windows laptop gets the buttons it doesn't strictly need;
/// that is the harmless side of the trade.
bool prefersOnScreenZoomControls({
  required bool isWeb,
  required TargetPlatform platform,
}) =>
    isWeb &&
    platform != TargetPlatform.iOS &&
    platform != TargetPlatform.android;

/// [prefersOnScreenZoomControls] for the running build. Note that `flutter test`
/// runs with `kIsWeb == false`, so this is false in unit tests — assert against
/// the pure predicate above instead.
bool get platformPrefersOnScreenZoomControls =>
    prefersOnScreenZoomControls(isWeb: kIsWeb, platform: defaultTargetPlatform);
