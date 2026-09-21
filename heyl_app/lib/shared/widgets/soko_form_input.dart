import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../core/theme/app_colors.dart';

/// Bottom-border-only Soko form input. Transparent background, 48 px height,
/// 1 px `sokoInk8` underline that animates to 2 px `sokoPink` on focus (and
/// `AppColors.error` on error). Pair with the auth/form pages and the
/// `/menu/account` editing surfaces; for filled search/note inputs inside
/// sheets, use [SokoTextField] instead.
///
/// Promoted from `features/auth/widgets/auth_input.dart` in PROD-2119 so the
/// account screen can reuse it. The container draws the border itself and
/// the inner `TextField` pins every [InputDecoration] border state to
/// `InputBorder.none` to defeat the global `InputDecorationTheme` — see
/// `docs/learnings/flutter-input-decoration-theme-border-states.md`.
class SokoFormInput extends StatefulWidget {
  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final IconData? prefixIcon;
  final bool isPassword;
  final bool obscureText;
  final VoidCallback? onToggleObscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextCapitalization textCapitalization;

  /// Trailing slot. Used by the account-handle edit field for its live
  /// validation icon + save button. When provided, wins over both the
  /// password eye-toggle and the × clear button.
  final Widget? suffix;

  /// When true (default), a trailing `×` clear button is shown whenever the
  /// controller has text. Tapping it clears the field. Hidden automatically
  /// for password fields (the eye toggle takes that slot) and when [suffix]
  /// is provided.
  final bool showClearButton;

  const SokoFormInput({
    super.key,
    this.controller,
    this.hintText,
    this.labelText,
    this.prefixIcon,
    this.isPassword = false,
    this.obscureText = false,
    this.onToggleObscure,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.textCapitalization = TextCapitalization.none,
    this.showClearButton = true,
    this.suffix,
  }) : assert(
         !(isPassword && suffix != null),
         'Pass either isPassword (eye toggle owns the trailing slot) or suffix — not both.',
       );

  @override
  State<SokoFormInput> createState() => _SokoFormInputState();
}

class _SokoFormInputState extends State<SokoFormInput> {
  late FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChange);
    widget.controller?.addListener(_onControllerChange);
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onControllerChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    } else {
      _focusNode.removeListener(_onFocusChange);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SokoFormInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onControllerChange);
      widget.controller?.addListener(_onControllerChange);
    }
  }

  void _onFocusChange() {
    setState(() {
      _isFocused = _focusNode.hasFocus;
    });
  }

  void _onControllerChange() {
    setState(() {});
  }

  void _handleClear() {
    widget.controller?.clear();
    widget.onChanged?.call('');
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

    Widget? trailing;
    if (widget.suffix != null) {
      trailing = Padding(
        padding: const EdgeInsets.only(left: 8),
        child: widget.suffix,
      );
    } else if (widget.isPassword && widget.onToggleObscure != null) {
      trailing = GestureDetector(
        onTap: widget.onToggleObscure,
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Icon(
            widget.obscureText ? LucideIcons.eye : LucideIcons.eye_off,
            size: 20,
            color: textSecondaryColor,
          ),
        ),
      );
    } else if (widget.showClearButton &&
        !widget.isPassword &&
        (widget.controller?.text.isNotEmpty ?? false)) {
      trailing = GestureDetector(
        onTap: widget.enabled ? _handleClear : null,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Icon(
            LucideIcons.x,
            size: 20,
            color: textSecondaryColor,
            semanticLabel: 'Clear',
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.labelText != null) ...[
          Text(
            widget.labelText!,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: textPrimaryColor,
            ),
          ),
          const SizedBox(height: 8),
        ],
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
              if (widget.prefixIcon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    widget.prefixIcon,
                    size: 20,
                    color: textSecondaryColor,
                  ),
                ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  autofocus: widget.autofocus,
                  obscureText: widget.obscureText,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  textCapitalization: widget.textCapitalization,
                  enabled: widget.enabled,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
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
                    hintText: widget.hintText,
                    hintStyle: TextStyle(
                      fontSize: 16,
                      color: textSecondaryColor,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              if (trailing != null) trailing,
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
