import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../data/models/social/follow_user_summary.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../profile/utils/profile_style.dart';
import '../../profile/widgets/mutual_avatars_row.dart';
import '../providers/list_followers_provider.dart';

/// Tappable follow social-proof cluster for a zine (Figma `7660:27950/27951`
/// below-card, `7660:28322` header): overlapping mini avatars + "{name} +N
/// seguem" — one named follower plus a count of the rest, no leading glyph, no
/// "+" badge on the avatars (the count lives in the label). Opens the zine's
/// followers list.
///
/// Hidden while loading / on error / when the follower summaries can't be read
/// (so it never shows a broken or "private" state) and when the viewer is the
/// only follower (social proof is about OTHER people).
///
/// Shared by the below-pager slot ([ListZineView]) and the non-owner header
/// subtitle ([ListPageHeader]); the header passes a smaller [size] + the stats
/// [textStyle] so it reads inline with the "Edt. Soko · 10p · 45" metadata.
class ListFollowersInline extends ConsumerWidget {
  final String listId;
  final String listName;
  final int followerCount;

  /// Diameter of each mini avatar. 20 in the below-card slot; the header
  /// passes 16 to sit inline with the 14 px stats text.
  final double size;

  /// How much each avatar tucks under the previous. 4 matches Figma's
  /// `mr-[-4]` cluster.
  final double overlap;

  /// Label style. Defaults to the below-card `Pt.b2`; the header passes the
  /// stats-line style so the cluster reads as part of the metadata run.
  final TextStyle? textStyle;

  const ListFollowersInline({
    super.key,
    required this.listId,
    required this.listName,
    required this.followerCount,
    this.size = 20,
    this.overlap = 4,
    this.textStyle,
  });

  /// First name (or `@handle`) of a follower, for the compact "{name} +N" label.
  static String _firstName(FollowUserSummary u) {
    final full = u.fullName?.trim();
    if (full != null && full.isNotEmpty) return full.split(' ').first;
    return '@${u.handle ?? ''}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final followers = ref.watch(listFollowersProvider(listId)).valueOrNull;
    if (followers == null || followers.items.isEmpty) {
      return const SizedBox.shrink();
    }
    // Social proof is about OTHER people, so drop the viewer's own row from the
    // names, avatars, and the count (no "you follow this").
    final myId = ref.watch(currentUserProvider)?.id;
    final items = followers.items.where((u) => u.userId != myId).toList();
    if (items.isEmpty) {
      // The viewer is the only follower — nothing to show as social proof.
      return const SizedBox.shrink();
    }
    final selfIsFollower = items.length != followers.items.length;
    final rawTotal = followerCount > 0 ? followerCount : followers.items.length;
    final total = selfIsFollower ? rawTotal - 1 : rawTotal;
    // Up to 3 avatars, no "+" badge (count carried by the label), then one name
    // + "+N" for everyone beyond that name.
    final shown = items.take(3).toList();
    final others = (total - 1).clamp(0, 1 << 30);
    final text = l10n.listFollowersInline(_firstName(items.first), others);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () =>
            context.push(AppRoutes.listFollowersPath(listId), extra: listName),
        child: MutualAvatarsRow(
          avatars: [for (final u in shown) u.avatarUrl ?? ''],
          // Suppress the "+" overflow badge — the "+N" is in the label instead.
          totalCount: shown.length,
          text: text,
          textStyle: textStyle ?? Pt.b2,
          size: size,
          overlap: overlap,
        ),
      ),
    );
  }
}
