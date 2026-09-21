import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/phone_formatter.dart';
import '../../../data/models/country.dart';
import '../../../data/repositories/country_repository.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_form_phone_input.dart';
import 'otp_verification_dialog.dart';

/// Inline widget for adding a phone number. Soko-rebranded — uses the
/// bottom-border [SokoFormPhoneInput] (matching the auth funnel's phone
/// input) and [BtSqIco] for the Cancel / Send-code action row.
class AddPhoneInline extends ConsumerStatefulWidget {
  final VoidCallback onCancel;
  final VoidCallback onSuccess;
  final void Function(VerifyResult) onMergeRequired;

  const AddPhoneInline({
    super.key,
    required this.onCancel,
    required this.onSuccess,
    required this.onMergeRequired,
  });

  @override
  ConsumerState<AddPhoneInline> createState() => _AddPhoneInlineState();
}

class _AddPhoneInlineState extends ConsumerState<AddPhoneInline> {
  final _phoneController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  Country _selectedCountry = CountryRepository.defaultCountry;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Focus the phone input when widget mounts
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _phoneFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSendCode() async {
    final localPhone = _phoneController.text.trim();
    if (localPhone.isEmpty) {
      setState(() {
        _error = Lt.of(context).addPhoneValidationEmpty;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final e164Phone = PhoneFormatter.toE164(localPhone, _selectedCountry);

    final success = await ref
        .read(accountProvider.notifier)
        .startAddPhone(e164Phone, channel: 'sms');

    if (!mounted) return;

    if (success) {
      final result = await showOtpVerificationDialog(
        context: context,
        identifier: e164Phone,
        type: IdentifierType.phone,
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
        SokoFormPhoneInput(
          controller: _phoneController,
          focusNode: _phoneFocusNode,
          hintText: l10n.authPhonePlaceholder,
          selectedCountry: _selectedCountry,
          onCountryChanged: (country) {
            setState(() => _selectedCountry = country);
          },
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
                    label: l10n.addPhoneSendCode,
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
