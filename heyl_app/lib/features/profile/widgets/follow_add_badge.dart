import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/follow_state_provider.dart';

/// The circular follow toggle that overlaps a suggestion's avatar (Figma
/// `Frame 9236`). Not following → opaque light-mauve (`sokoShade45`) disc with a
/// dark circled-"+"; following or requested → `sokoPink` disc with a dark check
/// (pink is the app-wide "kept/following" affordance). A 2-px `sokoPaper` ring
/// (`strokeAlignOutside`) frames the disc so that where it overhangs the avatar
/// photo it reads as a clean, punched-out sticker rather than muddying the image.
///
/// Shares its follow/unfollow side effect with [CompactFollowButton] via
/// [FollowStateStore.toggle], so state stays in lock-step with every other
/// follow control for the same user. Optimistic ("fast follow"): the glyph flips on
/// tap via a synchronous shared-store write, then the network reconciles (or
/// reverts on failure) — no blocking spinner.
///
/// Used by the onboarding follow carousel and by the Discovery "Locals" shelf,
/// which render the same card. It lives here rather than beside either of them
/// because it is a follow control first and a carousel detail second.
class FollowAddBadge extends ConsumerStatefulWidget {
  const FollowAddBadge({
    super.key,
    required this.userId,
    required this.initialFollowing,
    required this.requested,
    required this.followsYou,
    required this.analyticsSource,
    this.onboardingStep,
    this.onFollowToggled,
    this.size = 40,
  });

  final String userId;
  final bool initialFollowing;
  final bool requested;
  final bool followsYou;

  /// Which surface this badge lives on — same contract as
  /// [CompactFollowButton.analyticsSource]: without it we can count follows but
  /// not tell which discovery surface produced them.
  final String analyticsSource;

  /// When set, the tap is ALSO recorded as this onboarding funnel step (the
  /// carousel passes `profile.follows`, so we can count how many follows a user
  /// makes during onboarding). Null outside onboarding — the shelf's follows
  /// are not part of that funnel.
  final String? onboardingStep;

  /// PROD-4521 — fired after a **confirmed** follow/unfollow, with `true`
  /// meaning the viewer now follows this person.
  ///
  /// ⚠️ **Exists so the people grid can emit an engagement-ledger row without
  /// every other surface emitting one too.** This card is shared by eleven
  /// callers (`onboarding`, `discovery_locals_shelf`, `contact_match`,
  /// `profile`, `suggestions`, `follow_list`, `people_search`,
  /// `interested_list`, `discovery_readers`, `zine_followers_list` and the
  /// feed's people grid). Emitting from inside this widget — or from
  /// `applyFollowToggle` — would fire ledger rows for all of them: the
  /// tracker's `if (_sessionId == null) return` guard drops most, but a follow
  /// from the Locals shelf, or from a profile opened *during a live feed
  /// visit*, would still record a row with a null block, putting signals NOT
  /// given on the feed into the "signals given on the feed" tile.
  ///
  /// So the emission is the caller's, and only the people grid opts in.
  ///
  /// After the await, like `trackUserFollow`/`trackUserUnfollow`: confirmed
  /// writes only, never the optimistic flip.
  final ValueChanged<bool>? onFollowToggled;

  /// Diameter of the disc. Figma's card is 80×80 with a 40×40 badge; a shelf
  /// card that scales down passes half its own avatar size to keep the ratio.
  ///
  /// ⚠️ This is what the badge **paints**, not what it can be **tapped** by —
  /// see [minTapTarget].
  final double size;

  /// The smallest square the badge will accept a tap in, whatever it paints.
  ///
  /// The disc is `avatar / 2`, which is 40 at the 430 design width and ~34 on a
  /// 375-wide phone — both under the 44 px minimum. The old Locals shelf dodged
  /// this by showing 3.3 cards; the people feed's fixed 3-column grid cannot
  /// (PROD-4444). Zé's ruling: **keep the visual badge at the Figma ratio and
  /// expand only the hit area.**
  static const double minTapTarget = 44;

  /// The tap square for a disc of [size] — the disc itself once it is already
  /// big enough.
  static double tapTargetFor(double size) =>
      size < minTapTarget ? minTapTarget : size;

  @override
  ConsumerState<FollowAddBadge> createState() => _FollowAddBadgeState();
}

