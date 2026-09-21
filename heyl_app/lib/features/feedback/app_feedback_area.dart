/// App areas an app-wide feedback submission can be scoped to.
///
/// Wire values match the backend `app_feedback.area` CHECK constraint exactly
/// (PROD-2900) — do not rename without a coordinated migration.
enum AppFeedbackArea {
  general,
  chat,
  library,
  homepage,
  create,
  menu,
  profile;

  /// The value sent to the API (identical to the enum name).
  String get wire => name;
}

/// Map a go_router location (e.g. `matchedLocation`) to the app area it
/// represents, for the "this page" feedback scope.
///
/// This is the single place a new panel registers its feedback area. Home (`/`)
/// is the only route that maps to [homepage]; every other unmapped route falls
/// to [general] (PROD-3085) — being honestly scoped to the app rather than
/// mislabeled as "Home", which is what the old `homepage` default did.
AppFeedbackArea areaForRoute(String? location) {
  final loc = location ?? '';
  if (loc.startsWith('/chat')) return AppFeedbackArea.chat;
  if (loc.startsWith('/yours') || loc.startsWith('/library')) {
    return AppFeedbackArea.library;
  }
  if (loc.startsWith('/discovery')) return AppFeedbackArea.create;
  if (loc.startsWith('/menu')) return AppFeedbackArea.menu;
  // PROD-3085: profile surfaces — own profile + edit (`/profile*`), public
  // profiles (`/u/:handle`, `/@handle`) + their follow lists, and find-people.
  if (loc.startsWith('/profile') ||
      loc.startsWith('/u/') ||
      loc.startsWith('/@') ||
      loc.startsWith('/find-people')) {
    return AppFeedbackArea.profile;
  }
  if (loc == '/' || loc.isEmpty) return AppFeedbackArea.homepage;
  return AppFeedbackArea.general; // any other unmapped panel
}
