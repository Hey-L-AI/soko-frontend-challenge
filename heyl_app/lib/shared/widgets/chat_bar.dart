import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../l10n/generated/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/whatsapp_provider.dart';
import '../../features/chat/widgets/typing_placeholder_controller.dart';
import '../../features/notifications/widgets/notifications_top_button.dart';
import 'action_bar_location_pill.dart';
import 'bt_sq_ico.dart' show BtSqIcoVariant;

/// Shared chat-bar primitives used by both [DiscoveryChatBar] (Discovery
/// home composer at the top of the page) and [MessageInput] (chat
/// conversation composer at the bottom). Same widget tree, parameterized
/// behavior — keeps the two surfaces visually identical and enables the
/// Discovery → Chat Hero animation when sending starts a new session.
///
/// Source-of-truth design: `docs/ui/figma-cache/screens/discovery/header-chat-bar.md`
/// (Figma `3967:4158`).

/// Hero tag for the chat-bar geometry transition (Discovery top → Chat
/// bottom on send). Used by both DiscoveryChatBar and MessageInput; must
/// match exactly for the Hero overlay to fly.
const Object kChatBarHeroTag = 'chat-bar-shared';

/// Top row of the chat bar — text input with optional rotating typewriter
/// placeholder, optional mic button, send button. When [typingController] is
/// supplied the placeholder cycles through phrases (Discovery home); when
/// null the static [placeholder] is shown.
class ChatBarTopRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  /// When supplied, cycles the placeholder through its phrases. Otherwise
  /// [placeholder] is shown as static text.
  final TypingPlaceholderController? typingController;

  /// Static placeholder text — used when [typingController] is null.
  final String placeholder;

  final bool hasText;
  final bool voiceEnabled;
  final VoidCallback onSend;
  final Future<void> Function() onMicTap;

  /// When non-null, renders a leading affordance inside the input, before the
  /// text: an **X** that clears all text when [hasText], and a **search**
  /// glyph (focuses the field) when the input is empty. Null → no leading
  /// affordance (the Discovery composer opts out today).
  final VoidCallback? onClear;

  /// Chat composer style (Figma `7507:27889`): a single fully-rounded capsule
  /// on the paper background with a hairline `Soko/Ink` border and **bare**
  /// send/mic icons — no `Soko/Shade5` fill, no backdrop blur, no filled send
  /// circle. Default false keeps the Discovery home bar's original chrome.
  final bool outlined;

  /// Whether the send button is enabled. Disabled when there's no content
  /// to send AND voice isn't an option — the button still renders but
  /// skips the press/hover animations.
  final bool sendEnabled;

  /// When true the send slot shows a loading spinner instead of the icon.
  final bool isLoading;

  /// Forwarded to the inner [TextField]. Opens the soft keyboard on
  /// mount when true — used by the chat empty state so the user lands
  /// straight in the composer.
  final bool autofocus;

  /// When non-null AND [hasText] is true, the send slot renders as a
  /// pill with the icon followed by this label (e.g. "Chat"). Used by
  /// the discovery typeahead overlay to nudge the user toward starting
  /// a chat once their query has enough characters. Null → circle.
  final String? sendLabel;

  /// Optional hard character cap (no counter UI). Used by the onboarding name
  /// step; null everywhere else leaves the chat input uncapped.
  final int? maxLength;

  const ChatBarTopRow({
    super.key,
    required this.controller,
    required this.focusNode,
    this.typingController,
    required this.placeholder,
    required this.hasText,
    required this.voiceEnabled,
    required this.onSend,
    required this.onMicTap,
    this.onClear,
    this.outlined = false,
    this.sendEnabled = true,
    this.isLoading = false,
    this.autofocus = false,
    this.sendLabel,
    this.maxLength,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    // Leading affordance: X (clear all) when there's text, else a search glyph
    // that focuses the field. Opt-in via [onClear].
    final Widget? leading = onClear == null
        ? null
        : Semantics(
            button: true,
            label: hasText
                ? l10n.chatComposerClearLabel
                : l10n.chatComposerSearchLabel,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: hasText ? onClear : focusNode.requestFocus,
                child: SizedBox(
                  width: outlined ? 26 : 28,
                  height: outlined ? 24 : 36,
                  child: Center(
                    child: Icon(
                      hasText ? LucideIcons.x : LucideIcons.search,
                      size: outlined ? 18 : 16,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ),
              ),
            ),
          );

    final Widget input = Expanded(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: outlined ? 24 : 36),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (!hasText && !focusNode.hasFocus)
              if (typingController != null)
                AnimatedBuilder(
                  animation: typingController!,
                  builder: (context, _) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        typingController!.displayText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w300,
                          height: 1,
                          letterSpacing: -0.30,
                          color: AppColors.sokoShade4,
                        ),
                      ),
                    );
                  },
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    placeholder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w300,
                      height: 1,
                      letterSpacing: -0.30,
                      color: AppColors.sokoShade4,
                    ),
                  ),
                ),
            TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: autofocus,
              inputFormatters: maxLength == null
                  ? null
                  : [LengthLimitingTextInputFormatter(maxLength!)],
              maxLines: 4,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w300,
                height: 1.2,
                letterSpacing: -0.30,
                color: AppColors.sokoInk,
              ),
              cursorColor: AppColors.sokoInk,
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                filled: false,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 6,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Trailing controls — bare ink icons in the outlined chat style, the
    // chromed circle/pill buttons on the Discovery home bar.
    final List<Widget> trailing = outlined
        ? [
            if (voiceEnabled) ...[
              _BareBarIcon(
                icon: LucideIcons.mic,
                onTap: onMicTap,
                semanticLabel: l10n.discoveryChatBarMicLabel,
              ),
              const SizedBox(width: 8),
            ],
            _BareBarIcon(
              icon: LucideIcons.send,
              // Empty composer → send is a no-op; mute it and skip the call.
              onTap: () async {
                if (sendEnabled && hasText) onSend();
              },
              semanticLabel: l10n.discoveryChatBarSendLabel,
              loading: isLoading,
              muted: !hasText,
            ),
          ]
        : [
            if (voiceEnabled) ...[
              ChatBarCircleButton(
                background: AppColors.sokoShade5,
                iconColor: AppColors.sokoInk,
                icon: LucideIcons.mic,
                semanticLabel: l10n.discoveryChatBarMicLabel,
                onTap: onMicTap,
              ),
              const SizedBox(width: 6),
            ],
            ChatBarSendButton(
              background: hasText ? AppColors.sokoInk : AppColors.sokoShade45,
              iconColor: hasText ? AppColors.sokoPaper : AppColors.sokoInk,
              label: hasText ? sendLabel : null,
              semanticLabel: l10n.discoveryChatBarSendLabel,
              // D23: no scale feedback when the button is a no-op
              // (empty composer + voice disabled).
              enabled: sendEnabled && hasText,
              loading: isLoading,
              onTap: () async => onSend(),
            ),
          ];

    final row = Row(
      crossAxisAlignment: outlined
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        if (leading != null) leading,
        input,
        const SizedBox(width: 6),
        ...trailing,
      ],
    );

    if (outlined) {
      // Figma `7507:27889`: paper capsule, hairline Soko/Ink border, no blur.
      return Container(
        decoration: BoxDecoration(
          color: AppColors.sokoPaper,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: AppColors.sokoInk.withValues(alpha: 0.12),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
        child: row,
      );
    }

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25.495, sigmaY: 25.495),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.sokoShade5,
            borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
          ),
          padding: const EdgeInsets.all(8),
          child: row,
        ),
      ),
    );
  }
}

