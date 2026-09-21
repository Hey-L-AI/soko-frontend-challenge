import 'package:flutter/material.dart';

import '../widgets/weekly_bundle_overlay.dart';

/// Route screen for the Weekly Bundle overlay.
class WeeklyBundleScreen extends StatelessWidget {
  const WeeklyBundleScreen({super.key, this.openReason});

  /// PROD-2564 — analytics open-reason threaded from the nav `extra`:
  /// `'deep_link'` when opened via the `/weekly-bundle` deep link, `null` for a
  /// normal in-app tap. Forwarded to [WeeklyBundleOverlay], which reads it when
  /// it fires `weekly_bundle_open` on mount.
  final String? openReason;

  @override
  Widget build(BuildContext context) {
    return WeeklyBundleOverlay(openReason: openReason);
  }
}
