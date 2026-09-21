import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// Shared single-line text input that matches the new Soko design system —
/// `sokoShade5` fill, 6 px radius, no border, 14 px Zalando Sans Light text.
///
/// Used by the redesigned bottom sheets (PROD-1861 add-to-list, future
/// PROD-1862 visibility, PROD-1863 IG-share, PROD-1864 Google Maps share)
/// for their search and inline-note inputs. Different from the global
/// `Theme.inputDecorationTheme` which targets auth/form pages with a 12 px
/// outline border + surface fill.
///
/// Slot in optional [prefix] / [suffix] widgets (icons, clear buttons) to
/// cover the search-field variant; leave both null for a plain input.
class SokoTextField extends StatelessWidget {
  const SokoTextField({
    super.key,
    required this.controller,
    this.hintText,
    this.prefix,
    this.suffix,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.keyboardType,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.focusNode,
    this.contentPadding,
    this.textAlignVertical,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String? hintText;
  final Widget? prefix;
  final Widget? suffix;
  final int? maxLines;
  final int? minLines;

  /// Optional hard cap on character count. Input is truncated at this length
  /// (so callers can mirror a backend `max_length` and avoid 422s). The
  /// character counter is intentionally hidden to keep the DS look clean.
  final int? maxLength;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final TextInputType? keyboardType;
  final bool autocorrect;
  final bool enableSuggestions;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Override the default content padding. Useful when callers need the field
  /// to render at a specific height to align with neighbouring controls
  /// (e.g. the add-to-list sticky footer matching the Save button).
  final EdgeInsetsGeometry? contentPadding;

  /// Optional input filters (e.g. restrict a handle field to `[a-zA-Z0-9_]`).
  final List<TextInputFormatter>? inputFormatters;

  /// Vertical alignment of text + hint within the field. Pass
  /// [TextAlignVertical.top] for multi-line boxes so the hint sits at the top
  /// instead of being vertically centered.
  final TextAlignVertical? textAlignVertical;

  static const _textStyle = TextStyle(
    fontFamily: 'Zalando Sans',
    fontSize: 14,
    fontWeight: FontWeight.w300,
    letterSpacing: -0.14,
    color: AppColors.sokoInk,
  );

  static final _hintStyle = TextStyle(
    fontFamily: 'Zalando Sans',
    fontSize: 14,
    fontWeight: FontWeight.w300,
    height: 1.2,
    letterSpacing: -0.14,
    color: AppColors.sokoInk.withValues(alpha: 0.30),
  );

  @override
  Widget build(BuildContext context) {
    // Pin all five border states to `BorderSide.none` — the global
    // `inputDecorationTheme` sets an explicit `enabledBorder` /
    // `focusedBorder` for auth/form pages that would otherwise leak in here
    // because state-specific borders win over the catch-all `border` field.
    final borderless = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide.none,
    );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      textCapitalization: textCapitalization,
      textInputAction: textInputAction,
      keyboardType: keyboardType,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      maxLines: maxLines,
      minLines: minLines,
      textAlignVertical: textAlignVertical,
      inputFormatters: inputFormatters,
      maxLength: maxLength,
      // Hard-cap the input. The web/iOS default is
      // `truncateAfterCompositionEnds`, which lets users keep typing past
      // `maxLength` until composition ends (PROD-1868) — force enforcement so
      // the cap actually holds and mirrors the backend `max_length`.
      maxLengthEnforcement: maxLength == null
          ? null
          : MaxLengthEnforcement.enforced,
      // Hide the character counter chrome while keeping the hard cap.
      buildCounter: maxLength == null
          ? null
          : (
              context, {
              required int currentLength,
              required bool isFocused,
              int? maxLength,
            }) => null,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: _textStyle,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: _hintStyle,
        prefixIcon: prefix,
        suffixIcon: suffix,
        filled: true,
        fillColor: AppColors.sokoShade5,
        border: borderless,
        enabledBorder: borderless,
        focusedBorder: borderless,
        disabledBorder: borderless,
        errorBorder: borderless,
        focusedErrorBorder: borderless,
        isDense: true,
        contentPadding:
            contentPadding ??
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}
