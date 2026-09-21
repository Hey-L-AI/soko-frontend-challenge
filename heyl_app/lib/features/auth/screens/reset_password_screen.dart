import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/password_validator.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_form_input.dart';
import '../widgets/password_strength_indicator.dart';

/// PROD-2073: deep-link landing after the user clicks the password-reset link
/// in their inbox. Hosted inside [AuthShell], which paints the Scaffold +
/// SafeArea + SokoBrandHeader + back chevron + language picker + PageContent
/// 480-px max-width column. This widget only paints the body over the
/// shell's sokoPaper surface.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  final String? token;

  const ResetPasswordScreen({super.key, this.token});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isSuccess = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final l10n = Lt.of(context);
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (widget.token == null || widget.token!.isEmpty) {
      showSoko(
        ref,
        message: l10n.authResetValidationNoToken,
        variant: SokoVariant.error,
      );
      return;
    }

    if (password.isEmpty) {
      showSoko(
        ref,
        message: l10n.authResetValidationEmpty,
        variant: SokoVariant.error,
      );
      return;
    }

    if (password != confirmPassword) {
      showSoko(
        ref,
        message: l10n.authResetValidationMismatch,
        variant: SokoVariant.error,
      );
      return;
    }

    final validation = PasswordValidator.validate(password);
    if (!validation.isValid) {
      final unmet = validation.unmetRequirementKeys
          .map((r) => labelForRequirement(r, l10n))
          .join(', ');
      showSoko(
        ref,
        message: l10n.authRegisterValidationPasswordMust(unmet),
        variant: SokoVariant.error,
      );
      return;
    }

    final success = await ref
        .read(authStateProvider.notifier)
        .resetPassword(token: widget.token!, newPassword: password);

    if (success && mounted) {
      setState(() => _isSuccess = true);
    }
  }

  void _handleContinue() => context.go(AppRoutes.login);

  void _handleRequestNew() => context.go(AppRoutes.forgotPassword);

  @override
  Widget build(BuildContext context) {
    // ColoredBox keeps the layer opaque during the shell slide transition so
    // the previous screen doesn't bleed through.
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (widget.token == null || widget.token!.isEmpty) {
      return _buildInvalidTokenView();
    }
    if (_isSuccess) return _buildSuccessView();
    return _buildFormView();
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
    final password = _passwordController.text;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIllustration(
          'assets/images/illustrations/soko-walking-and-reading.webp',
          width: 140,
        ),
        const SizedBox(height: 16),
        _buildHeading(l10n.authResetTitle),
        const SizedBox(height: 12),
        _buildBody(l10n.authResetSubtitle, color: AppColors.sokoShade3),
        const SizedBox(height: 28),
        SokoFormInput(
          controller: _passwordController,
          hintText: l10n.authResetNewPasswordLabel,
          prefixIcon: Icons.lock_outline,
          isPassword: true,
          obscureText: _obscurePassword,
          onToggleObscure: () =>
              setState(() => _obscurePassword = !_obscurePassword),
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        if (password.isNotEmpty) ...[
          PasswordStrengthIndicator(password: password),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        SokoFormInput(
          controller: _confirmPasswordController,
          hintText: l10n.authResetConfirmPasswordLabel,
          prefixIcon: Icons.lock_outline,
          isPassword: true,
          obscureText: _obscureConfirmPassword,
          onToggleObscure: () => setState(
            () => _obscureConfirmPassword = !_obscureConfirmPassword,
          ),
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
          label: l10n.authResetButtonSubmit,
          onPressed: authState.isLoading ? null : _handleSubmit,
          loading: authState.isLoading,
        ),
      ],
    );
  }

  Widget _buildSuccessView() {
    final l10n = Lt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIllustration(
          'assets/images/illustrations/soko-seating-and-reading.webp',
        ),
        const SizedBox(height: 24),
        _buildHeading(l10n.authResetSuccessTitle),
        const SizedBox(height: 12),
        _buildBody(l10n.authResetSuccessSubtitle),
        const SizedBox(height: 32),
        SokoCtaButton(label: l10n.authButtonSignIn, onPressed: _handleContinue),
      ],
    );
  }

  Widget _buildInvalidTokenView() {
    final l10n = Lt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIllustration(
          'assets/images/illustrations/soko-walking-in-crowd.webp',
        ),
        const SizedBox(height: 24),
        _buildHeading(l10n.authResetInvalidTitle),
        const SizedBox(height: 12),
        _buildBody(l10n.authResetInvalidSubtitle, color: AppColors.sokoShade3),
        const SizedBox(height: 32),
        SokoCtaButton(
          label: l10n.authResetButtonRequestNew,
          onPressed: _handleRequestNew,
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: _handleContinue,
            child: Text(
              l10n.authResetButtonBackToSignIn,
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
