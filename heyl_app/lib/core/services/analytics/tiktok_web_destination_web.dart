@JS()
library;

import 'dart:js_interop';

import 'package:flutter/foundation.dart';

import 'analytics_destination.dart';

/// TikTok Pixel web destination (PROD-2919).
///
/// Calls `window.ttq` — the global loaded by the Pixel snippet in
/// `web/index.html`. That snippet queues calls before the remote script
/// finishes downloading, so we never need to gate on load state.
///
/// When `TIKTOK_PIXEL_CODE` was empty at build time, the snippet in
/// `web/index.html` short-circuits and never defines `ttq` — every call
/// here becomes a no-op ([_ttqAvailable] returns false).
///
/// Compared to [TikTokDestination] (mobile) there is no ATT gate on web —
/// tracking consent is handled by the browser's ad-blocking / storage
/// controls, not by iOS ATT. Buffering is also unnecessary because the
/// Pixel snippet handles its own queueing until the CDN script loads.
class TikTokWebDestination implements AnalyticsDestination {
  TikTokWebDestination();

  @override
  String get name => 'tiktok';

  /// Maps HeyL event names to TikTok Pixel standard event names.
  /// Matches the mobile destination's event set for cross-platform parity.
  static const _eventNameMap = <String, String>{
    'sign_up': 'CompleteRegistration',
    'login': 'ClickButton',
    'search': 'Search',
    'list_create': 'AddToWishlist',
  };

  @override
  Future<void> track(String event, Map<String, dynamic> properties) async {
    final mapped = _eventNameMap[event];
    if (mapped == null) return;
    if (!_ttqAvailable()) return;
    try {
      _ttqTrack(mapped.toJS, _jsifyProps(properties));
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('TikTokWebDestination.track("$event") error: $e\n$st');
      }
    }
  }

  @override
  Future<void> identify(String userId, Map<String, dynamic> traits) async {
    if (!_ttqAvailable()) return;
    try {
      final identifyArg = <String, Object?>{'external_id': userId};
      final email = traits['email'];
      if (email is String && email.isNotEmpty) {
        identifyArg['email'] = email;
      }
      final phone = traits['phone_number'] ?? traits['phone'];
      if (phone is String && phone.isNotEmpty) {
        identifyArg['phone_number'] = phone;
      }
      _ttqIdentify(_jsifyProps(identifyArg));
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('TikTokWebDestination.identify error: $e\n$st');
      }
    }
  }

  @override
  Future<void> reset() async {
    // TikTok Pixel has no explicit "logout" — subsequent `identify` calls
    // (from a new login) overwrite the visitor identity. On a full logout
    // we simply stop identifying and the pixel reverts to anonymous.
  }

  /// Strip nulls and JS-ify the properties map. TikTok's `ttq.track`
  /// accepts an object of primitives.
  JSAny _jsifyProps(Map<String, dynamic> props) {
    final cleaned = <String, Object?>{};
    for (final entry in props.entries) {
      if (entry.value != null) cleaned[entry.key] = entry.value;
    }
    return cleaned.jsify() ?? JSObject();
  }
}

/// True when `window.ttq` is defined — i.e. the pixel snippet in
/// `web/index.html` actually loaded (which requires `TIKTOK_PIXEL_CODE` to
/// have been non-empty at build time).
bool _ttqAvailable() {
  try {
    return _ttqRef.isDefinedAndNotNull;
  } catch (_) {
    return false;
  }
}

@JS('ttq')
external JSAny? _ttqRef;

@JS('ttq.track')
external void _ttqTrack(JSString event, JSAny params);

@JS('ttq.identify')
external void _ttqIdentify(JSAny params);
