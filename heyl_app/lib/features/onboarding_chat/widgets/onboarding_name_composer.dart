import 'package:flutter/material.dart';

import '../../../shared/widgets/soko_text_field.dart';
import 'onboarding_continue_button.dart';

/// The identity step's name composer: two stacked [SokoTextField]s (First name /
/// Surname) plus the shared [OnboardingContinueButton]. Replaces the single
/// free-text chat bar on the name turn — a person's name is first + surname, so
/// a structured two-field capture reads clearer than one chat message
/// (PROD-3888). The Continue CTA stays dimmed until both fields are non-empty.
class OnboardingNameComposer extends StatefulWidget {
  const OnboardingNameComposer({
    super.key,
    required this.firstNamePlaceholder,
    required this.surnamePlaceholder,
    required this.confirmLabel,
    required this.onConfirm,
    this.maxLength,
    this.enabled = true,
    this.initialFirstName,
    this.initialSurname,
  });

  final String firstNamePlaceholder;
  final String surnamePlaceholder;
  final String confirmLabel;

  /// Optional prefill for the correction (edit) path — seeds the two fields
  /// with the name already on record so the user tweaks rather than retypes.
  final String? initialFirstName;
  final String? initialSurname;

  /// Receives the trimmed first name and surname.
  final void Function(String firstName, String surname) onConfirm;

  /// Optional per-field hard cap (mirrors the single-field `nameMaxLength`).
  final int? maxLength;
  final bool enabled;

  @override
  State<OnboardingNameComposer> createState() => _OnboardingNameComposerState();
}

class _OnboardingNameComposerState extends State<OnboardingNameComposer> {
  late final _firstController = TextEditingController(
    text: widget.initialFirstName,
  );
  late final _surnameController = TextEditingController(
    text: widget.initialSurname,
  );
  final _firstFocus = FocusNode();
  final _surnameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _firstController.addListener(_onChanged);
    _surnameController.addListener(_onChanged);
  }

  @override
  void dispose() {
    _firstController
      ..removeListener(_onChanged)
      ..dispose();
    _surnameController
      ..removeListener(_onChanged)
      ..dispose();
    _firstFocus.dispose();
    _surnameFocus.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _canConfirm =>
      widget.enabled &&
      _firstController.text.trim().isNotEmpty &&
      _surnameController.text.trim().isNotEmpty;

  void _submit() {
    if (!_canConfirm) return;
    _firstFocus.unfocus();
    _surnameFocus.unfocus();
    widget.onConfirm(
      _firstController.text.trim(),
      _surnameController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SokoTextField(
          key: const Key('onboarding-name-first'),
          controller: _firstController,
          focusNode: _firstFocus,
          hintText: widget.firstNamePlaceholder,
          maxLength: widget.maxLength,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _surnameFocus.requestFocus(),
        ),
        const SizedBox(height: 8),
        SokoTextField(
          key: const Key('onboarding-name-surname'),
          controller: _surnameController,
          focusNode: _surnameFocus,
          hintText: widget.surnamePlaceholder,
          maxLength: widget.maxLength,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        // Hidden until both fields are filled — a visible CTA over two empty
        // fields read as "you can continue now" (PROD-3888), matching the
        // interests composer's gating. It appears once both have text.
        if (_canConfirm) ...[
          const SizedBox(height: 12),
          OnboardingContinueButton(
            key: const Key('onboarding-name-confirm'),
            label: widget.confirmLabel,
            enabled: true,
            onTap: _submit,
          ),
        ],
      ],
    );
  }
}
