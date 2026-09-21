import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../core/config/environment.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/phone_formatter.dart';
import '../../../data/models/api_responses.dart';
import '../../../data/models/country.dart';
import '../../../data/repositories/country_repository.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/detected_country_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_form_phone_input.dart';
import '../../../shared/widgets/soko_loading_view.dart';
import '../helpers/auth_oauth_handlers.dart';
import '../helpers/guest_session_starter.dart';
import '../helpers/auth_error_text.dart';
import '../widgets/auth_language_button.dart';

/// Single-screen login (PROD-2161). Replaces the previous welcome →
/// login-form two-step funnel with a phone-first surface: illustration on
/// top, phone input + "Iniciar Sessão" gated on a valid number, "—— OR ——"
/// divider, then Google / Apple (iOS) / Guest (web) and terms text.
///
/// The Scaffold, SokoBrandHeader, and back chevron are owned by [AuthShell].
/// This screen renders only the content that slides in below the brand
/// surface.
class LoginScreen extends ConsumerStatefulWidget {
  /// When true, the caller already fired auth_prompt(view) — skip the
  /// duplicate event in initState.
  final bool skipAuthPromptView;

  const LoginScreen({super.key, this.skipAuthPromptView = false});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  // GlobalKey on the input bundle so the TextField's EditableText state
  // survives the body's Column ↔ Stack swap when focus flips. Without this,
  // the first tap focuses → setState → body parent type changes → entire
  // subtree is disposed + recreated → the new TextField has no connection to
  // the soft keyboard the old one just opened, so the keyboard dismisses and
  // a second tap is needed. PR #603 shipped the layout swap without it.
  final GlobalKey _inputBundleKey = GlobalKey();
  // WhatsApp-first (PROD-3594): the first phone/start requests WhatsApp — the
  // cheapest, fraud-resistant channel. The channel-aware OTP screen then offers
  // SMS as a manual backup (allowlisted countries) and email as the final rung.
  final String _selectedChannel = PhoneStartResponse.channelWhatsapp;
  Country _selectedCountry = CountryRepository.defaultCountry;
  bool _didApplyDetectedCountry = false;
  bool _isPhoneValid = false;
  bool _hasPhoneInput = false;
  bool _isPhoneFocused = false;
  // PROD-2486 — drives the full-screen Soko loader while a native social
  // login (Google/Apple) runs in-process. Kept as local widget state rather
  // than reusing AuthState.isLoading, which is shared with the (fast, inline-
  // spinner) phone/email flows and would wrongly trigger the overlay there.
  bool _socialLoginInProgress = false;

