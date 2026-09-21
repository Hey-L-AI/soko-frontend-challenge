import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';

/// Renders the list's free-text description on the redesigned list page.
/// Soko/Shade4 Mobile/B2 Reg, truncated to 3 lines with a
/// chevron-tap-to-expand affordance when the text overflows. Returns
/// `SizedBox.shrink()` when [description] is null or empty so callers can
/// drop it in unconditionally. The widget does NOT add horizontal
/// padding — wrap it at the call site so it sits inside whatever gutter
/// the host body uses (15-px on both list and zine views today).
///
/// When [editable] is true (PROD-1783 page-level edit mode), the widget
/// renders an inline multi-line `TextField` styled the same as the
/// read-only Text. Committed on focus-loss via [onCommit] (the caller
/// wires it to `notifier.commitListUpdate(description: ...)`). The
/// editable variant always renders something — even when [description]
/// is null/empty — so the owner has a slot to start typing into.
class ListDescription extends StatefulWidget {
  final String? description;

  /// When true, render an inline editor instead of the read-only Text.
  final bool editable;

  /// Called on focus-loss when [editable] is true. Receives the new
  /// (trimmed) text; an empty string clears the description.
  final ValueChanged<String>? onCommit;

  const ListDescription({
    super.key,
    required this.description,
    this.editable = false,
    this.onCommit,
  });

  @override
  State<ListDescription> createState() => _ListDescriptionState();
}

class _ListDescriptionState extends State<ListDescription> {
  static const int _collapsedMaxLines = 3;

  /// Mirror the API contract on `UserListCreate.description`
  /// (`heyl/apps/user/schemas/user_list.py:47-49`).
  static const int _maxLength = 2000;

  bool _expanded = false;

  // Editable-mode wiring (PROD-1783).
  TextEditingController? _controller;
  FocusNode? _focusNode;
  String? _lastCommittedText;

  @override
  void initState() {
    super.initState();
    if (widget.editable) _initEditable();
  }

  void _initEditable() {
    final initial = widget.description ?? '';
    _controller = TextEditingController(text: initial);
    _lastCommittedText = initial.trim();
    _focusNode = FocusNode()..addListener(_onFocusChanged);
  }

  void _disposeEditable() {
    _focusNode?.removeListener(_onFocusChanged);
    _focusNode?.dispose();
    _focusNode = null;
    _controller?.dispose();
    _controller = null;
    _lastCommittedText = null;
  }

  void _onFocusChanged() {
    if (_focusNode?.hasFocus ?? false) return;
    _maybeCommit();
  }

  void _maybeCommit() {
    final text = _controller?.text.trim() ?? '';
    if (text == _lastCommittedText) return;
    _lastCommittedText = text;
    widget.onCommit?.call(text);
  }

  @override
  void didUpdateWidget(covariant ListDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editable && !oldWidget.editable) {
      _initEditable();
    } else if (!widget.editable && oldWidget.editable) {
      // Commit any pending edit before tearing down.
      _maybeCommit();
      _disposeEditable();
      setState(() {});
    } else if (widget.editable &&
        widget.description != oldWidget.description &&
        widget.description != _controller?.text) {
      // External update (e.g. refresh) — replace the controller text but
      // only when the field is not focused, to avoid clobbering the
      // user's in-flight edit.
      if (!(_focusNode?.hasFocus ?? false)) {
        _controller?.text = widget.description ?? '';
        _lastCommittedText = (widget.description ?? '').trim();
      }
    }
  }

  @override
  void dispose() {
    _disposeEditable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.editable) return _buildEditable(context);
    return _buildReadOnly(context);
  }

  Widget _buildReadOnly(BuildContext context) {
    final text = widget.description;
    if (text == null || text.trim().isEmpty) return const SizedBox.shrink();

    final style = AppTheme.mobileB2Reg(color: AppColors.sokoInk);

    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = _textOverflows(
          text: text,
          style: style,
          maxWidth: constraints.maxWidth,
          maxLines: _collapsedMaxLines,
        );
        final canTap = overflows;

        return MouseRegion(
          cursor: canTap ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: canTap ? () => setState(() => _expanded = !_expanded) : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    text,
                    style: style,
                    maxLines: _expanded ? null : _collapsedMaxLines,
                    overflow: _expanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                ),
                if (overflows) ...[
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      LucideIcons.chevron_down,
                      size: 16,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEditable(BuildContext context) {
    final l10n = Lt.of(context);
    // Match the inline note editor's panel chrome (see `list_item_note
    // .dart` `_Editor`) — Soko/Ink @ 6 % fill, 6 px rounded, hairline
    // border (Soko/Ink @ 30 % idle, solid Soko/Ink focused). The
    // description auto-commits on focus loss so there are no Save/Cancel
    // buttons — just the panel + an in-panel counter at bottom-right.
    const textStyle = TextStyle(
      fontFamily: 'ZalandoSans',
      fontWeight: FontWeight.w300,
      fontSize: 14,
      height: 1.3,
      color: AppColors.sokoInk,
    );
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: color),
    );
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          // `minLines: 1` + `maxLines: null` lets the field collapse to
          // a single visible line when empty and grow with the content
          // (bounded only by `_maxLength`).
          maxLines: null,
          minLines: 1,
          // Mirror the API contract on `UserListCreate.description`
          // (`heyl/apps/user/schemas/user_list.py:47-49`,
          // max_length=2000). Hard-enforce on web/iOS — the framework
          // default is `truncateAfterCompositionEnds`, which lets users
          // type past the limit until composition ends (see PROD-1868
          // / `docs/learnings/flutter-textfield-maxlength-not-enforced.md`).
          maxLength: _maxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          textInputAction: TextInputAction.newline,
          keyboardType: TextInputType.multiline,
          style: textStyle,
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.sokoInk.withValues(alpha: 0.06),
            // Extra bottom padding (24 vs 12 elsewhere) so typed text
            // never collides with the in-panel counter.
            contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            // Hide the default counter Flutter renders below the field —
            // we paint our own inside the panel via the Stack overlay.
            counterText: '',
            enabledBorder: border(AppColors.sokoInk.withValues(alpha: 0.3)),
            focusedBorder: border(AppColors.sokoInk),
            disabledBorder: border(AppColors.sokoInk.withValues(alpha: 0.3)),
            errorBorder: border(AppColors.sokoInk.withValues(alpha: 0.3)),
            focusedErrorBorder: border(AppColors.sokoInk),
            hintText: l10n.listEditDescriptionHint,
            hintStyle: textStyle.copyWith(color: AppColors.sokoShade4),
          ),
        ),
        Positioned(
          right: 12,
          bottom: 8,
          child: IgnorePointer(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller!,
              builder: (context, value, _) {
                return Text(
                  '${value.text.characters.length}/$_maxLength',
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w300,
                    fontSize: 12,
                    height: 1.0,
                    color: AppColors.sokoShade4,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  bool _textOverflows({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required int maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: maxLines,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: maxWidth);
    return painter.didExceedMaxLines;
  }
}
