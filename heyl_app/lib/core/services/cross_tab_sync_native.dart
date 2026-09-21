import 'cross_tab_sync.dart';
import 'cross_tab_sync_stub.dart' as stub;

/// Native (iOS/Android) implementation. The multi-tab problem doesn't
/// exist there — one app instance owns the refresh single-flight via
/// [RefreshCoordinator]'s in-memory Completer. Delegates to the stub so
/// every method is a no-op without dragging in any platform-channel
/// imports.
CrossTabSync createCrossTabSync({required bool enabled}) {
  return stub.createCrossTabSync(enabled: enabled);
}
