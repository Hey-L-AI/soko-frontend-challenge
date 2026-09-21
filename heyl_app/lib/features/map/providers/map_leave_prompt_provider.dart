import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The boundary a person explicitly kept *out* of their Search Center (C).
///
/// It is intentionally session-only: on the next map open we watch for a
/// deliberate return to that exact boundary, log the re-navigation metric once,
/// and clear it. It never affects where the map opens or what any query uses.
final keptMapLeaveBoundaryIdProvider = StateProvider<String?>((ref) => null);

/// Routes every shell-level navigation attempt through the mounted Map page's
/// leave decision. The Map page registers while mounted; every other page has
/// no handler, so navigation runs immediately.
///
/// Registration is token-based so a stale Map dispose can never unregister a
/// newer Map instance after a fast route replacement.
class MapLeaveNavigationGuard {
  Object? _owner;
  Future<void> Function(VoidCallback navigate)? _handler;

  Object register(Future<void> Function(VoidCallback navigate) handler) {
    final owner = Object();
    _owner = owner;
    _handler = handler;
    return owner;
  }

  void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _handler = null;
  }

  Future<void> navigate(VoidCallback navigate) async {
    final handler = _handler;
    if (handler == null) {
      navigate();
      return;
    }
    await handler(navigate);
  }
}

final mapLeaveNavigationGuardProvider = Provider<MapLeaveNavigationGuard>(
  (ref) => MapLeaveNavigationGuard(),
);
