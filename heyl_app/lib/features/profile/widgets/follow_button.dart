import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../providers/follow_state_provider.dart';
import '../providers/people_providers.dart';
import '../providers/public_profile_providers.dart';
import '../utils/profile_style.dart';

/// Follow / Following / Requested pill (PROD-2776, phase 2).
///
/// - `none` → filled "Follow", or "Follow back" when [followsYou] (this profile
///   already follows the viewer). Public → active follow; private → a request.
/// - `following` → outlined "Following" (tap unfollows).
/// - `requested` → outlined "Requested" (tap cancels the request).
///
/// On success it invalidates [publicProfileProvider] so the header + counts
/// refetch from the server (source of truth for the resulting state).
class FollowButton extends ConsumerStatefulWidget {
  final String handle;
  final String userId;
  final String relationship; // following | requested | none

  /// Whether this profile's owner follows the viewer — turns the `none`-state
  /// label into "Follow back". No effect once following/requested.
  final bool followsYou;

  /// Whether this profile is the official @soko account. Analytics-only: the
  /// @soko follow edge is written server-side for every user, so it has to be
  /// excludable or every follower metric is inflated by an automatic write.
  final bool targetIsSoko;

  const FollowButton({
    super.key,
    required this.handle,
    required this.userId,
    required this.relationship,
    this.followsYou = false,
    this.targetIsSoko = false,
  });

  @override
  ConsumerState<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<FollowButton> {
  Future<void> _onTap() async {
    // No busy latch: the store paints the flip instantly and queues a tap made
    // while a write is out, so a second tap changes the user's mind rather than
    // being swallowed.
    final settled = await ref
        .read(followStateProvider.notifier)
        .toggle(
          userId: widget.userId,
          seedRel: widget.relationship,
          source: 'profile_header',
          followsYou: widget.followsYou,
          isSoko: widget.targetIsSoko,
        );
    if (!mounted) return;
    if (settled == null) {
      // Null also means "a newer tap is still converging" — that call owns the
      // outcome, so only complain when nothing is left in flight.
      if (ref.read(followStateProvider.notifier).isSettling(widget.userId)) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Lt.of(context).commonSomethingWrongRetry)),
      );
      return;
    }
    // The target profile's counts (their followers) aren't in the store, so
    // still refetch it; Locals also drops already-followed users on refetch.
    ref.invalidate(publicProfileProvider(widget.handle));
    ref.invalidate(suggestedUsersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Watch (not read) the store so this button rebuilds when the same user's
    // relationship changes on another screen.
    final rel =
        ref.watch(followStateProvider)[widget.userId] ?? widget.relationship;
    final isFollowing = rel == 'following';
    final isRequested = rel == 'requested';
    final filled = !isFollowing && !isRequested; // none → filled "Follow"
    final label = isFollowing
        ? l10n.listActionFollowing
        : isRequested
        ? l10n.socialFollowRequested
        : (widget.followsYou ? l10n.socialFollowBack : l10n.listActionFollow);
    // ⊕ to follow, ✓ once following, ⧗ while a request is pending.
    final icon = isFollowing
        ? LucideIcons.check
        : isRequested
        ? LucideIcons.clock
        : LucideIcons.circle_plus;

    // Same Bt_Sq_Ico tokens as Edit/Share (h40 · radius 6 · Zalando 14):
    // pink fill for the follow action, grey (sokoShade45) fill once
    // following/requested — the ✓/⧗ symbol stays, only the fill colour changes.
    return GestureDetector(
      onTap: _onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? AppColors.sokoPink : AppColors.sokoShade45,
          borderRadius: BorderRadius.circular(6),
        ),
        // No spinner: the label and fill flip on tap now, which is faster
        // feedback than a spinner and the only honest render of a state the
        // user can change again mid-write.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: AppColors.sokoInk),
            const SizedBox(width: 8),
            Text(label, style: Pt.b2),
          ],
        ),
      ),
    );
  }
}
