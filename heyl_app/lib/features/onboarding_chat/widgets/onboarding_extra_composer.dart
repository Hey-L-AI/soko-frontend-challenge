import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/widgets/chat_bar.dart';
import 'onboarding_choice_row.dart';

/// The identity step's optional "anything else?" composer (Figma `7285:23262`).
///
/// Two sub-states:
/// - **Ask**: a right-aligned Sim/Não chip pair. Tapping "Não" ends the step
///   immediately via [onNo]; tapping "Sim" reveals the free-text input (no
///   server round-trip — advancement stays a single [onSubmitText] call).
/// - **Text**: the same chat composer used everywhere else ([ChatBarTopRow] —
///   name step, chat conversation), whose send button submits the trimmed text
///   through [onSubmitText]. Enter (without Shift) also sends.
class OnboardingExtraComposer extends StatefulWidget {
  const OnboardingExtraComposer({
    super.key,
    required this.yesLabel,
    required this.noLabel,
    required this.placeholder,
    required this.confirmLabel,
    required this.onNo,
    required this.onSubmitText,
    this.enabled = true,
  });

  final String yesLabel;
  final String noLabel;
  final String placeholder;
  final String confirmLabel;

  /// Invoked when the user declines to add anything.
  final VoidCallback onNo;

  /// Invoked with the trimmed free text when the user confirms.
  final ValueChanged<String> onSubmitText;
  final bool enabled;

  @override
  State<OnboardingExtraComposer> createState() =>
      _OnboardingExtraComposerState();
}

class _OnboardingExtraComposerState extends State<OnboardingExtraComposer> {
  static const _maxChars = 2000;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _expanded = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _focusNode.onKeyEvent = _handleKeyEvent;
  }

  void _onChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText && mounted) setState(() => _hasText = hasText);
  }

  /// Enter (without Shift) sends; Shift+Enter inserts a newline. Matches the
  /// name step / main chat composer.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_hasText && widget.enabled) {
        _submit();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openInput() {
    if (!widget.enabled) return;
    setState(() => _expanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled) return;
    _focusNode.unfocus();
    widget.onSubmitText(text);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      alignment: Alignment.topCenter,
      curve: Curves.easeOut,
      child: _expanded ? _buildInput() : _buildChoice(),
    );
  }

  Widget _buildChoice() {
    return OnboardingChoiceRow(
      noKey: const Key('onboarding-extra-no'),
      yesKey: const Key('onboarding-extra-yes'),
      noLabel: widget.noLabel,
      yesLabel: widget.yesLabel,
      onNo: widget.enabled ? widget.onNo : null,
      onYes: widget.enabled ? _openInput : null,
    );
  }

  Widget _buildInput() {
    // Same composer as the name step / chat conversation — its send button
    // submits (no separate CTA). Enter also sends via [_handleKeyEvent].
    return ChatBarTopRow(
      key: const Key('onboarding-extra-input'),
      controller: _controller,
      focusNode: _focusNode,
      placeholder: widget.placeholder,
      hasText: _hasText,
      voiceEnabled: false,
      sendEnabled: widget.enabled,
      autofocus: true,
      maxLength: _maxChars,
      onSend: _submit,
      onMicTap: () async {},
    );
  }
}
