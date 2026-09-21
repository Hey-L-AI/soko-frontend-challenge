import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;

/// One place to tune the app's haptics. The Dart API is platform-blind, but the
/// same call lands very differently on each OS, so an intent may need its own
/// constant per platform. Tune here, never at a call site.
///
/// Mapping in the pinned SDK (`services/haptic_feedback.dart`):
///
/// | Dart            | Android         | iOS                        |
/// |-----------------|-----------------|----------------------------|
/// | `lightImpact`   | `VIRTUAL_KEY`   | `UIImpactFeedbackStyleLight`  |
/// | `mediumImpact`  | `KEYBOARD_TAP`  | `UIImpactFeedbackStyleMedium` |
/// | `heavyImpact`   | `CONTEXT_CLICK` | `UIImpactFeedbackStyleHeavy`  |
/// | `selectionClick`| `CLOCK_TICK`    | `UISelectionFeedbackGenerator`|
///
/// Caveat worth knowing before reaching for `heavyImpact` on Android: the
/// constants are hints, and each OEM maps them to its own effect. They are not
/// reliably ordered by strength there — `CONTEXT_CLICK` is a tick on plenty of
/// devices, i.e. *lighter* than `KEYBOARD_TAP`. Anything beyond this ladder
/// needs a platform channel to `VibrationEffect.createOneShot`, where amplitude
/// is set explicitly rather than requested.
abstract final class SokoHaptics {
  /// Confirms a save that has no other feedback — the quicksave buzz on cards,
  /// chat, the map, and the detail bookmark. On those surfaces this IS the
  /// confirmation, so it has to register.
  ///
  /// Both platforms take `mediumImpact` — Android `KEYBOARD_TAP`, iOS
  /// `UIImpactFeedbackStyleMedium`.
  ///
  /// History, because the level has moved twice: it was tied at `lightImpact`
  /// (Android `VIRTUAL_KEY`), which read as too faint to notice mid-scroll.
  /// PROD-4029 raised Android alone and left iOS on Light, on the theory that
  /// Medium is a thud there. On a device it was the opposite — iOS Light was
  /// the weak one. So it is tied again, one level up from where it started.
  ///
  /// Fire-and-forget: never awaited, and a no-op on web.
  static void saveConfirm() {
    if (kIsWeb) return;
    unawaited(HapticFeedback.mediumImpact());
  }
}
