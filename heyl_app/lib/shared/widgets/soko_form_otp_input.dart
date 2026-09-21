import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// Bottom-border-only 6-digit OTP input. Six 44×56 px visual digit boxes
/// fronted by a single hidden-but-layout-visible [TextField] so iOS
/// QuickType, Android Autofill and Safari WebOTP all see a real input and
/// can auto-fill it.
///
/// The hidden [TextField] MUST stay layout-visible (paints transparent
/// text/cursor) — wrapping in `Opacity(opacity: 0)` breaks autofill on
/// every platform.
///
/// Promoted from `features/auth/screens/otp_verification_screen.dart` in
/// PROD-2119 so the account-screen OTP verify dialog can reuse the same
/// 6-box visual and a single shared controller.
class SokoFormOtpInput extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;

  /// Fires when the user has entered (or pasted/autofilled) 6 digits.
  final ValueChanged<String>? onCompleted;

  /// Renders the digit-box bottom borders in [AppColors.error] when set.
  /// The widget does NOT render an error label below itself — surface the
  /// error text in the parent so it can be styled alongside other copy.
  final String? errorText;

  final bool enabled;
  final bool autofocus;
  final Iterable<String>? autofillHints;

  const SokoFormOtpInput({
    super.key,
    required this.controller,
    this.focusNode,
    this.onCompleted,
    this.errorText,
    this.enabled = true,
    this.autofocus = true,
    this.autofillHints = const [AutofillHints.oneTimeCode],
  });

  @override
  State<SokoFormOtpInput> createState() => _SokoFormOtpInputState();
}

class _SokoFormOtpInputState extends State<SokoFormOtpInput> {
  late FocusNode _focusNode;
  bool _completedDispatched = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChanged);
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant SokoFormOtpInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _focusNode.removeListener(_onFocusChanged);
      if (oldWidget.focusNode == null) _focusNode.dispose();
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onFocusChanged() => setState(() {});

  void _onTextChanged() {
    setState(() {});
    final length = widget.controller.text.length;
    if (length == 6 && !_completedDispatched) {
      _completedDispatched = true;
      widget.onCompleted?.call(widget.controller.text);
    } else if (length < 6) {
      _completedDispatched = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final activeIndex = text.length < 6 ? text.length : 5;
    final hasFocus = _focusNode.hasFocus;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled ? () => _focusNode.requestFocus() : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: AutofillGroup(
          child: Stack(
            alignment: Alignment.center,
            children: [
              IgnorePointer(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(6, (index) {
                    return _DigitBox(
                      digit: index < text.length ? text[index] : null,
                      isActive: index == activeIndex && hasFocus,
                      showCursor:
                          index == activeIndex && hasFocus && text.length < 6,
                      isFirst: index == 0,
                      hasError: hasError,
                    );
                  }),
                ),
              ),
              // Real TextField sitting on top of the visual boxes. It stays
              // layout-visible (so iOS QuickType, Android Autofill and
              // Safari `autocomplete=one-time-code` all see it as a real
              // input) but renders text/cursor transparent so the
              // underline-digit boxes below remain the user-facing UI.
              // Wrapping in Opacity(opacity: 0) breaks autofill on every
              // platform — keep this layout-visible.
              Positioned.fill(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  autofocus: widget.autofocus,
                  enabled: widget.enabled,
                  maxLength: 6,
                  keyboardType: TextInputType.number,
                  autofillHints: widget.autofillHints,
                  showCursor: false,
                  cursorColor: Colors.transparent,
                  style: const TextStyle(color: Colors.transparent),
                  decoration: const InputDecoration(
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isCollapsed: true,
                    isDense: true,
                    // Defeat any global InputDecorationTheme fill — the
                    // field is layout-visible (so autofill engines see it)
                    // but must paint nothing on top of the digit boxes.
                    filled: false,
                    fillColor: Colors.transparent,
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DigitBox extends StatefulWidget {
  final String? digit;
  final bool isActive;
  final bool showCursor;
  final bool isFirst;
  final bool hasError;

  const _DigitBox({
    required this.digit,
    required this.isActive,
    required this.showCursor,
    required this.isFirst,
    required this.hasError,
  });

  @override
  State<_DigitBox> createState() => _DigitBoxState();
}

class _DigitBoxState extends State<_DigitBox>
    with SingleTickerProviderStateMixin {
  late AnimationController _cursorController;

  @override
  void initState() {
    super.initState();
    _cursorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _cursorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color borderColor;
    final double borderWidth;
    if (widget.hasError) {
      borderColor = AppColors.error;
      borderWidth = 2;
    } else if (widget.isActive) {
      borderColor = AppColors.sokoPink;
      borderWidth = 3;
    } else {
      borderColor = Colors.black.withValues(alpha: 0.2);
      borderWidth = 2;
    }

    return Container(
      width: 44,
      height: 56,
      margin: EdgeInsets.only(left: widget.isFirst ? 0 : 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: borderColor, width: borderWidth),
        ),
      ),
      child: Center(
        child: widget.digit != null
            ? Text(
                widget.digit!,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppColors.sokoInk,
                ),
              )
            : widget.showCursor
            ? AnimatedBuilder(
                animation: _cursorController,
                builder: (context, child) {
                  return Opacity(
                    opacity: _cursorController.value,
                    child: Container(
                      width: 2,
                      height: 28,
                      color: AppColors.sokoPink,
                    ),
                  );
                },
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
