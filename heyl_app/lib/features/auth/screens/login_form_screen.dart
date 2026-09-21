import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/phone_formatter.dart';
import '../../../data/models/country.dart';
import '../../../data/repositories/country_repository.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/detected_country_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_form_input.dart';
import '../../../shared/widgets/soko_form_phone_input.dart';
import '../helpers/auth_oauth_handlers.dart';
import '../helpers/guest_session_starter.dart';
import '../helpers/auth_error_text.dart';

/// Login form screen — tabbed Phone / Email login plus Google/Apple/Guest
/// sign-in. Reached from the welcome landing via `context.push('/login/form')`.
///
/// The Scaffold + SokoBrandHeader + back chevron are owned by [AuthShell] so
/// the brand surface stays anchored across auth transitions. This screen
/// renders only the form body that slides in below the shell.
class LoginFormScreen extends ConsumerStatefulWidget {
  const LoginFormScreen({super.key});

  @override
  ConsumerState<LoginFormScreen> createState() => _LoginFormScreenState();
}

class _LoginFormScreenState extends ConsumerState<LoginFormScreen> {
  // Method toggle: 0 = phone, 1 = email
  int _selectedMethod = 0;

  // Phone login controllers
  final _phoneController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  // Default reverted to SMS — WhatsApp-first rollout paused pending
  // production BE verification. Channel-aware OTP-screen infrastructure
  // (status mode, SMS-fallback link, 30 s timer, analytics) stays.
  final String _selectedChannel = 'sms';
  Country _selectedCountry = CountryRepository.defaultCountry;
  bool _didApplyDetectedCountry = false;