class _FollowAddBadgeState extends ConsumerState<FollowAddBadge> {
  String get _seed => widget.initialFollowing
      ? 'following'
      : (widget.requested ? 'requested' : 'none');

  Future<void> _onTap() async {
    final rel = ref.read(followStateProvider)[widget.userId] ?? _seed;
    final wasActive = rel == 'following' || rel == 'requested';
    final onboardingStep = widget.onboardingStep;
    if (onboardingStep != null) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackOnboardingStep(
            step: onboardingStep,
            action: wasActive ? 'unfollow' : 'follow',
          );
    }
    // The store paints the flip, queues a tap made mid-write, and reverts to
    // server truth on failure — silently, because the badge is a low-stakes
    // bulk-follow affordance and the user can simply tap again.
    final settled = await ref
        .read(followStateProvider.notifier)
        .toggle(
          userId: widget.userId,
          seedRel: _seed,
          source: widget.analyticsSource,
          followsYou: widget.followsYou,
        );

    // PROD-4521 — confirmed, so the caller may record it.
    //
    // Driven by `toggle`'s RETURN value rather than by `!wasActive`: `toggle`
    // answers the relationship the server confirmed, or `null` when the write
    // failed or a newer tap is still converging. Neither of those is a follow
    // that happened, and the pre-merge version (which reported `!wasActive`
    // from inside a try) could not tell them apart.
    //
    // ⚠️ **Guarded.** A throw here propagates out of `_onTap`, and a listener's
    // own failure must never decide whether the mutation counts — the same
    // hazard that made the old `applyFollowToggle` wrap its telemetry, and the
    // reason `FollowStateStore._write` still needs the same treatment.
    if (settled != null) {
      try {
        widget.onFollowToggled?.call(settled != 'none');
      } catch (_) {
        // A listener's problem is not this badge's, and not the user's.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rel = ref.watch(followStateProvider)[widget.userId] ?? _seed;
    final active = rel == 'following' || rel == 'requested';

    final hit = FollowAddBadge.tapTargetFor(widget.size);

    // The tap square, with the disc pinned to its RIGHT edge and centred
    // vertically — so the extra area is taken entirely from the inside of the
    // card, over the avatar.
    //
    // Deliberately not centred on the disc: the disc overhangs the avatar's
    // right edge, so a symmetric box would stick out past the Stack that
    // contains it, and area outside that Stack is painted but **not
    // hit-testable** (the very bug the card's own SizedBox exists to prevent).
    // Growing leftward always fits, at every avatar size.
    //
    // The few px of overlap with the card's own tap area are fine — a child
    // gesture wins inside its own bounds, so the overlap follows rather than
    // opening the profile, which is the whole point.
    //
    // ⚠️ `HitTestBehavior.opaque` is load-bearing: without it the transparent
    // margin around the disc would let taps fall straight through to the card.
    return SizedBox(
      width: hit,
      height: hit,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // ⚠️ **Always attached, never conditionally null.** The recognizer has
        // to stay in the arena even while a write is settling:
        // `HitTestBehavior.opaque` stops the hit test reaching widgets
        // *beneath* the badge, but the card's own `GestureDetector` is an
        // ANCESTOR and is always in the path. A badge with no recognizer
        // therefore does not absorb the tap — the card's wins, and a second tap
        // during the network settle opens the profile instead of toggling. The
        // innermost recognizer wins the arena, so attaching it is what makes
        // the badge swallow its own taps.
        //
        // The store makes this safe rather than merely tolerable: a tap made
        // mid-write is painted and queued, never dropped (`SettlingValue`).
        onTap: _onTap,
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? AppColors.sokoPink : AppColors.sokoShade45,
              // Paper ring painted outward so the disc keeps its full diameter
              // and, where it overhangs the avatar photo, reads as a
              // punched-out sticker.
              border: Border.all(
                color: AppColors.sokoPaper,
                width: 2,
                strokeAlign: BorderSide.strokeAlignOutside,
              ),
            ),
            // No spinner: the store's optimistic flip makes the glyph swap
            // instantly on tap (fast follow), and a re-tap while the write is
            // settling is queued rather than blocked.
            child: Icon(
              // Following → check; not-following → circled "+".
              active ? Icons.check_circle_outline : Icons.add_circle_outline,
              size: widget.size / 2,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      ),
    );
  }
}
