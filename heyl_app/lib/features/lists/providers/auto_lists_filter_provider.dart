import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PROD-2026 — when `false`, the Yours shelf hides system-managed lists
/// (those with `UserList.systemKind != null` — Saved Items, the weekly
/// "This Week" bundle mirror, Instagram-share imports, onboarding seed
/// lists). Default `true` preserves the prior behaviour where every
/// list owned by the user shows up.
///
/// Screen-local (`autoDispose`) — the toggle resets between visits.
/// Persisting across sessions would require a SharedPreferences write,
/// deferred per the PROD-2026 plan.
final includeAutoListsProvider = StateProvider.autoDispose<bool>((_) => true);
