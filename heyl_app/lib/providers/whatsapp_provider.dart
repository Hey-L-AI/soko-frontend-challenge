import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/user_profile.dart';
import 'api_provider.dart';
import 'detected_country_provider.dart';

/// Country code to locale mapping (mirrors backend region_utils.py)
const _countryToLocale = {
  'PT': 'pt',
  'BR': 'pt-BR',
  'US': 'en',
};

/// Provider that fetches available WhatsApp numbers from the public API.
/// Used for guests who have no user profile.
final guestWhatsAppNumbersProvider =
    FutureProvider<List<WhatsAppNumber>>((ref) async {
  final api = ref.watch(whatsAppApiProvider);
  return api.listNumbers();
});

/// Provider that resolves the appropriate WhatsApp phone number for guests
/// based on IP geolocation country detection.
///
/// Returns null if no numbers are available (API failed).
final guestWhatsAppPhoneProvider = Provider<String?>((ref) {
  final numbersAsync = ref.watch(guestWhatsAppNumbersProvider);
  final countryAsync = ref.watch(detectedCountryCodeProvider);

  return numbersAsync.when(
    data: (numbers) {
      if (numbers.isEmpty) return null;

      // Resolve locale from detected country code
      final countryCode = countryAsync.valueOrNull;
      final locale = countryCode != null
          ? _countryToLocale[countryCode]
          : null;

      // Find matching number by locale
      if (locale != null) {
        final match = numbers.where((n) => n.locale == locale).firstOrNull;
        if (match != null) {
          debugPrint(
              '[guestWhatsAppPhoneProvider] Matched locale $locale → ${match.phone}');
          return match.phone;
        }
      }

      // Fallback: try 'en' (International), then first available
      final intl = numbers.where((n) => n.locale == 'en').firstOrNull;
      final fallback = intl ?? numbers.first;
      debugPrint(
          '[guestWhatsAppPhoneProvider] Fallback → ${fallback.phone}');
      return fallback.phone;
    },
    loading: () => null,
    error: (_, __) => null,
  );
});
