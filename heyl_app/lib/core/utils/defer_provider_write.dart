import 'package:flutter/widgets.dart';

/// Runs [write] after the current frame, swallowing the `StateError` a
/// torn-down `ProviderScope` throws.
///
/// **Use this for every provider write inside `dispose()`.**
///
/// Two different bugs live at that line, and the fix for the first hides the
/// second:
///
/// 1. **Reachability.** `ref.read(...)` after dispose throws "Cannot use ref
///    after the widget was disposed". The fix is to capture the notifier in
///    `initState` — see
///    `docs/learnings/ref-read-in-consumerstate-dispose-always-throws.md` and
///    the `test/lint/no_ref_in_dispose_test.dart` guard.
/// 2. **Phase.** That captured field is still a provider, and `dispose()` runs
///    inside `Element.unmount`, which the framework performs during
///    `WidgetsBinding.drawFrame`. Riverpod forbids a provider write in the
///    build phase, so it throws `Tried to modify a provider while the widget
///    tree was building`.
///
/// (2) is the nasty one: the throw aborts the rest of `dispose()` — every
/// timer cancel and controller dispose below it silently never runs — and the
/// NEXT frame trips an element-lifecycle assertion that names none of this. It
/// red-screened app launch from `DiscoveryShell.dispose`, and cost a bisect to
/// find. `test/lint/no_sync_provider_write_in_dispose_test.dart` guards it.
///
/// **Deferring changes ordering — check for a race before you use it.**
/// `drawFrame` runs `buildScope` before `finalizeTree`, so a widget that mounts
/// in the same frame registers its post-frame callback FIRST and yours runs
/// AFTER it. A reset that used to land harmlessly before the new owner wrote
/// its value will now overwrite it. Where that matters, guard inside the
/// callback — an ownership token (`MapScreen._strayTapCallback`) or a live
/// count (`DiscoveryShell._liveShells`) — never outside it.
void deferProviderWrite(VoidCallback write) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      write();
    } on StateError {
      // The ProviderScope went down with the widget (app teardown). Whatever
      // this write was resetting, nobody is rendering it — a no-op by
      // definition, not an error worth surfacing.
    }
  });
}
