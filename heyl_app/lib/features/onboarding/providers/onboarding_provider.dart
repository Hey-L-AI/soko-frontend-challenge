import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/storage_service.dart';

const _hasSeenOnboardingKey = 'has_seen_onboarding';

/// Provider that checks if the user has completed onboarding
/// Uses the pre-initialized SharedPreferences from main.dart to avoid race conditions
final hasSeenOnboardingProvider = Provider<bool>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getBool(_hasSeenOnboardingKey) ?? false;
});

/// Marks onboarding as complete and invalidates the provider
Future<void> markOnboardingComplete(WidgetRef ref) async {
  final prefs = ref.read(sharedPreferencesProvider);
  await prefs.setBool(_hasSeenOnboardingKey, true);
  ref.invalidate(hasSeenOnboardingProvider);
}
