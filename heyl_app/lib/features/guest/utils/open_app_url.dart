/// Returns the `soko.fyi/get/<path>` destination for the guest banner /
/// popup CTAs (PROD-2072). The web team owns the `soko.fyi/get/...`
/// routing — it smart-routes to the App Store, Play Store, or directly
/// into the native app via universal link if it's installed.
///
/// [currentPath] is the GoRouter `matchedLocation` (e.g. `/`,
/// `/events/abc-123`, `/lists/xyz`). A leading `/` is stripped so the
/// returned URL doesn't double up after `soko.fyi/get/`.
String openAppUrl(String currentPath) {
  final trimmed = currentPath.startsWith('/')
      ? currentPath.substring(1)
      : currentPath;
  return 'https://soko.fyi/get/$trimmed';
}
