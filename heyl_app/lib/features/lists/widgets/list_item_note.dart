import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/person_dot.dart';
import '../../../data/models/user_list.dart' show kUserListItemTipMaxLength;
import '../../../l10n/generated/l10n.dart';
import '../../moderation/content_blocked_handler.dart';
import '../providers/unified_list_provider.dart';

/// Single, reusable affordance for the user-authored note (`tip`) on a
/// list element. Replaces the previous split between
/// `_LeaveNoteButton` + `_UserTipBlock` + modal `showLeaveNoteSheet` —
/// editing now happens inline in the same slot.
///
/// States:
/// - **No tip + can edit**: "Deixar nota" button (sokoInk @ 6%, edit.svg).
/// - **No tip + read-only**: nothing (collapses).
/// - **Has tip + read-only**: tinted callout (`_TipCallout`).
/// - **Has tip + can edit**: callout + edit-icon button → tap opens the
///   inline editor below.
/// - **Editing**: TextField + Cancel/Save row, sokoInk styling.
///
/// Mounted on three surfaces today: zine view item slot, venue inline
/// actions, event inline actions.
class ListItemNote extends ConsumerStatefulWidget {
  final String listId;
  final String listElementId;
  final String? tip;
  final bool canEdit;

  /// When true and [canEdit] is true, the widget opens the inline editor
  /// immediately on mount (and whenever [canEdit] transitions to true)
  /// without requiring a pencil-tap. Used by the page-level edit mode on
  /// the redesigned list page (PROD-1783) where every owner-editable note
  /// row auto-expands as the user enters edit mode. Save still commits
  /// per row; exiting edit mode collapses the row back to read-only and
  /// any unsaved draft is silently discarded.
  final bool autoExpand;

  /// Optional display name of the entity the note is attached to
  /// (e.g. a venue or event name). When provided + non-empty, the
  /// editor's placeholder reads "Nota sobre {itemName}..." instead of
  /// the generic "Adicionar uma nota..." fallback. PROD-1783.
  final String? itemName;

  /// Note author identity, used to render a leading [PersonDot] on the
  /// read-only callout (their photo when the backend expands
  /// `added_by.avatar_url`, else their seeded initial). Mirrors the
  /// in-card note treatment in `list_zine_item_page.dart`. When all three
  /// are null/empty no dot renders, so callers that lack author data keep
  /// the previous text-only layout.
  final String? authorAvatarUrl;
  final String? authorName;
  final String? authorId;

  const ListItemNote({
    super.key,
    required this.listId,
    required this.listElementId,
    required this.tip,
    required this.canEdit,
    this.autoExpand = false,
    this.itemName,
    this.authorAvatarUrl,
    this.authorName,
    this.authorId,
  });

  @override
  ConsumerState<ListItemNote> createState() => _ListItemNoteState();
}

class _ListItemNoteState extends ConsumerState<ListItemNote> {
  TextEditingController? _controller;
  FocusNode? _focusNode;
  bool _editing = false;
  bool _saving = false;

  /// Last value already persisted to the server. Used to decide whether a
  /// focus-loss should trigger a save (text changed) or be a no-op.
  String _lastCommittedText = '';

