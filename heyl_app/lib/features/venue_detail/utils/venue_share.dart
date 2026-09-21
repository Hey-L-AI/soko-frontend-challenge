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

/// Build the canonical public share URL for a venue. Form-aware: in-list
/// shares preserve the parent-list context so the recipient lands back
/// inside that list (design doc § 7.4).
///
/// Slug support: pass `urlIdentifier` once Backend #11 ships slugs (today
/// the slug column doesn't exist on Venue tables, so callers pass the
/// UUID).
String buildVenueShareUrl({
  required String venueIdentifier,
  String? listIdentifier,
}) {
  final base = listIdentifier != null
      ? '${ApiConstants.webappUrl}/lists/$listIdentifier/venues/$venueIdentifier'
      : '${ApiConstants.webappUrl}/venues/$venueIdentifier';
  return '$base?utm_source=soko_app'
      '&utm_medium=share'
      '&utm_campaign=venue_share'
      '&utm_content=$venueIdentifier';
}

/// PROD-2071 — On web, opens the shared bottom sheet with a venue preview;
/// on mobile, opens the native share sheet directly. Payload is URL only.
/// Fires `external_click` analytics (`destination_type = share`).
Future<void> shareVenue({
  required BuildContext context,
  required WidgetRef ref,
  required String venueId,
  required String venueName,
  String? venueDescription,
  String? listIdentifier,
}) async {
  final l10n = Lt.of(context);
  final analytics = ref.read(unifiedAnalyticsProvider);

  // PROD-4388 — short, previewable link with the long URL as fallback.
  final shareUrl = await resolveShareUrl(
    ref: ref,
    shareContext: 'venue',
    entityId: venueId,
    localFallbackUrl: buildVenueShareUrl(
      venueIdentifier: venueId,
      listIdentifier: listIdentifier,
    ),
  );

  void fireAnalytics() {
    analytics.trackItemShare(
      venueId: venueId,
      originSource: OriginSource.detailView,
      originEntityId: listIdentifier,
    );
  }

  if (!context.mounted) return;

  await shareItem(
    context: context,
    ref: ref,
    title: l10n.shareVenueTitle,
    url: shareUrl,
    webPreview: ShareSheetItemTile(icon: LucideIcons.map_pin, title: venueName),
    onCopyAnalytics: fireAnalytics,
    onShareAnalytics: fireAnalytics,
  );
}
