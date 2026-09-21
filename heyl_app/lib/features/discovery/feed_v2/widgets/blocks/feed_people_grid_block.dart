// PROD-4444 — the `people_grid` block. Figma `7740:46909`, in page context
// `7740:46155`.
//
// **A grid, not a horizontally scrolling shelf, and no see-all CTA.** That is
// the whole shape of it: three equal columns, `ceil(n / 3)` rows, a ragged last
// row left-aligned on the same column grid.
//
// ⚠️ **The 400 in Figma is the content column, not the page.** Every feed frame
// is 400 wide against a 430 viewport; the missing 30 is the page margin that
// `FeedPageContent` already applies around every block in the list builder
// (`discovery_feed_v2_screen.dart`). So this widget adds **no horizontal
// padding of its own** and the three 125/126/125 cells are derived from the
// width it is given — hardcoding 125 would break every viewport that is not
// 430. Same rule, and the same reason, as `venue_grid`.
//
// ⚠️ **An empty grid never reaches this widget** — `renderableFeedBlocks` drops
// a zero-item `people_grid` before the list builder (PROD-4442). Like
// `venue_grid`, the block is placed during composition and filled per request,
// so the backend cannot know it is empty in time to omit it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/router/app_router.dart';
import '../../../../../core/services/discovery_session_tracker.dart';
import '../../../../../core/services/unified_analytics_service.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../data/models/discovery_engagement.dart';
import '../../../../../data/models/feed_impression.dart';
import '../../../../../data/models/social/user_search_item.dart';
import '../../../../../providers/api_provider.dart';
import '../../../../../shared/widgets/impression_detector.dart';
import '../../../../profile/widgets/follow_suggestion_card.dart';
import '../../../../profile/widgets/mutual_avatars_row.dart';
import 'feed_block_atoms.dart';

class FeedPeopleGridBlock extends ConsumerWidget {
  final FeedBlockPeopleGrid block;

  const FeedPeopleGridBlock({super.key, required this.block});

  /// Columns are the CLIENT's decision — the backend sends a count and has no
  /// idea how wide the viewport is. Three matches the frame's
  /// `3 × 125 + 2 × 12 = 399` at the design width.
  static const int columns = 3;

  /// Horizontal gap between cells (`7740:46909`: cells at x0, x137, x275 across
  /// 400, i.e. 125 + 12 + 126 + 12 + 125).
  static const double columnGap = 12;

  /// Vertical gap between rows.
  ///
  /// Public because it is **also the gap between two consecutive `people_grid`
  /// blocks** (PROD-4463), so that a slate delivered as three pages reads as one
  /// uninterrupted grid. `FeedBlockSeparator` reads this constant rather than
  /// respelling the number — changing it here moves both boundaries together,
  /// which is the whole point.
  ///
  /// ⚠️ **Figma never shows a multi-row people grid** — `7740:46909` is a
  /// single row of three cards — so this number is a judgement, not a
  /// measurement. It started as the column gutter mirrored onto the other axis
  /// (12, a uniform grid on both axes) and Zé raised it on device: with the
  /// details row wrapping to two lines, the last word of one card sat almost
  /// against the next row's avatar.
  ///
  /// **28, and 29 is the ceiling.** It has to stay *below*
  /// `kFeedPageBlockGap` (30), because PROD-4463 makes this same constant the
  /// gap between two consecutive grids — at 30 that seam would be metrically
  /// identical to an ordinary block boundary, and "three pages read as one
  /// grid" would survive only as the absent dotted rule.
  ///
  /// Raised 24 → 28 by Zé on device (2026-09-18), the second such raise after
  /// 12 → 24. The two constants are now 2 apart, so the PROD-4463 illusion is
  /// carried almost entirely by the absent dotted rule rather than by the
  /// metric. **Anything past 29 is not a tweak here — it is a decision to stop
  /// making consecutive grids read as one, and PROD-4463 has to be revisited
  /// with it.**
  ///
  /// One constant, two boundaries. Change it here and the rows and the seam
  /// move together; that is the whole reason it is public.
  static const double rowGap = 28;

  /// Avatar side as a fraction of the cell (`7740:46912` is 80 in a 125 cell).
  /// The card's badge, and therefore its tap target, scale with this.
  static const double _avatarToCell = 80 / 125;

