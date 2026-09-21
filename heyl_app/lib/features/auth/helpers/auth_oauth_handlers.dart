import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../providers/auth_provider.dart';

/// Shared Google sign-in handler used by both the welcome landing and the
/// login form screen. Fires the methodSelected analytics event, triggers the
/// auth notifier, and navigates to home on success.
Future<void> handleGoogleLogin(WidgetRef ref, BuildContext context) async {
  ref
      .read(unifiedAnalyticsProvider)
      .trackAuthPrompt(
        page: AuthPage.login,
        action: AuthPromptAction.methodSelected,
        method: AuthMethod.google,
      );
  final returnUrl = ref.read(returnUrlProvider);
  final success = await ref
      .read(authStateProvider.notifier)
      .startGoogleLogin(returnUrl: returnUrl);
  // On native, Google login completes in-process (no page redirect).
  // Navigate explicitly because the router redirect doesn't handle
  // pushed routes (login screen may have been pushed from profile sheet).
  if (success && context.mounted) {
    // PROD-2689: honor a captured returnUrl (e.g. a `/drop` / `/weekly-bundle`
    // deep-link login) instead of always landing on home. The native Google
    // flow completes in-process and does NOT pass through OAuthCallbackScreen
    // (which restores returnUrl on web), so the restore must happen here —
    // matching the phone-OTP path (otp_verification_screen.dart).
    if (returnUrl != null) {
      ref.read(returnUrlProvider.notifier).state = null;
      context.go(returnUrl);
    } else {
      context.go(AppRoutes.home);
    }
  }
}

Future<void> handleAppleLogin(WidgetRef ref, BuildContext context) async {
  ref
      .read(unifiedAnalyticsProvider)
      .trackAuthPrompt(
        page: AuthPage.login,
        action: AuthPromptAction.methodSelected,
        method: AuthMethod.apple,
      );
  final returnUrl = ref.read(returnUrlProvider);
  final success = await ref.read(authStateProvider.notifier).startAppleLogin();
  if (success && context.mounted) {
    // PROD-2689: mirror handleGoogleLogin — honor a captured returnUrl so a
    // deep-link login (`/drop`, `/weekly-bundle`) reopens after Apple sign-in.
    if (returnUrl != null) {
      ref.read(returnUrlProvider.notifier).state = null;
      context.go(returnUrl);
    } else {
      context.go(AppRoutes.home);
    }
  }
}
