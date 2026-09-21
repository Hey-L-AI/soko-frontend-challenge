import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import 'auth_language_button.dart';
import 'soko_brand_header.dart';

/// Shell wrapper for the auth funnel routes (welcome, login form, register,
/// OTP). Owns the Scaffold + SafeArea + SokoBrandHeader so the wordmark sits
/// at the exact same pixel Y on every auth screen — the routed child slides
/// in/out below it without disturbing the brand surface.
///
/// The back chevron (left) and language picker (right) are floated as
/// `Positioned` overlays inside a `Stack` so they don't push the wordmark
/// down. Both controls use the same bare styling as the rest of the app
/// (menu sub-screens, `AuthHeader`) — no background chip, no border, no
/// elevation.
///
/// The current route is delivered via [currentLocation] (sourced from
/// `state.uri.path` in the ShellRoute's pageBuilder) instead of read from
/// `routeInformationProvider.value` inside `build()`. The notifier-based
/// read raced microtask ordering: on push, the shell rebuilt with the new
/// child before the notifier's value updated, so `isWelcome` evaluated
/// against the stale path and the back chevron stayed hidden.
class AuthShell extends ConsumerWidget {
  final String currentLocation;
  final Widget child;

  const AuthShell({
    super.key,
    required this.currentLocation,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goRouter = GoRouter.of(context);
    final isWelcome = currentLocation == AppRoutes.login;
    final canPop = goRouter.canPop();
    final showBack = !isWelcome;
    // PROD-2161: the OAuth callback ("Verifying your account…") owns the
    // whole surface — no brand wordmark, no back chevron, no language
    // picker. It's a brief in-flight screen and any chrome competes with
    // the centered character + status text. Still inherits the sokoPaper
    // background + safe area + PageContent max-width below.
    final isChromeless = currentLocation == AppRoutes.authCallback;

    return Scaffold(
      backgroundColor: AppColors.sokoPaper,
      body: SafeArea(
        // PageContent centres the auth funnel in the same 480-max-width
        // column Discovery uses, so the SokoBrandHeader wordmark renders
        // at the exact same pixel width across the two surfaces on
        // desktop. Below the breakpoint it fills the viewport.
        child: PageContent(
          child: Stack(
            children: [
              Column(
                children: [
                  if (!isChromeless) const SokoBrandHeader(),
                  // Session-replay: mask the entire auth funnel body. Every
                  // credential surface (phone, email, and both OTP screens)
                  // routes through here as `child`, so one wrap hides them all
                  // in native recordings. The SokoBrandHeader + nav chrome
                  // above stay visible (not PII). See posthog_service.dart.
                  Expanded(child: PostHogMaskWidget(child: child)),
                ],
              ),
              if (!isChromeless) ...[
                // Back chevron — fades in/out across the slide transition.
                // Deep-link landings (no Navigator history) fall through to
                // context.go('/login') so the user is never stranded.
                Positioned(
                  top: 4,
                  left: 4,
                  child: AnimatedOpacity(
                    opacity: showBack ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeInOut,
                    child: IgnorePointer(
                      ignoring: !showBack,
                      child: _AuthBackButton(
                        onTap: canPop
                            ? () => goRouter.pop()
                            : () => context.go(AppRoutes.login),
                      ),
                    ),
                  ),
                ),
                // Language picker — top-right overlay on every auth screen
                // except `/login`, where the picker is rendered inline next
                // to the phone input so the two controls share a row.
                if (!isWelcome)
                  const Positioned(
                    top: 4,
                    right: 4,
                    child: AuthLanguageButton(),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Bare back chevron matching the menu sub-screens
/// (`account_screen.dart`, `preferences_screen.dart`, etc.) — no background
/// chip, no border, no elevation.
class _AuthBackButton extends StatelessWidget {
  const _AuthBackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        icon: const Icon(
          LucideIcons.arrow_left,
          size: 20,
          color: AppColors.sokoInk,
        ),
        onPressed: onTap,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      ),
    );
  }
}
