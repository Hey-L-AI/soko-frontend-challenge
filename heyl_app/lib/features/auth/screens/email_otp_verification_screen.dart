import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/soko_form_otp_input.dart';
import '../../business_home/providers/business_session_provider.dart';
import '../../business_home/utils/business_return_state.dart';

/// Email-OTP verification (PROD-3594). Mirrors [OtpVerificationScreen] but
/// stripped of everything phone/SMS-specific: no SMS retriever / WebOTP, no
/// channel or SMS-fallback plumbing, no silent-fail timer. Just a 6-digit
/// code entry, a resend countdown, and an "edit email" back link.
///
/// The Scaffold, SokoBrandHeader, and back chevron are owned by `AuthShell`.
class EmailOtpVerificationScreen extends ConsumerStatefulWidget {
  /// The email the code was sent to — threaded from [EmailLoginScreen] so
  /// resend/verify hit the same address.
  final String email;

  const EmailOtpVerificationScreen({super.key, required this.email});

  @override
  ConsumerState<EmailOtpVerificationScreen> createState() =>
      _EmailOtpVerificationScreenState();
}

class _EmailOtpVerificationScreenState
    extends ConsumerState<EmailOtpVerificationScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  // Local "verifying" flag spans the whole `_verify` lifecycle (guards against
  // a double-submit racing an already-spent code) — see OtpVerificationScreen.
  bool _isVerifying = false;

  // Resend cooldown. Starts at 30 s on entry; the "Resend code" link only
  // enables once it hits zero.
  static const _resendCooldownSeconds = 30;
  Timer? _resendTimer;
  int _resendSecondsRemaining = _resendCooldownSeconds;

  @override
  void initState() {
    super.initState();
    _startResendCountdown();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendSecondsRemaining = _resendCooldownSeconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSecondsRemaining <= 1) {
        timer.cancel();
        setState(() => _resendSecondsRemaining = 0);
      } else {
        setState(() => _resendSecondsRemaining--);
      }
    });
  }

  Future<void> _verify(String code) async {
    if (_isVerifying) return;
    if (code.length != 6) return;

    setState(() => _isVerifying = true);
    try {
      final authNotifier = ref.read(authStateProvider.notifier);
      // PROD-4040 T2.4: pass the captured return + any claim_intent so the
      // backend can echo a validated business_return_to (symmetric to phone).
      final ok = await authNotifier.verifyEmailLogin(
        widget.email,
        code,
        returnTo: ref.read(returnUrlProvider),
        claimIntent: Uri.base.queryParameters['claim_intent'],
      );

      if (!mounted) return;
      if (ok) {
        // Keep `_isVerifying = true` through navigation: the screen is about
        // to unmount, so the button/entry never flashes back to idle.
        // T2.4: the backend-validated business return wins and re-arms the
        // business session so the owner isn't swept into consumer onboarding.
        final businessReturn = routableBusinessReturn(
          authNotifier.pendingBusinessReturnTo,
        );
        if (businessReturn != null) {
          ref.read(businessSessionActiveProvider.notifier).state = true;
          ref.read(returnUrlProvider.notifier).state = null;
          context.go(businessReturn);
          return;
        }
        // Honor a captured returnUrl exactly like the phone-OTP path.
        final returnUrl = ref.read(returnUrlProvider);
        if (returnUrl != null) {
          ref.read(returnUrlProvider.notifier).state = null;
          context.go(returnUrl);
        } else {
          context.go(AppRoutes.home);
        }
        return;
      }
      // Failure: clear the boxes so the user can retype; error surfaces below.
      _controller.clear();
      _focusNode.requestFocus();
      setState(() => _isVerifying = false);
    } catch (_) {
      if (mounted) setState(() => _isVerifying = false);
      rethrow;
    }
  }

  Future<void> _handleResend() async {
    if (_isVerifying || _resendSecondsRemaining > 0) return;
    _controller.clear();
    _focusNode.requestFocus();
    _startResendCountdown();

    await ref.read(authStateProvider.notifier).startEmailLogin(widget.email);
    if (!mounted) return;
    showSoko(
      ref,
      message: Lt.of(context).emailOtpResendSuccess,
      variant: SokoVariant.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final l10n = Lt.of(context);
    final textSecondaryColor = AppColors.sokoShade3;

    final canResend = _resendSecondsRemaining == 0;
    final minutes = _resendSecondsRemaining ~/ 60;
    final seconds = _resendSecondsRemaining % 60;
    final countdown = '$minutes:${seconds.toString().padLeft(2, '0')}';

    return ColoredBox(
      color: AppColors.sokoPaper,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const bottomPadding = 24.0;
          return SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: bottomPadding),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - bottomPadding,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.emailOtpTitle,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: AppColors.sokoInk,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.emailOtpSubtitle(widget.email),
                      style: TextStyle(fontSize: 13, color: textSecondaryColor),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TapRegion(
                      onTapOutside: (_) =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      child: SokoFormOtpInput(
                        controller: _controller,
                        focusNode: _focusNode,
                        autofocus: true,
                        enabled: !_isVerifying,
                        errorText: authState.error,
                        onCompleted: (code) => _verify(code),
                      ),
                    ),
                    if (authState.error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        authState.error!,
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    Center(
                      child: canResend
                          ? GestureDetector(
                              onTap: _isVerifying ? null : _handleResend,
                              child: Text(
                                l10n.emailOtpResend,
                                style: TextStyle(
                                  color: _isVerifying
                                      ? AppColors.sokoShade3
                                      : AppColors.sokoInk,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            )
                          : Text(
                              l10n.emailOtpResendCountdown(countdown),
                              style: TextStyle(
                                fontSize: 14,
                                color: textSecondaryColor,
                              ),
                            ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: GestureDetector(
                        onTap: _isVerifying ? null : () => context.pop(),
                        child: Text(
                          l10n.emailOtpEditEmail,
                          style: TextStyle(
                            color: _isVerifying
                                ? AppColors.sokoShade3
                                : AppColors.sokoInk,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
