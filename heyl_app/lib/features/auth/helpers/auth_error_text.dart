import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';

/// Resolves the user-facing text for an [AuthState] failure (PROD-2979).
///
/// The provider has no `BuildContext`, so it reports failures it wants
/// localized as an [AuthErrorCode]; the screen turns that into copy here.
/// Raw [AuthState.error] text (backend `detail`, rate-limit copy) is passed
/// through unchanged when no code is set.
extension AuthStateErrorText on AuthState {
  String? displayError(Lt l10n) => switch (errorCode) {
    AuthErrorCode.invalidPhone => l10n.authValidationPhoneInvalid,
    AuthErrorCode.loginFailed => l10n.errorLoginFailed,
    null => error,
  };
}
