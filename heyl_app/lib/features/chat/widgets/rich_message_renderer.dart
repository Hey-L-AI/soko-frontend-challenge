import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/text_scale.dart';
import '../../../data/models/chat_message.dart';
import '../../../data/models/rich_message.dart';
import '../../../shared/navigation/detail_siblings.dart';
import 'buttons_message_widget.dart';

/// Renders any RichMessage type with the appropriate widget
class RichMessageRenderer extends StatelessWidget {
  final RichMessage message;
  final Function(String)? onPostback;
  final void Function(ItemSuggestion item, DetailSiblings siblings)? onCardTap;
  final Function(ItemSuggestion)? onCardBookmark;
  final bool Function(ItemSuggestion)? isCardSaved;

  const RichMessageRenderer({
    super.key,
    required this.message,
    this.onPostback,
    this.onCardTap,
    this.onCardBookmark,
    this.isCardSaved,
  });

  @override
  Widget build(BuildContext context) {
    return switch (message) {
      TextRichMessage(:final content, :final isAcknowledgment) =>
        _TextMessageContent(
          content: content,
          isAcknowledgment: isAcknowledgment,
        ),
      // CardCarouselMessage is rendered outside the bubble by chat_screen.dart,
      // so we return an empty widget here to avoid duplicate rendering
      CardCarouselMessage() => const SizedBox.shrink(),
      ButtonsMessage(:final text, :final buttons) => ButtonsMessageWidget(
        text: text,
        buttons: buttons,
        onPostback: onPostback,
      ),
      ImageRichMessage(:final url, :final caption) => _ImageMessageContent(
        url: url,
        caption: caption,
      ),
    };
  }
}

/// Text message content widget
class _TextMessageContent extends StatelessWidget {
  final String content;
  final bool isAcknowledgment;

  const _TextMessageContent({
    required this.content,
    this.isAcknowledgment = false,
  });

  @override
  Widget build(BuildContext context) {
    // PROD-2875: SelectableLinkify ignores the OS MediaQuery text scaler
    // (its textScaleFactor defaults to 1.0), so bake the app-wide-clamped
    // factor into the font size. This style feeds only the Linkify below.
    final linkifyScale = effectiveTextScaleFactor(context);
    final textStyle = AppTheme.body(
      fontSize: 15 * linkifyScale,
      fontWeight: FontWeight.w400,
      height: 1.4,
      color: AppColors.sokoInk,
    );

    final linkStyle = textStyle.copyWith(
      color: AppColors.sokoInk,
      decoration: TextDecoration.underline,
    );

    return SelectableLinkify(
      text: content,
      style: textStyle,
      linkStyle: linkStyle,
      onOpen: (link) async {
        final uri = Uri.parse(link.url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    );
  }
}

/// Image message content widget
class _ImageMessageContent extends StatelessWidget {
  final String url;
  final String? caption;

  const _ImageMessageContent({required this.url, this.caption});

  @override
  Widget build(BuildContext context) {
    const surfaceVariant = AppColors.sokoShade5;
    const captionColor = AppColors.sokoShade3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            url,
            width: 200,
            height: 150,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 200,
              height: 150,
              color: surfaceVariant,
              child: const Icon(Icons.image_not_supported),
            ),
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return Container(
                width: 200,
                height: 150,
                color: surfaceVariant,
                child: Center(
                  child: CircularProgressIndicator(
                    value: loadingProgress.expectedTotalBytes != null
                        ? loadingProgress.cumulativeBytesLoaded /
                              loadingProgress.expectedTotalBytes!
                        : null,
                    strokeWidth: 2,
                  ),
                ),
              );
            },
          ),
        ),
        if (caption != null && caption!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            caption!,
            style: AppTheme.body(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: captionColor,
            ),
          ),
        ],
      ],
    );
  }
}
