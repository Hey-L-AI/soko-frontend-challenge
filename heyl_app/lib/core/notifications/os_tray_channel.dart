import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bridges the Flutter side of the inbox to the iOS / Android system
/// notification tray. Lets the in-app inbox keep the OS tray and lock
/// screen in sync — when the user marks a row read, the matching
/// delivered push disappears from Notification Center / the status bar.
///
/// Identification is via `tag` (the inbox row's `notification_id` UUID,
/// stamped by `heyl-backend` as Android `tag` + iOS `apns-collapse-id`).
/// Pushes from older backend builds that don't yet stamp the id are a
/// silent no-op — the inbox mutation still succeeds, the tray entry just
/// lingers (status quo, not a regression).
///
/// Calls are fire-and-forget from the caller's perspective: native
/// errors are swallowed to a debugPrint so a tray-sync hiccup never
/// rolls back an inbox state change. No-op on web / desktop.
class OsTrayChannel {
  static const _channel = MethodChannel('ai.heyl.os_tray');

  bool get _supported =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Future<void> clearAll() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('clearAll');
    } catch (e) {
      debugPrint('[OsTrayChannel] clearAll failed: $e');
    }
  }

  Future<void> clearByTag(String tag) async {
    if (!_supported || tag.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('clearByTag', {'tag': tag});
    } catch (e) {
      debugPrint('[OsTrayChannel] clearByTag($tag) failed: $e');
    }
  }
}

final osTrayChannelProvider = Provider<OsTrayChannel>((_) => OsTrayChannel());
