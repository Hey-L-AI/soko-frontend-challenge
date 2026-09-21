import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/auth_provider.dart';

/// Whether the user is currently operating inside the authed Business Connect
/// portal (PROD-4040).
///
/// Set `true` when the Business Home screen mounts. While active, the consumer
/// onboarding gates in `app_router` (chat onboarding / Soko welcome / location
/// ask) are suppressed — a venue owner must not be forced through the consumer
/// "vibe" onboarding while doing business tasks that route through *shared*
/// consumer routes: **verify phone** (`/menu/account`), **manage Instagram**
/// (`/menu/business-connections`), or **edit venue** (`/venues/:id`). Exempting
/// only the `/business` route itself (which is all `isBusinessHomeRoute` does)
/// isn't enough because those CTAs navigate away from it.
///
/// Session-scoped: once an owner has entered the portal we treat them as a
/// business user for the rest of the app session (a business user shouldn't be
/// trapped in consumer onboarding); a cold reload resets it to `false`, so a
/// user who never opens the portal still gets consumer onboarding normally.
///
/// Also resets whenever the authenticated user changes — a logout followed by a
/// different login in the same tab (no reload) must not carry one account's
/// business session into the next, or the new (possibly consumer) user would
/// have their onboarding silently suppressed. Mirrors [accountProvider]'s
/// identity-change reset.
final businessSessionActiveProvider = StateProvider<bool>((ref) {
  ref.listen<String?>(authStateProvider.select((state) => state.user?.id), (
    previous,
    next,
  ) {
    if (previous != next) ref.invalidateSelf();
  });
  return false;
});
