import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/sms_retriever_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_form_otp_input.dart';

/// Type of identifier being verified
enum IdentifierType { phone, email }

/// Shows the OTP verification bottom sheet and returns the result.
///
/// Mirrors the auth funnel's OTP screen — bottom-border-only digit boxes
/// with the shared [SokoFormOtpInput] widget (PROD-2119).
Future<VerifyResult?> showOtpVerificationDialog({
  required BuildContext context,
  required String identifier,
  required IdentifierType type,
  required WidgetRef ref,
}) {
  return showBottomSheetWithHiddenNav<VerifyResult>(
    context: context,
    ref: ref,
    isDismissible: false,
    enableDrag: false,
    builder: (context) =>
        _OtpVerificationSheet(identifier: identifier, type: type, ref: ref),
  );
}

class _OtpVerificationSheet extends StatefulWidget {
  final String identifier;
  final IdentifierType type;
  final WidgetRef ref;

  const _OtpVerificationSheet({
    required this.identifier,
    required this.type,
    required this.ref,
  });

  @override
  State<_OtpVerificationSheet> createState() => _OtpVerificationSheetState();
}

class _OtpVerificationSheetState extends State<_OtpVerificationSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _isLoading = false;
  String? _error;

  // Android SMS Retriever — silent OTP auto-read (PROD-3323). No-op on iOS/web.
  SmsRetrieverService? _smsRetriever;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    // Only relevant for the phone flow; harmless no-op for email + off Android.
    if (widget.type == IdentifierType.phone) {
      _startSmsRetriever();
    }
  }

  @override
  void dispose() {
    _smsRetriever?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Fills the OTP field when the Retriever matches an SMS, auto-firing verify
  /// via [SokoFormOtpInput]'s `onCompleted`. No-op on iOS/web. Safe to call
  /// again on resend: cancels any prior listener first.
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

  void _onTextChanged() {
    if (_error != null) {
      setState(() => _error = null);
    }
  }

  Future<void> _handleVerify() async {
    final code = _controller.text;
    if (code.length != 6) {
      setState(() {
        _error = Lt.of(context).authOtpValidationIncomplete;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    VerifyResult result;
    if (widget.type == IdentifierType.phone) {
      result = await widget.ref
          .read(accountProvider.notifier)
          .verifyAddPhone(code);
    } else {
      result = await widget.ref
          .read(accountProvider.notifier)
          .verifyAddEmail(code);
    }

    if (!mounted) return;

    if (result == VerifyResult.error) {
      final accountState = widget.ref.read(accountProvider);
      setState(() {
        _isLoading = false;
        _error = accountState.error ?? Lt.of(context).errorUnknown;
      });
    } else {
      Navigator.of(context).pop(result);
    }
  }

  void _resendCode() {
    _controller.clear();
    _focusNode.requestFocus();
    setState(() => _error = null);

    if (widget.type == IdentifierType.phone) {
      // Re-arm the Android Retriever so the resent SMS auto-reads too.
      _startSmsRetriever();
      widget.ref
          .read(accountProvider.notifier)
          .startAddPhone(widget.identifier);
    } else {
      widget.ref
          .read(accountProvider.notifier)
          .startAddEmail(widget.identifier);
    }

    showSoko(
      widget.ref,
      message: Lt.of(context).authOtpResendSuccess,
      variant: SokoVariant.success,
    );
  }

  void _handleCancel() {
    widget.ref.read(accountProvider.notifier).cancelFlow();
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: DSSheetShell(
        bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.authOtpTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.0,
                letterSpacing: -0.36,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.verifyAddCodeSent(widget.identifier),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 14,
                fontWeight: FontWeight.w300,
                height: 1.3,
                letterSpacing: -0.14,
                color: AppColors.sokoShade3,
              ),
            ),
            const SizedBox(height: 20),
            SokoFormOtpInput(
              controller: _controller,
              focusNode: _focusNode,
              enabled: !_isLoading,
              errorText: _error,
              onCompleted: (_) => _handleVerify(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.sokoRed, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            Center(
              child: TextButton(
                onPressed: _isLoading ? null : _resendCode,
                style: TextButton.styleFrom(foregroundColor: AppColors.sokoInk),
                child: Text(
                  l10n.authOtpLinkResend,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: IgnorePointer(
                    ignoring: _isLoading,
                    child: Opacity(
                      opacity: _isLoading ? 0.5 : 1.0,
                      child: BtSqIco(
                        icon: LucideIcons.x,
                        label: l10n.commonCancel,
                        variant: BtSqIcoVariant.normal,
                        expand: true,
                        onTap: _handleCancel,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: IgnorePointer(
                    ignoring: _isLoading,
                    child: Opacity(
                      opacity: _isLoading ? 0.5 : 1.0,
                      child: BtSqIco(
                        icon: LucideIcons.check,
                        label: l10n.authOtpButtonVerify,
                        variant: BtSqIcoVariant.selected,
                        expand: true,
                        onTap: _handleVerify,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
