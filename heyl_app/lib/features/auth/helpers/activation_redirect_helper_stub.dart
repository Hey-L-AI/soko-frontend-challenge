import 'activation_redirect_helper.dart';

/// Creates the stub implementation for non-web platforms
ActivationRedirectHelper createActivationRedirectHelperImpl() =>
    _StubActivationRedirectHelper();

/// Stub implementation for mobile/desktop native apps
class _StubActivationRedirectHelper implements ActivationRedirectHelper {
  @override
  bool isMobileWeb() => false;

  @override
  void tryOpenNativeApp(String token) {
    // No-op on native platforms - already in the app
  }
}
