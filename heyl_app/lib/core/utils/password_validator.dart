/// Password strength bucket. UI maps to a localized label.
enum PasswordStrengthLevel { weak, fair, good, strong }

/// A single unmet password requirement. UI maps to a localized string.
enum PasswordRequirement { minLength, uppercase, lowercase, digit }

/// Password validation utility
///
/// Validates passwords against the API requirements:
/// - Minimum 8 characters
/// - Maximum 72 characters (128 for reset)
/// - At least one uppercase letter
/// - At least one lowercase letter
/// - At least one digit
class PasswordValidator {
  PasswordValidator._();

  static const int minLength = 8;
  static const int maxLength = 72;
  static const int maxLengthForReset = 128;

  /// Validate a password against requirements
  static PasswordValidationResult validate(String password) {
    final hasMinLength = password.length >= minLength;
    final hasMaxLength = password.length <= maxLength;
    final hasUppercase = password.contains(RegExp(r'[A-Z]'));
    final hasLowercase = password.contains(RegExp(r'[a-z]'));
    final hasDigit = password.contains(RegExp(r'[0-9]'));

    final isValid =
        hasMinLength &&
        hasMaxLength &&
        hasUppercase &&
        hasLowercase &&
        hasDigit;

    return PasswordValidationResult(
      isValid: isValid,
      hasMinLength: hasMinLength,
      hasMaxLength: hasMaxLength,
      hasUppercase: hasUppercase,
      hasLowercase: hasLowercase,
      hasDigit: hasDigit,
    );
  }

  /// Calculate password strength as a value from 0.0 to 1.0
  static double calculateStrength(String password) {
    if (password.isEmpty) return 0.0;

    double score = 0.0;
    final result = validate(password);

    // Base requirements (each adds 0.2)
    if (result.hasMinLength) score += 0.2;
    if (result.hasUppercase) score += 0.2;
    if (result.hasLowercase) score += 0.2;
    if (result.hasDigit) score += 0.2;

    // Bonus for extra length
    if (password.length >= 12) score += 0.1;

    // Bonus for special characters
    if (password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>\-_=+\[\]\\;/~`]'))) {
      score += 0.1;
    }

    return score.clamp(0.0, 1.0);
  }

  /// Map a numeric strength score to a [PasswordStrengthLevel].
  ///
  /// PROD-2037: the previous string-returning `getStrengthLabel` is gone —
  /// UI layers now look up the localized label via `Lt.of(context)` based
  /// on the returned enum. Keeping the strings out of this utility means
  /// it has no `BuildContext` / `Lt` dependency and stays unit-testable.
  static PasswordStrengthLevel getStrengthLevel(double strength) {
    if (strength < 0.3) return PasswordStrengthLevel.weak;
    if (strength < 0.6) return PasswordStrengthLevel.fair;
    if (strength < 0.8) return PasswordStrengthLevel.good;
    return PasswordStrengthLevel.strong;
  }
}

/// Result of password validation
class PasswordValidationResult {
  final bool isValid;
  final bool hasMinLength;
  final bool hasMaxLength;
  final bool hasUppercase;
  final bool hasLowercase;
  final bool hasDigit;

  const PasswordValidationResult({
    required this.isValid,
    required this.hasMinLength,
    required this.hasMaxLength,
    required this.hasUppercase,
    required this.hasLowercase,
    required this.hasDigit,
  });

  /// Unmet requirements as enum values. UI layer maps to localized strings.
  ///
  /// PROD-2037: the previous string-returning `unmetRequirements` is gone.
  /// Note `hasMaxLength` is intentionally not surfaced here — pre-existing
  /// gap, oversized passwords still produce a backend 400.
  List<PasswordRequirement> get unmetRequirementKeys {
    return [
      if (!hasMinLength) PasswordRequirement.minLength,
      if (!hasUppercase) PasswordRequirement.uppercase,
      if (!hasLowercase) PasswordRequirement.lowercase,
      if (!hasDigit) PasswordRequirement.digit,
    ];
  }
}
