import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_form_input.dart';

/// PROD-2073: "Forgot your password?" entry point (request a reset email).
/// Hosted inside [AuthShell], which paints the Scaffold + SafeArea +
/// SokoBrandHeader + back chevron + language picker + PageContent (480-px
/// max-width column). This widget only paints the body over the shell's
/// sokoPaper surface.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  bool _emailSent = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final l10n = Lt.of(context);
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      showSoko(
        ref,
        message: l10n.authValidationEmailEmpty,
        variant: SokoVariant.error,
      );
      return;
    }

    await ref.read(authStateProvider.notifier).forgotPassword(email);

    // Always show success for security — don't reveal whether the email exists.
    if (mounted) {
      setState(() => _emailSent = true);
    }
  }

  void _handleBackToLogin() => context.go(AppRoutes.login);

  @override
  Widget build(BuildContext context) {
    // ColoredBox keeps the layer opaque during the shell slide transition.
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        child: _emailSent ? _buildSuccessView() : _buildFormView(),
      ),
    );
  }

  Widget _buildIllustration(String asset, {double width = 200}) {
    return Center(
      child: Image.asset(
        asset,
        width: width,
        fit: BoxFit.contain,
        semanticLabel: 'Soko',
      ),
    );
  }

  Widget _buildHeading(String text) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontFamily: 'SeasonMix',
        fontSize: 32,
        fontWeight: FontWeight.w400,
        height: 1.05,
        color: AppColors.sokoInk,
      ),
    );
  }

  Widget _buildBody(String text, {Color color = AppColors.sokoInk}) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 15, height: 1.35, color: color),
    );
  }

  Widget _buildFormView() {
    final authState = ref.watch(authStateProvider);
    final l10n = Lt.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIllustration(
          'assets/images/illustrations/soko-walking-and-reading.webp',
          width: 140,
        ),
        const SizedBox(height: 16),
        _buildHeading(l10n.authForgotTitle),
        const SizedBox(height: 12),
        _buildBody(l10n.authForgotSubtitle, color: AppColors.sokoShade3),
        const SizedBox(height: 28),
        SokoFormInput(
          controller: _emailController,
          hintText: l10n.authForgotEmailPlaceholder,
          prefixIcon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => authState.isLoading ? null : _handleSubmit(),
        ),
        if (authState.error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.sokoRed.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: AppColors.sokoInk,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    authState.error!,
                    style: const TextStyle(
                      color: AppColors.sokoInk,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        SokoCtaButton(
          label: l10n.authForgotButtonSend,
          onPressed: authState.isLoading ? null : _handleSubmit,
          loading: authState.isLoading,
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              l10n.authForgotRememberText,
              style: const TextStyle(color: AppColors.sokoShade3, fontSize: 14),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: _handleBackToLogin,
              child: Text(
                l10n.authButtonSignIn,
                style: const TextStyle(
                  color: AppColors.sokoInk,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSuccessView() {
    final l10n = Lt.of(context);
    final email = _emailController.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIllustration(
          'assets/images/illustrations/soko-seating-and-reading.webp',
        ),
        const SizedBox(height: 24),
        _buildHeading(l10n.authForgotSuccessTitle),
        const SizedBox(height: 12),
        _buildBody(
          l10n.authForgotSuccessSubtitle(email),
          color: AppColors.sokoShade3,
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.sokoYellow.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.info_outline,
                color: AppColors.sokoInk,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.authForgotSpamNotice,
                  style: const TextStyle(
                    color: AppColors.sokoInk,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SokoCtaButton(
          label: l10n.authForgotButtonBack,
          onPressed: _handleBackToLogin,
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: () => setState(() => _emailSent = false),
            child: Text(
              l10n.authForgotButtonTryDifferent,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontWeight: FontWeight.w600,
                fontSize: 14,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
