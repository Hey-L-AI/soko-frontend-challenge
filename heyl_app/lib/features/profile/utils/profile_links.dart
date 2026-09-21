import '../../../core/constants/api_constants.dart';

/// The one canonical shareable URL for a public profile (PROD-2823).
///
/// Uses the `/u/<handle>` path + share UTM params. The web app resolves it
/// directly; on native, this path must be registered for universal links
/// (Apple App Site Association / Android asset links) to open the app instead
/// of the browser.
String profileShareUrl(String handle) {
  return '${ApiConstants.webappUrl}/u/$handle'
      '?utm_source=soko_app&utm_medium=share&utm_campaign=profile_share';
}
