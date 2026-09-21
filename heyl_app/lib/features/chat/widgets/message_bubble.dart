import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/text_scale.dart';
import '../../../data/models/models.dart';
import '../../../shared/navigation/detail_siblings.dart';
import '../../../shared/widgets/soko_chat_bubble_shell.dart';
import '../../../shared/widgets/soko_typewriter_text.dart';
import 'buttons_message_widget.dart';
import 'rich_message_renderer.dart';

/// Message bubble widget for chat
class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// Called when a postback button is tapped (sends text as user message)
  final Function(String)? onPostback;

  /// Called when a card is tapped
  final void Function(ItemSuggestion item, DetailSiblings siblings)? onCardTap;

  /// Called when a card's bookmark button is tapped
  final Function(ItemSuggestion)? onCardBookmark;

  /// Returns whether a card is saved
  final bool Function(ItemSuggestion)? isCardSaved;

  /// Grouping context for the Instagram-style user-bubble corners: whether the
  /// message directly above / below (on screen) is also a user bubble. Drives
  /// [sokoUserBubbleRadius] and the tight inter-bubble seam.
  final bool prevIsUser;
  final bool nextIsUser;

  /// When true, this (fresh, newest assistant) message's text types out
  /// grapheme-by-grapheme; otherwise it renders whole (history / user).
  final bool animateTypewriter;

  /// Fired when the typewriter finishes (or immediately under reduce-motion) —
  /// chat_screen uses it to reveal the reply's cards only after its text.
  final VoidCallback? onTextRevealed;

  const MessageBubble({
    super.key,
    required this.message,
    this.onPostback,
    this.onCardTap,
    this.onCardBookmark,
    this.isCardSaved,
    this.prevIsUser = false,
    this.nextIsUser = false,
    this.animateTypewriter = false,
    this.onTextRevealed,
  });

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Check if the path is a local file path (not a URL)
  bool _isLocalFilePath(String path) {
    // On web, we can't use local file paths
    if (kIsWeb) return false;
    // Check if it's a URL (http, https, or data URI)
    if (path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('data:')) {
      return false;
    }
    // Assume it's a local file path
    return true;
  }

  /// Build image widget that handles both local files and network URLs
  Widget _buildImageWidget(String mediaUrl, Color fallbackColor) {
    final errorWidget = Container(
      width: 200,
      height: 150,
      color: fallbackColor,
      child: const Icon(Icons.image_not_supported),
    );

    if (_isLocalFilePath(mediaUrl)) {
      // Local file path (optimistic update from user-selected image)
      return Image.file(
        File(mediaUrl),
        width: 200,
        height: 150,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => errorWidget,
      );
    } else {
      // Network URL (from API response)
      return Image.network(
        mediaUrl,
        width: 200,
        height: 150,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => errorWidget,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    // User → pink bubble with Instagram-style grouped corners (a tight 3-px seam
    // between stacked user bubbles). Soko → NO bubble: plain text on the paper
    // surface, matching the onboarding chat.
    if (isUser) {
      return Padding(
        padding: EdgeInsets.only(bottom: nextIsUser ? 3 : 12),
        child: SokoChatBubbleShell(
          isUser: true,
          backgroundColor: AppColors.sokoPink,
          borderRadius: sokoUserBubbleRadius(
            prevIsUser: prevIsUser,
            nextIsUser: nextIsUser,
          ),
          // 14×8 insets — tighter vertical than Figma's 14×12 (matches
          // onboarding; product decision for short replies).
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: _buildUserContent(context),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _buildAssistantContent(context),
      ),
    );
  }

  /// Soko's reply: no bubble, plain left-aligned text (fontSize 16 / height 1.5,
  /// like onboarding). Fresh text types out via [SokoTypewriterText]; buttons /
  /// image rich content render as-is; a pure card carousel renders nothing here
  /// (chat_screen draws the cards below).
  Widget _buildAssistantContent(BuildContext context) {
    final scale = effectiveTextScaleFactor(context);
    final sokoStyle = AppTheme.body(
      fontSize: 16 * scale,
      fontWeight: FontWeight.w400,
      height: 1.5,
      color: AppColors.sokoInk,
    );
    final linkStyle = sokoStyle.copyWith(decoration: TextDecoration.underline);

    final rich = message.richContent;
    // A pure card carousel is drawn (gated) by chat_screen below.
    if (rich is CardCarouselMessage) return const SizedBox.shrink();
    // An image message is self-contained (no leading text to wait on).
    if (rich is ImageRichMessage) {
      return RichMessageRenderer(
        message: rich,
        onPostback: onPostback,
        onCardTap: onCardTap,
        onCardBookmark: onCardBookmark,
        isCardSaved: isCardSaved,
      );
    }

    // Leading text — types out first. For a buttons message the prompt text
    // types, and the buttons themselves are held back until it finishes (like
    // the carousel cards). TextRichMessage / legacy text is just the content.
    final isButtons = rich is ButtonsMessage;
    final text = isButtons
        ? rich.text
        : (rich is TextRichMessage ? rich.content : (message.text ?? ''));

    final Widget textWidget;
    if (animateTypewriter && text.isNotEmpty) {
      textWidget = SokoTypewriterText(
        text: text,
        style: sokoStyle,
        onComplete: onTextRevealed,
      );
    } else if (text.isEmpty) {
      textWidget = const SizedBox.shrink();
    } else {
      // Settled/history: Linkify so links stay tappable; non-selectable so a
      // long-press copies the whole reply (chat_screen wraps it).
      textWidget = Linkify(
        onOpen: (link) => _openLink(link.url),
        text: text,
        style: sokoStyle,
        linkStyle: linkStyle,
      );
    }

    if (!isButtons) return textWidget;

    // Buttons reveal only after the prompt text has typed out
    // (animateTypewriter flips false once the text finishes).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        textWidget,
        if (!animateTypewriter && rich.buttons.isNotEmpty) ...[
          const SizedBox(height: 12),
          // Buttons only — the prompt text is already rendered above.
          ButtonsMessageWidget(
            text: '',
            buttons: rich.buttons,
            onPostback: onPostback,
          ),
        ],
      ],
    );
  }

  Widget _buildUserContent(BuildContext context) {
    // PROD-2875: flutter_linkify's `textScaleFactor` defaults to 1.0 and
    // ignores the OS MediaQuery scaler, so bake the (app-wide-clamped) factor
    // into the font sizes below.
    final linkifyScale = effectiveTextScaleFactor(context);
    final textStyle = AppTheme.body(
      fontSize: 15 * linkifyScale,
      fontWeight: FontWeight.w400,
      height: 1.4,
      color: AppColors.sokoInk,
    );
    final linkStyle = textStyle.copyWith(decoration: TextDecoration.underline);

    final userType = message.userMessageType ?? UserMessageType.text;
    switch (userType) {
      case UserMessageType.text:
        return SelectableLinkify(
          onOpen: (link) => _openLink(link.url),
          text: message.text ?? '',
          style: textStyle,
          linkStyle: linkStyle,
        );
      case UserMessageType.image:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.mediaUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildImageWidget(
                  message.mediaUrl!,
                  AppColors.sokoShade5,
                ),
              ),
            if (message.text != null && message.text!.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableLinkify(
                onOpen: (link) => _openLink(link.url),
                text: message.text!,
                style: textStyle,
                linkStyle: linkStyle,
              ),
            ],
          ],
        );
      case UserMessageType.voice:
        // Voice messages: show transcribed text with mic icon
        final displayText = message.text ?? '[Voice message]';
        // Remove "[Voice] " prefix if present (backend adds it)
        final cleanText = displayText.startsWith('[Voice] ')
            ? displayText.substring(8)
            : displayText;

        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.mic,
              size: 18,
              color: AppColors.sokoInk.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: SelectableLinkify(
                onOpen: (link) => _openLink(link.url),
                text: cleanText,
                style: textStyle,
                linkStyle: linkStyle,
              ),
            ),
          ],
        );
    }
  }
}
