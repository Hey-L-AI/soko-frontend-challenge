import 'web_history_stub.dart' if (dart.library.html) 'web_history_web.dart';

/// Step the **browser** history back one entry (web only; no-op elsewhere).
///
/// PROD-3524. Needed because nothing in go_router ever walks history
/// backwards: `GoRouteInformationProvider.routerReportsNewRouteInformation`
/// (go_router 14.8.1, `information_provider.dart`) reports **every**
/// navigation — `go`, `push` *and* `pop` — with `replace: false`, i.e. each one
/// pushes a new browser-history entry.
///
/// So when page-local state has been mirrored INTO the URL (the map's focused
/// search mode → `/map?search=1`) and the user closes it from inside the app,
/// navigating "back" to the clean URL with `context.go('/map')` would push a
/// *third* entry rather than undo the second — leaving a dead back press
/// behind, and one more for every open/close cycle. Popping the entry is the
/// only way to keep the history stack honest, and it routes the in-app exit
/// through the exact same popstate → route-rebuild path the browser back
/// button uses, so the two can't diverge.
///
/// Callers must confirm the entry they mean to pop is actually on top (e.g.
/// the live URL still carries the query param they added) — this pops
/// whatever is there.
void browserHistoryBack() => browserHistoryBackImpl();
