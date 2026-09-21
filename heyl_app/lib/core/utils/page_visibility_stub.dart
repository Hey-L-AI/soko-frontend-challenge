/// Default implementation — used when neither dart:html nor dart:io is
/// available (test runner, web-prerender, etc.). Treats the page as
/// always visible.
bool isPageHidden() => false;

/// Register a one-shot listener that fires when the document becomes
/// visible. Returns a disposer. On non-web platforms (or test stub),
/// the disposer is a no-op and the callback is never invoked.
void Function() onPageVisible(void Function() callback) {
  return () {};
}
