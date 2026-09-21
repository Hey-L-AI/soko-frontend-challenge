import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../providers/api_provider.dart';

/// Fetches and caches the onboarding question catalog. Riverpod's
/// FutureProvider auto-caches across the app lifetime; the catalog is small
/// and changes rarely, so a single fetch per session is fine.
///
/// Refresh by `ref.invalidate(userProfilingQuestionsProvider)` if the user
/// somehow needs a fresh catalog (e.g. dev menu).
final userProfilingQuestionsProvider = FutureProvider<UserProfilingQuestions>((ref) {
  final api = ref.watch(userProfilingApiProvider);
  return api.getQuestions();
});
