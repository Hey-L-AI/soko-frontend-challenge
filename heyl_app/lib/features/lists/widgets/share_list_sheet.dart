import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/share_helpers.dart';
import '../../share/utils/share_url_resolver.dart';

/// PROD-1992 — DS chrome migration of the share-list sheet.
/// PROD-2071 — Now a thin wrapper around the shared [shareItem] helper so
/// list, event, venue, and daily-drop share entry points stay aligned:
/// web shows the generic share sheet, mobile uses native share (URL only).
/// Public so PROD-2785's `SokoShareSheet` wiring (`list_page_header.dart`)
/// can reuse the same canonical share URL the legacy share-list sheet
/// generated. Originally private to this file (PROD-1992 / PROD-2071).
String buildListShareUrl(UserList list) {
  final base = '${ApiConstants.webappUrl}/lists/${list.urlIdentifier}';
  return '$base?utm_source=soko_app&utm_medium=share'
      '&utm_campaign=list_share&utm_content=${list.urlIdentifier}';
}

/// Show the share-list entry point. On web this opens the generic share
/// sheet with a list-preview tile; on mobile this skips straight to the
/// native share sheet with the URL only.
Future<void> showShareListSheet(
  BuildContext context,
  UserList list, {
  required WidgetRef ref,
}) async {
  final l10n = Lt.of(context);
  final analytics = ref.read(unifiedAnalyticsProvider);

  // PROD-4388 — short, previewable link with the long URL as fallback. The
  // zine cover is already rendered and stored, so this is the surface where
  // the preview image costs nothing extra.
  final shareUrl = await resolveShareUrl(
    ref: ref,
    shareContext: 'list',
    entityId: list.id,
    localFallbackUrl: buildListShareUrl(list),
  );

  if (!context.mounted) return;

  return shareItem(
    context: context,
    ref: ref,
    title: l10n.shareListTitle,
    url: shareUrl,
    webPreview: _ListPreviewTile(list: list, l10n: l10n),
    onCopyAnalytics: () => analytics.trackListShare(
      listId: list.id,
      shareMethod: ShareMethod.copyLink,
      listName: list.name,
    ),
    onShareAnalytics: () => analytics.trackListShare(
      listId: list.id,
      shareMethod: ShareMethod.social,
      listName: list.name,
    ),
  );
}

/// Compact preview tile: bookmark glyph + list name + item count, with a
/// "public" chip on the right. Soko/Shade5 background, radius 12.
class _ListPreviewTile extends StatelessWidget {
  const _ListPreviewTile({required this.list, required this.l10n});
  final UserList list;
  final Lt l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.sokoPink.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              LucideIcons.bookmark,
              size: 22,
              color: AppColors.sokoPink,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  list.name,
                  style: const TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                    letterSpacing: -0.16,
                    color: AppColors.sokoInk,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  l10n.listsItemCount(list.itemCount),
                  style: AppTheme.mobileB2Reg(color: AppColors.sokoShade4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _PublicChip(label: l10n.listsVisibilityPublic),
        ],
      ),
    );
  }
}

/// Visibility chip — Soko/Pink @ 10% bg, pink globe + label.
class _PublicChip extends StatelessWidget {
  const _PublicChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.sokoPink.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.globe, size: 12, color: AppColors.sokoPink),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.sokoPink,
            ),
          ),
        ],
      ),
    );
  }
}
