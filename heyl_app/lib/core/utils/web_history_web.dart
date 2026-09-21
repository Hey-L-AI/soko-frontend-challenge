import 'package:web/web.dart' as web;

/// Step the browser history back one entry.
///
/// Fires a `popstate`, which the Flutter engine turns into a route-information
/// update — the same path the browser's own back button takes. It is
/// asynchronous: the URL (and any state derived from it) changes on a later
/// task, not on return from this call.
void browserHistoryBackImpl() => web.window.history.back();
