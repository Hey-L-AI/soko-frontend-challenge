import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/social/follow_user_summary.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/expert_badge.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../profile/utils/profile_style.dart';
import '../../profile/widgets/compact_follow_button.dart';
import '../../profile/widgets/textured_avatar.dart';
import '../providers/list_followers_provider.dart';

/// Followers of a zine (list). Public zines are viewable by anyone; private
/// zines are owner-only (the request 403s otherwise). Reached from the zine's
/// tappable follower count and the "Followed by …" line under its description.
/// Rows reuse the exact same format as the profile followers list.
class ListFollowersScreen extends ConsumerWidget {
  final String listId;

  /// Zine name for the header (`{name} · followers`). Optional — falls back to
  /// just the "followers" label when the list wasn't handed in via `extra`.
  final String? zineName;

  const ListFollowersScreen({super.key, required this.listId, this.zineName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final title = (zineName != null && zineName!.trim().isNotEmpty)
        ? '${zineName!} · ${l10n.profileStatFollowers}'
        : l10n.profileStatFollowers;

    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                child: Row(
                  children: [
                    SokoBackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Pt.b1Bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _ListFollowersBody(listId: listId)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListFollowersBody extends ConsumerWidget {
  final String listId;

  const _ListFollowersBody({required this.listId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final res = ref.watch(listFollowersProvider(listId));

    return res.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      // A zine's follower list is never "private" — if you can open the zine
      // you can see who follows it. Any error here (timeout / network / 5xx /
      // an unreachable zine) is transient, so always offer a retry rather than
      // a misleading privacy message.
      error: (e, __) => _LoadError(
        onRetry: () => ref.invalidate(listFollowersProvider(listId)),
      ),
      data: (r) {
        if (r.items.isEmpty) {
          return _EmptyList(l10n.profileListEmpty);
        }
        // Pin the viewer's own row to the top when they follow this zine, so
        // "me" is the first thing they see rather than buried in follow order.
        final myId = ref.watch(currentUserProvider)?.id;
        final items = [...r.items];
        if (myId != null) {
          final mine = items.indexWhere((e) => e.userId == myId);
          if (mine > 0) items.insert(0, items.removeAt(mine));
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox.shrink(),
          itemBuilder: (_, i) => _UserRow(item: items[i]),
        );
      },
    );
  }
}

class _UserRow extends ConsumerWidget {
  final FollowUserSummary item;

  const _UserRow({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handle = item.handle;
    // Don't offer a follow button on your own row.
    final isSelf = ref.watch(currentUserProvider)?.id == item.userId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: (handle == null || handle.isEmpty)
                  ? null
                  : () => context.push(AppRoutes.publicProfilePath(handle)),
              child: Row(
                children: [
                  TexturedAvatar(
                    url: item.avatarUrl,
                    name: item.fullName ?? item.handle,
                    colorSeed: item.userId,
                    width: 50,
                    height: 50,
                    initialFontScale: 0.34,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                item.fullName ?? '@${item.handle ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Pt.b1Bold,
                              ),
                            ),
                            if (item.isExpert) ...[
                              const SizedBox(width: 6),
                              const ExpertBadge(compact: true),
                            ],
                          ],
                        ),
                        if (item.handle != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            '@${item.handle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Pt.b2.copyWith(color: pInk50),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!isSelf) ...[
            const SizedBox(width: 8),
            CompactFollowButton(
              userId: item.userId,
              initialFollowing: item.isFollowing,
              followsYou: item.followsYou,
              requested: item.requested,
              refreshSuggestionsOnChange: true,
              analyticsSource: 'zine_followers_list',
            ),
          ],
        ],
      ),
    );
  }
}

/// "No one here yet" — the Soko reading illustration + a short message, matching
/// the profile followers empty state.
class _EmptyList extends StatelessWidget {
  final String text;
  const _EmptyList(this.text);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/illustrations/soko-reading.png',
              height: 96,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Pt.b2.copyWith(color: pInk50),
            ),
          ],
        ),
      ),
    );
  }
}

/// Transient load failure (timeout / network / 5xx) — a retry, never the
/// misleading "this list is private".
class _LoadError extends StatelessWidget {
  final VoidCallback onRetry;
  const _LoadError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.circle_alert, size: 34, color: pInk30),
            const SizedBox(height: 12),
            Text(
              l10n.profileListLoadError,
              textAlign: TextAlign.center,
              style: Pt.b2.copyWith(color: pInk50),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: onRetry, child: Text(l10n.commonRetry)),
          ],
        ),
      ),
    );
  }
}
