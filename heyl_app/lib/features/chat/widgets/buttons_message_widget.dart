import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/rich_message.dart';

/// Widget for rendering a buttons message (text with action buttons)
class ButtonsMessageWidget extends StatelessWidget {
  final String text;
  final List<ButtonAction> buttons;
  final Function(String)? onPostback;

  const ButtonsMessageWidget({
    super.key,
    required this.text,
    required this.buttons,
    this.onPostback,
  });

  Future<void> _handleButtonTap(ButtonAction button) async {
    if (button.type == ButtonActionType.url && button.url != null) {
      // Open URL externally
      final uri = Uri.parse(button.url!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } else if (button.type == ButtonActionType.postback && button.text != null) {
      // Send postback text as user message
      onPostback?.call(button.text!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final textColor = isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final linkColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;
    final buttonTextColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    final textStyle = AppTheme.body(
      fontSize: 15,
      fontWeight: FontWeight.w400,
      color: textColor,
      height: 1.4,
    );

    final linkStyle = textStyle.copyWith(
      color: linkColor,
      decoration: TextDecoration.underline,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Text content
        SelectableLinkify(
          text: text,
          style: textStyle,
          linkStyle: linkStyle,
          onOpen: (link) async {
            final uri = Uri.parse(link.url);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        ),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 12),
          // Buttons row (wrap if needed)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: buttons.map((button) {
              return OutlinedButton(
                onPressed: () => _handleButtonTap(button),
                style: OutlinedButton.styleFrom(
                  foregroundColor: buttonTextColor,
                  side: BorderSide(color: borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      button.label,
                      style: AppTheme.body(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (button.type == ButtonActionType.url) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.open_in_new,
                        size: 14,
                        color: buttonTextColor,
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}
