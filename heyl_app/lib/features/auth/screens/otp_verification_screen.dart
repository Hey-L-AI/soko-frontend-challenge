import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/services/sms_retriever_service.dart';
import '../../../core/services/web_otp_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/router/app_router.dart';
import '../../../data/models/api_responses.dart';
import '../../../l10n/generated/l10n.dart';
import '../helpers/auth_error_text.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_form_otp_input.dart';
import '../../business_home/providers/business_session_provider.dart';
import '../../business_home/utils/business_return_state.dart';

/// OTP verification screen
/// Uses a single hidden TextField with 6 visual display boxes for better UX.
///
/// PROD-2632 — the screen now adapts to the WhatsApp-first contract from
/// PROD-2609. Three render modes driven by [initialStatus]:
///  * `sent` — normal OTP entry + (conditional) "Send via SMS" link +
///    (conditional after 30 s) "Try email or social" link
///  * `channel_unavailable` — no OTP boxes; SMS link (if available) or
///    email/social link surfaces immediately
///  * `region_unsupported` — no OTP boxes; only email/social link
///
/// The 30 s silent-fail timer catches the "Twilio reported `sent` but
/// Meta dropped the WhatsApp message because the recipient doesn't have
/// WhatsApp" case — the only failure mode the backend can't surface
/// synchronously.
class OtpVerificationScreen extends ConsumerStatefulWidget {
  final String phone;
  // Channel originally used to send the code. Threaded from the login form
  // so resend uses the same channel (defaults to 'sms' so OS-level SMS
  // autofill keeps working when the user lands here via tab-restore deep link).
  final String channel;

  /// True iff the destination country is in the server's SMS allowlist
  /// (PROD-2613). Drives visibility of the "Send via SMS" link.
  final bool smsFallbackAvailable;

  /// Status from the most recent `PhoneStartResponse`. One of `sent`,
  /// `channel_unavailable`, `region_unsupported`. Defaults to `sent`
  /// (also the tab-restore default since we can't recover the original).
  final String initialStatus;

  const OtpVerificationScreen({
    super.key,
    required this.phone,
    this.channel = 'sms',
    this.smsFallbackAvailable = false,
    this.initialStatus = 'sent',
  });

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  // WebOTP service for auto-reading OTP from SMS on supported browsers
  WebOtpService? _webOtpService;
  bool _webOtpRequested = false;

  // Android SMS Retriever — silent OTP auto-read on the native app (PROD-3323).
  // Parallel to the WebOTP path above; no-op on iOS (QuickType) and web.
  SmsRetrieverService? _smsRetriever;

  // Local "verifying" flag spans the whole `_handleVerify` lifecycle, not
  // just `authState.isLoading`. `verifyOtp` flips `isLoading` to false
  // early (before the analytics/Klaviyo/push-registration/experiment-flag
  // tail awaits), so binding the button to `isLoading` would re-enable it
  // a few seconds before navigation actually fires — letting an impatient
  // user tap Verify again with an already-spent code. The flag stays true
  // until the screen navigates away (or fails, in which case we reset it).
  bool _isVerifying = false;

  // PROD-2632 silent-fail timer. Fires 30 s after entry on a WhatsApp send;
  // when it fires we reveal the "Try email or social" fallback for users
  // whose country isn't in the SMS allowlist. Cancelled on user input,
  // verify, resend, SMS-link tap, and dispose.
  static const _silentFailDelay = Duration(seconds: 30);
  Timer? _silentFailTimer;
  bool _timeoutFired = false;

  // Triggers the "Send via SMS" link to fire `otp_fallback_sms` with
  // triggered_by=timeout instead of user_tap.
  bool _smsLinkPending = false;

  bool get _isSent => widget.initialStatus == PhoneStartResponse.statusSent;
  bool get _isChannelUnavailable =>
      widget.initialStatus == PhoneStartResponse.statusChannelUnavailable;
  bool get _isRegionUnsupported =>
      widget.initialStatus == PhoneStartResponse.statusRegionUnsupported;

