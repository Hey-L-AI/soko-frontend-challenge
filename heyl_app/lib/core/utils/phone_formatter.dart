import '../../data/models/country.dart';

/// Utility class for phone number formatting
class PhoneFormatter {
  PhoneFormatter._();

  /// Converts local phone number + country to E.164 format
  /// Example: "912 345 678" + Country(dialCode: "+351") -> "+351912345678"
  static String toE164(String localNumber, Country country) {
    // Strip all non-digit characters
    String digits = localNumber.replaceAll(RegExp(r'\D'), '');

    // Remove leading zero if present (common in many countries)
    if (digits.startsWith('0')) {
      digits = digits.substring(1);
    }

    // Prepend the dial code
    return '${country.dialCode}$digits';
  }

  /// Validates if the phone number looks reasonable (basic length check)
  static bool isValidLength(String localNumber) {
    final digits = localNumber.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 6 && digits.length <= 15;
  }
}
