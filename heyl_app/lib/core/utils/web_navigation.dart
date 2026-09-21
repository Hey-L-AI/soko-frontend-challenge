import 'web_navigation_stub.dart'
    if (dart.library.html) 'web_navigation_web.dart';

/// Navigate to [url] via a hidden form submission (web only).
///
/// This bypasses iOS Universal Link handling that would otherwise open
/// the destination app instead of staying in the browser.
void navigateViaForm(String url) => navigateViaFormImpl(url);
