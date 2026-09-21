import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/country.dart';
import 'country_picker_sheet.dart';

/// Bottom-border-only Soko phone input. Country flag + dial code prefix
/// (taps open [showCountryPickerSheet]) followed by the number field, on
/// the same 48 px bottom-border chrome as [SokoFormInput].
///
/// Promoted from `features/auth/widgets/auth_phone_input.dart` in PROD-2119
/// so `/menu/account` can reuse the same widget.
class SokoFormPhoneInput extends ConsumerStatefulWidget {
  final TextEditingController? controller;
  final String? hintText;
  final Country selectedCountry;
  final ValueChanged<Country> onCountryChanged;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final bool enabled;
  final FocusNode? focusNode;
  final bool showClearButton;

  const SokoFormPhoneInput({
    super.key,
    this.controller,
    this.hintText,
    required this.selectedCountry,
    required this.onCountryChanged,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.enabled = true,
    this.focusNode,
    this.showClearButton = false,
  });

  @override
  ConsumerState<SokoFormPhoneInput> createState() => _SokoFormPhoneInputState();
}

class _SokoFormPhoneInputState extends ConsumerState<SokoFormPhoneInput> {
  late FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChange);
    if (widget.showClearButton) {
      widget.controller?.addListener(_onControllerChange);
    }
  }

  @override
  void didUpdateWidget(covariant SokoFormPhoneInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showClearButton != oldWidget.showClearButton ||
        widget.controller != oldWidget.controller) {
      if (oldWidget.showClearButton) {
        oldWidget.controller?.removeListener(_onControllerChange);
      }
      if (widget.showClearButton) {
        widget.controller?.addListener(_onControllerChange);
      }
    }
  }

  @override
  void dispose() {
    if (widget.showClearButton) {
      widget.controller?.removeListener(_onControllerChange);
    }
    if (widget.focusNode == null) {
      _focusNode.dispose();
    } else {
      _focusNode.removeListener(_onFocusChange);
    }
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {
      _isFocused = _focusNode.hasFocus;
    });
  }

  void _onControllerChange() {
    // Rebuild so the clear-X visibility tracks the controller's text.
    if (mounted) setState(() {});
  }

  void _handleClear() {
    widget.controller?.clear();
    widget.onChanged?.call('');
    _focusNode.requestFocus();
  }

  void _openCountryPicker() {
    showCountryPickerSheet(
      context,
      ref: ref,
      selectedCountry: widget.selectedCountry,
      onCountrySelected: (country) {
        widget.onCountryChanged(country);
        _focusNode.requestFocus();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final textPrimaryColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;

    Color bottomBorderColor;
    double bottomBorderWidth;
    if (hasError) {
      bottomBorderColor = AppColors.error;
      bottomBorderWidth = 2;
    } else if (_isFocused) {
      bottomBorderColor = primaryColor;
      bottomBorderWidth = 2;
    } else {
      bottomBorderColor = borderColor;
      bottomBorderWidth = 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 48,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: bottomBorderColor,
                width: bottomBorderWidth,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Material + InkWell gives the trigger a Soko-tappable feel:
              // pointer cursor on web hover, ripple on tap, and a generous
              // tap target via the 6/4 px padding. Caret-down hints that
              // it's a picker, not just a flag.
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.enabled ? _openCountryPicker : null,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.selectedCountry.flag,
                          style: const TextStyle(fontSize: 20),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.selectedCountry.dialCode,
                          style: TextStyle(
                            fontSize: 14,
                            color: textPrimaryColor,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: textSecondaryColor,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  enabled: widget.enabled,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  inputFormatters: [
                    _PhoneInputFormatter(widget.selectedCountry),
                  ],
                  style: TextStyle(fontSize: 16, color: textPrimaryColor),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    hintText: widget.hintText ?? 'Phone number',
                    hintStyle: TextStyle(
                      fontSize: 16,
                      // Extra-"ghosted" empty-state placeholder — a faded
                      // version of the secondary text colour so the hint
                      // recedes further when no number is entered.
                      color: textSecondaryColor.withValues(alpha: 0.4),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              if (widget.showClearButton)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: animation, child: child),
                  ),
                  child: (widget.controller?.text.isNotEmpty ?? false)
                      ? IconButton(
                          key: const ValueKey('clear'),
                          onPressed: widget.enabled ? _handleClear : null,
                          icon: Icon(
                            Icons.cancel,
                            size: 18,
                            color: textSecondaryColor,
                          ),
                          splashRadius: 18,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          tooltip: 'Clear',
                        )
                      : const SizedBox(
                          key: ValueKey('empty'),
                          width: 32,
                          height: 32,
                        ),
                ),
            ],
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 4),
          Text(
            widget.errorText!,
            style: TextStyle(fontSize: 14, color: AppColors.error),
          ),
        ],
      ],
    );
  }
}

/// Strips non-digits, caps length, and for PT inserts a space after the 3rd
/// and 6th digit so users see `912 345 678` while they type. Cursor parks at
/// the end — fine for phone entry, where mid-string edits are rare.
class _PhoneInputFormatter extends TextInputFormatter {
  _PhoneInputFormatter(this.country);

  final Country country;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final String formatted;
    if (country.isoCode == 'PT') {
      final capped = digits.length > 9 ? digits.substring(0, 9) : digits;
      final buf = StringBuffer();
      for (int i = 0; i < capped.length; i++) {
        if (i == 3 || i == 6) buf.write(' ');
        buf.write(capped[i]);
      }
      formatted = buf.toString();
    } else {
      // Generic: digits only, capped at E.164 max (15 excluding the +).
      formatted = digits.length > 15 ? digits.substring(0, 15) : digits;
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