  /// Which surface a follow from this grid is attributed to.
  ///
  /// ⚠️ **Not the same vocabulary as [FeedImpressionSurface.peopleGrid]**, and
  /// the near-miss is deliberate rather than sloppy. This string names a
  /// surface in the FOLLOW event's namespace, whose neighbours are
  /// `discovery_locals_shelf`, `contact_match` and `profile`; `people_grid`
  /// names a block class in the discovery namespace, whose neighbours are
  /// `hero`, `venue_grid` and `bundle_highlight`. The two answer different
  /// questions and are grouped in different dashboards.
  ///
  /// Do not "tidy" them into one constant. They agree today only because the
  /// backend happens to record this grid's impressions as
  /// `retrieval_type='feed_people_grid'`; that is a coincidence of naming at
  /// the store, not a shared contract, and collapsing them would make the next
  /// surface that carries both silently wrong in one of the two.
  static const String analyticsSource = 'feed_people_grid';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ⚠️ **This block renders NO chrome — no title, no eyebrow, no subtitle —
    // and that is a ruling, not an omission** (Zé, 2026-09-16).
    //
    // Figma draws the block untitled, and the backend nonetheless sends
    // `title` on page 1 of EVERY slate (`feed_layout.py`'s
    // `title_key=... if page == 1`). That put a 42 px "People to follow"
    // in the middle of the reader's scroll every time they loaded a slate —
    // the page boundary made visible again, and a louder break than the dotted
    // rule and the 30 px gap that PROD-4463 removed for exactly this reason.
    //
    // So `block.title` is deliberately ignored rather than rendered. The
    // backend is dropping it too, but this is the half that needs no deploy and
    // no app release to hold, and the rule it protects — consecutive grids read
    // as ONE grid — is the client's to enforce, because only the client can see
    // what is actually on the page above.
    //
    // ⚠️ Do not "fix" this by restoring `FeedBlockTitle`. If the Pessoas feed
    // ever wants a heading, it wants ONE, at the top of the page — which is a
    // different thing from a per-block title and belongs to the page chrome.

