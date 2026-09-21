import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/services/backend_analytics_service.dart'
    show OriginSource;
import '../../../core/services/unified_analytics_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/share_helpers.dart';
import '../../share/utils/share_url_resolver.dart';
import '../../../shared/widgets/share_sheet.dart';

/// Build the canonical public share URL for an event. Form-aware: in-list
/// shares preserve the parent-list context so the recipient lands back
/// inside that list (design doc § 7.4).
///
/// Slug support: pass `urlIdentifier` once Backend ships event slugs (today
/// the slug column doesn't exist on Event tables, so callers pass the UUID).
String buildEventShareUrl({
  required String eventIdentifier,
  String? listIdentifier,
}) {
  final base = listIdentifier != null
      ? '${ApiConstants.webappUrl}/lists/$listIdentifier/events/$eventIdentifier'
      : '${ApiConstants.webappUrl}/events/$eventIdentifier';
  return '$base?utm_source=soko_app'
      '&utm_medium=share'
      '&utm_campaign=event_share'
      '&utm_content=$eventIdentifier';
}

/// PROD-2071 — On web, opens the shared bottom sheet with an event preview;
/// on mobile, opens the native share sheet directly. Payload is URL only.
/// Fires `external_click` analytics (`destination_type = share`).
Future<void> shareEvent({
  required BuildContext context,
  required WidgetRef ref,
  required String eventId,
  required String eventTitle,
  String? eventDescription,
  String? listIdentifier,
}) async {
  final l10n = Lt.of(context);
  final analytics = ref.read(unifiedAnalyticsProvider);

  // PROD-4388 — prefer the backend's short, previewable share.soko.fyi link;
  // `buildEventShareUrl` stays as the fallback so a failed or slow mint
  // degrades to the old long URL instead of breaking the share.
  final shareUrl = await resolveShareUrl(
    ref: ref,
    shareContext: 'event',
    entityId: eventId,
    localFallbackUrl: buildEventShareUrl(
      eventIdentifier: eventId,
      listIdentifier: listIdentifier,
    ),
  );

  void fireAnalytics() {
    analytics.trackItemShare(
      eventId: eventId,
      originSource: OriginSource.detailView,
      originEntityId: listIdentifier,
    );
  }

  // The resolve above is the first await in this function, so the context may
  // have gone away while it was in flight (user navigated back).
  if (!context.mounted) return;

  await shareItem(
    context: context,
    ref: ref,
    title: l10n.shareEventTitle,
    url: shareUrl,
    webPreview: ShareSheetItemTile(
      icon: LucideIcons.calendar,
      title: eventTitle,
    ),
    onCopyAnalytics: fireAnalytics,
    onShareAnalytics: fireAnalytics,
  );
}
