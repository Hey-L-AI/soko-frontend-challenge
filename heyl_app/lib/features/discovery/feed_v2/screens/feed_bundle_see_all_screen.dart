// PROD-4068 — every result behind a bundle, as a vertical list.
//
// **Same pattern as `ShelfSeeMoreScreen`, different layout**: title with a back
// arrow, no search bar, no filter chips — but a vertical list rather than that
// screen's 2-up grid, because the rows here are the bundle's own rows.
//
// **`FeedBundleRow` is reused unchanged, not reimplemented.** That is the point
// of the design: the rows a user tapped through from must be recognisably the
// same rows, and a lookalike would drift the first time either surface changed.
//
// **No fetch and no spinner** (D80). The block arrived with the feed and the
// full result set came with it, so this screen renders from a model it is
// handed. The known cost is stated rather than hidden: this is also a *web*
// app, so a browser refresh or a pasted link has no in-memory block — the route
// degrades to the feed instead of rendering empty.
//
// **The open transition** (PROD, 2026-09-08) — "move the whole bundle as one".
// The route push is opaque (feed covered instantly, no ghosting), and the page
// morphs the bundle into place by hand rather than element-by-element:
//
//   * a **group** at the top — header (centred title + back arrow + count) and
//     the bundle's *highlighted* rows, floated to the top so they match exactly
//     what the feed showed — **slides up as one unit** from the on-screen
//     rectangle the feed block occupied ([feedBundleMorphSourceRectProvider]).
//     It is a translation (measured src → rest), so nothing scales or distorts.
//   * the **result count** and the **results beyond the highlighted ones** pop
//     in once the slide lands — "under the rows we were already showing".
//
// **Why not a `Hero`?** The rows are themselves `Hero`s (their thumbnail flies
// into the item detail), and Flutter forbids nesting Heroes — one Hero around
// the group asserts on the feed. Hence the manual slide. The rows also carry
// their detail-morph tags **only while the page is at rest** ([_atRest]) — off
// through the open and the back pop — so no thumbnail flies between this page
// and the feed's bundle rows, which share those tags.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/services/discovery_session_tracker.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/page_layout.dart';
import '../../../../data/models/feed_home.dart';
import '../../../../data/models/feed_impression.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/soko_back_button.dart';
import '../../../../shared/widgets/soko_pop_in.dart';
import '../../../../core/services/impression_scroll_tracker.dart';
import '../../../../shared/widgets/impression_detector.dart';
import '../../../../providers/api_provider.dart';
import '../providers/feed_home_provider.dart';
import '../providers/feed_impression_trackers.dart';
import '../utils/feed_item_open.dart';
import '../widgets/blocks/feed_bundle_block.dart';
import '../widgets/blocks/feed_bundle_row.dart';
import '../widgets/feed_bundle_hero.dart';

class FeedBundleSeeAllScreen extends ConsumerStatefulWidget {
  /// The block this page was opened from, already carrying its full result
  /// set. Handed over as a route `extra` — never refetched.
  final FeedBlockBundle block;

  const FeedBundleSeeAllScreen({super.key, required this.block});

  @override
  ConsumerState<FeedBundleSeeAllScreen> createState() =>
      _FeedBundleSeeAllScreenState();
}

