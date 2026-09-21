import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/password_validator.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_form_input.dart';
import '../widgets/password_strength_indicator.dart';

/// Email registration screen
/// Matches Lovable mockup design with bottom-border inputs
class EmailRegisterScreen extends ConsumerStatefulWidget {
  const EmailRegisterScreen({super.key});

  @override
  ConsumerState<EmailRegisterScreen> createState() =>
      _EmailRegisterScreenState();
}

class _EmailRegisterScreenState extends ConsumerState<EmailRegisterScreen> {
  final _emailController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  // Outlives authState.isLoading: stays true through the post-success
  // navigation to /auth/activation-pending so the button doesn't flicker
  // back to enabled while the slide transition is in flight.
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Track signup page view
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackAuthPrompt(
            page: AuthPage.signup,
            action: AuthPromptAction.view,
            referrer: AuthReferrer.onboarding,
          );
      ref
          .read(unifiedAnalyticsProvider)
          .trackLoginPageView(page: PreAuthPage.signup);
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _fullNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (_submitting) return;
    final l10n = Lt.of(context);
    final email = _emailController.text.trim();
    final fullName = _fullNameController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) {
      showSoko(
        ref,
        message: l10n.authValidationEmailEmpty,
        variant: SokoVariant.error,
      );
      return;
    }

    if (password.isEmpty) {
      showSoko(
        ref,
        message: l10n.authRegisterValidationPasswordEmpty,
        variant: SokoVariant.error,
      );
      return;
    }

    // Validate password locally first
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

    // Track email auth method selected on signup
    ref
        .read(unifiedAnalyticsProvider)
        .trackAuthPrompt(
          page: AuthPage.signup,
          action: AuthPromptAction.methodSelected,
          method: AuthMethod.email,
        );

    setState(() => _submitting = true);

    final success = await ref
        .read(authStateProvider.notifier)
        .register(
          email: email,
          password: password,
          fullName: fullName.isNotEmpty ? fullName : null,
        );

    if (!mounted) return;
    if (success) {
      // Skip Siga here — it now fires post-activation via the router gate
      // in app_router.dart (only after the user logs in with an activated
      // account), so the greeting + permission opt-in surface lands *after*
      // the user has confirmed their email. Leave _submitting=true: the
      // screen is unmounting and we don't want the button to flicker.
      context.go(AppRoutes.activationPending, extra: email);
      return;
    }
    setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final l10n = Lt.of(context);
    final password = _passwordController.text;
    // PROD-2073: register screen always uses Soko tokens (no dark variant in
    // the design).
    final textSecondaryColor = AppColors.sokoShade3;

    // ColoredBox keeps the register layer opaque during shell slide
    // transitions so the welcome illustration doesn't bleed through.
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          // Scrollable form area — fields + submit. Terms + "already have
          // an account" link sit *outside* this scroll, pinned to the
          // bottom of the page so they don't get lost mid-form on long
          // viewports.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SokoFormInput(
                    controller: _emailController,
                    hintText: l10n.authRegisterEmailPlaceholder,
                    prefixIcon: Icons.email_outlined,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 20),
                  SokoFormInput(
                    controller: _fullNameController,
                    hintText: l10n.authRegisterFullNamePlaceholder,
                    prefixIcon: Icons.person_outline,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 20),
                  SokoFormInput(
                    controller: _passwordController,
                    hintText: l10n.authRegisterPasswordPlaceholder,
                    prefixIcon: Icons.lock_outline,
                    isPassword: true,
                    obscureText: _obscurePassword,
                    onToggleObscure: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _submitting ? null : _handleSubmit(),
                  ),
                  const SizedBox(height: 16),
                  if (password.isNotEmpty) ...[
                    PasswordStrengthIndicator(password: password),
                    const SizedBox(height: 8),
                  ],
                  if (authState.error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: AppColors.error,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              authState.error!,
                              style: const TextStyle(
                                color: AppColors.error,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  // "By continuing…" disclaimer — sits directly above the
                  // submit button so it's adjacent to the action that
                  // triggers consent.
                  _buildTermsText(l10n, textSecondaryColor),
                  const SizedBox(height: 16),
                  // Submit — canonical SokoCtaButton.
                  SokoCtaButton(
                    label: l10n.authRegisterButtonCreate,
                    onPressed: _submitting ? null : _handleSubmit,
                    loading: _submitting || authState.isLoading,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          // Pinned bottom section — "already have account" link.
          // Lives outside the scroll so it stays anchored at the bottom of
          // the page regardless of form height / viewport size.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // "Already have an account? Sign In" — outlined secondary
                // CTA, same geometry as primary CTAs (h44 / r6 /
                // Zalando Sans 14 w400).
                SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: () => context.pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.sokoInk,
                      side: BorderSide(
                        color: AppColors.sokoInk.withValues(alpha: 0.12),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: Text(
                      '${l10n.authRegisterHaveAccountText}${l10n.authButtonSignIn}',
                      style: const TextStyle(
                        fontFamily: 'Zalando Sans',
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTermsText(Lt l10n, Color textSecondaryColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    final baseStyle = TextStyle(fontSize: 13, color: textSecondaryColor);

    final linkStyle = TextStyle(
      fontSize: 13,
      color: primaryColor,
      decoration: TextDecoration.underline,
      decorationColor: primaryColor,
    );

    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: l10n.authTermsPrefix),
          TextSpan(
            text: l10n.aboutTermsOfService,
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => context.push(AppRoutes.terms),
          ),
          TextSpan(text: l10n.authTermsAndFinal),
          TextSpan(
            text: l10n.aboutPrivacyPolicy,
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => context.push(AppRoutes.privacy),
          ),
        ],
      ),
    );
  }
}