/// A bare (chrome-less) tappable icon for the outlined chat composer — the
/// send / mic glyphs sit directly on the capsule, `Soko/Ink`, no circle.
class _BareBarIcon extends StatelessWidget {
  const _BareBarIcon({
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
    this.loading = false,
    this.muted = false,
  });

  final IconData icon;
  final Future<void> Function() onTap;
  final String semanticLabel;
  final bool loading;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted
        ? AppColors.sokoInk.withValues(alpha: 0.35)
        : AppColors.sokoInk;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(),
          child: SizedBox(
            width: 32,
            height: 24,
            child: Center(
              child: loading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    )
                  : Icon(icon, size: 20, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom row of the chat bar — pink strip holding the "Create list" CTA
/// on the left and an optional History button on the right.
///
/// Callers should omit this widget entirely when neither slot has anything
/// to surface — there is no "empty row" state.
class ChatBarBottomRow extends StatelessWidget {
  final VoidCallback? onCreateListTap;
  final VoidCallback? onHistoryTap;

  /// Read-only current chat search-center city name. When non-null, renders
  /// [ChatBarLocationLabel] as the leading element of the left slot (before
  /// the optional Create-list pill). Null → left slot behaves as before.
  final String? searchLocationLabel;

  const ChatBarBottomRow({
    super.key,
    this.onCreateListTap,
    this.onHistoryTap,
    this.searchLocationLabel,
  }) : assert(
         onCreateListTap != null || onHistoryTap != null,
         'ChatBarBottomRow needs at least one slot wired up.',
       );

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25.495, sigmaY: 25.495),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.sokoShade45,
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(6)),
          ),
          height: 60,
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Left slot — read-only location indicator (leading) and/or the
              // Create-list pill. The indicator is persistent context; the
              // pill is transient. Both left-aligned; the label ellipsizes so
              // the pink pill and "Recents" are never clipped.
              Expanded(
                child: Row(
                  children: [
                    if (searchLocationLabel != null)
                      Flexible(
                        child: ChatBarLocationLabel(
                          label: searchLocationLabel!,
                        ),
                      ),
                    if (searchLocationLabel != null && onCreateListTap != null)
                      const SizedBox(width: 10),
                    if (onCreateListTap != null)
                      CreateListPill(onTap: onCreateListTap!),
                  ],
                ),
              ),
              if (onHistoryTap != null) ...[
                const SizedBox(width: 10),
                // Label-only "Recents" button — same 40 px / 6 px-radius
                // rectangle as `CreateListPill`. Soko/Shade4 grey fill keeps
                // it visually neutral. Semantic label keeps "Past
                // conversations" because it describes the destination more
                // precisely than the shorter visible "Recents".
                Semantics(
                  label: l10n.discoveryChatBarHistoryLabel,
                  button: true,
                  child: ChatBarTextPill(
                    label: l10n.chatBarRecentsLabel,
                    onTap: onHistoryTap!,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// PROD-2265: AI data-disclosure line shown in the chat bar's bottom strip
/// (left of "Recents") while a chat is in its early state. Generic copy — the
/// AI providers are named in the shared disclosure sheet opened via the
/// underlined "third-party AI providers" link.
///
/// Also reused standalone (centered) under the discovery typeahead composer,
/// where there is no bottom strip — see [discovery_typeahead_overlay.dart].
class AiDisclosureStripText extends StatelessWidget {
  const AiDisclosureStripText({
    super.key,
    this.onSeeMore,
    this.textAlign = TextAlign.start,
  });

  final VoidCallback? onSeeMore;

  /// Alignment of the sentence. Defaults to [TextAlign.start] (the chat-bar
  /// strip); the typeahead overlay passes [TextAlign.center].
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    // The sentence carries an {aiProviders} placeholder; we split on a private-
    // use sentinel and render the provider phrase as a (non-bold) underlined
    // link that opens the disclosure sheet. Placeholder keeps word order intact
    // across languages.
    const aiMark = '\u{E000}';
    final template = l10n.aiDisclosureInlineText(aiMark);

    final spans = <InlineSpan>[];
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isNotEmpty) {
        spans.add(TextSpan(text: buffer.toString()));
        buffer.clear();
      }
    }

    for (final rune in template.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == aiMark) {
        flush();
        spans.add(
          TextSpan(
            text: l10n.aiDisclosureInlineLink,
            style: const TextStyle(
              decoration: TextDecoration.underline,
              decorationColor: AppColors.sokoInk,
            ),
            recognizer: TapGestureRecognizer()..onTap = () => onSeeMore?.call(),
          ),
        );
      } else {
        buffer.write(ch);
      }
    }
    flush();

    return Text.rich(
      TextSpan(
        style: const TextStyle(
          fontSize: 11,
          height: 1.25,
          fontWeight: FontWeight.w300,
          letterSpacing: -0.11,
          color: AppColors.sokoInk,
        ),
        children: spans,
      ),
      textAlign: textAlign,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Read-only search-location indicator for the chat bar's bottom strip
/// (left of "Recents"). A pin + the current chat search-center city name.
/// Purely informational — no tap target, not a button (PROD-3129 follow-up;
/// see `docs/superpowers/specs/2026-07-16-chat-search-location-indicator-design.md`).
/// The city label ellipsizes so it never clips its bottom-row siblings.
class ChatBarLocationLabel extends StatelessWidget {
  final String label;

  const ChatBarLocationLabel({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Semantics(
      label: l10n.chatSearchLocationSemantics(label),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.map_pin, size: 14, color: AppColors.sokoInk),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  height: 1.2,
                  letterSpacing: -0.14,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Label-only button in Soko/Shade4 grey with Soko/Ink text. Same
/// 40 px height + 6 px radius rectangle as [CreateListPill] so the
/// two siblings read as a matched pair on the chat bar's bottom row.
/// Currently used for the "Recents" history-drawer trigger.
class ChatBarTextPill extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const ChatBarTextPill({super.key, required this.label, required this.onTap});

  @override
  State<ChatBarTextPill> createState() => _ChatBarTextPillState();
}

class _ChatBarTextPillState extends State<ChatBarTextPill> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    // Hover/press overlays use Soko/Ink as the highlight so they
    // darken against the light Soko/Shade4 fill — same overlay model
    // [BtSqIco] uses on its light variants.
    Color effectiveBg = AppColors.sokoShade4;
    if (_isPressed) {
      effectiveBg = Color.alphaBlend(
        AppColors.sokoInk.withValues(alpha: 0.16),
        AppColors.sokoShade4,
      );
    } else if (_isHovered) {
      effectiveBg = Color.alphaBlend(
        AppColors.sokoInk.withValues(alpha: 0.08),
        AppColors.sokoShade4,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: _isPressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: effectiveBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              widthFactor: 1,
              child: Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  height: 1.2,
                  letterSpacing: -0.14,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Create list" pink CTA pill — Soko/Pink fill, 6 px radius, 40 px height,
/// list icon + label. Tapping opens the create-list flow for the active
/// conversation's cards.
class CreateListPill extends StatefulWidget {
  final VoidCallback onTap;
  const CreateListPill({super.key, required this.onTap});

  @override
  State<CreateListPill> createState() => _CreateListPillState();
}

class _CreateListPillState extends State<CreateListPill> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: _isPressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.sokoPink,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  LucideIcons.list_plus,
                  size: 14,
                  color: AppColors.sokoInk,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.chatCreateListButton,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    height: 1.2,
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

/// 40×40 circular icon button with press / hover scale animation. Used for
/// the mic, send, history (and any other icon-only) slots in the chat bar.
class ChatBarCircleButton extends StatefulWidget {
  final Color background;
  final Color iconColor;
  final IconData icon;
  final String? semanticLabel;
  final Future<void> Function() onTap;

  /// When false, hover/press scale animations are skipped (D23). The button
  /// still renders and accepts taps — only the visual feedback is muted.
  final bool enabled;

  /// When true, a CircularProgressIndicator is shown instead of [icon].
  final bool loading;

  const ChatBarCircleButton({
    super.key,
    required this.background,
    required this.iconColor,
    required this.icon,
    required this.onTap,
    this.semanticLabel,
    this.enabled = true,
    this.loading = false,
  });

  @override
  State<ChatBarCircleButton> createState() => _ChatBarCircleButtonState();
}

class _ChatBarCircleButtonState extends State<ChatBarCircleButton> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.enabled
        ? (_isPressed ? 0.95 : (_isHovered ? 1.08 : 1.0))
        : 1.0;
    Color effectiveBg = widget.background;
    if (widget.enabled && _isPressed) {
      effectiveBg = Color.alphaBlend(
        widget.iconColor.withValues(alpha: 0.16),
        widget.background,
      );
    } else if (widget.enabled && _isHovered) {
      effectiveBg = Color.alphaBlend(
        widget.iconColor.withValues(alpha: 0.10),
        widget.background,
      );
    }
    final core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: effectiveBg,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: widget.loading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: widget.iconColor,
                      ),
                    )
                  : Icon(widget.icon, size: 16, color: widget.iconColor),
            ),
          ),
        ),
      ),
    );
    if (widget.semanticLabel == null) return core;
    return Semantics(label: widget.semanticLabel, button: true, child: core);
  }
}

