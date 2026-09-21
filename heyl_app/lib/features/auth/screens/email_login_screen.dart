import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_form_input.dart';
import '../../../shared/widgets/soko_loading_view.dart';
import '../helpers/auth_oauth_handlers.dart';

/// Passwordless email-OTP login (PROD-3594) — the email fallback rung of the
/// phone-login channel ladder. Collects an email, fires [startEmailLogin], and
/// pushes to [EmailOtpVerificationScreen] to enter the 6-digit code.
///
/// The Scaffold, SokoBrandHeader wordmark, and back chevron are owned by
/// `AuthShell`. This screen renders only the body content below the brand
/// surface — mirrors [LoginScreen].
class EmailLoginScreen extends ConsumerStatefulWidget {
  /// When true, renders an amber banner explaining that phone login isn't
  /// available in the user's region — this screen is the fallback they were
  /// routed to.
  final bool regionUnsupported;

  const EmailLoginScreen({super.key, this.regionUnsupported = false});

  @override
  ConsumerState<EmailLoginScreen> createState() => _EmailLoginScreenState();
}

class _EmailLoginScreenState extends ConsumerState<EmailLoginScreen> {
  final _emailController = TextEditingController();
  final _emailFocusNode = FocusNode();

  // Simple "looks like an email" gate: something before an @, a dot after it.
  // The backend does the authoritative validation; this just gates the CTA.
  static final _emailRegExp = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  bool _isEmailValid = false;

  // Drives the full-screen Soko loader while a native social login runs
  // in-process. Local widget state rather than AuthState.isLoading, which is
  // shared with the (fast, inline-spinner) email flow — see LoginScreen.
  bool _socialLoginInProgress = false;

  @override
  void initState() {
    super.initState();
    _emailController.addListener(_onEmailChanged);
  }

  @override
  void dispose() {
    _emailController.removeListener(_onEmailChanged);
    _emailController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  void _onEmailChanged() {
    final valid = _emailRegExp.hasMatch(_emailController.text.trim());
    if (valid != _isEmailValid) {
      setState(() => _isEmailValid = valid);
    }
  }

  Future<void> _handleSubmit() async {
    final email = _emailController.text.trim();
    if (!_emailRegExp.hasMatch(email)) return;

    _emailFocusNode.unfocus();
    final res = await ref
        .read(authStateProvider.notifier)
        .startEmailLogin(email);
    if (res == null || !mounted) return;

    context.push(
      '/auth/email-login/verify?email=${Uri.encodeComponent(email)}',
    );
  }

  /// Run a native social login while showing the full-screen Soko loader.
  /// On success it navigates away and this widget unmounts, so the `finally`
  /// reset no-ops via `mounted`. On cancel/error it hides the loader.
  Future<void> _runSocialLogin(Future<void> Function() action) async {
    setState(() => _socialLoginInProgress = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _socialLoginInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final textSecondaryColor = AppColors.sokoShade3;
    final borderColor = AppColors.sokoInk8;

    final body = SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.regionUnsupported) ...[
            _RegionBanner(text: l10n.emailLoginRegionBanner),
            const SizedBox(height: 24),
          ],
          Text(
            l10n.emailLoginTitle,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.emailLoginSubtitle,
            style: TextStyle(fontSize: 14, color: textSecondaryColor),
          ),
          const SizedBox(height: 24),
          TapRegion(
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            child: SokoFormInput(
              controller: _emailController,
              focusNode: _emailFocusNode,
              hintText: l10n.emailLoginPlaceholder,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autofocus: true,
              onSubmitted: (_) => (authState.isLoading || !_isEmailValid)
                  ? null
                  : _handleSubmit(),
            ),
          ),
          if (authState.error != null) ...[
            const SizedBox(height: 12),
            Text(
              authState.error!,
              style: const TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ],
          const SizedBox(height: 24),
          SokoCtaButton(
            label: l10n.emailLoginSendCode,
            variant: SokoCtaVariant.ink,
            onPressed: (authState.isLoading || !_isEmailValid)
                ? null
                : _handleSubmit,
            loading: authState.isLoading,
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(child: Divider(color: borderColor)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  l10n.emailLoginOr.toUpperCase(),
                  style: TextStyle(fontSize: 12, color: textSecondaryColor),
                ),
              ),
              Expanded(child: Divider(color: borderColor)),
            ],
          ),
          const SizedBox(height: 24),
          _AuthCta(
            label: l10n.emailLoginContinueGoogle,
            background: Colors.white,
            foreground: AppColors.sokoInk,
            border: AppColors.sokoInk.withValues(alpha: 0.12),
            leading: Image.asset(
              'assets/images/google.png',
              width: 18,
              height: 18,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.g_mobiledata, size: 20),
            ),
            onPressed: authState.isLoading
                ? null
                : () {
                    _emailFocusNode.unfocus();
                    _runSocialLogin(() => handleGoogleLogin(ref, context));
                  },
          ),
          if (!kIsWeb && Platform.isIOS) ...[
            const SizedBox(height: 12),
            _AuthCta(
              label: l10n.emailLoginContinueApple,
              background: isDark ? Colors.white : AppColors.sokoInk,
              foreground: isDark ? AppColors.sokoInk : Colors.white,
              onPressed: authState.isLoading
                  ? null
                  : () {
                      _emailFocusNode.unfocus();
                      _runSocialLogin(() => handleAppleLogin(ref, context));
                    },
            ),
          ],
        ],
      ),
    );

    return Stack(
      children: [
        ColoredBox(
          color: AppColors.sokoPaper,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: body,
          ),
        ),
        if (_socialLoginInProgress)
          Positioned.fill(child: SokoLoadingView(message: l10n.authSigningIn)),
      ],
    );
  }
}

/// Amber "phone login isn't available in your region" banner. Shown only when
/// [EmailLoginScreen.regionUnsupported] is true.
class _RegionBanner extends StatelessWidget {
  const _RegionBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.warning, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.sokoInk, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Geometry + typography match the canonical [SokoCtaButton]; differs only in
/// supporting an arbitrary [leading] widget + custom [border] colour, used
/// here for Google's multi-colour PNG icon and the hairline border. Mirrors
/// the `_AuthCta` in `login_screen.dart`.
class _AuthCta extends StatelessWidget {
  const _AuthCta({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onPressed,
    this.leading,
    this.border,
  });

  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;
  final Widget? leading;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: background.withValues(alpha: 0.5),
          disabledForegroundColor: foreground.withValues(alpha: 0.5),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          side: border != null ? BorderSide(color: border!, width: 1) : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Text(
              label,
              style: const TextStyle(
                fontFamily: 'Zalando Sans',
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
