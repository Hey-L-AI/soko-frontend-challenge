import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/backend_analytics_service.dart' show OriginSource;
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/rich_message.dart';

/// Compact action buttons for card widgets
class CardActionButtons extends ConsumerWidget {
  final List<ButtonAction> buttons;
  final Function(String)? onPostback;
  /// Event ID for analytics tracking (if these buttons are for an event)
  final String? eventId;
  /// Venue ID for analytics tracking (if these buttons are for a place)
  final String? venueId;

  const CardActionButtons({
    super.key,
    required this.buttons,
    this.onPostback,
    this.eventId,
    this.venueId,
  });

  Future<void> _handleButtonTap(ButtonAction button, WidgetRef ref) async {
    if (button.type == ButtonActionType.url && button.url != null) {
      // Track the external click (fire-and-forget)
      _trackExternalClick(ref, button.url!);

      final uri = Uri.parse(button.url!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } else if (button.type == ButtonActionType.postback && button.text != null) {
      onPostback?.call(button.text!);
    }
  }

  void _trackExternalClick(WidgetRef ref, String url) {
    try {
      // Determine destination type based on URL and call appropriate method
      final lowerUrl = url.toLowerCase();
      if (lowerUrl.contains('google.com/maps') || lowerUrl.contains('maps.google')) {
        ref.read(unifiedAnalyticsProvider).trackGoogleMapsClick(
          url: url,
          eventId: eventId,
          venueId: venueId,
          originSource: OriginSource.chat,
        );
      } else if (lowerUrl.contains('ticket') || lowerUrl.contains('eventbrite') || lowerUrl.contains('dice.fm')) {
        ref.read(unifiedAnalyticsProvider).trackTicketingClick(
          url: url,
          eventId: eventId,
          venueId: venueId,
          originSource: OriginSource.chat,
        );
      } else if (lowerUrl.contains('calendar.google.com')) {
        ref.read(unifiedAnalyticsProvider).trackCalendarClick(
          url: url,
          eventId: eventId,
          venueId: venueId,
          originSource: OriginSource.chat,
        );
      } else {
        ref.read(unifiedAnalyticsProvider).trackWebsiteClick(
          url: url,
          eventId: eventId,
          venueId: venueId,
          originSource: OriginSource.chat,
        );
      }
    } catch (e) {
      debugPrint('Analytics: Failed to track button click - $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (buttons.isEmpty) return const SizedBox.shrink();

    const borderColor = AppColors.sokoShade5;
    const buttonTextColor = AppColors.sokoInk;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: buttons.map((button) {
          return OutlinedButton(
            onPressed: () => _handleButtonTap(button, ref),
            style: OutlinedButton.styleFrom(
              foregroundColor: buttonTextColor,
              side: BorderSide(color: borderColor),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
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
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (button.type == ButtonActionType.url) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.open_in_new,
                    size: 12,
                    color: buttonTextColor,
                  ),
                ],
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
