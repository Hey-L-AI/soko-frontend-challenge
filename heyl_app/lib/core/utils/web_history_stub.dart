/// Stub implementation for non-web platforms.
///
/// Deliberately a silent no-op rather than a throw (unlike
/// `web_navigation_stub.dart`): callers guard on `kIsWeb` and native has no
/// browser history to step, so reaching here means "nothing to undo", not a
/// programming error.
void browserHistoryBackImpl() {}
