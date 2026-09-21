import 'dart:js_interop';

@JS('hideAppLoading')
external void _hideAppLoading();

/// Web implementation - calls JavaScript function to hide HTML loading indicator.
void hideAppLoading() {
  _hideAppLoading();
}
