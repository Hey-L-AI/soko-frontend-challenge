import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/notification_item.dart';
import '../../../l10n/generated/l10n.dart';

/// PROD-2524 T-E — single inbox card. Card-style (not a row tile):
/// rounded, soft shadow, left accent stripe coloured per category.
///
/// Unread cards: stronger background tint (sokoPink @ 6%) + visible
/// unread dot + bolder title. Read cards: paper bg, no dot, title weight
/// drops one notch.
class NotificationCard extends StatelessWidget {
  final NotificationItem item;
  final VoidCallback? onTap;

  const NotificationCard({super.key, required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isUnread = item.isUnread;
    final accentColor = _accentForCategory(item.category);
    final cardBg = isUnread
        ? const Color(0xFFFFF2F5) // sokoPink @ ~6%
        : AppColors.sokoPaper;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.sokoInk8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0F000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      bottomLeft: Radius.circular(12),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                item.title,
                                style: TextStyle(
                                  color: AppColors.sokoInk,
                                  fontSize: 15,
                                  fontWeight: isUnread
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  height: 1.25,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isUnread) ...[
                              const SizedBox(width: 8),
                              Container(
                                margin: const EdgeInsets.only(top: 5),
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: AppColors.sokoPink,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (item.body.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.body,
                            style: const TextStyle(
                              color: AppColors.sokoShade3,
                              fontSize: 13,
                              height: 1.35,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              _footerLabel(l10n, item),
                              style: const TextStyle(
                                color: AppColors.sokoShade3,
                                fontSize: 12,
                              ),
                            ),
                            if (item.routePath != null) ...[
                              const SizedBox(width: 8),
                              const Icon(
                                LucideIcons.arrow_up_right,
                                color: AppColors.sokoShade3,
                                size: 12,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Color _accentForCategory(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.reminders:
        return AppColors.sokoPink;
      case NotificationCategory.asyncJobs:
        return AppColors.sokoBlue;
      case NotificationCategory.chat:
        return AppColors.sokoLilac;
      case NotificationCategory.social:
        return AppColors.sokoGreen;
      case NotificationCategory.discovery:
        return AppColors.sokoRed;
      case NotificationCategory.feedback:
      case NotificationCategory.marketing:
      case NotificationCategory.unknown:
        return AppColors.sokoInk;
    }
  }

  /// Reminder-category cards (PROD-2525 T-K3) display "Starts in Xh"
  /// computed from `data.event_start_at`, falling back to the standard
  /// "Xm ago" when the field is missing.
  static String _footerLabel(Lt l10n, NotificationItem item) {
    if (item.category == NotificationCategory.reminders) {
      final startAt = _parseTime(item.data?['event_start_at']);
      if (startAt != null) {
        return _untilLabel(l10n, startAt);
      }
    }
    return _relativeTime(l10n, item.createdAt);
  }

  static String _untilLabel(Lt l10n, DateTime startAt) {
    final now = DateTime.now().toUtc();
    final diff = startAt.difference(now);
    if (diff.isNegative || diff.inSeconds < 60) {
      return l10n.reminderInboxStartsNow;
    }
    if (diff.inMinutes < 60) {
      return l10n.reminderInboxStartsInMinutes(diff.inMinutes);
    }
    if (diff.inHours < 24) {
      return l10n.reminderInboxStartsInHours(diff.inHours);
    }
    return l10n.reminderInboxStartsInDays(diff.inDays);
  }

  static DateTime? _parseTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  static String _relativeTime(Lt l10n, DateTime when) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(when);
    if (diff.inSeconds < 60) return l10n.notificationsJustNow;
    if (diff.inMinutes < 60)
      return l10n.notificationsMinutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l10n.notificationsHoursAgo(diff.inHours);
    if (diff.inDays < 7) return l10n.notificationsDaysAgo(diff.inDays);
    if (diff.inDays < 28) {
      return l10n.notificationsWeeksAgo((diff.inDays / 7).floor());
    }
    return '${when.day}/${when.month}/${when.year}';
  }
}