  // Email login controllers
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reset stale isLoading if the form is mounted while loading
      // (e.g. user navigated back from Google OAuth without completing).
      final authState = ref.read(authStateProvider);
      if (authState.isLoading) {
        ref.read(authStateProvider.notifier).cancelOAuth();
      }
    });
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handlePhoneSubmit() async {
    final l10n = Lt.of(context);
    final localPhone = _phoneController.text.trim();
    if (localPhone.isEmpty) {
      showSoko(
        ref,
        message: l10n.authValidationPhoneEmpty,
        variant: SokoVariant.error,
      );
      return;
    }

    ref
        .read(unifiedAnalyticsProvider)
        .trackAuthPrompt(
          page: AuthPage.login,
          action: AuthPromptAction.methodSelected,
          method: AuthMethod.phone,
        );

    final e164Phone = PhoneFormatter.toE164(localPhone, _selectedCountry);

    final response = await ref
        .read(authStateProvider.notifier)
        .startPhoneLogin(e164Phone, channel: _selectedChannel);

    if (response == null || !mounted) return;

    unawaited(
      ref
          .read(unifiedAnalyticsProvider)
          .trackOtpSend(
            channelRequested: _selectedChannel,
            channelResponse: response.channel,
            status: response.status,
            smsFallbackAvailable: response.smsFallbackAvailable,
          ),
    );

    final encodedPhone = Uri.encodeComponent(e164Phone);
    context.push(
      '${AppRoutes.otpVerify}?phone=$encodedPhone'
      '&channel=${response.channel}'
      '&smsFallbackAvailable=${response.smsFallbackAvailable}'
      '&status=${response.status}',
    );
  }

  Future<void> _handleEmailSubmit() async {
    final l10n = Lt.of(context);
    final email = _emailController.text.trim();
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
        message: l10n.authValidationPasswordEmpty,
        variant: SokoVariant.error,
      );
      return;
    }

    ref
        .read(unifiedAnalyticsProvider)
        .trackAuthPrompt(
          page: AuthPage.login,
          action: AuthPromptAction.methodSelected,
          method: AuthMethod.email,
        );

    final success = await ref
        .read(authStateProvider.notifier)
        .loginWithEmail(email: email, password: password);

    if (success && mounted) {
      final returnUrl = ref.read(returnUrlProvider);
      if (returnUrl != null) {
        ref.read(returnUrlProvider.notifier).state = null;
        context.go(returnUrl);
      } else {
        context.go(AppRoutes.home);
      }
    } else if (!success && mounted) {
      final authState = ref.read(authStateProvider);
      if (authState.pendingActivationEmail != null) {
        context.go(AppRoutes.activationPending, extra: email);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Apply detected country for phone input (only once, on first load)
    final detectedCountry = ref.watch(defaultPhoneCountryProvider);
    if (!_didApplyDetectedCountry &&
        detectedCountry != CountryRepository.defaultCountry) {
      _didApplyDetectedCountry = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _selectedCountry = detectedCountry;
          });
        }
      });
    }

    final textSecondaryColor = AppColors.sokoShade3;
    final textPrimaryColor = AppColors.sokoInk;
    final primaryColor = AppColors.sokoInk;
    final borderColor = AppColors.sokoInk8;
    final backgroundColor = AppColors.sokoPaper;

    // ColoredBox keeps the form layer opaque during shell slide
    // transitions so the welcome illustration doesn't bleed through.
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildMethodToggle(l10n),
                  const SizedBox(height: 24),
                  if (_selectedMethod == 0)
                    _buildPhoneTab(
                      authState,
                      l10n,
                      textPrimaryColor,
                      backgroundColor,
                    )
                  else
                    _buildEmailTab(
                      authState,
                      l10n,
                      textPrimaryColor,
                      backgroundColor,
                      primaryColor,
                      textSecondaryColor,
                    ),
                  if (authState.displayError(l10n) case final errorText?) ...[
                    const SizedBox(height: 16),
                    Text(
                      errorText,
                      style: const TextStyle(color: AppColors.error),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      Expanded(child: Divider(color: borderColor)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          l10n.authDividerOr.toUpperCase(),
                          style: TextStyle(
                            fontSize: 12,
                            color: textSecondaryColor,
                          ),
                        ),
                      ),
                      Expanded(child: Divider(color: borderColor)),
                    ],
                  ),
                  const SizedBox(height: 32),
                  _AuthCta(
                    label: l10n.authButtonGoogle,
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
                        : () => handleGoogleLogin(ref, context),
                  ),
                  if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) ...[
                    const SizedBox(height: 12),
                    _AuthCta(
                      label: l10n.authButtonApple,
                      background: isDark ? Colors.white : AppColors.sokoInk,
                      foreground: isDark ? AppColors.sokoInk : Colors.white,
                      leading: _AppleLogo(
                        color: isDark ? AppColors.sokoInk : Colors.white,
                      ),
                      onPressed: authState.isLoading
                          ? null
                          : () => handleAppleLogin(ref, context),
                    ),
                  ],
                  // Continue-as-guest is web-only. Native apps require a
                  // real sign-in — the router redirect enforces this even
                  // if a stale build still shows the button.
                  if (kIsWeb) ...[
                    const SizedBox(height: 12),
                    _AuthCta(
                      label: l10n.authEnterAsGuest,
                      background: Colors.transparent,
                      foreground: textSecondaryColor,
                      border: borderColor,
                      onPressed: authState.isLoading
                          ? null
                          : () async {
                              ref
                                  .read(unifiedAnalyticsProvider)
                                  .trackAuthPrompt(
                                    page: AuthPage.login,
                                    action: AuthPromptAction.methodSelected,
                                    method: AuthMethod.guest,
                                  );
                              await startGuestSession(context, ref);
                            },
                    ),
                  ],
                  const SizedBox(height: 24),
                  _buildTermsText(l10n, textSecondaryColor),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMethodToggle(Lt l10n) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.sokoInk.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Expanded(
            child: _MethodPill(
              label: l10n.authTabPhone,
              isSelected: _selectedMethod == 0,
              onTap: () => setState(() => _selectedMethod = 0),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _MethodPill(
              label: l10n.authTabEmail,
              isSelected: _selectedMethod == 1,
              onTap: () => setState(() => _selectedMethod = 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneTab(
    AuthState authState,
    Lt l10n,
    Color textPrimaryColor,
    Color backgroundColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SokoFormPhoneInput(
          controller: _phoneController,
          focusNode: _phoneFocusNode,
          hintText: l10n.authPhonePlaceholder,
          selectedCountry: _selectedCountry,
          onCountryChanged: (country) {
            setState(() {
              _selectedCountry = country;
            });
          },
          onSubmitted: (_) => authState.isLoading ? null : _handlePhoneSubmit(),
        ),
        const SizedBox(height: 24),
        SokoCtaButton(
          label: l10n.authButtonSignIn,
          onPressed: authState.isLoading ? null : _handlePhoneSubmit,
          loading: authState.isLoading,
        ),
      ],
    );
  }

  Widget _buildEmailTab(
    AuthState authState,
    Lt l10n,
    Color textPrimaryColor,
    Color backgroundColor,
    Color primaryColor,
    Color textSecondaryColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SokoFormInput(
          controller: _emailController,
          hintText: l10n.authEmailPlaceholder,
          prefixIcon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 20),
        SokoFormInput(
          controller: _passwordController,
          hintText: l10n.authPasswordPlaceholder,
          prefixIcon: Icons.lock_outline,
          isPassword: true,
          obscureText: _obscurePassword,
          onToggleObscure: () =>
              setState(() => _obscurePassword = !_obscurePassword),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => authState.isLoading ? null : _handleEmailSubmit(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () => context.push(AppRoutes.forgotPassword),
            child: Text(
              l10n.authForgotPassword,
              style: TextStyle(color: primaryColor, fontSize: 14),
            ),
          ),
        ),
        const SizedBox(height: 20),
        SokoCtaButton(
          label: l10n.authButtonSignIn,
          onPressed: authState.isLoading ? null : _handleEmailSubmit,
          loading: authState.isLoading,
        ),
      ],
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

/// Single pill inside the Phone / Email segmented control. Visual spec
/// mirrors `_VisibilityPill` in `lists/widgets/list_visibility_toggle.dart`
/// so the login funnel and the list visibility toggle read as the same
/// component.
class _MethodPill extends StatelessWidget {
  const _MethodPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.sokoInk : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.w500 : FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: isSelected
                  ? AppColors.sokoPaper
                  : AppColors.sokoInk.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

/// Geometry + typography match the canonical `SokoCtaButton` (height 44,
/// radius 6, 24 px horizontal pad, Zalando Sans 14/400). Differs only in
/// supporting an arbitrary `leading` widget + custom `border` colour, used
/// here for Google's multi-colour PNG icon and the hairline border on
/// secondary CTAs.
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

/// Apple logo glyph rendered via the official painter from the
/// `sign_in_with_apple` package so the icon stays HIG-compliant while the
/// surrounding button matches our design system typography.
class _AppleLogo extends StatelessWidget {
  const _AppleLogo({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 18,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: CustomPaint(painter: AppleLogoPainter(color: color)),
      ),
    );
  }
}
