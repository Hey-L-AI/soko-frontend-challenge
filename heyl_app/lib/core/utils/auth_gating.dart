import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/lists/widgets/login_prompt_sheet.dart';
import '../../providers/auth_provider.dart';
import '../router/app_router.dart';
import '../services/unified_analytics_service.dart';
import 'deep_link_redaction.dart';

/// Navigate to `/login` from a guest screen, preserving the user's current
/// location so the post-OAuth flow restores them here.
///
/// **Prefer [requireAuth] when the guest just triggered an action** (tapped
/// a button, submitted something). It shows the prompt sheet in place and
/// only reaches `/login` if they choose to sign in — a hard page nav in
/// response to a tap reads as a jarring context switch (PROD-3142).
///
/// Use *this* helper only on surfaces that are **themselves** the
/// explanation of the gate — guest walls, blur overlays, the persistent
/// banner, [GuestGateScreen] — where the user is already looking at a
/// "sign in to continue" message and a sheet repeating it would just ask
/// them to sign in twice.
///
/// Within that case, **use this instead of `context.push(AppRoutes.login)`**.
/// Direct navigation leaves [returnUrlProvider] null, which causes the
/// OAuth round-trip to drop the user on `/home` after login instead of
/// returning them to the page they were viewing.
///
/// The persistence chain is:
///   1. This helper saves the current location (path + query) to
///      [returnUrlProvider]. Storing the full URI rather than just
///      `matchedLocation` keeps deep-link query params (UTM, view
///      selectors) alive through the OAuth round-trip — PROD-2054. The
///      value is passed through [redactDeepLinkForLogging] first so any
///      `access_token` / `refresh_token` / `id_token` / `token` query keys
///      are stripped before they hit localStorage via
///      `saveOAuthReturnUrl`. Non-sensitive params (UTM, `view=`, `ref=`)
///      survive.
///   2. The login screen's "Continue with Google" handler reads that value
///      and passes it to `startGoogleLogin`, which writes it to localStorage
///      via `saveOAuthReturnUrl` before navigating to Google.
///   3. After Google → backend callback → `/auth/callback`, the OAuth callback
///      screen reads the value back from localStorage and navigates there.
///
/// [referrer] is an analytics tag (one of [AuthReferrer]) describing where
/// the prompt came from. It surfaces in `auth_prompt` events so the auth
/// funnel can attribute conversions to specific entry points.
void navigateToLoginPreservingReturn(
  BuildContext context,
  WidgetRef ref, {
  required String referrer,
}) {
  // Capture the user's current location BEFORE the push, so we don't accidentally
  // save `/login` as the return target. Use `uri.toString()` to preserve any
  // query params (PROD-2054 — `matchedLocation` strips query), then strip
  // anything token-shaped before persisting.
  final currentUri = GoRouterState.of(context).uri;
  ref.read(returnUrlProvider.notifier).state =
      redactDeepLinkForLogging(currentUri);
  context.push('${AppRoutes.login}?from=$referrer');
}

/// Helper function to gate actions that require authentication.
///
/// If the user is authenticated, executes [onAuthenticated] immediately.
/// If not, shows a login prompt sheet explaining the action and offering
/// to sign in.
///
/// Usage:
/// ```dart
/// IconButton(
///   onPressed: () => requireAuth(
///     context,
///     ref,
///     action: 'save this event',
///     onAuthenticated: () => _showAddToListSheet(context),
///   ),
///   icon: const Icon(Icons.bookmark_add),
/// )
/// ```
Future<void> requireAuth(
  BuildContext context,
  WidgetRef ref, {
  required VoidCallback onAuthenticated,
  required String action,
  String referrer = 'guest_prompt',
}) async {
  if (ref.read(isAuthenticatedProvider)) {
    onAuthenticated();
    return;
  }
  // Capture provider notifiers + router BEFORE opening the sheet. The
  // trigger widget (e.g. Criar bottom-nav button, chat-bar Add pill) can
  // unmount while the sheet is open — `showBottomSheetWithHiddenNav` flips
  // `bottomNavVisibleProvider` to hide the nav, and the animated collapse
  // disposes the trigger's `WidgetRef`. Any `ref.read(...)` from the
  // `onLogin` closure or the post-await branch then throws "Cannot use ref
  // after the widget was disposed", silently breaking the Sign-In CTA.
  final analytics = ref.read(unifiedAnalyticsProvider);
  final returnUrlNotifier = ref.read(returnUrlProvider.notifier);
  final router = GoRouter.of(context);
  // Match the persistence shape used by `navigateToLoginPreservingReturn`:
  // preserve the full URI (so deep-link query params survive OAuth) but
  // strip sensitive tokens via the redactor before they hit storage.
  final currentLocation = redactDeepLinkForLogging(
    GoRouterState.of(context).uri,
  );

  analytics.trackAuthPrompt(
    page: AuthPage.login,
    action: AuthPromptAction.view,
    referrer: referrer,
  );
  final result = await showLoginPromptSheet(
    context,
    ref: ref,
    action: action,
    onLogin: () {
      returnUrlNotifier.state = currentLocation;
      router.push('${AppRoutes.login}?from=$referrer');
    },
  );
  if (result != true) {
    analytics.trackAuthPrompt(
      page: AuthPage.login,
      action: AuthPromptAction.dismissed,
      referrer: referrer,
    );
  }
}

/// Extension on WidgetRef for convenience auth checking.
extension AuthGatingExtension on WidgetRef {
  /// Returns true if the current user is authenticated.
  bool get isAuthenticated => read(isAuthenticatedProvider);

  /// Watch the authentication state for reactive UI updates.
  bool get watchAuthenticated => watch(isAuthenticatedProvider);
}
