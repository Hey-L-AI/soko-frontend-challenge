/// Native (iOS/Android) implementation. There's no multi-window
/// problem on native, so the page is always considered "visible".
bool isPageHidden() => false;

/// Native: never invoked (page is always visible). Returns a no-op
/// disposer for API compatibility.
void Function() onPageVisible(void Function() callback) {
  return () {};
}
