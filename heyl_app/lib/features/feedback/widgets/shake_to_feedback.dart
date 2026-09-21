import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../../providers/session_provider.dart';
import '../feedback_area_resolver.dart';
import 'app_feedback_sheet.dart';

/// Standard gravity (m/s²), used to convert raw accelerometer magnitude to a
/// gravity-relative g-force so the shake threshold is device-independent.
const double _kGravity = 9.80665;

/// Pure shake-gesture detector, driven by **g-force** samples (raw
/// accelerometer magnitude / gravity; ≈ 1.0 at rest). Kept free of
/// Flutter/sensor deps so the threshold + debounce logic is unit-testable.
///
/// A jolt is an *upward crossing* of [threshold], not a sample above it
/// (PROD-3292). The sensor streams at 20ms, so one physical impact — putting
/// the phone down — stays over the threshold for several consecutive samples;
/// counting samples made a single impact look like the two separate motions
/// [requiredJolts] is meant to demand, and the sheet opened unsolicited.
class ShakeDetector {
  /// G-force that counts as a jolt (≈ 1.0 at rest; a firm shake exceeds ~2.5).
  final double threshold;

  /// G-force the signal must fall back below before another jolt can be
  /// counted. This is what makes a jolt one *motion* rather than one *sample*.
  final double releaseThreshold;

  /// Jolts required within [window] to register a shake (rejects a single bump).
  final int requiredJolts;

  /// Minimum spacing between two counted jolts. Rejects the fast ringing of a
  /// single impact (a phone bouncing as it lands) while staying well under the
  /// ~100-160ms between peaks of a deliberate hand shake.
  final Duration minJoltGap;

  /// How long the jolts may span.
  final Duration window;

  /// Suppress further shakes for this long after one fires.
  final Duration cooldown;

  ShakeDetector({
    this.threshold = 2.5,
    this.releaseThreshold = 1.6,
    this.requiredJolts = 2,
    this.minJoltGap = const Duration(milliseconds: 80),
    this.window = const Duration(milliseconds: 1000),
    this.cooldown = const Duration(seconds: 3),
  });

  DateTime? _firstJolt;
  DateTime? _lastJolt;
  DateTime? _lastTrigger;
  int _joltCount = 0;

  /// False while the signal is still above [releaseThreshold] from a jolt we
  /// have already counted — i.e. we are mid-motion, not at a new one.
  bool _armed = true;

  /// Feed one [gForce] sample at [now]. Returns true exactly when this sample
  /// completes a shake (past the cooldown).
  bool onSample(double gForce, DateTime now) {
    // The motion has settled — the next upward crossing is a genuine new jolt.
    if (gForce < releaseThreshold) {
      _armed = true;
      return false;
    }

    // Either between the two thresholds, or still inside a jolt already
    // counted. Note this does NOT re-arm: the signal has to fall all the way
    // below releaseThreshold first.
    if (gForce < threshold || !_armed) return false;

    _armed = false; // consume this upward crossing

    // Ringing from the impact we just counted, not a second motion. Push the
    // marker forward so sustained vibration keeps re-suppressing itself.
    if (_lastJolt != null && now.difference(_lastJolt!) < minJoltGap) {
      _lastJolt = now;
      return false;
    }

    if (_firstJolt == null || now.difference(_firstJolt!) > window) {
      _firstJolt = now;
      _joltCount = 0;
    }
    _lastJolt = now;
    _joltCount++;
    if (_joltCount < requiredJolts) return false;

    if (_lastTrigger != null && now.difference(_lastTrigger!) < cooldown) {
      return false;
    }
    _lastTrigger = now;
    _joltCount = 0;
    _firstJolt = null;
    return true;
  }
}

/// Listens for a phone shake and opens the app-wide feedback sheet, scoped to
/// the current page (PROD-2953 — the fast-follow to the always-there tab).
///
/// Renders nothing; mount it once at the shell level next to [FeedbackSideTab].
/// Degrades gracefully where there's no accelerometer (desktop web): the
/// stream simply never emits, so the tab stays the only entry point.
class ShakeToFeedback extends ConsumerStatefulWidget {
  const ShakeToFeedback({super.key});

  @override
  ConsumerState<ShakeToFeedback> createState() => _ShakeToFeedbackState();
}

class _ShakeToFeedbackState extends ConsumerState<ShakeToFeedback> {
  final ShakeDetector _detector = ShakeDetector();
  StreamSubscription<AccelerometerEvent>? _sub;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    try {
      // Basic accelerometer (gravity included) — the widest-supported sensor
      // across native iOS/Android AND Android Chrome web. (iOS Safari web has
      // no Generic Sensor API, so shake is unavailable there — the tab still
      // works.)
      _sub =
          accelerometerEventStream(
            samplingPeriod: SensorInterval.gameInterval,
          ).listen(
            _onEvent,
            onError: (Object e) =>
                debugPrint('[Shake] accelerometer error: $e'),
            cancelOnError: false,
          );
    } catch (e) {
      debugPrint('[Shake] accelerometer unavailable: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(AccelerometerEvent e) {
    final gForce = sqrt(e.x * e.x + e.y * e.y + e.z * e.z) / _kGravity;
    if (_detector.onSample(gForce, DateTime.now())) {
      _openFeedback();
    }
  }

  Future<void> _openFeedback() async {
    if (!mounted || _sheetOpen) return;
    _sheetOpen = true;
    try {
      final area = resolveFeedbackArea(context, ref);
      final sessionId = ref.read(activeSessionIdProvider);
      await showAppFeedbackSheet(
        context,
        ref,
        currentArea: area,
        sessionId: sessionId,
        trigger: 'shake',
      );
    } finally {
      _sheetOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