  bool get _hasTip => (widget.tip ?? '').trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (widget.autoExpand && widget.canEdit) {
      _openEditor();
    }
  }

  @override
  void didUpdateWidget(covariant ListItemNote oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldBeAutoExpanded = widget.autoExpand && widget.canEdit;
    final wasAutoExpanded = oldWidget.autoExpand && oldWidget.canEdit;
    if (shouldBeAutoExpanded && !wasAutoExpanded && !_editing) {
      // Page-level edit mode just turned on — pop the editor open.
      setState(_openEditor);
    } else if (!shouldBeAutoExpanded &&
        wasAutoExpanded &&
        _editing &&
        !_saving) {
      // Page-level edit mode just turned off — collapse back to read-only
      // and discard any unsaved draft. PROD-1783 auto-save-on-blur model.
      setState(_closeEditor);
    } else if (_editing &&
        widget.tip != oldWidget.tip &&
        !(_focusNode?.hasFocus ?? false)) {
      // External refresh (e.g. another tab updated the tip). Reseed the
      // controller text — but only when the user isn't actively editing,
      // to avoid clobbering their in-flight typing.
      final next = widget.tip ?? '';
      _controller?.text = next;
      _lastCommittedText = next.trim();
    }
  }

  @override
  void dispose() {
    _disposeEditor();
    super.dispose();
  }

  void _openEditor() {
    _editing = true;
    final initial = widget.tip ?? '';
    _controller = TextEditingController(text: initial);
    _lastCommittedText = initial.trim();
    _focusNode = FocusNode()..addListener(_onFocusChanged);
  }

  void _closeEditor() {
    _editing = false;
    _disposeEditor();
  }

  void _disposeEditor() {
    _focusNode?.removeListener(_onFocusChanged);
    _focusNode?.dispose();
    _focusNode = null;
    _controller?.dispose();
    _controller = null;
  }

  void _onFocusChanged() {
    if (_focusNode?.hasFocus ?? false) return;
    _onBlur();
  }

  void _onBlur() {
    final text = _controller?.text.trim() ?? '';
    if (text == _lastCommittedText) {
      // No change. Outside edit mode, blur still collapses the editor;
      // inside edit mode (autoExpand), we keep it visible.
      if (!widget.autoExpand && _editing) {
        setState(_closeEditor);
      }
      return;
    }
    // ignore: discarded_futures
    _save();
  }

  /// Explicit commit from the send button. Saving directly gives immediate
  /// feedback; dropping focus afterwards also fires [_onBlur], but the
  /// `_saving` guard + `_lastCommittedText` comparison make that a no-op, so
  /// the note is never saved twice.
  void _submit() {
    // ignore: discarded_futures
    _save();
    _focusNode?.unfocus();
  }

  void _startEditing() {
    setState(_openEditor);
    // Acquire focus once mounted so the user lands directly in the field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode?.requestFocus();
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final text = _controller?.text.trim() ?? '';
    setState(() => _saving = true);
    bool ok = false;
    try {
      ok = await ref
          .read(unifiedListProvider(widget.listId).notifier)
          .updateItemTip(widget.listElementId, text);
    } catch (e) {
      if (!mounted) return;
      // PROD-2264 — wordlist filter rejection. The optimistic update
      // has already been rolled back by [updateItemTip]; surface the
      // backend message via the shared handler.
      setState(() => _saving = false);
      if (!handleContentBlocked(
        ref,
        context,
        e,
        field: ContentBlockedField.listItemTip,
      )) {
        showSoko(
          ref,
          message: Lt.of(context).errorUnknown,
          variant: SokoVariant.error,
        );
      }
      return;
    }
    if (!mounted) return;
    if (!ok) {
      setState(() => _saving = false);
      showSoko(
        ref,
        message: Lt.of(context).errorUnknown,
        variant: SokoVariant.error,
      );
      return;
    }
    _lastCommittedText = text;
    // Page-level edit mode (autoExpand): keep editor open. Legacy
    // single-tap-edit flow: collapse to read-only.
    if (widget.autoExpand && widget.canEdit) {
      setState(() => _saving = false);
      return;
    }
    setState(() {
      _saving = false;
      _closeEditor();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      final l10n = Lt.of(context);
      final trimmedName = widget.itemName?.trim();
      final hintText = trimmedName != null && trimmedName.isNotEmpty
          ? l10n.listEditNoteHintWithName(trimmedName)
          : l10n.listEditNoteHint;
      return _Editor(
        controller: _controller!,
        focusNode: _focusNode!,
        hintText: hintText,
        // Only autofocus when the user explicitly opened the editor
        // (pencil tap). In page-level edit mode every owner-editable
        // note auto-expands at once — if every TextField asked for
        // focus, the page would race-grab focus into a random one.
        autofocus: !widget.autoExpand,
        onSubmit: _submit,
        lastCommittedText: _lastCommittedText,
        saving: _saving,
      );
    }

    if (_hasTip) {
      return _TipCallout(
        tip: widget.tip!,
        onEdit: widget.canEdit ? _startEditing : null,
        authorAvatarUrl: widget.authorAvatarUrl,
        authorName: widget.authorName,
        authorId: widget.authorId,
      );
    }

    if (!widget.canEdit) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: _LeaveNoteButton(onTap: _startEditing),
    );
  }
}

/// "Deixar nota" pill — the `Bt_Sq_Ico` host treatment (Figma `7660:27960`):
/// `rgba(121,121,121,0.1)` grey ground, 6-px radius, edit.svg 14×14 + label.
/// Same translucent grey ground the toggle/host pills use across the design
/// system (mirrors the `Color.fromRGBO(121,121,121,·)` grounds elsewhere).
class _LeaveNoteButton extends StatelessWidget {
  final VoidCallback onTap;

