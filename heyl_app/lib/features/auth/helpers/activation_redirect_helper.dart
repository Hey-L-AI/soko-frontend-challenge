import 'activation_redirect_helper_stub.dart'
    if (dart.library.html) 'activation_redirect_helper_web.dart';

/// Helper to handle mobile deep link redirect for activation
abstract class ActivationRedirectHelper {
  /// Check if running on mobile web (not native app)
  bool isMobileWeb();

  /// Attempt to open the native app via deep link
  void tryOpenNativeApp(String token);
}

/// Create the platform-specific helper
ActivationRedirectHelper createActivationRedirectHelper() =>
    createActivationRedirectHelperImpl();
