import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/single_flight.dart';
import '../providers/follow_state_provider.dart';
import '../providers/people_providers.dart';
import '../utils/profile_style.dart';

/// Small self-managed follow toggle for list rows (search / suggestions).
///
/// Unlike [FollowButton] it holds its own state and does not invalidate a
/// profile provider — it just flips locally after the API call, so lists don't
/// flicker. Public account → Following, private → Requested.
class CompactFollowButton extends ConsumerStatefulWidget {
  final String userId;
  final bool initialFollowing;

  /// Whether the viewer has a pending follow request to this user — seeds the
  /// "Requested" state on load (not only after tapping).
  final bool requested;

  /// Whether this user follows the viewer. When the viewer doesn't follow back
  /// yet, the not-following label becomes "Follow back" instead of "Follow".
  /// This is what keeps the button viewer-relative (Instagram-style) rather
  /// than showing "Follow back" for everyone in someone else's list.
  final bool followsYou;

  /// When true, a successful follow/unfollow invalidates [suggestedUsersProvider]
  /// so the Locals surface refetches fresh viewer-relative state (else it keeps
  /// showing a stale "Follow back" for someone you just followed here). Only set
  /// this on rows that are NOT themselves inside a suggestions list — otherwise
  /// invalidating would reload the very list this button lives in and flicker.
  final bool refreshSuggestionsOnChange;

  /// When non-null, this button lives in the viewer's OWN followers list.
  /// Tapping while already following runs this callback (the "Remove follower"
  /// flow) instead of unfollowing — Instagram-style follower management. A
  /// "Follow back" tap (not yet following) still follows normally.
  final Future<void> Function()? onRemoveFollowerTap;

  /// Which surface this row lives on — 'follow_list', 'suggestions',
  /// 'people_search', 'contact_match' or 'follow_request'. Analytics-only, and
  /// the whole point of the follow events: without it we can count follows but
  /// can't tell which discovery surface produced them.
  final String analyticsSource;

  /// Geometry. The list rows this button was built for use the 38/18/8 shape;
  /// the profile header draws the Figma pill — 76x30, radius 6, 14 of side
  /// padding — so those surfaces override rather than forking the widget or
  /// resizing every list row.
  final double height;
  final double horizontalPadding;
  final double borderRadius;

  /// Floor on the button's width, so "Seguir" and "A Seguir" render at the
  /// same 76 rather than each hugging its own label.
  ///
  /// A floor and not a fixed width on purpose: the same button also renders
  /// "Seguir também" and "Pedido enviado", which are far wider than 76 — a
  /// hard width would clip them. Short labels get exactly the designed size;
  /// only the long states grow past it.
  final double minWidth;

  /// Whether this row is the official @soko account — see [FollowButton].
  final bool targetIsSoko;

  const CompactFollowButton({
    super.key,
    required this.userId,
    required this.initialFollowing,
    required this.analyticsSource,
    this.height = 38,
    this.horizontalPadding = 18,
    this.borderRadius = 8,
    this.minWidth = 0,
    this.requested = false,
    this.followsYou = false,
    this.refreshSuggestionsOnChange = false,
    this.onRemoveFollowerTap,
    this.targetIsSoko = false,
  });

  @override
  ConsumerState<CompactFollowButton> createState() =>
      _CompactFollowButtonState();
}

class _CompactFollowButtonState extends ConsumerState<CompactFollowButton> {
  /// The server-seeded relationship, used only when the shared store has no
  /// entry for this user yet.
  String get _seed => widget.initialFollowing
      ? 'following'
      : (widget.requested ? 'requested' : 'none');

  /// Current relationship: the shared follow store wins, else the seed.
  String get _rel => ref.read(followStateProvider)[widget.userId] ?? _seed;

  /// Latches the remove-follower branch only. That callback opens a confirm
  /// dialog, so a second tap would stack a duplicate — and unlike a follow, it
  /// is not an intent to converge on.
  final SingleFlight _removeFlight = SingleFlight();

  Future<void> _onTap() async {
    // On my own followers list, tapping an already-followed ("Following") row
    // means "remove this follower" (this callback), NOT "unfollow them" — the
    // two edges are directional, so I keep following them. A "Follow back" tap
    // (not yet following) falls through to the normal follow below.
    if (widget.onRemoveFollowerTap != null && _rel == 'following') {
      await _removeFlight.run(() async {
        await widget.onRemoveFollowerTap!();
        return null;
      });
      return;
    }
    // No busy latch: the store paints the flip instantly and queues a tap made
    // while a write is out, so a second tap changes the user's mind rather than
    // being swallowed.
    final settled = await ref
        .read(followStateProvider.notifier)
        .toggle(
          userId: widget.userId,
          seedRel: _seed,
          source: widget.analyticsSource,
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
        SnackBar(content: Text(Lt.of(context).commonSomethingWrong)),
      );
      return;
    }
    if (widget.refreshSuggestionsOnChange) {
      ref.invalidate(suggestedUsersProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Watch (not read) the store so this row rebuilds when the same user's
    // relationship changes on another screen.
    final rel = ref.watch(followStateProvider)[widget.userId] ?? _seed;
    final isFollowing = rel == 'following';
    final isRequested = rel == 'requested';
    final filled = !isFollowing && !isRequested;
    final label = isFollowing
        ? l10n.listActionFollowing
        : isRequested
        // "Pedido", not "Pedido enviado" — the button is a 76-wide pill, and
        // the longer phrase was the only PT state that overflowed it.
        ? l10n.socialFollowRequestedShort
        // Not following and no pending request: "Follow back" only when they
        // already follow the viewer, otherwise a plain "Follow".
        : (widget.followsYou ? l10n.socialFollowBack : l10n.listActionFollow);

    return GestureDetector(
      onTap: _onTap,
      child: Container(
        height: widget.height,
        constraints: BoxConstraints(minWidth: widget.minWidth),
        padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // Pink to follow; grey (sokoShade45) once following/requested.
          color: filled ? AppColors.sokoPink : AppColors.sokoShade45,
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        // No spinner: the label and fill flip on tap now, which is both faster
        // feedback than a spinner and the only honest render of a state the
        // user can change again mid-write.
        child: Text(label, style: Pt.b2),
      ),
    );
  }
}
