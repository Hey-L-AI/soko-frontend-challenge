import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Active label on the Yours page's animated `Yours / Following` toggle
/// (PROD-2026). The active mode picks which card-row shelf the hub
/// renders: [yours] surfaces the user's own lists ([yoursShelfProvider]),
/// [following] surfaces lists the user has followed
/// ([followingShelfProvider]).
enum YoursFollowingMode { yours, following }

/// Screen-local toggle state for the Yours / Following swap. Defaults to
/// [YoursFollowingMode.yours] so a cold visit lands on the user's own
/// lists — matching the page's name and the prior single-mode behaviour.
///
/// State is `autoDispose`d intentionally: it lives only as long as the
/// hub screen is mounted, so navigating away and back resets to Yours.
/// Persisting across sessions would require a SharedPreferences write,
/// deferred per the PROD-2026 plan.
final yoursFollowingModeProvider =
    StateProvider.autoDispose<YoursFollowingMode>(
      (_) => YoursFollowingMode.yours,
    );
