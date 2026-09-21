import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/social/follow_user_summary.dart';
import '../../../l10n/generated/l10n.dart';
import '../../profile/widgets/mutual_avatars_row.dart';

/// Faces + "{name} +N follow" from the library feed's `follower_preview`.
///
/// Same cluster as the zine page ([ListFollowersInline]) but the payload is
/// already on the row — no extra `GET …/followers`.
class LibraryZineFollowerProof extends StatelessWidget {
  const LibraryZineFollowerProof({
    super.key,
    required this.listId,
    required this.listName,
    required this.preview,
    this.followerCount,
  });

  final String listId;
  final String listName;
  final List<FollowUserSummary> preview;
  final int? followerCount;

  static String _firstName(FollowUserSummary u) {
    final full = u.fullName?.trim();
    if (full != null && full.isNotEmpty) return full.split(' ').first;
    final handle = u.handle?.trim();
    if (handle != null && handle.isNotEmpty) return '@$handle';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    if (preview.isEmpty) return const SizedBox.shrink();
    final name = _firstName(preview.first);
    if (name.isEmpty) return const SizedBox.shrink();
    final total = followerCount != null && followerCount! > 0
        ? followerCount!
        : preview.length;
    final others = (total - 1).clamp(0, 1 << 30);
    final shown = preview.take(3).toList();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () =>
            context.push(AppRoutes.listFollowersPath(listId), extra: listName),
        child: MutualAvatarsRow(
          avatars: [for (final u in shown) u.avatarUrl ?? ''],
          totalCount: shown.length,
          text: Lt.of(context).listFollowersInline(name, others),
          textStyle: AppTheme.mobileB2Reg(color: AppColors.sokoInk),
          size: 16,
          overlap: 4,
        ),
      ),
    );
  }
}
