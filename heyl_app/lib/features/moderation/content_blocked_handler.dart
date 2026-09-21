import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/exceptions/api_exceptions.dart';
import '../../core/services/unified_analytics_service.dart';
import '../../l10n/generated/l10n.dart';
import '../../shared/notifications/heyl_notification.dart';
import '../../shared/notifications/notification_state.dart';

/// Which form field triggered a 400 `CONTENT_BLOCKED`. Used to (a) pick
/// the right fallback copy (name vs generic) and (b) tag the
/// `content_blocked` analytics event so we can track block rates per
/// surface. PROD-2264.
enum ContentBlockedField {
  listName('list_name', usesNameCopy: true),
  listDescription('list_description'),
  listPrompt('list_prompt'),
  listItemTip('list_item_tip'),
  profileName('profile_name', usesNameCopy: true),
  profileHandle('profile_handle', usesNameCopy: true);

  final String analyticsValue;
  final bool usesNameCopy;
  const ContentBlockedField(this.analyticsValue, {this.usesNameCopy = false});
}

/// Pick the user-facing copy for a [ContentBlockedException]. Prefers the
/// backend's message (already localized server-side) and falls back to a
/// locally-localized string when it's missing — matches the backend's
/// two copy variants (`This content…` vs `This name…`).
String resolveContentBlockedMessage(
  ContentBlockedException blocked,
  Lt l10n, {
  required ContentBlockedField field,
}) {
  if (blocked.userMessage.isNotEmpty) return blocked.userMessage;
  return field.usesNameCopy
      ? l10n.moderationContentBlockedNameFallback
      : l10n.moderationContentBlockedFallback;
}

/// One-shot handler for the wordlist filter (400 `CONTENT_BLOCKED`).
///
/// Pass the raw error from a `catch (e)` block alongside the field
/// context. Returns `true` if the error matched a [ContentBlockedException]
/// — in which case the snackbar has been shown and the `content_blocked`
/// analytics event fired. Returns `false` otherwise so the caller can
/// fall through to its generic error path.
///
/// Safe to call from any consumer widget; uses [showSoko] which floats
/// above routes/dialogs/sheets via [NotificationHost].
bool handleContentBlocked(
  WidgetRef ref,
  BuildContext context,
  Object? error, {
  required ContentBlockedField field,
}) {
  final blocked = ContentBlockedException.tryFrom(error);
  if (blocked == null) return false;

  final message = resolveContentBlockedMessage(
    blocked,
    Lt.of(context),
    field: field,
  );
  ref
      .read(unifiedAnalyticsProvider)
      .trackContentBlocked(field: field.analyticsValue);
  showSoko(ref, message: message, variant: SokoVariant.error);
  return true;
}
