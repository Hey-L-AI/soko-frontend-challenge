import 'package:app_tracking_transparency/app_tracking_transparency.dart';

/// Uniform AppsFlyer consent (spec §2a): no region branching, ATT-derived,
/// GDPR-subject explicitly false for every user.
class AppsflyerConsentValues {
  const AppsflyerConsentValues({
    required this.hasConsentForDataUsage,
    required this.hasConsentForAdsPersonalization,
  });
  final bool hasConsentForDataUsage;
  final bool hasConsentForAdsPersonalization;
  bool get isSubjectToGdpr => false;
}

/// Maps ATT status to consent. iOS: authorized -> true, everything else
/// (including notDetermined) -> false. Android has no ATT -> true (matches
/// current Meta/TikTok Android behaviour). Pass [status] null on Android.
AppsflyerConsentValues appsflyerConsentFor(
  TrackingStatus? status, {
  required bool isIOS,
}) {
  if (!isIOS) {
    return const AppsflyerConsentValues(
      hasConsentForDataUsage: true,
      hasConsentForAdsPersonalization: true,
    );
  }
  final granted = status == TrackingStatus.authorized;
  return AppsflyerConsentValues(
    hasConsentForDataUsage: granted,
    hasConsentForAdsPersonalization: granted,
  );
}
