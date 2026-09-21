import 'package:web/web.dart' as web;

import 'activation_redirect_helper.dart';

/// Creates the web implementation
ActivationRedirectHelper createActivationRedirectHelperImpl() =>
    _WebActivationRedirectHelper();

/// Web implementation for browser-based activation
class _WebActivationRedirectHelper implements ActivationRedirectHelper {
  @override
  bool isMobileWeb() {
    final userAgent = web.window.navigator.userAgent.toLowerCase();
    return userAgent.contains('android') ||
        userAgent.contains('iphone') ||
        userAgent.contains('ipad') ||
        userAgent.contains('mobile');
  }

  @override
  void tryOpenNativeApp(String token) {
    final deepLink = 'heyl://auth/activate?token=$token';
    web.window.location.href = deepLink;
  }
}