class _FeedBundleSeeAllScreenState extends ConsumerState<FeedBundleSeeAllScreen>
    with SingleTickerProviderStateMixin {
  /// Horizontal content inset. Matches `ShelfSeeMoreScreen`'s list padding.
  static const double _hPad = 16;

  /// Measures the group's resting position so the slide knows where "home" is.
  final GlobalKey _groupKey = GlobalKey();

  /// The group's slide-up-and-settle clock.
  late final AnimationController _slide;
  late final Animation<double> _curve;

  /// Group's start offset = (feed block rect topLeft) − (group's resting
  /// topLeft). Null until measured on the first post-frame; treated as zero
  /// (no slide) when there is no source rect to morph from.
  Offset? _startOffset;
  bool _measured = false;

  /// Latched once the slide lands: reveals the count + the extra results.
  bool _revealed = false;

  bool _wired = false;

  /// The discovery-session tracker, captured in [initState] so [dispose] can
  /// release this surface without touching `ref` (illegal post-dispose). Safe
  /// to hold: the provider is `keepAlive`, so the instance outlives this
  /// screen.
  DiscoverySessionTracker? _sessionTracker;

  @override
  void initState() {
    super.initState();
    // Hold the discovery session for this see-all visit (PROD-4257). The
    // tracker counts holders: acquiring here keeps the visit the feed opened
    // ALIVE while this route covers it (the feed's own release is bridged by
    // the tracker's close-linger), so the see-all rows' engagement rail lands
    // inside the same session instead of after its end.
    final tracker = ref.read(discoverySessionTrackerProvider);
    _sessionTracker = tracker;
    tracker.acquireSurface('bundle_see_all');
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _curve = CurvedAnimation(parent: _slide, curve: Curves.easeOutCubic);
    _slide.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_revealed && mounted) {
        setState(() => _revealed = true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;

    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    // Seed the group slide from the feed block's captured rectangle.
    final srcRect = reduce ? null : ref.read(feedBundleMorphSourceRectProvider);
    if (srcRect == null) {
      // Nothing to morph from — show settled immediately.
      _slide.value = 1;
      _measured = true;
      _revealed = true;
      return;
    }
    // Measure the group's resting position after first layout, then slide it in
    // from the source rect. Consume the provider so a later open can't reuse it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(feedBundleMorphSourceRectProvider.notifier).state = null;
      final box = _groupKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        _slide.value = 1;
        setState(() {
          _measured = true;
          _revealed = true;
        });
        return;
      }
      setState(() {
        _startOffset = srcRect.topLeft - box.localToGlobal(Offset.zero);
        _measured = true;
      });
      _slide.forward();
    });
  }

  @override
  void dispose() {
    // Release, NOT endSession: the feed underneath re-acquires when the pop
    // reveals it, and the tracker's 800 ms close-linger bridges the pop
    // transition so the visit survives the hand-over. If nothing re-acquires
    // (tab switch, deep-linked entry) the linger fires and the visit closes.
    // The tracker cancels its own timer on dispose, so no app-side
    // pending-timer risk; widget tests that end inside the window pump past
    // 800 ms instead.
    _sessionTracker?.releaseSurface('bundle_see_all', reason: 'disposed');
    _slide.dispose();
    super.dispose();
  }

  FeedBlockBundle get block => widget.block;

  /// The highlighted rows first (in the order the bundle showed them), then the
  /// rest of the result set. Floating the highlighted rows to the top puts
  /// *exactly the rows the feed showed* into the group, and lets the new results
  /// pop in under them — the backend is free to order
  /// [FeedBlockBundle.highlightedItems] out of [FeedBlockBundle.items] order.
  List<FeedItem> get _orderedItems {
    final highlighted = block.highlightedItems;
    final highlightedIds = {for (final it in highlighted) it.id};
    return [
      ...highlighted,
      for (final it in block.items)
        if (!highlightedIds.contains(it.id)) it,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;

    final title = (block.title?.isNotEmpty ?? false)
        ? block.title!
        : l10n.feedBundleSeeAllTitleFallback;
    final total = block.totalCount ?? block.items.length;

    final items = _orderedItems;
    final highlightedCount = block.highlightedItems.length;

    final tracker = ref.watch(
      feedBundleSeeAllTrackerProvider((
        blockId: block.id,
        itemType: block.itemType,
      )),
    );
    // The run that served THIS block (PROD-4303): the wire block's own run_id
    // when the backend sends one, else the run of the page it arrived on (the
    // feed screen is still mounted underneath, so its state is live). Captured
    // once here — row callbacks fire where `ref` may be dead.
    final runId =
        block.runId ??
        ref.read(feedHomeProvider).valueOrNull?.runIdForBlock(block.id);

    Widget rowAt(int index) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: _hPad),
      child: _row(
        index: index,
        item: items[index],
        tracker: tracker,
        runId: runId,
      ),
    );

    // The group that morphs from the feed block: header + the rows it showed.
    final group = Column(
      key: _groupKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, title: title, total: total, ink: inkColor),
        for (var i = 0; i < highlightedCount && i < items.length; i++) ...[
          const SizedBox(height: FeedBundleBlock.rowGap),
          rowAt(i),
        ],
      ],
    );

    // Slide the group up from the feed block's rectangle to its resting place.
    // Translation only (paints, doesn't relayout), so the rows below stay put
    // and nothing scales. Hidden for the single frame before it is measured.
    final slidingGroup = AnimatedBuilder(
      animation: _slide,
      builder: (context, child) {
        final t = _curve.value;
        final offset = (_startOffset ?? Offset.zero) * (1 - t);
        final opacity = !_measured ? 0.0 : (0.5 + 0.5 * t).clamp(0.0, 1.0);
        return Transform.translate(
          offset: offset,
          child: Opacity(opacity: opacity, child: child),
        );
      },
      child: group,
    );

    // PROD-4303 — the session hold follows what the reader can SEE, mirroring
    // the feed screen's wrapper: a detail route pushed over THIS page fully
    // hides it, releasing its hold (the detail is not a discovery surface, so
    // the visit closes after the linger unless the feed is somehow visible);
    // popping back re-acquires. Mount/dispose bracket the same hold in
    // initState/dispose because the detector's first report can lag the first
    // frame.
    return VisibilityDetector(
      key: ValueKey('bundle-see-all-session-${block.id}'),
      onVisibilityChanged: (info) {
        // A callback can be delivered a frame after dispose; a late `> 0`
        // report would re-acquire a hold nothing ever releases.
        if (!mounted) return;
        if (info.visibleFraction == 0) {
          _sessionTracker?.releaseSurface(
            'bundle_see_all',
            reason: 'screen_hidden',
          );
        } else {
          _sessionTracker?.acquireSurface('bundle_see_all');
        }
      },
      child: ColoredBox(
        // Opaque paper fills the screen from the first frame (opaque push), so the
        // sliding group is seen over paper — never over the feed.
        color: isDark ? AppColors.surfaceDark : AppColors.sokoPaper,
        child: PageContent(
          child: SafeArea(
            // A greedy scroll view fills the viewport and top-aligns (unlike a
            // bare `SingleChildScrollView`, which shrinks to content and let
            // `PageContent`'s `Center` centre the page — "started in the middle").
            // The extras build lazily, so opening the page doesn't decode 30 row
            // images at once (that lag stuttered the first row → detail flight).
            child: CustomScrollView(
              slivers: [
                // The morphing group: header + the highlighted rows.
                SliverToBoxAdapter(child: slidingGroup),
                // Results beyond the highlighted ones — withheld until the slide
                // lands, then popped in (staggered) under the rows already shown.
                if (_revealed)
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, i) {
                      final index = highlightedCount + i;
                      return Padding(
                        padding: const EdgeInsets.only(
                          top: FeedBundleBlock.rowGap,
                        ),
                        child: SokoPopIn(
                          startDelay: Duration(milliseconds: 40 * i),
                          child: rowAt(index),
                        ),
                      );
                    }, childCount: items.length - highlightedCount),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context, {
    required String title,
    required int total,
    required Color ink,
  }) => Padding(
    // Top matches the large-title page rhythm (Library sits at safe-area + 27).
    // Kept in sync with ShelfSeeMoreScreen's twin header — change both together.
    padding: const EdgeInsets.fromLTRB(4, 27, 4, 8),
    child: Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            // Symmetric insets keep the title truly centred despite the back
            // button occupying the left edge — same trick as
            // `ShelfSeeMoreScreen`.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 52),
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.displayPrimary(
                  fontSize: 32,
                  fontWeight: FontWeight.w300,
                  color: ink,
                  height: 0.95,
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SokoBackButton(color: ink),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // New to this page (the bundle has no count). Laid out from the first
        // frame — scaled/faded, never absent — so its pop never nudges the rows.
        AnimatedScale(
          scale: _revealed ? 1 : 0.7,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          child: AnimatedOpacity(
            opacity: _revealed ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Text(
              Lt.of(context).feedBundleSeeAllCount(total),
              textAlign: TextAlign.center,
              style: AppTheme.body(
                fontSize: 14,
                fontWeight: FontWeight.w300,
                color: ink,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _row({
    required int index,
    required FeedItem item,
    required ImpressionScrollTracker tracker,
    required String? runId,
  }) {
    // D83 — both rails, for the rows actually SEEN (70 % visible for 300 ms).
    // Read HERE, not in onResolved — that fires from ImpressionDetector.dispose()
    // (row scrolls off, or the screen pops) where `ref` is dead. keepAlive.
    final sessionTracker = ref.read(discoverySessionTrackerProvider);
    return ImpressionDetector(
      // ⚠️ **The key belongs HERE, on the detector, not only on the tile below
      // it** (PROD-4524). Element reuse happens at the level that sits in the
      // parent's child list, and that is this widget — so keyed one level too
      // low, a rebuild that puts a DIFFERENT item in the same slot reuses
      // `_ImpressionDetectorState`: the running dwell clock, `_episodeQualified`
      // and the post-tap reopen block all carry over, and the closing
      // `exposure_end` is billed to the new occupant while the previous one's
      // is lost outright. `dispose()` also only `forget()`s the CURRENT key, so
      // the pre-swap one leaks in `VisibilityDetector`'s app-global static map.
      //
      // ⚠️ **The new occupant is NOT silent, which is what hides this.**
      // `ImpressionDetector._key` is a getter over `widget.itemId`, so the
      // inner `VisibilityDetector` element is replaced and its detach re-arms
      // the state — the row count looks right and only the attribution is
      // wrong. A regression test asserting "the new item reports nothing"
      // passes with the bug present; assert the CLOSING event instead. Full
      // argument and the measured before/after: `feed_people_grid_block.dart`.
      //
      // The tile keeps its own key where it has one — that guards the tile's
      // state if this wrapper is ever removed. This one is the load-bearing
      // half.
      //
      // Shape: the detector's own `scopeId` plus the item id. `scopeId` already
      // carries this surface's uniqueness argument (the Zines page mounts a
      // grid and a bundle at once; a bundle and its see-all page share a
      // `block_id`), so reusing it keeps the key unique for the same reasons
      // and distinct from the tile's own key below.
      key: ValueKey('${tracker.scopeId}-${item.id}'),
      // From the tracker so the detector key and dedup gate cannot drift — NOT
      // the bare block id (this page and the home-page bundle share one, and
      // `VisibilityDetector`'s key map is app-global and static).
      scopeId: tracker.scopeId,
      itemId: item.id,
      // Scopes a tap's resolveForItem to THIS card when the same item is also
      // mounted in another block (hero + bundle row, D82).
      blockId: block.id,
      onImpression: () => tracker.record(item.id, cardIndex: index),
      // Discovery-session impression at qualification + exposure_end with
      // dwell on episode close (PROD-4257, contract v2). The see-all page
      // carries every item type (event/venue/zine), so this closes the
      // engagement rail for those surfaces too.
      onEngagementQualified: (dwellMs) => sessionTracker.impression(
        itemId: item.id,
        itemType: block.itemType,
        runId: runId,
        blockType: 'bundle',
        blockId: block.id,
        surface: tracker.surface,
        cardIndex: index,
        dwellMs: dwellMs,
      ),
      onResolved: (dwellMs, qualified, endReason) => sessionTracker.exposureEnd(
        dwellMs: dwellMs,
        qualified: qualified,
        endReason: endReason,
        itemId: item.id,
        itemType: block.itemType,
        runId: runId,
        blockType: 'bundle',
        blockId: block.id,
        surface: tracker.surface,
        cardIndex: index,
      ),
      child: FeedBundleRow(
        key: ValueKey('feed-see-all-${block.id}-${item.id}'),
        item: item,
        socialProof: block.showSocialProof,
        onTap: () => openFeedItemDetail(
          context,
          ref,
          itemType: block.itemType,
          item: item,
          blockId: block.id,
          surface: FeedImpressionSurface.bundleSeeAllFor(block.itemType),
          cardIndex: index,
          runId: runId,
        ),
      ),
    );
  }
}