/// The pink map button shown to the right of the chat composer when the
/// session has results. Matches the home feed's `DiscoveryMapButton` colour
/// (`AppColors.sokoPink` fill, `AppColors.sokoInk` glyph) so the two map
/// entry points read as the same control. Opens the full-screen map with all
/// of the session's results.
class ChatBarMapButton extends StatelessWidget {
  const ChatBarMapButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: Lt.of(context).chatComposerMapLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: AppColors.sokoPink,
              shape: BoxShape.circle,
            ),
            // Same glyph as the Discovery "Mapa" button
            // (`discovery_map_button.dart`) so the map entry point reads
            // identically in chat and on the homepage. Alpha silhouette tinted
            // to Soko/Ink via srcIn; a fixed slot keeps the aspect regardless of
            // the artwork.
            child: Center(
              child: SizedBox(
                width: 23,
                height: 18,
                child: Image.asset(
                  'assets/images/icons/discovery/map_button_glyph.png',
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  color: AppColors.sokoInk,
                  colorBlendMode: BlendMode.srcIn,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Send slot that morphs between a 40 × 40 circle (icon only) and a pill
/// (icon + label) based on [label]. Always 40 px tall and uses a 20 px
/// radius — so a circle shape is just a pill where width == height. The
/// label fade + width animate together via `AnimatedSize` + a fade so
/// the transition reads as the button "extending" / "collapsing".
class ChatBarSendButton extends StatefulWidget {
  final Color background;
  final Color iconColor;

  /// When null OR empty, renders as a 40 × 40 circle (icon only). When
  /// non-empty, the button extends to a pill with the label to the right
  /// of the icon. Transition is animated.
  final String? label;
  final String? semanticLabel;
  final Future<void> Function() onTap;
  final bool enabled;
  final bool loading;

  const ChatBarSendButton({
    super.key,
    required this.background,
    required this.iconColor,
    required this.onTap,
    this.label,
    this.semanticLabel,
    this.enabled = true,
    this.loading = false,
  });

  @override
  State<ChatBarSendButton> createState() => _ChatBarSendButtonState();
}

class _ChatBarSendButtonState extends State<ChatBarSendButton> {
  bool _isPressed = false;
  bool _isHovered = false;

  static const Duration _morphDuration = Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) {
    final scale = widget.enabled
        ? (_isPressed ? 0.95 : (_isHovered ? 1.04 : 1.0))
        : 1.0;
    Color effectiveBg = widget.background;
    if (widget.enabled && _isPressed) {
      effectiveBg = Color.alphaBlend(
        widget.iconColor.withValues(alpha: 0.16),
        widget.background,
      );
    } else if (widget.enabled && _isHovered) {
      effectiveBg = Color.alphaBlend(
        widget.iconColor.withValues(alpha: 0.10),
        widget.background,
      );
    }
    final hasLabel = widget.label != null && widget.label!.isNotEmpty;

    final iconOrSpinner = widget.loading
        ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: widget.iconColor,
            ),
          )
        : Icon(LucideIcons.send, size: 16, color: widget.iconColor);

    final core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 150),
          // AnimatedSize handles the width transition when the label
          // appears/disappears. Inner Container animates the bg color
          // (e.g. shade45 → ink when the user starts typing).
          child: AnimatedContainer(
            duration: _morphDuration,
            curve: Curves.easeOutCubic,
            height: 36,
            padding: hasLabel
                ? const EdgeInsets.symmetric(horizontal: 14)
                : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: effectiveBg,
              borderRadius: BorderRadius.circular(18),
            ),
            child: AnimatedSize(
              duration: _morphDuration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerLeft,
              child: hasLabel
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        iconOrSpinner,
                        const SizedBox(width: 8),
                        Text(
                          widget.label!,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            height: 1.2,
                            letterSpacing: -0.14,
                            color: widget.iconColor,
                          ),
                        ),
                      ],
                    )
                  : SizedBox(width: 36, child: Center(child: iconOrSpinner)),
            ),
          ),
        ),
      ),
    );
    if (widget.semanticLabel == null) return core;
    return Semantics(label: widget.semanticLabel, button: true, child: core);
  }
}