  bool get _showSmsLink {
    if (_isRegionUnsupported) return false;
    if (widget.channel != PhoneStartResponse.channelWhatsapp) return false;
    return widget.smsFallbackAvailable;
  }

  bool get _showEmailOrSocialLink {
    if (_isRegionUnsupported) return true;
    if (_isChannelUnavailable && !widget.smsFallbackAvailable) return true;
    if (_timeoutFired &&
        !widget.smsFallbackAvailable &&
        widget.channel == PhoneStartResponse.channelWhatsapp) {
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    // Cancel the silent-fail timer the moment the user starts typing.
    _controller.addListener(_cancelTimerOnInput);
    // Start WebOTP request if on web platform AND we're actually waiting
    // for a code. Skip for failure-status renders.
    if (kIsWeb && _isSent) {
      _startWebOtpRequest();
    }
    // Native Android SMS Retriever — only while awaiting a code. No-op on iOS
    // and web (the service self-gates to Android).
    if (!kIsWeb && _isSent) {
      _startSmsRetriever();
    }
    if (_isSent && widget.channel == PhoneStartResponse.channelWhatsapp) {
      _silentFailTimer = Timer(_silentFailDelay, () {
        if (!mounted) return;
        setState(() => _timeoutFired = true);
      });
    }
  }

  @override
  void dispose() {
    // Cancel any pending WebOTP request
    _webOtpService?.cancel();
    _smsRetriever?.cancel();
    _silentFailTimer?.cancel();
    _controller.removeListener(_cancelTimerOnInput);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _cancelTimerOnInput() {
    if (_silentFailTimer?.isActive == true && _controller.text.isNotEmpty) {
      _silentFailTimer?.cancel();
    }
  }

  /// Request OTP via WebOTP API (Chrome Android only)
  /// This shows a browser prompt when SMS arrives, allowing one-tap OTP entry
  Future<void> _startWebOtpRequest() async {
    _webOtpService = WebOtpService();

    if (!_webOtpService!.isSupported || _webOtpRequested) {
      return;
    }

    _webOtpRequested = true;
    final result = await _webOtpService!.requestOtp();

    if (!mounted) return;

    if (result.success && result.code != null) {
      // Auto-fill the OTP field
      final digits = result.code!.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length >= 6) {
        _controller.text = digits.substring(0, 6);
      }
    }
    // For cancelled or failed, do nothing - user can manually enter code
  }

  /// Start (or restart) the Android SMS Retriever listener. Fills the OTP field
  /// when the matching SMS arrives, which auto-fires verify via
  /// [SokoFormOtpInput]'s `onCompleted`. No-op on iOS/web. Silent on
  /// timeout/no-match — the user can still type the code manually. Safe to call
  /// again on resend: cancels any prior listener first so the fresh SMS is
  /// caught even after the first listener fired or timed out.
  Future<void> _startSmsRetriever() async {
    await _smsRetriever?.cancel();
    _smsRetriever = SmsRetrieverService();
    if (!_smsRetriever!.isSupported) return;

    final code = await _smsRetriever!.listenForCode();
    if (!mounted || code == null) return;

    final digits = code.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length >= 6) {
      _controller.text = digits.substring(0, 6);
    }
  }

