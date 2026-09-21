import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/expert_badge.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/social/follow_user_summary.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../providers/public_profile_providers.dart';
import '../utils/profile_style.dart';
import '../widgets/compact_follow_button.dart';
import '../widgets/remove_follower_sheet.dart';
import '../widgets/textured_avatar.dart';

/// Which relationship list a [FollowListScreen] shows.
enum FollowListMode { followers, following, mutual }

/// Followers / following / mutual-followers list for a profile (PROD-2819 /
/// PROD-2822). The followers & following person surfaces 403 (locked) on a
/// private account viewed by a non-follower; the mutual list is the viewer's
/// own circle so it's never gated by the target's privacy.
class FollowListScreen extends ConsumerWidget {
  final String handle;
  final FollowListMode mode;

  const FollowListScreen({super.key, required this.handle, required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final String title;
    switch (mode) {
      case FollowListMode.followers:
        title = l10n.profileStatFollowers;
        break;
      case FollowListMode.following:
        title = l10n.profileStatFollowing;
        break;
      case FollowListMode.mutual:
        title = l10n.profileMutualFollowersTitle;
        break;
    }

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
                    Text('@$handle · $title', style: Pt.b1Bold),
                  ],
                ),
              ),
              Expanded(
                child: FollowListBody(handle: handle, mode: mode),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The scrollable followers/following/mutual list body (no app bar / back
/// button). Extracted from [FollowListScreen] so the profile "Connections" tab
/// can reuse the exact same row rendering inside its Followers/Following
/// sub-tabs.
class FollowListBody extends ConsumerStatefulWidget {
  final String handle;
  final FollowListMode mode;

  const FollowListBody({super.key, required this.handle, required this.mode});

  @override
  ConsumerState<FollowListBody> createState() => _FollowListBodyState();
}

class _FollowListBodyState extends ConsumerState<FollowListBody> {
  /// Followers I removed this session — hidden from the list instantly
  /// (optimistic) until the next refetch, which won't include them.
  final Set<String> _removed = {};

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final handle = widget.handle;
    final mode = widget.mode;
    final AsyncValue<FollowUserListResponse> res;
    switch (mode) {
      case FollowListMode.followers:
        res = ref.watch(profileFollowersProvider(handle));
        break;
      case FollowListMode.following:
        res = ref.watch(profileFollowingProvider(handle));
        break;
      case FollowListMode.mutual:
        res = ref.watch(profileMutualFollowersListProvider(handle));
        break;
    }
    // "Remove follower" is only offered on MY OWN followers list.
    final myHandle = ref.watch(currentUserProvider)?.handle;
    final isOwnList = myHandle != null && myHandle == handle;
    final canRemove = mode == FollowListMode.followers && isOwnList;

    void retry() {
      switch (mode) {
        case FollowListMode.followers:
          ref.invalidate(profileFollowersProvider(handle));
          break;
        case FollowListMode.following:
          ref.invalidate(profileFollowingProvider(handle));
          break;
        case FollowListMode.mutual:
          ref.invalidate(profileMutualFollowersListProvider(handle));
          break;
      }
    }

    return res.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, __) {
        // A real privacy gate is a 403 on someone else's followers/following
        // (a private account viewed by a non-follower). Your OWN lists are
        // never private, and the mutual list is your own circle — so a 403
        // there, or ANY other error (timeout / network / 5xx), is transient
        // and must NOT be mislabelled "private". Show a retry instead.
        final isForbidden = e is DioException && e.response?.statusCode == 403;
        if (isForbidden && !isOwnList && mode != FollowListMode.mutual) {
          return _Message(l10n.profileListPrivate);
        }
        return _LoadError(onRetry: retry);
      },
      data: (r) {
        final items = r.items
            .where((i) => !_removed.contains(i.userId))
            .toList();
        if (items.isEmpty) {
          return _EmptyList(l10n.profileListEmpty);
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox.shrink(),
          itemBuilder: (_, i) => _UserRow(
            item: items[i],
            canRemove: canRemove,
            onRemoved: () => setState(() => _removed.add(items[i].userId)),
          ),
        );
      },
    );
  }
}

class _UserRow extends ConsumerWidget {
  final FollowUserSummary item;

  /// Whether to offer "Remove follower" (only true on my own followers list).
  final bool canRemove;

  /// Called after a successful remove so the parent hides the row instantly.
  final VoidCallback? onRemoved;

  const _UserRow({required this.item, this.canRemove = false, this.onRemoved});

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final name = item.fullName ?? '@${item.handle ?? ''}';
    final ok = await showRemoveFollowerSheet(
      context,
      ref: ref,
      name: name,
      onRemove: () async {
        try {
          await ref.read(followsApiProvider).removeFollower(item.userId);
          // Optimistic: my followers count drops instantly, everywhere.
          ref.read(myFollowerCountDeltaProvider.notifier).bump(-1);
          // Removing a follower is a directional edge deletion, not an
          // unfollow — grouped with the request actions because it's the same
          // "who gets to follow me" decision.
          ref
              .read(unifiedAnalyticsProvider)
              .trackFollowRequestAction(
                action: 'remove_follower',
                source: 'followers_list',
              );
          return true;
        } catch (_) {
          return false;
        }
      },
    );
    if (ok == true) {
      onRemoved?.call();
    } else if (ok == false && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Lt.of(context).commonSomethingWrong)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handle = item.handle;
    // Don't offer a follow button on your own row.
    final isSelf = ref.watch(currentUserProvider)?.id == item.userId;
    // Borderless row matching the "Locals suggested" cards: textured
    // rounded-rectangle avatar, name + @handle, follow button trailing.
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
              analyticsSource: 'follow_list',
              // On my own followers list, tapping an already-followed
              // ("Following") row opens "Remove follower" instead of
              // unfollowing. "Follow back" taps still follow normally.
              onRemoveFollowerTap: canRemove
                  ? () => _confirmRemove(context, ref)
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.sokoInkSecondary),
        ),
      ),
    );
  }
}

/// "No one here yet" — the Soko reading illustration + a short message, matching
/// the profile's zines/saved empty states.
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