/// Discovery-only bottom row — location pill (city/scope picker) on the
/// left, WhatsApp deep-link + notifications inbox on the right.
///
/// The location pill took over the slot of the old "Adiciona à Soko" pill;
/// with the location out of the action bar below, the purple "Descobre a
/// cidade" pill there now spans its full row. Add-to-Soko keeps its entry
/// point in [DiscoveryEndActions] at the end of the feed.
///
/// Restored on the Discovery surface only; the chat MessageInput keeps
/// the simpler [ChatBarBottomRow] (Create-list pill) introduced in
/// PROD-1894.
class ChatBarDiscoveryBottomRow extends ConsumerWidget {
  /// Retained for API compatibility — the Add-to-Soko pill left this row
  /// (replaced by the location pill), so this callback no longer renders.
  final VoidCallback onAddTap;

  /// PROD-2221 — `onHistoryTap` retained for API compatibility but no
  /// longer renders the "Recents" pill on Discovery. The history
  /// drawer is still reachable from the chat conversation composer
  /// (`ChatBarBottomRow`) and remains a no-op slot here so callers
  /// upstream don't need to drop the wiring just for this surface.
  final VoidCallback? onHistoryTap;

  const ChatBarDiscoveryBottomRow({
    super.key,
    required this.onAddTap,
    this.onHistoryTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25.495, sigmaY: 25.495),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.sokoShade45,
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(6)),
          ),
          height: 60,
          padding: const EdgeInsets.all(10),
          // Location pill on the left (took the Add-to-Soko slot);
          // WhatsApp + Notifications inbox sit as a right-aligned glyph
          // cluster (same 40×40 brand-button treatment for both).
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LayoutBuilder(
                    // Grey fill (Soko/Ink @ 6%) — the neutral action-bar pill
                    // look, per João's call to keep it grey rather than pink
                    // in the slot the Add-to-Soko pill vacated. Reads fine on
                    // this row's dark blur (unlike the transparent idle pill).
                    builder: (context, constraints) => ActionBarLocationPill(
                      availableWidth: constraints.maxWidth,
                      variant: BtSqIcoVariant.normal,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const WhatsAppBrandIcon(),
              const SizedBox(width: 6),
              // Reminders live inside the notifications inbox now (its
              // "Reminders" tab) — the standalone bell was retired.
              const NotificationsTopButton(),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Adiciona à Soko" pink CTA pill — Soko/Pink fill, 6 px radius, 40 px
/// height, link icon + label. Originally Soko/Pink, briefly recoloured to
/// Soko/Yellow in PROD-1959 (#429), reverted back to Soko/Pink in PROD-1980.
class AddToSokoPill extends StatefulWidget {
  final VoidCallback onTap;
  const AddToSokoPill({super.key, required this.onTap});

  @override
  State<AddToSokoPill> createState() => _AddToSokoPillState();
}

class _AddToSokoPillState extends State<AddToSokoPill> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) {
          setState(() => _isPressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: _isPressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.sokoPink,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  LucideIcons.link,
                  size: 14,
                  color: AppColors.sokoInk,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.discoveryChatBarAddToSoko,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    height: 1.2,
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

/// WhatsApp brand glyph — opens wa.me with the user's WhatsApp phone (or
/// the guest phone fallback). Renders nothing when no phone is available.
class WhatsAppBrandIcon extends ConsumerStatefulWidget {
  const WhatsAppBrandIcon({super.key});

  @override
  ConsumerState<WhatsAppBrandIcon> createState() => _WhatsAppBrandIconState();
}

class _WhatsAppBrandIconState extends ConsumerState<WhatsAppBrandIcon> {
  bool _isPressed = false;
  bool _isHovered = false;

  String? _resolvePhone() {
    final user = ref.read(currentUserProvider);
    if (user?.whatsappPhone != null) return user!.whatsappPhone;
    return ref.read(guestWhatsAppPhoneProvider);
  }

  Future<void> _openWhatsApp() async {
    final phone = _resolvePhone();
    if (phone == null || phone.isEmpty) return;
    final greeting = Lt.of(context).homeWhatsAppGreeting;
    final url = Uri.https('wa.me', '/$phone', {'text': greeting});
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentUserProvider);
    ref.watch(guestWhatsAppPhoneProvider);
    final hasWhatsApp = _resolvePhone() != null;
    if (!hasWhatsApp) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    final scale = _isPressed ? 0.95 : (_isHovered ? 1.08 : 1.0);

    return Semantics(
      label: l10n.homeWhatsAppButton,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) {
            setState(() => _isPressed = false);
            _openWhatsApp();
          },
          onTapCancel: () => setState(() => _isPressed = false),
          child: AnimatedScale(
            scale: scale,
            duration: const Duration(milliseconds: 150),
            child: SvgPicture.asset(
              'assets/images/logos/whatsapp-icon-figma.svg',
              width: 40,
              height: 40,
            ),
          ),
        ),
      ),
    );
  }
}
