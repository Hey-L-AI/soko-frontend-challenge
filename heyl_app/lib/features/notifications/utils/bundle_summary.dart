import 'package:flutter/widgets.dart';

import '../../../data/models/notification_item.dart';
import '../../../l10n/generated/l10n.dart';

/// Synthesised title + body for the collapsed/expanded head of a
/// multi-member inbox bundle. The head is NOT one of the bundle members
/// (PROD-2781 follow-up) — it's a parent card that summarises the group
/// so expanding reveals all N children rather than N-1.
///
/// Title reuses the head's own title (shared across members of the same
/// bundle — e.g. "Sempre vais?" for every event-reminder firing of an
/// event). Body is a category-aware, count-aware localized line
/// ("3 lembretes pendentes", "2 updates", …). Falls back to a generic
/// "{count} notifications" line for categories without dedicated copy.
class BundleSummary {
  final String title;
  final String body;

  const BundleSummary({required this.title, required this.body});
}

BundleSummary computeBundleSummary(
  BuildContext context,
  NotificationBundle bundle,
) {
  final l10n = Lt.of(context);
  final count = bundle.members.length;
  final head = bundle.head;
  final body = switch (head.category) {
    NotificationCategory.reminders => l10n.inboxBundleRemindersBody(count),
    NotificationCategory.discovery => l10n.inboxBundleDiscoveryBody(count),
    NotificationCategory.asyncJobs => l10n.inboxBundleAsyncJobsBody(count),
    NotificationCategory.chat => l10n.inboxBundleChatBody(count),
    NotificationCategory.social => l10n.inboxBundleSocialBody(count),
    NotificationCategory.feedback => l10n.inboxBundleFeedbackBody(count),
    NotificationCategory.marketing ||
    NotificationCategory.unknown => l10n.inboxBundleGenericBody(count),
  };
  return BundleSummary(title: head.title, body: body);
}
