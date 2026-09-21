import 'dart:io' show Platform;

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';

import 'posthog_service.dart';
import 'unified_analytics_service.dart';

/// Idempotent ATT trigger. Calls
/// `MetaAnalyticsService.requestTrackingAuthorizationIfNeeded()`,
/// which is a no-op on Android/web and short-circuits when iOS ATT
/// status is already determined. Safe to call from multiple sites:
/// iOS caches resolution and the method itself guards re-entry.
///
/// PROD-2285 Phase 2: moved out of cold launch into Siga +
/// LocationAsk's `_onContinue`. The Meta buffer (PROD-2137) covers
/// the deferral between cold launch and ATT resolution so no
/// attribution leaks.
///
/// After the dialog resolves, writes `att_status`, `att_resolved_at`,
/// and `att_platform` to PostHog person properties so product /
/// marketing can segment cohorts by ATT outcome without a backend
/// schema change.
///
/// Accepts either `WidgetRef`, `Ref`, or `ProviderContainer` — any
/// object with `read<T>(provider)`.
Future<void> triggerAttIfNeeded(dynamic ref) async {
  try {
    await ref
        .read(metaAnalyticsServiceProvider)
        .requestTrackingAuthorizationIfNeeded();
  } catch (e) {
    debugPrint('[ATT] trigger failed: $e');
  }

  // TikTok reads the same ATT status the Meta trigger just resolved
  // (Apple caches the resolution), so this call never re-prompts — it
  // just boots the TikTok SDK and opens the destination gate on iOS.
  try {
    await ref
        .read(tiktokAnalyticsServiceProvider)
        .requestTrackingAuthorizationIfNeeded();
  } catch (e) {
    debugPrint('[ATT] tiktok trigger failed: $e');
  }

  // AppsFlyer: start already happened on cold launch. Here we only push the
  // resolved ATT status into AF consent (spec §2, §2a). Not retroactive — this
  // governs subsequent events, not the already-sent install.
  try {
    if (!kIsWeb && Platform.isIOS) {
      final status = await AppTrackingTransparency.trackingAuthorizationStatus;
      await ref
          .read(appsflyerAnalyticsServiceProvider)
          ?.updateConsentOnAttResolved(status);
    }
  } catch (e) {
    debugPrint('[ATT] appsflyer consent update failed: $e');
  }

  // Only iOS produces a meaningful ATT status. On Android/web the
  // resolution is unrelated to App Tracking Transparency and writing
  // it would pollute the segment.
  if (kIsWeb || !Platform.isIOS) return;

  try {
    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    if (status == TrackingStatus.notDetermined) return;
    await ref.read(postHogServiceProvider).setPersonProperties({
      'att_status': _statusString(status),
      'att_resolved_at': DateTime.now().toUtc().toIso8601String(),
      'att_platform': 'ios',
    });
  } catch (e) {
    debugPrint('[ATT] PostHog property write failed: $e');
  }
}

String _statusString(TrackingStatus status) {
  switch (status) {
    case TrackingStatus.authorized:
      return 'authorized';
    case TrackingStatus.denied:
      return 'denied';
    case TrackingStatus.restricted:
      return 'restricted';
    case TrackingStatus.notDetermined:
      return 'notDetermined';
    case TrackingStatus.notSupported:
      return 'notSupported';
  }
}