  Future<void> _handleVerify() async {
    if (_isVerifying) return;
    final l10n = Lt.of(context);
    final code = _controller.text;
    if (code.length != 6) {
      showSoko(
        ref,
        message: l10n.authOtpValidationIncomplete,
        variant: SokoVariant.error,
      );
      return;
    }

    _silentFailTimer?.cancel();
    setState(() => _isVerifying = true);
    try {
      final authNotifier = ref.read(authStateProvider.notifier);
      // PROD-4040 T2.4: pass the captured return + any claim_intent so the
      // backend can echo a validated business_return_to.
      final success = await authNotifier.verifyOtp(
        widget.phone,
        code,
        returnTo: ref.read(returnUrlProvider),
        claimIntent: Uri.base.queryParameters['claim_intent'],
      );

      if (!mounted) return;
      if (success) {
        // Keep `_isVerifying = true` through navigation: the screen is
        // about to unmount, and leaving it true prevents the button from
        // flashing back to its idle state during the route transition.
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
        final returnUrl = ref.read(returnUrlProvider);
        if (returnUrl != null) {
          ref.read(returnUrlProvider.notifier).state = null;
          context.go(returnUrl);
        } else {
          context.go(AppRoutes.home);
        }
        return;
      }
      setState(() => _isVerifying = false);
    } catch (_) {
      if (mounted) setState(() => _isVerifying = false);
      rethrow;
    }
  }

  Future<void> _handleResend() async {
    if (_isVerifying) return;
    _silentFailTimer?.cancel();
    _controller.clear();
    _focusNode.requestFocus();
    // Re-arm the Android Retriever so the resent SMS auto-reads too.
    if (!kIsWeb && _isSent) {
      _startSmsRetriever();
    }
    await ref
        .read(authStateProvider.notifier)
        .startPhoneLogin(widget.phone, channel: widget.channel);
    if (!mounted) return;
    showSoko(
      ref,
      message: Lt.of(context).authOtpResendSuccess,
      variant: SokoVariant.success,
    );
  }

  Future<void> _handleSendViaSms() async {
    if (_isVerifying || _smsLinkPending) return;
    _smsLinkPending = true;
    _silentFailTimer?.cancel();

    final triggeredBy = _timeoutFired ? 'timeout' : 'user_tap';
    unawaited(
      ref
          .read(unifiedAnalyticsProvider)
          .trackOtpFallbackSms(triggeredBy: triggeredBy),
    );

    final response = await ref
        .read(authStateProvider.notifier)
        .startPhoneLogin(widget.phone, channel: PhoneStartResponse.channelSms);

    if (!mounted) {
      _smsLinkPending = false;
      return;
    }
    if (response == null) {
      _smsLinkPending = false;
      return;
    }

    unawaited(
      ref
          .read(unifiedAnalyticsProvider)
          .trackOtpSend(
            channelRequested: PhoneStartResponse.channelSms,
            channelResponse: response.channel,
            status: response.status,
            smsFallbackAvailable: response.smsFallbackAvailable,
          ),
    );

    final encodedPhone = Uri.encodeComponent(widget.phone);
    context.pushReplacement(
      '${AppRoutes.otpVerify}?phone=$encodedPhone'
      '&channel=${response.channel}'
      '&smsFallbackAvailable=${response.smsFallbackAvailable}'
      '&status=${response.status}',
    );
  }

  void _handleTryEmailOrSocial() {
    _silentFailTimer?.cancel();
    // PROD-3594: the email rung is now a real passwordless email-OTP flow
    // (PROD-3595), not a bounce back to the phone-first /login. Social login
    // also lives on that screen, so it stays the "email or social" target.
    context.push(AppRoutes.emailLogin);
  }

  /// Get user-friendly error message from auth state error
  String? _getDisplayError(String? error) {
    if (error == null) return null;

    // Check for technical errors and replace with user-friendly messages
    if (error.contains('DioException') ||
        error.contains('bad response') ||
        error.contains('Error:')) {
      return Lt.of(context).authOtpErrorInvalidCode;
    }

    return error;
  }

