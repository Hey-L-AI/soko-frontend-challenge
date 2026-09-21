import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/storage_service.dart';
import '../../../providers/auth_provider.dart';

const _finishedKeyPrefix = 'user_profiling_finished_';

@visibleForTesting
String userProfilingFinishedKey(String userId) => '$_finishedKeyPrefix$userId';

@visibleForTesting
bool hasFinishedUserProfilingLocally(SharedPreferences prefs, String? userId) {
  if (userId == null || userId.isEmpty) return false;
  return prefs.getBool(userProfilingFinishedKey(userId)) ?? false;
}

/// Local fallback for the server-gated onboarding check.
///
/// The backend remains the source of truth via `/auth/me.onboarding_complete`,
/// but this prevents users from being trapped if the profile refresh is stale
/// immediately after a successful submit, or if they explicitly skip.
final hasFinishedUserProfilingLocallyProvider = Provider<bool>((ref) {
  final userId = ref.watch(authStateProvider.select((state) => state.user?.id));
  final prefs = ref.watch(sharedPreferencesProvider);
  return hasFinishedUserProfilingLocally(prefs, userId);
});

/// Whether the current user has already completed user-profiling — used to gate
/// the `/user-profiling/flow` deep link (PROD-2566): an already-profiled tapper
/// is redirected to the persona "you've already done this" landing instead of
/// re-running the survey.
///
/// **Local flag first, server-confirm** (per the PROD-2566 decision): the local
/// flag is instant and survives a stale `/auth/me` right after a submit; the
/// server `onboarding_complete` is authoritative and covers a fresh device /
/// reinstall where the local flag is absent. Either being true gates.
///
/// Edge case: `onboarding_complete` is also set by the WhatsApp onboarding flow,
/// so a user who completed that but never ran the V6 survey can gate true here
/// yet have no V6 persona — the landing then renders without a persona card (the
/// [alreadyProfiledPersonaProvider] graceful fallback). PROD-2698's "has a
/// persona" read could refine this later; for now it matches the agreed gate.
final hasCompletedUserProfilingProvider = Provider<bool>((ref) {
  final local = ref.watch(hasFinishedUserProfilingLocallyProvider);
  final serverComplete = ref.watch(
    authStateProvider.select(
      (state) => state.user?.onboardingComplete ?? false,
    ),
  );
  return local || serverComplete;
});

Future<void> markUserProfilingFinishedLocally(WidgetRef ref) async {
  var userId = ref.read(authStateProvider).user?.id;
  if (userId == null || userId.isEmpty) {
    await ref.read(authStateProvider.notifier).refreshUserProfile();
    userId = ref.read(authStateProvider).user?.id;
  }
  if (userId == null || userId.isEmpty) return;

  final prefs = ref.read(sharedPreferencesProvider);
  await prefs.setBool(userProfilingFinishedKey(userId), true);
  ref.invalidate(hasFinishedUserProfilingLocallyProvider);
}
