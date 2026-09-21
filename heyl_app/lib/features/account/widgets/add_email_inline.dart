import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_form_input.dart';
import 'otp_verification_dialog.dart';

/// Inline widget for adding an email address. Soko-rebranded — uses the
/// bottom-border [SokoFormInput] (matching the auth funnel's email input)
/// with a mail-icon prefix and [BtSqIco] for the Cancel / Send-code
/// action row.
class AddEmailInline extends ConsumerStatefulWidget {
  final VoidCallback onCancel;
  final VoidCallback onSuccess;
  final void Function(VerifyResult) onMergeRequired;

  const AddEmailInline({
    super.key,
    required this.onCancel,
    required this.onSuccess,
    required this.onMergeRequired,
  });

  @override
  ConsumerState<AddEmailInline> createState() => _AddEmailInlineState();
}

class _AddEmailInlineState extends ConsumerState<AddEmailInline> {
  final _emailController = TextEditingController();
  final _emailFocusNode = FocusNode();
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _emailFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);
  }

  Future<void> _handleSendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() {
        _error = Lt.of(context).addEmailValidationEmpty;
      });
      return;
    }

    if (!_isValidEmail(email)) {
      setState(() {
        _error = Lt.of(context).addEmailValidationInvalid;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final success = await ref
        .read(accountProvider.notifier)
        .startAddEmail(email);

    if (!mounted) return;

    if (success) {
      final result = await showOtpVerificationDialog(
        context: context,
        identifier: email,
        type: IdentifierType.email,
        ref: ref,
      );

      if (!mounted) return;

      if (result == VerifyResult.success) {
        widget.onSuccess();
      } else if (result == VerifyResult.mergeRequired) {
        widget.onMergeRequired(result!);
      }
      setState(() => _isLoading = false);
    } else {
      final accountState = ref.read(accountProvider);
      setState(() {
        _isLoading = false;
        _error = accountState.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SokoFormInput(
          controller: _emailController,
          focusNode: _emailFocusNode,
          hintText: l10n.authEmailPlaceholder,
          prefixIcon: LucideIcons.mail,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.none,
          onSubmitted: (_) => _handleSendCode(),
          errorText: _error,
          enabled: !_isLoading,
        ),
        const SizedBox(height: 12),
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
                    onTap: widget.onCancel,
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
                    icon: LucideIcons.send,
                    label: l10n.addEmailSendCode,
                    variant: BtSqIcoVariant.selected,
                    expand: true,
                    onTap: _handleSendCode,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