  String _subtitleFor(Lt l10n) {
    if (_isChannelUnavailable) return l10n.authOtpChannelUnavailableHeader;
    if (_isRegionUnsupported) return l10n.authOtpRegionUnsupportedHeader;
    return widget.channel == PhoneStartResponse.channelWhatsapp
        ? l10n.authOtpSubtitleWhatsapp(widget.phone)
        : l10n.authOtpSubtitleSms(widget.phone);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final l10n = Lt.of(context);
    final textSecondaryColor = AppColors.sokoShade3;

    final displayError = _getDisplayError(authState.displayError(l10n));
    final showOtpEntry = _isSent;

    return PopScope<Object?>(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          await ref
              .read(authStateProvider.notifier)
              .clearPendingPhoneVerification();
        }
      },
      // ColoredBox keeps the OTP layer opaque during shell slide
      // transitions so the form (or welcome) doesn't bleed through.
      child: ColoredBox(
        color: AppColors.sokoPaper,
        // LayoutBuilder + ConstrainedBox(minHeight) lets the inner Column
        // size to at least the viewport, so mainAxisAlignment.center has
        // room to actually center. SingleChildScrollView still allows
        // overflow when the soft keyboard appears.
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
                      if (showOtpEntry)
                        // TapRegion wraps only the OTP input — every other
                        // pixel on the screen counts as "outside" and
                        // dismisses the numeric keypad. PR #603 wrapped the
                        // whole body, leaving every dead zone "inside" so
                        // onTapOutside never fired (iOS numeric pad has no
                        // Done key, so this was the only dismiss path).
                        TapRegion(
                          onTapOutside: (_) =>
                              FocusManager.instance.primaryFocus?.unfocus(),
                          child: SokoFormOtpInput(
                            controller: _controller,
                            focusNode: _focusNode,
                            onCompleted: (_) => _handleVerify(),
                          ),
                        ),
                      if (showOtpEntry) const SizedBox(height: 24),
                      // Subtitle — channel-aware copy (PROD-2632) or
                      // failure-status header.
                      Text(
                        _subtitleFor(l10n),
                        style: TextStyle(
                          fontSize: 13,
                          color: textSecondaryColor,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (showOtpEntry) ...[
                        const SizedBox(height: 24),
                        // Verify — canonical SokoCtaButton. Driven by the
                        // local `_isVerifying` flag so the button stays
                        // disabled + spinning through the post-API tail
                        // awaits (analytics, Klaviyo, push registration,
                        // experiment flags) until route navigation fires.
                        SokoCtaButton(
                          label: l10n.authOtpButtonVerify,
                          onPressed: _isVerifying ? null : _handleVerify,
                          loading: _isVerifying,
                        ),
                      ],
                      if (displayError != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: AppColors.error.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: AppColors.error,
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  displayError,
                                  style: const TextStyle(
                                    color: AppColors.error,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (showOtpEntry) ...[
                        const SizedBox(height: 24),
                        // Resend code link — "Não recebeste o código? Reenviar".
                        // Disabled while a verify is in flight so a tap
                        // can't race a parallel `startPhoneLogin` against
                        // the verify request.
                        Center(
                          child: GestureDetector(
                            onTap: _isVerifying ? null : _handleResend,
                            child: Text(
                              l10n.authOtpLinkResend,
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
                      ],
                      if (_showSmsLink) ...[
                        SizedBox(height: showOtpEntry ? 16 : 24),
                        Center(
                          child: GestureDetector(
                            onTap: _isVerifying || _smsLinkPending
                                ? null
                                : _handleSendViaSms,
                            child: Text(
                              l10n.authOtpLinkSendViaSms,
                              style: TextStyle(
                                color: (_isVerifying || _smsLinkPending)
                                    ? AppColors.sokoShade3
                                    : AppColors.sokoInk,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (_showEmailOrSocialLink) ...[
                        SizedBox(
                          height: (showOtpEntry || _showSmsLink) ? 16 : 24,
                        ),
                        Center(
                          child: GestureDetector(
                            onTap: _isVerifying
                                ? null
                                : _handleTryEmailOrSocial,
                            child: Text(
                              l10n.authOtpLinkTryEmailOrSocial,
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
                      ],
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
