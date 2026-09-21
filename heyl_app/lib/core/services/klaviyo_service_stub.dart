import 'package:flutter/foundation.dart';

import 'push_permission_state.dart';

class KlaviyoService {
  bool get isEnabled => false;

  Future<void> initialize() async {}

  Future<void> identify(String userId) async {}

  Future<PushRegResult> requestPushPermissionAndRegister() async {
    return PushRegResult.sdkDisabled;
  }

  Future<PushRegResult> registerForPushIfAlreadyAuthorized() async {
    return PushRegResult.sdkDisabled;
  }

  Future<bool> verifyTokenPresence() async => false;

  Future<String?> getPushToken() async => null;

  Future<bool> get isPushAuthorized async => false;

  Future<void> openNotificationSettings() async {}

  Future<void> handleUniversalTrackingLink(Uri uri) async {}

  Future<void> resetProfile() async {}

  Future<void> trackEvent(
    String eventName, {
    Map<String, dynamic>? properties,
  }) async {
    if (kDebugMode) {
      debugPrint('[Klaviyo] Stub ignored event: $eventName');
    }
  }
}
