import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/social/follow_user_summary.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/widgets/cached_image.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../providers/follow_state_provider.dart';
import '../providers/people_providers.dart';
import '../providers/public_profile_providers.dart';
import '../utils/profile_style.dart';

/// Incoming follow requests for a private account — accept / reject
/// (PROD-2776, phase 2).
class FollowRequestsScreen extends ConsumerWidget {
  const FollowRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    SokoBackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      Lt.of(context).profileFollowRequestsTitle,
                      style: Pt.b1Bold,
                    ),
                  ],
                ),
              ),
              const Expanded(child: FollowRequestsList()),
            ],
          ),
        ),
      ),
    );
  }
}

/// The incoming-follow-requests list body (no header/scaffold), so it can be
/// embedded both in [FollowRequestsScreen] and in the Notifications screen's
/// "Requests" tab.
class FollowRequestsList extends ConsumerStatefulWidget {
  const FollowRequestsList({super.key});

  @override
  ConsumerState<FollowRequestsList> createState() => _FollowRequestsListState();
}

class _FollowRequestsListState extends ConsumerState<FollowRequestsList> {
  @override
  void initState() {
    super.initState();
    // Re-fetch on (re)entry so requests resolved in a previous visit drop off.
    // Within a visit the rows persist (Instagram-style "Follow back") because
    // accept/reject don't invalidate this provider.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(followRequestsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(followRequestsProvider);
    return async.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, __) => _Message(Lt.of(context).profileRequestsLoadError),
      data: (res) {
        if (res.items.isEmpty) {
          return _Message(Lt.of(context).profileNoRequests);
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: res.items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          // Keyed by userId so per-row busy state stays with its own request
          // when the list shrinks after an accept/reject (avoids the spinner
          // jumping to the wrong row).
          itemBuilder: (_, i) => _RequestRow(
            key: ValueKey(res.items[i].userId),
            item: res.items[i],
          ),
        );
      },
    );
  }
}

class _RequestRow extends ConsumerStatefulWidget {
  final FollowUserSummary item;
  const _RequestRow({super.key, required this.item});

  @override
  ConsumerState<_RequestRow> createState() => _RequestRowState();
}

enum _ReqOutcome { pending, accepted, rejected }

class _RequestRowState extends ConsumerState<_RequestRow> {
  bool _busy = false;
  _ReqOutcome _outcome = _ReqOutcome.pending;
  // null = not followed back; 'following' or 'requested' (private target).
  String? _followBackRel;

  Future<void> _act({required bool accept}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(followsApiProvider);
      if (accept) {
        await api.acceptRequest(widget.item.userId);
      } else {
        await api.rejectRequest(widget.item.userId);
      }
      // Refresh my follower count/list (an accept adds a follower). The row
      // itself STAYS (Instagram-style) — it only drops when the page is
      // re-opened (see [_FollowRequestsListState.initState]). Drop the badge
      // count immediately though.
      invalidateMyFollowerCounts(ref);
      ref.read(pendingRequestCountProvider.notifier).decrement();
      // After the await — a confirmed accept/reject, not an optimistic tap.
      ref
          .read(unifiedAnalyticsProvider)
          .trackFollowRequestAction(
            action: accept ? 'accept' : 'reject',
            source: 'requests_screen',
          );
      if (mounted) {
        setState(() {
          _busy = false;
          _outcome = accept ? _ReqOutcome.accepted : _ReqOutcome.rejected;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Lt.of(context).commonSomethingWrong)),
        );
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _followBack() async {
    if (_busy) return;
    setState(() => _busy = true);
    final analytics = ref.read(unifiedAnalyticsProvider);
    final actionContext = analytics.actionContext;
    try {
      final res = await ref.read(followsApiProvider).follow(widget.item.userId);
      // Shared store → this follow-back reflects on every other screen instantly.
      ref
          .read(followStateProvider.notifier)
          .set(widget.item.userId, res.requested ? 'requested' : 'following');
      invalidateMyFollowingCounts(ref);
      // Locals also drops already-followed users on its next refetch.
      ref.invalidate(suggestedUsersProvider);
      // A follow-back off an accepted request — the reciprocity signal that
      // turns a one-way edge into a mutual one.
      ref
          .read(unifiedAnalyticsProvider)
          .trackUserFollow(
            actionContext: actionContext,
            targetUserId: widget.item.userId,
            source: 'follow_request',
            resultingState: res.requested ? 'requested' : 'following',
            isSoko: false,
            wasFollowBack: true,
          );
      if (mounted) {
        setState(() {
          _busy = false;
          // Private target → pending request ("Requested"), else "Following".
          _followBackRel = res.requested ? 'requested' : 'following';
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Lt.of(context).commonSomethingWrong)),
        );
        setState(() => _busy = false);
      }
    }
  }

  /// The trailing action area — reflects the row's outcome.
  Widget _trailing(BuildContext context) {
    if (_busy) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    switch (_outcome) {
      case _ReqOutcome.pending:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillButton(
              label: Lt.of(context).commonAccept,
              filled: true,
              onTap: () => _act(accept: true),
            ),
            const SizedBox(width: 6),
            _PillButton(
              label: Lt.of(context).commonReject,
              filled: false,
              onTap: () => _act(accept: false),
            ),
          ],
        );
      case _ReqOutcome.accepted:
        if (_followBackRel == 'following')
          return _StateChip(Lt.of(context).socialFollowingState);
        if (_followBackRel == 'requested')
          return _StateChip(Lt.of(context).socialFollowRequested);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StateChip(Lt.of(context).socialFollowAccepted),
            const SizedBox(width: 6),
            _PillButton(
              label: Lt.of(context).socialFollowBack,
              filled: true,
              onTap: _followBack,
            ),
          ],
        );
      case _ReqOutcome.rejected:
        return _StateChip(Lt.of(context).socialFollowRemoved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final handle = item.handle;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sokoInk8),
      ),
      child: Row(
        children: [
          // Whole left area (avatar + name + @handle) opens the profile.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: (handle == null || handle.isEmpty)
                  ? null
                  : () => context.push(AppRoutes.publicProfilePath(handle)),
              child: Row(
                children: [
                  _MiniAvatar(url: item.avatarUrl, name: item.fullName),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.fullName ?? '@${item.handle ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Pt.b2Bold,
                        ),
                        if (item.fullName != null &&
                            item.fullName!.isNotEmpty &&
                            item.handle != null) ...[
                          const SizedBox(height: 1),
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
          const SizedBox(width: 8),
          _trailing(context),
        ],
      ),
    );
  }
}

/// Small muted state pill ("Accepted" / "Following" / "Removed").
class _StateChip extends StatelessWidget {
  final String label;
  const _StateChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.sokoInk8,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: Pt.b2.copyWith(color: pInk50)),
    );
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _PillButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? AppColors.sokoPink : Colors.transparent,
          border: filled ? null : Border.all(color: pInk8),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: Pt.b2Bold),
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  final String? url;
  final String? name;
  const _MiniAvatar({this.url, this.name});

  @override
  Widget build(BuildContext context) {
    const size = 40.0;
    if (url != null && url!.isNotEmpty) {
      return ClipOval(
        child: CachedImage(imageUrl: url!, width: size, height: size),
      );
    }
    final initial = (name != null && name!.isNotEmpty)
        ? name!.characters.first.toUpperCase()
        : '?';
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.sokoPink,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: AppColors.sokoInk,
        ),
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