  @override
  void initState() {
    super.initState();
    _phoneController.addListener(_onPhoneChanged);
    _phoneFocusNode.addListener(_onPhoneFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reset stale isLoading if the screen is mounted while loading
      // (e.g. user navigated back from Google OAuth without completing).
      final authState = ref.read(authStateProvider);
      if (authState.isLoading) {
        ref.read(authStateProvider.notifier).cancelOAuth();
      }

      // Track auth prompt view (skip if caller already fired it).
      if (!widget.skipAuthPromptView) {
        ref
            .read(unifiedAnalyticsProvider)
            .trackAuthPrompt(
              page: AuthPage.login,
              action: AuthPromptAction.view,
              referrer: AuthReferrer.onboarding,
            );
      }
      ref
          .read(unifiedAnalyticsProvider)
          .trackLoginPageView(page: PreAuthPage.login);
    });
  }

  @override
  void dispose() {
    _phoneController.removeListener(_onPhoneChanged);
    _phoneFocusNode.removeListener(_onPhoneFocusChange);
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  void _onPhoneFocusChange() {
    // Focus can flip during route teardown — e.g. tapping a CTA fires
    // `unfocus()` synchronously, then the closure changes routes and the
    // screen begins disposing. Guard the setState so the post-frame rebuild
    // doesn't land on a defunct element.
    if (!mounted) return;
    final focused = _phoneFocusNode.hasFocus;
    if (focused != _isPhoneFocused) {
      setState(() => _isPhoneFocused = focused);
    }
  }

  void _onPhoneChanged() {
    final text = _phoneController.text;
    final valid = PhoneFormatter.isValidLength(text);
    final hasInput = text.trim().isNotEmpty;
    if (valid != _isPhoneValid || hasInput != _hasPhoneInput) {
      setState(() {
        _isPhoneValid = valid;
        _hasPhoneInput = hasInput;
      });
    }
  }

  Future<void> _handlePhoneSubmit() async {
    final localPhone = _phoneController.text.trim();
    if (!PhoneFormatter.isValidLength(localPhone)) return;

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

    // PROD-2632: fire otp_send for every send attempt — the analytics
    // funnel needs visibility into channel adoption + per-status volume
    // (Twilio dashboard sees only the request side).
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

    // PROD-3594 ladder: when neither WhatsApp nor SMS can serve this country
    // (region_unsupported), skip the code-less OTP screen and drop straight
    // into the email fallback rung with the "can't text your region" banner.
    if (response.status == PhoneStartResponse.statusRegionUnsupported) {
      context.push('${AppRoutes.emailLogin}?reason=region');
      return;
    }

    final encodedPhone = Uri.encodeComponent(e164Phone);
    context.push(
      '${AppRoutes.otpVerify}?phone=$encodedPhone'
      '&channel=${response.channel}'
      '&smsFallbackAvailable=${response.smsFallbackAvailable}'
      '&status=${response.status}',
    );
  }

  /// PROD-2486 — run a native social login while showing the full-screen Soko
  /// loader. [action] is the awaited OAuth handler; on success it navigates
  /// away and this widget unmounts, so the `finally` reset no-ops via
  /// `mounted`. On cancel/error it resets and hides the loader.
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

    // Apply detected country for phone input (only once, on first load).
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
    final borderColor = AppColors.sokoInk8;

    // On mobile widths, hide the illustration once the user focuses the
    // phone input and vertically center the input bundle — keeps the field
    // above the soft keyboard and matches the centered layout used on the
    // OTP screen.
    final isMobileWidth =
        MediaQuery.of(context).size.width < PageLayout.desktopBreakpoint;
    final showIllustration = !(_isPhoneFocused && isMobileWidth);

    // Input + alternatives bundle — extracted so we can swap the surrounding
    // layout between the illustration-on-top mode (Column with Expanded) and
    // the focused-centered mode (Stack with terms pinned to the bottom).
    // KeyedSubtree + GlobalKey preserves the TextField's EditableText state
    // (and its soft-keyboard binding) across that structural swap.
    final inputBundle = KeyedSubtree(
      key: _inputBundleKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // TapRegion wraps only the phone input row — every other pixel on
          // the screen (above, below, sides, terms, OAuth buttons, brand
          // header) counts as "outside" and dismisses the keyboard. Wrapping
          // the whole body (PR #603) left every dead zone "inside" the
          // region, so onTapOutside never fired.
          //
          // Language picker sits on the same row as the phone input so it's
          // discoverable without competing with the wordmark for the
          // top-right slot (the `AuthShell` overlay is suppressed on
          // `/login` — see `auth_shell.dart`). Phone input takes the
          // remaining horizontal space via `Expanded`; the picker
          // shrink-wraps to content.
          TapRegion(
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: SokoFormPhoneInput(
                    controller: _phoneController,
                    focusNode: _phoneFocusNode,
                    hintText: l10n.authPhonePlaceholder,
                    selectedCountry: _selectedCountry,
                    onCountryChanged: (country) {
                      setState(() {
                        _selectedCountry = country;
                      });
                    },
                    onSubmitted: (_) => (authState.isLoading || !_isPhoneValid)
                        ? null
                        : _handlePhoneSubmit(),
                    showClearButton: true,
                  ),
                ),
                const SizedBox(width: 8),
                const AuthLanguageButton(),
              ],
            ),
          ),
          if (authState.displayError(l10n) case final errorText?) ...[
            const SizedBox(height: 16),
            Text(
              errorText,
              style: const TextStyle(color: AppColors.error),
              textAlign: TextAlign.center,
            ),
          ],
          // The middle section keeps a stable footprint: a Stack sized to
          // the (larger) alternatives column, with the (smaller) Sign In
          // button layered on top. The two states slide horizontally —
          // alternatives exit to the left, Sign In enters from the right
          // (and vice versa). ClipRect prevents the off-stage child from
          // bleeding into the page edges during the swap. Opacity runs
          // alongside the slide so the mid-transition overlap is clean
          // rather than smeared.
          ClipRect(
            child: Stack(
              alignment: AlignmentDirectional.topCenter,
              children: [
                _AltsSlideLayer(
                  hasPhoneInput: _hasPhoneInput,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(child: Divider(color: borderColor)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              l10n.authDividerOr.toLowerCase(),
                              style: TextStyle(
                                fontSize: 14,
                                letterSpacing: -0.14,
                                color: textSecondaryColor,
                              ),
                            ),
                          ),
                          Expanded(child: Divider(color: borderColor)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _AuthCta(
                        label: l10n.authButtonGoogle,
                        background: AppColors.sokoPaper,
                        foreground: AppColors.sokoInk,
                        border: AppColors.sokoInk.withValues(alpha: 0.1),
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
                                _phoneFocusNode.unfocus();
                                _runSocialLogin(
                                  () => handleGoogleLogin(ref, context),
                                );
                              },
                      ),
                      if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) ...[
                        const SizedBox(height: 12),
                        _AuthCta(
                          label: l10n.authButtonApple,
                          background: AppColors.sokoPaper,
                          foreground: AppColors.sokoInk,
                          border: AppColors.sokoInk.withValues(alpha: 0.1),
                          leading: const _AppleLogo(color: AppColors.sokoInk),
                          onPressed: authState.isLoading
                              ? null
                              : () {
                                  _phoneFocusNode.unfocus();
                                  _runSocialLogin(
                                    () => handleAppleLogin(ref, context),
                                  );
                                },
                        ),
                      ],
                      // Continue-as-guest: web keeps it unconditionally; on
                      // native it is gated by [EnvironmentConfig.guestModeEnabled]
                      // (Apple 5.1.1(v) still satisfied on web; native removal
                      // is a compile-time flip). Hidden — not just disabled —
                      // so no dead entry point can set the guest flag.
                      if (EnvironmentConfig.guestModeEnabled) ...[
                        const SizedBox(height: 12),
                        _AuthCta(
                          label: l10n.authEnterAsGuest,
                          background: Colors.transparent,
                          foreground: textSecondaryColor,
                          border: borderColor,
                          onPressed: authState.isLoading
                              ? null
                              : () async {
                                  _phoneFocusNode.unfocus();
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
                    ],
                  ),
                ),
                _SignInSlideLayer(
                  hasPhoneInput: _hasPhoneInput,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 16),
                      SokoCtaButton(
                        label: l10n.authButtonContinue,
                        onPressed: (authState.isLoading || !_isPhoneValid)
                            ? null
                            : _handlePhoneSubmit,
                        loading: authState.isLoading,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final termsRow = _buildTermsText(l10n, textSecondaryColor);

    // Two layouts:
    //   - `showIllustration` (default / wide viewports): Soko on top inside an
    //     `Expanded` so it scales with the viewport, then input + CTAs + terms
    //     stacked below. Non-scrolling per PROD-2161.
    //   - focused on mobile: Column with the input bundle vertically centered
    //     in the available area (above the terms) and the terms in normal flow
    //     at the bottom. With the soft keyboard open the Scaffold shrinks this
    //     area, so the bundle still centers above the keyboard. The terms live
    //     in flow rather than a bottom-pinned Stack layer so the (now ~6-line)
    //     disclaimer can never overlap the OAuth buttons — PROD-2265 grew the
    //     terms past the height the old pinned Stack assumed. The Center is
    //     wrapped in a SingleChildScrollView so the bundle can scroll rather
    //     than clip on very short viewports.
    final Widget body = showIllustration
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: Center(child: _buildWelcomeIllustration())),
              const SizedBox(height: 16),
              inputBundle,
              const SizedBox(height: 16),
              termsRow,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Center(child: SingleChildScrollView(child: inputBundle)),
              ),
              const SizedBox(height: 16),
              termsRow,
            ],
          );

    return Stack(
      children: [
        ColoredBox(
          color: AppColors.sokoPaper,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: body,
          ),
        ),
        // PROD-2486 — full-screen Soko loader over the login content while a
        // native social login waits on the backend (the account picker has
        // already dismissed, so without this the user stares at a frozen
        // screen for ~5s).
        if (_socialLoginInProgress)
          Positioned.fill(child: SokoLoadingView(message: l10n.authSigningIn)),
      ],
    );
  }

  Widget _buildWelcomeIllustration() {
    // Wrapped in `Expanded` by the caller so the illustration scales
    // smoothly with the leftover viewport height. `BoxFit.contain` keeps
    // the aspect ratio; on tiny viewports the illustration squeezes (and
    // can collapse to 0) so the inputs + CTAs always stay visible without
    // introducing a scroll.
    return Image.asset(
      'assets/images/illustrations/soko-walking-in-crowd.webp',
      fit: BoxFit.contain,
      semanticLabel: 'Soko',
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

/// Alternatives layer in the cross-fade Stack. Slides out to the left when
/// the user starts typing and fades out alongside the slide so the
/// transition reads cleanly instead of overlapping the Sign In button
/// mid-flight.
class _AltsSlideLayer extends StatelessWidget {
  const _AltsSlideLayer({required this.hasPhoneInput, required this.child});

  final bool hasPhoneInput;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      offset: hasPhoneInput ? const Offset(-1, 0) : Offset.zero,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        opacity: hasPhoneInput ? 0.0 : 1.0,
        child: IgnorePointer(ignoring: hasPhoneInput, child: child),
      ),
    );
  }
}

/// Sign In layer in the cross-fade Stack. Slides in from the right when the
/// user types and slides back off-stage when the field is cleared. Width
/// is forced to `double.infinity` so the button stretches across the same
/// horizontal span as the alternatives column underneath.
class _SignInSlideLayer extends StatelessWidget {
  const _SignInSlideLayer({required this.hasPhoneInput, required this.child});

  final bool hasPhoneInput;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      offset: hasPhoneInput ? Offset.zero : const Offset(1, 0),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        opacity: hasPhoneInput ? 1.0 : 0.0,
        child: IgnorePointer(
          ignoring: !hasPhoneInput,
          child: SizedBox(width: double.infinity, child: child),
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
    // Sized to optically match the 18px Google asset alongside it.
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
