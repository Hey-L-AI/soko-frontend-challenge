import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/services/unified_analytics_service.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models/models.dart' show SharedByUser, UserRole;
import '../../l10n/generated/l10n.dart';
import '../../providers/providers.dart' show currentUserProvider;
import 'avatar_name_label.dart';
import 'expert_badge.dart';

/// `Shared by <user>` attribution row for user-created events & venues
/// (PROD-3134). Rendered directly below the description on the event/venue
/// detail body, as a small credit line: a 20 px avatar (or a person glyph
/// fallback) followed by the creator's name.
///
/// Tappable → the creator's social profile (`/u/{handle}`), reusing the exact
/// pattern established for the list-curator link
/// (`list_page_header.dart`). Because the public-profile route is still an
/// admin-gated pilot (PROD-2775), the row is only made tappable for admins
/// with a resolvable handle; for everyone else it renders as plain,
/// non-interactive text. Callers should only mount this when
/// [EventDetailResponse2.sharedBy] / [VenueDetailResponse.sharedBy] is
/// non-null, so there is no widget (and no layout shift) for system items.
class SharedByAttribution extends ConsumerStatefulWidget {
  final SharedByUser sharedBy;

  /// PROD-3168: analytics context for shared_by_view / shared_by_click.
  /// [entityType] ∈ [SharedByEntity]; [entityId] is the event/venue id.
  final String entityType;
  final String entityId;

  const SharedByAttribution({
    super.key,
    required this.sharedBy,
    required this.entityType,
    required this.entityId,
  });

  @override
  ConsumerState<SharedByAttribution> createState() =>
      _SharedByAttributionState();
}

class _SharedByAttributionState extends ConsumerState<SharedByAttribution> {
  static const _textStyle = TextStyle(
    fontFamily: 'ZalandoSans',
    fontWeight: FontWeight.w300,
    fontSize: 13,
    height: 1.2,
    letterSpacing: -0.13,
    color: AppColors.sokoShade1,
  );

  /// PROD-3168: shared_by_view fires once, the first frame the credit is
  /// actually shown (not on every rebuild, and not when nothing renders).
  bool _viewTracked = false;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final sharedBy = widget.sharedBy;

    // Display name: prefer the full name, fall back to the @handle, and
    // render nothing rather than a dangling "Shared by " if neither exists.
    final fullName = sharedBy.fullName?.trim() ?? '';
    final handle = sharedBy.handle?.trim() ?? '';
    final displayName = fullName.isNotEmpty
        ? fullName
        : (handle.isNotEmpty ? '@$handle' : '');
    if (displayName.isEmpty) return const SizedBox.shrink();

    final avatarUrl = sharedBy.avatarUrl?.trim() ?? '';
    final isAdmin = ref.watch(currentUserProvider)?.role == UserRole.admin;
    // Tapping the sharer's name opens their profile — open to everyone now that
    // public profiles are live (was admin-only during rollout). isAdmin still
    // drives the analytics viewerRole below.
    final canLinkProfile = handle.isNotEmpty;
    final viewerRole = isAdmin ? ViewerRole.admin : ViewerRole.user;

    if (!_viewTracked) {
      _viewTracked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(unifiedAnalyticsProvider)
            .trackSharedByView(
              entityType: widget.entityType,
              entityId: widget.entityId,
              viewerRole: viewerRole,
              sharedByUserId: sharedBy.id,
            );
      });
    }

    Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: AvatarNameLabel(
            label: l10n.sharedByAttribution(displayName),
            avatarUrl: avatarUrl,
            style: _textStyle,
          ),
        ),
        if (sharedBy.isExpert) ...[
          const SizedBox(width: 4),
          const ExpertBadge(compact: true),
        ],
      ],
    );

    if (canLinkProfile) {
      row = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            ref
                .read(unifiedAnalyticsProvider)
                .trackSharedByClick(
                  entityType: widget.entityType,
                  entityId: widget.entityId,
                  // The link is tappable for everyone now (was admin-only), so
                  // report the actual viewer role, not a hardcoded admin.
                  viewerRole: viewerRole,
                  sharedByUserId: sharedBy.id,
                );
            context.push(AppRoutes.publicProfilePath(handle));
          },
          child: row,
        ),
      );
    }

    return Semantics(
      label: l10n.sharedByAttribution(displayName),
      button: canLinkProfile,
      child: row,
    );
  }
}
