import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/storage_service.dart';

/// SharedPreferences key storing whether the user has given explicit consent
/// to send their chat data to our third-party AI providers (OpenAI + Google /
/// Gemini). PROD-2265 Phase 2 — Apple Guideline 5.1.1(i) / 5.1.2(i) R3.
const _aiConsentGrantedKey = 'ai_consent_granted';

/// Whether the user has granted consent to share chat data with the AI
/// providers. The chat composer gates the **first** AI send on this: while it
/// is `false`, attempting to send shows the blocking consent sheet and the
/// message is held until the user agrees. Once `true`, chat sends proceed
/// without re-prompting.
///
/// Stored client-side only (Apple R3 requires consent before transmission,
/// not a server record). A durable server-side record is tracked separately in
/// PROD-2281 (Icebox); when it ships the client will mirror consent on grant.
final aiConsentGrantedProvider = Provider<bool>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getBool(_aiConsentGrantedKey) ?? false;
});

/// Records that the user has agreed to AI processing. Idempotent. Accepts a
/// `WidgetRef` (widgets) or `Ref` (providers) like the other prefs-flag
/// helpers in this codebase.
Future<void> grantAiConsent(dynamic ref) async {
  final prefs = ref.read(sharedPreferencesProvider);
  await prefs.setBool(_aiConsentGrantedKey, true);
  ref.invalidate(aiConsentGrantedProvider);
}

/// Withdraws AI-processing consent (Settings → "AI & data" → revoke). The next
/// chat send re-shows the consent sheet.
Future<void> revokeAiConsent(dynamic ref) async {
  final prefs = ref.read(sharedPreferencesProvider);
  await prefs.setBool(_aiConsentGrantedKey, false);
  ref.invalidate(aiConsentGrantedProvider);
}