  const _LeaveNoteButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Material(
      color: const Color.fromRGBO(121, 121, 121, 0.1),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: SizedBox(
            height: 20,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SvgPicture.asset(
                  'assets/images/icons/detail/edit.svg',
                  width: 14,
                  height: 14,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.venueDetailButtonDeixarNota,
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w300,
                    fontSize: 14,
                    // Figma `Mobile/B2 Reg` — leading-none.
                    height: 1.0,
                    letterSpacing: -0.14,
                    color: AppColors.sokoInk,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Plain prose rendering of the tip — no tinted box, no left rail.
/// Matches the [ListDescription] widget's visual treatment so the note
/// reads as another piece of the page's prose rather than a card.
///
/// Truncates to 3 lines with ellipsis; when overflowing, a chevron-down
/// affordance appears to the right of the text and toggles full-text
/// expansion on tap (same pattern as `ListDescription`). For owners, a
/// pencil sits at the far right and is the ONLY way to enter edit mode
/// — tapping the text body is a no-op.
///
/// Affordance order on the row: `[ text… ][ chevron? ][ pencil ]` so
/// the pencil's position stays anchored at the right edge regardless of
/// whether the chevron is present (muscle memory for "rightmost icon =
/// edit" stays stable across short and long notes).
class _TipCallout extends StatefulWidget {
  final String tip;
  final VoidCallback? onEdit;

  /// Note author identity — see [ListItemNote]. A [PersonDot] renders to
  /// the left of the text when a photo or name is available.
  final String? authorAvatarUrl;
  final String? authorName;
  final String? authorId;

  const _TipCallout({
    required this.tip,
    required this.onEdit,
    this.authorAvatarUrl,
    this.authorName,
    this.authorId,
  });

  @override
  State<_TipCallout> createState() => _TipCalloutState();
}

class _TipCalloutState extends State<_TipCallout> {
  static const int _collapsedMaxLines = 3;
  // mobileB2Reg = 14-px font × 1.2 line-height ≈ 17 px.
  static const double _textLineHeight = 17.0;
  // 28-px hit target preserved for accessibility on the icon affordances.
  static const double _tapTargetSize = 28.0;
  // Leading author avatar — matches the in-card note dot
  // (list_zine_item_page.dart): 14-px dot, 6-px gap to the text.
  static const double _avatarSize = 14.0;
  static const double _avatarGap = 6.0;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final textStyle = AppTheme.mobileB2Reg(color: AppColors.sokoInk);
    final canEdit = widget.onEdit != null;
    final showAvatar =
        (widget.authorAvatarUrl?.isNotEmpty ?? false) ||
        (widget.authorName?.isNotEmpty ?? false);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Width available to the text in the WORST case (leading avatar +
        // chevron + pencil all rendered alongside). Measure overflow
        // against this so we don't under-detect when those affordances
        // take width away from the text. Reserve `4 + 28` per right-side
        // icon and `14 + 6` for the leading avatar.
        final reservedForIcons =
            (showAvatar ? _avatarSize + _avatarGap : 0) +
            (canEdit ? _tapTargetSize + 4 : 0) +
            _tapTargetSize +
            4;
        final overflows = _textOverflows(
          text: widget.tip,
          style: textStyle,
          maxWidth: (constraints.maxWidth - reservedForIcons).clamp(
            0.0,
            double.infinity,
          ),
          maxLines: _collapsedMaxLines,
        );

        final showChevron = overflows;
        final textWidget = Text(
          widget.tip,
          style: textStyle,
          maxLines: _expanded ? null : _collapsedMaxLines,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        );

        if (!showAvatar && !showChevron && !canEdit) return textWidget;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showAvatar) ...[
              PersonDot(
                url: widget.authorAvatarUrl,
                name: widget.authorName,
                seed: widget.authorId,
                size: _avatarSize,
              ),
              const SizedBox(width: _avatarGap),
            ],
            Expanded(child: textWidget),
            if (showChevron) ...[
              const SizedBox(width: 4),
              _FirstLineAlignedAffordance(
                // Flutter's bundled MaterialLocalizations returns PT
                // hints with a trailing period ("Aberto." / "Recolhido.")
                // which reads awkward in a button tooltip — strip it.
                tooltip: _hintWithoutTrailingPeriod(context),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(
                    LucideIcons.chevron_down,
                    size: 16,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ],
            if (canEdit) ...[
              const SizedBox(width: 4),
              _FirstLineAlignedAffordance(
                tooltip: Lt.of(context).venueDetailButtonEditarNota,
                onPressed: widget.onEdit!,
                child: SvgPicture.asset(
                  'assets/images/icons/detail/edit.svg',
                  width: 14,
                  height: 14,
                  colorFilter: ColorFilter.mode(
                    AppColors.sokoInk.withValues(alpha: 0.6),
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  bool _textOverflows({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required int maxLines,
  }) {
    if (maxWidth <= 0) return false;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: maxLines,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: maxWidth);
    return painter.didExceedMaxLines;
  }

  String _hintWithoutTrailingPeriod(BuildContext context) {
    final ml = MaterialLocalizations.of(context);
    final raw = _expanded ? ml.collapsedHint : ml.expandedHint;
    return raw.replaceAll(RegExp(r'\.$'), '');
  }
}

/// Hit-target whose *layout* height is constrained to the text line
/// (~17 px) via [OverflowBox], so the row never grows beyond the
/// visible text and the next divider's spacing stays symmetric. The
/// icon glyph is top-aligned inside the box so its visual centre lands
/// on the first text line's glyph centre.
///
/// Hover treatment matches [ListDescription]'s chevron — pointer-cursor
/// change only, no background circle. An `IconButton`'s built-in
/// hover/splash circle is geometrically centred on its bounds, so the
/// circle would render below the top-aligned icon (visibly low). A
/// plain `MouseRegion + GestureDetector + Tooltip` keeps the icon
/// position as the single source of truth.
class _FirstLineAlignedAffordance extends StatelessWidget {
  final Widget child;
  final VoidCallback onPressed;
  final String tooltip;

  const _FirstLineAlignedAffordance({
    required this.child,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _TipCalloutState._tapTargetSize,
      height: _TipCalloutState._textLineHeight,
      child: OverflowBox(
        maxHeight: _TipCalloutState._tapTargetSize,
        alignment: Alignment.topCenter,
        child: Tooltip(
          message: tooltip,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onPressed,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: _TipCalloutState._tapTargetSize,
                height: _TipCalloutState._tapTargetSize,
                child: Align(alignment: Alignment.topCenter, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline editor — a chat-composer-style paper capsule (Figma chat bar
/// `7507:27889`: `Soko/Paper` fill, 22-px radius, hairline `Soko/Ink` @12%
/// border) holding the note field, its 0/500 counter, and a rectangular
/// send-icon button. Auto-commits on focus-loss (handled by the parent
/// [_ListItemNoteState]); the send button is an explicit, deliberate commit.
class _Editor extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final String hintText;

  /// Explicit-commit handler wired to the send button.
  final VoidCallback onSubmit;

  /// Last value already persisted — the send button is a no-op (and renders
  /// disabled) while the trimmed text matches it, so tapping send only does
  /// something when there's an actual change to save.
  final String lastCommittedText;

  /// A save is in flight — swap the send glyph for a spinner and block
  /// re-taps.
  final bool saving;

  const _Editor({
    required this.controller,
    required this.focusNode,
    required this.autofocus,
    required this.hintText,
    required this.onSubmit,
    required this.lastCommittedText,
    required this.saving,
  });

  // Mirror the backend `tip` cap (500). Was 280 pre-PROD-2430 — kept in sync
  // via the shared constant so the counter and hard-cap match the API.
  static const int _maxLength = kUserListItemTipMaxLength;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      // Chat composer chrome — see `shared/widgets/chat_bar.dart` `outlined`.
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: AppColors.sokoInk.withValues(alpha: 0.12),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            // `minLines: 1` + `maxLines: null` lets the field collapse to
            // a single visible line when empty and grow as the user types
            // (bounded only by `_maxLength`).
            maxLines: null,
            minLines: 1,
            maxLength: _maxLength,
            // Default on web/iOS is `truncateAfterCompositionEnds`, which lets
            // users keep typing past `maxLength` until composition ends (e.g.
            // a space) — see PROD-1868. Force hard enforcement.
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontWeight: FontWeight.w300,
              fontSize: 14,
              height: 1.3,
              color: AppColors.sokoInk,
            ),
            cursorColor: AppColors.sokoInk,
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              contentPadding: EdgeInsets.zero,
              // Borderless — the surrounding capsule is the visible frame.
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              // Flutter's default counter is hidden; we render our own below.
              counterText: '',
              hintText: hintText,
              hintStyle: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontWeight: FontWeight.w300,
                fontSize: 14,
                height: 1.3,
                color: AppColors.sokoShade4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Bottom controls row: counter, then the rectangular send button.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final hasChange = value.text.trim() != lastCommittedText;
              return Row(
                children: [
                  const Spacer(),
                  Text(
                    '${value.text.characters.length}/$_maxLength',
                    style: const TextStyle(
                      fontFamily: 'ZalandoSans',
                      fontWeight: FontWeight.w300,
                      fontSize: 12,
                      height: 1.0,
                      color: AppColors.sokoShade4,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Tooltip(
                    message: l10n.discoveryChatBarSendLabel,
                    child: BtSqIco(
                      icon: LucideIcons.send,
                      label: '',
                      variant: BtSqIcoVariant.selected,
                      loading: saving,
                      // Disabled (dimmed, no tap) when nothing changed or a
                      // save is already running.
                      onTap: hasChange && !saving ? onSubmit : null,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
