import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// PROD-2168 Phase 2.D — read `document.visibilityState`.
///
/// Returns `true` when the current tab/document is hidden (background
/// tab, minimized window). `TokenSchedulerService` uses this to suppress
/// PROACTIVE refresh when the user isn't looking at this tab — another
/// visible tab can do the rotation, and waking a hidden tab just to
/// refresh wastes lock contention + Sentry breadcrumbs.
///
/// **Important**: only used for proactive refresh suppression. Reactive
/// 401-driven refresh must continue to fire from hidden tabs so that
/// background API calls already in flight can still recover when the
/// tab returns to the foreground.
bool isPageHidden() {
  try {
    return web.document.visibilityState == 'hidden';
  } catch (_) {
    return false;
  }
}

/// PROD-2168 Phase 2 Codex round-2 [P2] — register a one-shot listener
/// that fires when the document becomes visible. Used by
/// [TokenSchedulerService] to re-attempt a proactive refresh that was
/// suppressed while the tab was hidden. Returns a disposer that
/// detaches the listener if it hasn't fired yet (e.g. on
/// scheduler disposal).
void Function() onPageVisible(void Function() callback) {
  late final JSFunction handler;
  var disposed = false;
  void dispose() {
    if (disposed) return;
    disposed = true;
    try {
      web.document.removeEventListener('visibilitychange', handler);
    } catch (_) {}
  }

  handler = ((web.Event _) {
    if (disposed) return;
    if (web.document.visibilityState != 'hidden') {
      dispose();
      try {
        callback();
      } catch (_) {
        // Caller's exception must not leave the listener attached.
      }
    }
  }).toJS;

  try {
    web.document.addEventListener('visibilitychange', handler);
  } catch (_) {
    disposed = true;
  }
  return dispose;
}