    // One `LayoutBuilder`, here, ABOVE the `IntrinsicHeight`s below.
    //
    // ⚠️ The nesting is load-bearing, not incidental: `IntrinsicHeight` asks its
    // subtree for intrinsic dimensions, and a `LayoutBuilder` *inside* that
    // subtree throws `LayoutBuilder does not support returning intrinsic
    // dimensions` at layout time. Measuring the cell once up here and handing
    // every cell an explicit width keeps the two apart. (This is the same trap
    // that stops `venue_grid` from equalising its rows at all — its tile
    // measures its own cover with a `LayoutBuilder`.)
    return FeedBlockSurface(
      block: block,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The feed always hands this a bounded width (a sliver inside
          // `FeedPageContent`), but the guard is not academic: an unbounded
          // width makes `cellWidth` infinite and `SizedBox(width: infinity)`
          // throws during layout, and a width under two gutters makes it
          // negative, which asserts. Both would be a crash rather than a
          // degraded grid, and both are one careless reparenting away.
          if (!constraints.hasBoundedWidth) return const SizedBox.shrink();
          final available = constraints.maxWidth - (columns - 1) * columnGap;
          // Narrower than its own gutters: bail rather than clamp the cells to
          // zero, which would still lay out `0 + 12 + 0 + 12 + 0` and overflow
          // the row by the gutters alone.
          if (available <= 0) return const SizedBox.shrink();
          final cellWidth = available / columns;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [..._rows(context, ref, cellWidth)],
          );
        },
      ),
    );
  }

  /// The cards, in rows of [columns].
  ///
  /// A `Column` of `Row`s rather than a `GridView`: a `SliverGridDelegate`
  /// forces **every** cell to the same size, so it cannot express this design at
  /// all. Card height varies with the name (1–2 lines) and the details row
  /// (0–3), and each row must take its tallest member — which is what
  /// `IntrinsicHeight` + `CrossAxisAlignment.stretch` does and a grid delegate
  /// cannot. A scrollable inside an already-scrolling feed would also need
  /// `shrinkWrap` + `NeverScrollableScrollPhysics` to behave, and would build
  /// every card anyway.
  ///
  /// `IntrinsicHeight` costs an extra layout pass over its subtree. With at most
  /// three cards per row and three rows per block that is not worth trading the
  /// design for.
  List<Widget> _rows(BuildContext context, WidgetRef ref, double cellWidth) {
    final items = block.items;
    final rowCount = (items.length + columns - 1) ~/ columns;

    return [
      for (var row = 0; row < rowCount; row++) ...[
        if (row > 0) const SizedBox(height: rowGap),
        IntrinsicHeight(
          child: Row(
            // Every card in a row takes the row's height. Cards differ because
            // the name is 1–2 lines and the details row 0–3; the design says the
            // row is not ragged vertically (Zé, 2026-09-15).
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var col = 0; col < columns; col++) ...[
                if (col > 0) const SizedBox(width: columnGap),
                // A fixed width rather than `Expanded`, so the empty slots of a
                // ragged last row hold the column grid and the real cards stay
                // **left-aligned** at the same width as every other row — never
                // stretched across the block.
                SizedBox(
                  width: cellWidth,
                  child: switch (row * columns + col) {
                    final i when i < items.length => _card(
                      context,
                      ref,
                      items[i],
                      i,
                      cellWidth,
                    ),
                    _ => const SizedBox.shrink(),
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    ];
  }

  /// One person, as the app's shared follow-suggestion card (PROD-4443) — the
  /// same card the onboarding carousel and the old Locals shelf draw, extended
  /// here with the details row.
  Widget _card(
    BuildContext context,
    WidgetRef ref,
    FeedPersonItem person,
    int index,
    double cellWidth,
  ) {
    final details = person.details;
    // Captured during build, while `ref` is alive: `onResolved` fires from
    // `ImpressionDetector.dispose()`, where reading a provider throws.
    final tracker = ref.read(discoverySessionTrackerProvider);

    return ImpressionDetector(
      // ⚠️ **The key belongs HERE, on the outermost widget of the cell** — not
      // only on the card below it (codex, 2026-09-17). Element reuse happens at
      // the level that sits in the parent's child list, and since PROD-4511
      // that is this detector, not the card. Keyed one level too low, a refetch
      // that reorders the grid reuses `_ImpressionDetectorState` by position:
      // the dwell clock, `_episodeQualified` and the post-tap reopen block all
      // carry over to a DIFFERENT person, so the next reader's exposure is
      // credited from the previous occupant's timer — and, because
      // `ImpressionDetector._key` is a getter over `widget.itemId`, the old
      // key is never `forget()`-ten and leaks in `VisibilityDetector`'s
      // app-global static map.
      //
      // The card keeps its own key as well. That one guards its follow state
      // if this wrapper is ever removed; this one is the load-bearing half.
      key: ValueKey('feed-people-grid-${block.id}-${person.userId}'),
      // **Engagement rail ONLY** (PROD-4511). The no-op `onImpression` is the
      // whole point: it keeps this card off the seen-suppression rail, which
      // the Pessoas feed does not use and must not start using by accident.
      // Deprioritising a suggestion because the viewer scrolled past it is
      // explicitly out of scope (Zé, 2026-09-15), so there is no
      // `FeedImpressionIn` here and no `POST /feed/impressions`.
      //
      // These rows are therefore **recorded and read by nothing**, on purpose —
      // recording leads reading because surface-level history cannot be
      // backfilled. Nobody will disappear from this grid because they were
      // reported seen.
      scopeId: 'block:${block.id}:people_grid',
      itemId: person.userId,
      // Scopes a tap's `resolveForItem` to THIS card when the same person is
      // mounted in two blocks at once — which a three-page slate makes routine
      // rather than exotic (D82).
      blockId: block.id,
      onImpression: () {},
      onEngagementQualified: (dwellMs) => tracker.impression(
        itemId: person.userId,
        // The BLOCK's declared type, never the active filter (D34). Constant
        // `'person'`; the parser rejects any other value.
        itemType: block.itemType,
        // ⚠️ No `runId`, permanently (D6). People are ranked by the follow
        // graph, not the Discovery engine, so this filter has no slate to join
        // to — `run_id` is null on every people payload. Passing
        // `block.runId` would look harmless and quietly invite a
        // `discovery_runs` join that can never resolve.
        blockType: 'people_grid',
        blockId: block.id,
        surface: FeedImpressionSurface.peopleGrid,
        cardIndex: index,
        dwellMs: dwellMs,
      ),
      onResolved: (dwellMs, qualified, endReason) => tracker.exposureEnd(
        dwellMs: dwellMs,
        qualified: qualified,
        endReason: endReason,
        itemId: person.userId,
        itemType: block.itemType,
        blockType: 'people_grid',
        blockId: block.id,
        surface: FeedImpressionSurface.peopleGrid,
        cardIndex: index,
      ),
      child: FollowSuggestionCard(
        // Person id, not index: a refetch that reorders the grid must not let
        // Flutter reuse one card's element — and its follow state — for another
        // person. See the detector's key above for the half that matters more.
        key: ValueKey('feed-people-grid-${block.id}-${person.userId}'),
        // `FeedPersonItem` is deliberately not a `FeedItem` (PROD-4442) and the
        // card speaks `UserSearchItem`, so the two are bridged here rather than
        // by making the shared card depend on the feed's wire shape.
        item: UserSearchItem(
          userId: person.userId,
          handle: person.handle,
          fullName: person.fullName,
          avatarUrl: person.avatarUrl,
          // Straight from the wire, never assumed false: the backend's per-viewer
          // cache keeps returning someone the reader followed during the hour,
          // and the card must show it.
          isFollowing: person.isFollowing,
          requested: person.requested,
          followsYou: person.followsYou,
        ),
        analyticsSource: analyticsSource,
        // The cell, not the card's self-sizing default: Figma's feed card is 125
        // wide around the same 80 avatar (the carousel's is 118), and the details
        // text must wrap across all of it.
        width: cellWidth,
        avatarSize: cellWidth * _avatarToCell,
        details: details == null
            ? null
            : FollowSuggestionDetails(
                text: details.text,
                // `MutualAvatar`, never bare URLs — the legacy mode drops a
                // photoless person, which would leave two faces beside "3 pessoas
                // em comum". The card caps the list at three.
                avatars: [
                  for (final face in details.avatars)
                    MutualAvatar(
                      url: face.avatarUrl,
                      name: face.name,
                      seed: face.userId,
                    ),
                ],
              ),
        // The badge keeps its own tap inside its own bounds, so this fires for
        // the rest of the card.
        onTap: () => _openProfile(context, ref, person, index),
        // PROD-4521 — ⚠️ **wired HERE, not in the shared card and not in
        // `applyFollowToggle`.** Both of those are on the path of eleven
        // surfaces; only this one is the feed.
        onFollowToggled: (nowFollowing) =>
            _reportFollow(tracker, person, index, nowFollowing: nowFollowing),
      ),
    );
  }

  /// Record a confirmed follow/unfollow on the engagement ledger.
  ///
  /// Without this the people feed can never appear in tile 5.4a (signals given
  /// on the feed, by block) or in the on-feed column of 5.4b: `applyFollowToggle`
  /// reaches PostHog only, with a `source` string and no block, no card index
  /// and no surface.
  /// ⚠️ Takes the tracker rather than a `WidgetRef`, and that matters: this
  /// fires **after** the badge's network round-trip, by which time the card may
  /// have been disposed (a filter change, a refresh, a scroll that rebuilt the
  /// grid) and reading a provider off a dead `ref` throws. The tracker captured
  /// during build is safe to hold — `discoverySessionTrackerProvider` is a
  /// keep-alive `Provider`, so the instance outlives this widget. Same reason
  /// the impression callbacks above capture it.
  void _reportFollow(
    DiscoverySessionTracker tracker,
    FeedPersonItem person,
    int index, {
    required bool nowFollowing,
  }) {
    // Resolve the card's pending exposure first, so the exposure precedes the
    // action in `seq` order (contract v2, PROD-4306 — an action must never be
    // credited before the exposure that earned it). `endReason: 'action'`, not
    // the default `'tap'`, so it does not suppress the card's next episode: the
    // reader stays on the feed looking at this card after following.
    ImpressionDetector.resolveForItem(
      person.userId,
      blockId: block.id,
      endReason: 'action',
    );
    tracker.action(
      actionKind: nowFollowing
          ? DiscoveryEngagementAction.follow
          : DiscoveryEngagementAction.unfollow,
      itemId: person.userId,
      itemType: block.itemType,
      blockType: 'people_grid',
      blockId: block.id,
      surface: FeedImpressionSurface.peopleGrid,
      // ⚠️ **Threaded, not inherited.** `action()` inherits `runId`,
      // `blockId`, `blockType` and `surface` from `_itemContext` — the
      // provenance remembered from the item's last exposure — which is why
      // the save path passes only `actionKind`/`itemId`/`itemType`. But
      // `_ItemContext` does not remember `cardIndex`, so the inherit
      // mechanism cannot supply it and it has to come from the grid.
      //
      // Deliberately NOT fixed by teaching `_ItemContext` about
      // `cardIndex`: that would start populating `card_index` on every
      // existing `action` row across all eleven follow surfaces plus saves
      // and thumbs, which is a change to shipped analytics well outside
      // this ticket. Left as a follow-up.
      cardIndex: index,
      // No `runId`: people blocks carry none (D6).
    );
  }

  /// Fires the click event, resolves the card's exposure, then opens the
  /// profile — **in that order**.
  ///
  /// This grid cannot route through `openFeedItemDetail` and is not a candidate
  /// for being made to: that helper takes a `FeedItem`, and `FeedPersonItem` is
  /// deliberately not one (PROD-4442), because a person is not a discovery
  /// entity with a detail page in the feed's corpus — `feedItemDetailPath` has
  /// no `person` case and should not grow one. So the same three steps are
  /// spelled out here instead, with the ordering the shared helper documents.
  ///
  /// ⚠️ **Resolve BEFORE the tap is enqueued** (contract v2, PROD-4306). The
  /// exposure — and the impression that qualified it — must precede the tap in
  /// `seq` order, or a follow performed on the profile is credited before the
  /// exposure that earned it.
  ///
  /// ⚠️ **No `beginDetailNavigation`.** A public profile is not a feed detail
  /// page, and `detail_engagement` (PROD-4307) is scoped to feed-originated
  /// opens of feed entities. Adding a fourth surface to that rail is a product
  /// decision about what "detail dwell" means, not plumbing this ticket may
  /// decide on its own — so the tap carries no `navigation_id` and no dwell is
  /// measured on the profile.
  void _openProfile(
    BuildContext context,
    WidgetRef ref,
    FeedPersonItem person,
    int index,
  ) {
    ref
        .read(unifiedAnalyticsProvider)
        .trackDiscoveryShelfCardClicked(
          // ⚠️ `block_id` and `shelf_id` are an **xor, not a preference**
          // (PROD-4077) — the call asserts on it. On the feed it is always
          // `blockId`; this grid has no shelf and never will.
          blockId: block.id,
          surface: FeedImpressionSurface.peopleGrid,
          cardIndex: index,
          itemId: person.userId,
          itemType: block.itemType,
          // ⚠️ **No `slateKind`, for exactly the reason there is no `runId`**
          // (codex, 2026-09-17). Every other feed surface forwards
          // `feedHomeProvider`'s `slate_kind`, and copying that here was wrong:
          // it names *which ranking served the page* — `personalized` vs
          // `safe_bet` — and these cards were not ranked at all. Forwarding it
          // would not error; it would quietly attribute a follow-graph
          // suggestion to a Discovery ranker that never saw it, and split the
          // people CTR by a dimension that does not apply to it.
          //
          // "It is null on this filter in practice" is not a reason to send it.
          // That was the same reasoning `run_id` gets, and the same answer
          // applies: a backend promise is not a structural guarantee, and the
          // client must not forward a dimension it knows is meaningless here.
          // Not reading `feedHomeProvider` at all also keeps a tap from
          // touching an auto-dispose provider it has no business creating.
        );

    ImpressionDetector.resolveForItem(person.userId, blockId: block.id);

    ref
        .read(discoverySessionTrackerProvider)
        .tap(
          itemId: person.userId,
          itemType: block.itemType,
          blockType: 'people_grid',
          blockId: block.id,
          surface: FeedImpressionSurface.peopleGrid,
          cardIndex: index,
        );

    // `handle` is guaranteed non-empty by the contract (D3) and by the parser,
    // which drops a person without one.
    context.push(AppRoutes.publicProfilePath(person.handle));
  }
}
