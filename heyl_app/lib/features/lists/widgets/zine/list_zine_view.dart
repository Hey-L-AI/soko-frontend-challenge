import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/unified_analytics_service.dart'
    show unifiedAnalyticsProvider;
import '../../../../core/theme/app_colors.dart';
import '../../../../providers/providers.dart';
import '../../../../shared/turn_page/turn_page_view.dart';
import '../../../../shared/widgets/soko_reveal_on_settle.dart';
import '../../../../data/models/models.dart' show UserListItem;
import '../../providers/current_zine_page_provider.dart';
import '../../providers/unified_list_provider.dart';
import '../../utils/zine_cover_recipe.dart';
import '../list_description.dart';
import '../list_followers_inline.dart';
import '../list_item_note.dart';
import '../list_view_mode/list_view_section.dart' show guestVisibleItemCount;
import 'list_zine_cover_page.dart';
import 'list_zine_item_page.dart';
import 'zine_progress_line.dart';
import 'zine_side_arrows.dart';

/// Hosts the zine view as an inline column — a single fixed-size pager
/// holds the cover (page 0) and item cards (pages 1..N), and the
/// auxiliary content for the active page (map / calendar / suggestions)
/// renders below the pager. Per `docs/designs/list-page-redesign.md` § 6.3
/// / § 11 + PROD-1738:
///
/// - **Page transition** is a `TurnPageView` (`turn_page_transition`
///   package, same animation as the weekly bundle): horizontal drag on
///   the card flips the page with a paper-style turn. Programmatic
///   navigation (cover hero tap, desktop side arrows, cover map pin tap)
///   goes through [TurnPageController].
/// - **Card dimensions are uniform across the list**: derived from the
///   viewport — width = `viewportWidth - 30`, height = `max(width × 5/4,
///   kListZinePageMinHeight)` (D110: 4:5 portrait, with a content floor
///   on SE-class phones). Item cards use [Expanded] for the hero so the
///   card always fits regardless of content.
/// - **Auxiliary content** (map, calendar, suggestions) cross-fades on
///   page change via [AnimatedSwitcher]. The card flip and the aux
///   cross-fade run on the same timeline.
/// - **URL stays at `/lists/:listId`** regardless of the current page;
///   refresh lands on the cover.
class ListZineView extends ConsumerStatefulWidget {
  /// Family key used to read [unifiedListProvider]. Passed down to
  /// [ListItemNote] so writes (`updateItemTip`) hit the SAME provider
  /// instance the page reads from. The route's `:listId` may be a slug
  /// (e.g. `nova-3`); using `state.list?.id` (the resolved UUID) here
  /// would route writes to a different family instance whose
  /// optimistic update never reaches this widget — the UI would appear
  /// to drop the change even though the API call succeeded.
  final String listId;
  final UnifiedListState state;

  /// Onboarding "sandbox" mode (mirrors the `sandbox` flag on
  /// `VenueDetailBody` / `EventDetailBody`). When true the reader stays
  /// fully visual but read-only: the cover's change-cover tap is
  /// disabled, item cards drop their external/share actions, the
  /// auxiliary map/calendar are wrapped in `IgnorePointer` (they render
  /// but don't launch external maps / navigate), and item-card taps are
  /// routed to [onSandboxItemTap] instead of the in-list detail route.
  /// `unifiedListProvider` reports `isOwner: true` for the user's own
  /// hidden onboarding-preliminary list, so this flag — NOT `isOwner` —
  /// is the single gate for read-only.
  final bool sandbox;

  /// Invoked with the tapped item in [sandbox] mode (the onboarding host
  /// opens the sandbox event/venue detail). Ignored when [sandbox] is
  /// false.
  final void Function(UserListItem item)? onSandboxItemTap;

  const ListZineView({
    super.key,
    required this.listId,
    required this.state,
    this.sandbox = false,
    this.onSandboxItemTap,
  });

  @override
  ConsumerState<ListZineView> createState() => _ListZineViewState();
}

class _ListZineViewState extends ConsumerState<ListZineView> {
  late TurnPageController _turnController;
  // PROD-1968: the vendored `TurnAnimationController` now allocates
  // controllers lazily for the active page ± `windowRadius`, with a
  // mutable `itemCount` that the inner State propagates from
  // `widget.itemCount` via `didUpdateWidget`. So tail-fetch growth
  // (PROD-1967's slim progressive fetch) lands in-place — no
  // ValueKey remount, no fresh controller swap, no `_currentIndex`
  // reset to 0. The user stays on whatever page they were on when
  // items appended.
  //
  // Pre-PROD-1968 history (for context, since this is the second
  // major change to the pager lifecycle): the pre-vendored package
  // sized its `_controllers` list to `itemCount` at `initState` and
  // never resized on `didUpdateWidget`, so async-loaded items would
  // trigger a `RangeError` on the first `generatePages` call. The
  // workaround was the `ValueKey('zine-pager-$pageCount')` +
  // controller-swap dance that lived here through PROD-1955.
  Timer? _pagePoller;
  int _currentIndex = 0;
  int _pageCount = 1;
  // True while a pointer is currently down on the pager (drag or
  // tap-in-progress). Used to suppress the corner-peel tease — once
  // the user is interacting, the tease stops immediately so it
  // doesn't compete with the live page-flip animation.
  bool _userInteracting = false;
  // Set while a progress-line-driven cascade is running. Blocks
  // additional progress-line taps, disables pager drag, and gates
  // pointer events at the pager (`IgnorePointer`). PROD-1955.
  bool _isAnimating = false;
  // While a cascade is running, the page the cascade started from.
  // Used as the source-of-truth for the aux + slot AnimatedSwitcher
  // keys so they stay anchored to the *origin* page through every
  // intermediate flip and only cross-fade once when the cascade
  // settles on the destination. PROD-1955.
  int? _cascadeSourceIndex;

  int _computePageCount() => 1 + widget.state.items.length;

  @override
  void initState() {
    super.initState();
    _pageCount = _computePageCount();
    _turnController = TurnPageController();
    // Polling is the most reliable way to track page changes with
    // TurnPageController — its ChangeNotifier fires inconsistently
    // during/after drags. Same pattern as the weekly bundle overlay.
    _pagePoller = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      final idx = _turnController.currentIndex;
      if (idx != _currentIndex) {
        setState(() => _currentIndex = idx);
        // PROD-3209: page-settle beacon; item pages double as per-item
        // impressions (page 0 is the cover). Fires on change only, so a
        // poll tick never re-emits the same page.
        final items = widget.state.items;
        final itemIndex = idx - 1;
        // Publish the foregrounded item so the (separately-built) header can
        // show the contextual reminder bell on event pages. Cover → null.
        ref
            .read(currentZinePageItemProvider(widget.listId).notifier)
            .state = (itemIndex >= 0 && itemIndex < items.length)
            ? items[itemIndex]
            : null;
        ref
            .read(unifiedAnalyticsProvider)
            .trackZinePageView(
              zineId: widget.state.list?.id ?? widget.listId,
              pageIndex: idx,
              pageTotal: _pageCount,
              entityId: (itemIndex >= 0 && itemIndex < items.length)
                  ? items[itemIndex].entityKey
                  : null,
            );
      }
    });
  }

  @override
  void didUpdateWidget(covariant ListZineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newCount = _computePageCount();
    if (newCount != _pageCount) {
      // PROD-1968: just track the new count. The inner
      // `_TurnPageViewState.didUpdateWidget` propagates the new
      // `widget.itemCount` to the animation controller, which
      // re-runs `_ensureWindow(currentIndex)` to allocate any
      // newly-in-range pages. Active page, controller instance,
      // cascade state — all preserved across the growth.
      _pageCount = newCount;
    }
  }

  @override
  void dispose() {
    _pagePoller?.cancel();
    // Do NOT dispose `_turnController` here — `_TurnPageViewState.dispose`
    // in the `turn_page_transition` package already disposes the
    // controller it was given (see `turn_page_view.dart:130`). Calling
    // dispose again would double-dispose the inner `AnimationController`s
    // and surface as "AnimationController.animateTo() called after
    // dispose" if a queued tap-handler closure (side arrow, cover hero)
    // fires after disposal.
    super.dispose();
  }

  void _next() {
    if (!mounted || _isAnimating) return;
    if (_currentIndex < _pageCount - 1) _turnController.nextPage();
  }

  void _prev() {
    if (!mounted || _isAnimating) return;
    if (_currentIndex > 0) _turnController.previousPage();
  }

  /// Jumps from the cover map pin / cover map drawer to the matching
  /// item page. `itemIndex` is 0-based into `state.items`; the pager
  /// page is `itemIndex + 1` (cover is page 0).
  ///
  /// Uses `jumpToPage` (instant) instead of `animateToPage` because the
  /// latter cascades through every intermediate page at 50ms intervals,
  /// which would also fan out the aux content cross-fade through every
  /// in-between page.
  /// Underlay rendered behind the cover's tease-peel: the ACTUAL first
  /// item page (same widget the TurnPageView would render at index 1),
  /// not a hand-built placeholder. The peel clips this to its
  /// lifted-away triangle so the user sees exactly the page they'd
  /// reach by swiping — title, photo, buttons, all of it. The card is
  /// rendered with `isActive: false` (so its page-label auto-fade
  /// behaviour is inert) and `pageLabel: null` (the peel paints its
  /// own next-page label and we don't want a duplicate underneath).
  Widget _buildFirstItemUnderlay({
    required UserListItem item,
    required String listId,
    required List<UserListItem> allItems,
    required bool isBlurred,
  }) {
    return ListZineItemCard(
      item: item,
      // Cover is page 1, first item is page 2 — matches the pageNumber
      // the item card receives when it's rendered as the active page.
      pageNumber: 2,
      listId: listId,
      allItems: allItems,
      pageLabel: null,
      teaseNextLabel: null,
      isActive: false,
      isBlurred: isBlurred,
      // Underlay is a non-interactive visual peek (clipped to the peel
      // triangle); inherit sandbox so its actions stay suppressed too.
      sandbox: widget.sandbox,
    );
  }

  /// Beyond this step count the cascade animation no longer feels
  /// good — at 50 ms per flip the total runs >1 s and the rapid
  /// flicker is more nausea than charm. Long jumps fall back to
  /// `jumpToPage` (instant), the same path the cover map pin uses.
  /// PROD-1955.
  static const int _kMaxCascadeSteps = 20;

  /// Cascade-flip from the current page to [targetPageIndex] (a pager
  /// index, 0 = cover). Tap on the active segment is a noop; taps that
  /// arrive while a cascade is already running are dropped. Pager drag
  /// + pointer events are suspended for the cascade duration via
  /// `_isAnimating` (drives `useOnSwipe` + the outer `IgnorePointer`).
  /// Long jumps (step count > [_kMaxCascadeSteps]) skip the cascade
  /// and use `jumpToPage` (instant). PROD-1955.
  /// PROD-4XXX — instantly move the pager to the page whose item matches
  /// [entityId] (event or venue). Used to keep the zine in sync with the
  /// in-list detail's sibling swipe. No-op if the entity isn't in the loaded
  /// items, the pager isn't mounted (still on the static cover), or we're
  /// already there. Instant (`jumpToPage`) since it happens off-screen.
  void _jumpToEntity(String entityId) {
    if (!mounted) return;
    final items = widget.state.items;
    if (items.isEmpty) return;
    final itemIndex = items.indexWhere(
      (it) => it.eventId == entityId || it.venueId == entityId,
    );
    if (itemIndex < 0) return;
    final pageIndex = itemIndex + 1; // page 0 is the cover
    if (pageIndex >= _pageCount) return;
    if (_turnController.currentIndex == pageIndex) return;
    _turnController.jumpToPage(pageIndex);
    setState(() => _currentIndex = pageIndex);
  }

  Future<void> _animateToPage(int targetPageIndex) async {
    if (!mounted || _isAnimating) return;
    if (targetPageIndex < 0 || targetPageIndex >= _pageCount) return;
    // Authoritative source = the controller's current index, not the
    // poll-derived `_currentIndex`, so a tap that arrives mid-flip
    // computes the right step count.
    final source = _turnController.currentIndex;
    if (targetPageIndex == source) return;
    final steps = (targetPageIndex - source).abs();
    if (steps > _kMaxCascadeSteps) {
      // Long-distance seek (typical for the continuous-bar mode on
      // big lists): jump instantly. No `_isAnimating` lockout — the
      // jump is synchronous and there's no animation to interrupt.
      _turnController.jumpToPage(targetPageIndex);
      setState(() => _currentIndex = targetPageIndex);
      return;
    }
    final schedule = _buildCascadeSchedule(steps);

    setState(() {
      _isAnimating = true;
      _cascadeSourceIndex = source;
    });

    try {
      await _turnController.animateToPageWithSchedule(
        targetPageIndex,
        schedule,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAnimating = false;
          _cascadeSourceIndex = null;
          // Snap `_currentIndex` straight to the target so the aux +
          // slot AnimatedSwitchers transition source → target in a
          // single rebuild (one cross-fade). Skip if the controller
          // didn't end up where we asked — e.g. the controller was
          // swapped mid-cascade by `didUpdateWidget` on a pageCount
          // change. The poller will reconcile naturally in that case.
          if (_turnController.currentIndex == targetPageIndex) {
            _currentIndex = targetPageIndex;
          }
        });
      }
    }
  }

  /// Per-flip duration schedule for a cascade of [n] flips. PROD-1955.
  ///
  /// | n  | Schedule (ms)                  |
  /// | -- | ------------------------------ |
  /// | 1  | 300                            |
  /// | 2  | 100, 300                       |
  /// | 3  | 50, 100, 300                   |
  /// | 4+ | 50 × (n-3), then 50, 100, 300  |
  ///
  /// 50 ms floor keeps each flip ≥ ~1.5 frames so it doesn't visibly
  /// snap on lower-end devices. The trailing 50 → 100 → 300 "settle"
  /// gives the destination a recognisable page-turn feel — the 300 ms
  /// final flip matches the natural drag-flip duration so the cascade
  /// lands on the destination at the same cadence as if the user had
  /// dragged there themselves.
  static List<Duration> _buildCascadeSchedule(int n) {
    if (n <= 0) return const [];
    if (n == 1) return const [Duration(milliseconds: 300)];
    if (n == 2) {
      return const [Duration(milliseconds: 100), Duration(milliseconds: 300)];
    }
    return [
      for (var i = 0; i < n - 3; i++) const Duration(milliseconds: 50),
      const Duration(milliseconds: 50),
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 300),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final list = state.list;
    // PROD-4415 — the cover is the owner's; nobody else gets a tap target.
    final canTapCover = coverTapEnabled(sandbox: widget.sandbox, state: state);

    // PROD-4XXX — follow the in-list detail page: when the user swipes to a
    // sibling item there, jump this pager to match so a back-press lands on
    // the same page. Registered every build; Riverpod dedups the listener.
    ref.listen<String?>(zineDetailSyncTargetProvider(widget.listId), (_, next) {
      if (next != null) _jumpToEntity(next);
    });

    if (list == null) return const SizedBox.shrink();

    final pageCount = _pageCount;
    final currentIndex = _currentIndex;
    final isLast = currentIndex == pageCount - 1;
    final hasItems = state.items.isNotEmpty;
    // PROD-1979 — guests see the first ⌈N/3⌉ item pages clearly; the
    // rest render blurred with a sign-in CTA. The pager keeps the full
    // pageCount so users can still swipe past, see the tease, and
    // discover the cap.
    final isGuest = !ref.watch(isAuthenticatedProvider);
    final guestCap = guestVisibleItemCount(state.items.length);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Card pager (TurnPageView) with desktop side arrows ───
          // `IgnorePointer` wraps the pager group so any pointer event
          // is dropped while a progress-line cascade is running
          // (PROD-1955). Belt-and-suspenders alongside `useOnSwipe:
          // !_isAnimating` on the TurnPageView and the
          // `if (_isAnimating) return;` guards on `_prev`/`_next`.
          IgnorePointer(
            ignoring: _isAnimating,
            child: ZineSideArrows(
              showLeft: currentIndex > 0,
              showRight: !isLast,
              onPrev: _prev,
              onNext: _next,
              // Listener observes pointer events on the pager surface
              // without claiming them — TurnPageView's own
              // GestureDetector still handles drag-to-flip. We use it
              // purely to toggle `_userInteracting`, which suppresses
              // the corner-peel tease the moment the user touches the
              // pager and re-enables it when they let go.
              child: Listener(
                onPointerDown: (_) {
                  if (!_userInteracting) {
                    setState(() => _userInteracting = true);
                  }
                },
                onPointerUp: (_) {
                  if (_userInteracting) {
                    setState(() => _userInteracting = false);
                  }
                },
                onPointerCancel: (_) {
                  if (_userInteracting) {
                    setState(() => _userInteracting = false);
                  }
                },
                // Card dimensions: derived from the *actual* width
                // available to us via `LayoutBuilder` (not
                // `MediaQuery.size.width`, which returns the device
                // viewport — on desktop our content column is
                // constrained to ~480pt by the app shell, but
                // MediaQuery still reports the full screen width).
                // Height targets the 4:5 portrait policy (D110:
                // `width × 5/4`) on every viewport, with a content
                // floor at `kListZinePageMinHeight`: on SE-class
                // phones (≤ ~320 viewport) the pure 4:5 height would
                // compress the item card's Expanded hero photo below
                // its `minHeight: 150`. The floor keeps the layout
                // intact at the cost of a slightly taller-than-4:5
                // cover on those narrow widths (~0.73 ratio, visually
                // indistinguishable from 4:5 = 0.80).
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cardWidth = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : 0.0;
                    final cardHeight = math.max(
                      cardWidth * 5 / 4,
                      kListZinePageMinHeight,
                    );
                    return SizedBox(
                      width: cardWidth,
                      height: cardHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        // PROD-4XXX: until the items load, show the cover as a
                        // STATIC card — never a 1-page pager that later grows,
                        // which corrupts the vendored TurnPageView controller
                        // on the first flip (the zine would blank out). The
                        // real pager mounts exactly once, with the loaded items.
                        //
                        // Gate on `itemsLoaded` (an item fetch completed), NOT
                        // on `items.isEmpty`. They diverge in exactly the case
                        // that used to hang: items empty because the fetch
                        // failed or the zine has none. `items.isEmpty` reads
                        // that as "still loading" and parks on this static,
                        // non-interactive card permanently — no pager, nothing
                        // scrollable, no way out but Back (reported
                        // 2026-09-15). `ListPageScreen` now intercepts both
                        // states ahead of this widget (error → retry, loaded +
                        // empty → the empty hero); this gate is what makes the
                        // branch honest on its own rather than relying on that.
                        child: !state.itemsLoaded
                            ? ListZineCoverCard(
                                recipe: resolveZineCoverRecipe(state),
                                title: list.name,
                                pageNumber: 1,
                                onAddPhotoTap: canTapCover
                                    ? () => onCoverAddPhotoTap(
                                        context: context,
                                        ref: ref,
                                        state: state,
                                      )
                                    : null,
                                teaseNextLabel: null,
                                teaseUnderlay: null,
                              )
                            : TurnPageView.builder(
                                controller: _turnController,
                                itemCount: pageCount,
                                animationTransitionPoint: 0.5,
                                // The back of the lifted page is plain Soko paper
                                // with no outline — the switching page reads as a
                                // clean sheet of paper rather than a coloured,
                                // bordered card back.
                                overleafColorBuilder: (_) =>
                                    AppColors.sokoPaper,
                                overleafBorderColorBuilder: (_) =>
                                    Colors.transparent,
                                overleafBorderWidthBuilder: (_) => 0,
                                // Disable TurnPageView's built-in tap-to-navigate —
                                // we have our own tap behaviours: the cover's hero
                                // tap zones advance, item cards' tap opens detail.
                                // Drag-to-flip stays on, except while a progress-line
                                // cascade is running (PROD-1955) — we disable it so
                                // the user can't fight the programmatic animation.
                                useOnTap: false,
                                useOnSwipe: !_isAnimating,
                                itemBuilder: (context, index) {
                                  if (index == 0) {
                                    return ListZineCoverCard(
                                      recipe: resolveZineCoverRecipe(state),
                                      title: list.name,
                                      pageNumber: 1,
                                      // Cover is non-navigating — no prev/next tap
                                      // zones. Users advance via drag-to-flip,
                                      // desktop side arrows, or the cover map pin.
                                      // PROD-1908: tap on the cover routes to the
                                      // change-cover sheet for owners. Disabled in
                                      // sandbox (read-only preview) and for
                                      // non-owners (PROD-4415).
                                      onAddPhotoTap: canTapCover
                                          ? () => onCoverAddPhotoTap(
                                              context: context,
                                              ref: ref,
                                              state: state,
                                            )
                                          : null,
                                      // Tease the first item ("1") when there's
                                      // anything to swipe to. Suppressed while the
                                      // user is interacting with the pager so the
                                      // tease doesn't compete with the live flip.
                                      teaseNextLabel:
                                          (hasItems && !_userInteracting)
                                          ? '1'
                                          : null,
                                      // The "page behind" the cover IS the
                                      // first item's page — same widget the
                                      // TurnPageView would render at index 1
                                      // (title, hero photo, buttons, all of
                                      // it). The peel clips it to its
                                      // lifted-away triangle so the user
                                      // peeks at the real next page rather
                                      // than a stand-in.
                                      teaseUnderlay: hasItems
                                          ? _buildFirstItemUnderlay(
                                              item: state.items.first,
                                              listId: list.id,
                                              allItems: state.items,
                                              isBlurred:
                                                  isGuest && 0 >= guestCap,
                                            )
                                          : null,
                                    );
                                  }
                                  final itemIndex = index - 1;
                                  final item = state.items[itemIndex];
                                  final pageNumber = index + 1;
                                  return ListZineItemCard(
                                    item: item,
                                    pageNumber: pageNumber,
                                    listId: list.id,
                                    allItems: state.items,
                                    sandbox: widget.sandbox,
                                    onSandboxTap: widget.onSandboxItemTap,
                                    isBlurred: isGuest && itemIndex >= guestCap,
                                    // Display numbering: cover = no label; first
                                    // item = "1"; item N = "$N". Maps directly to
                                    // the TurnPageView index for items (index 1 →
                                    // "1", index 2 → "2", …).
                                    pageLabel: '$index',
                                    // Tease only runs on the cover for now — item
                                    // cards don't show the corner-peel hint.
                                    teaseNextLabel: null,
                                    // Drives the page-label fade-out: visible while
                                    // the page is freshly active, fades out 1s after
                                    // settling. Polling-derived `_currentIndex` lags
                                    // the controller by ≤300ms, which is fine — the
                                    // 1s timer still feels prompt after a flip.
                                    isActive: index == currentIndex,
                                  );
                                },
                              ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // Everything below the flip-book is deferred off the cover
          // Hero-flight frames and revealed once it lands (fade + slide-up),
          // matching the detail pages. The pager (which carries the cover
          // Hero) stays put, and the heavy cover map/calendar (ListZineCoverAux)
          // stay off the flight frames. See [SokoRevealOnSettle]. Latches, so
          // flipping pages afterwards never re-defers.
          SokoRevealOnSettle(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Follow-proof ←→ leave-note row (Figma 7660:27950) ────
                // Sits ABOVE the pagination line. On the cover it carries the
                // list description + follow social-proof; on item pages it's a
                // justified row — list follow-proof on the left, the owner's
                // leave-note affordance on the right ([_FollowNoteRow]). The
                // note itself collapses to nothing for non-owners. Wrapped in
                // an AnimatedSwitcher so the row cross-fades on the same beat
                // as the aux-content switcher below it (220 ms). The 12-px top
                // spacer is inside the conditional so an empty row leaves no gap.
                //
                // PROD-1955 cascade gating: while a progress-line cascade is
                // running, the row stays anchored to the source page (the
                // page the cascade started from) — both its KEY and the
                // content it builds. When the cascade ends, the source is
                // cleared and the KEY transitions source → destination in a
                // single rebuild, triggering one 220 ms cross-fade instead
                // of fanning a cross-fade through every intermediate page.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: KeyedSubtree(
                    key: ValueKey(
                      'zine-slot-${_cascadeSourceIndex ?? currentIndex}',
                    ),
                    child: Builder(
                      builder: (_) {
                        final slotIndex = _cascadeSourceIndex ?? currentIndex;
                        // Follow social-proof is list-level, so it shows on every
                        // page (Figma shows it on an item page beside the note
                        // button — not cover-only as before).
                        final followProof = list.followerCount > 0
                            ? ListFollowersInline(
                                listId: list.id,
                                listName: list.name,
                                followerCount: list.followerCount,
                              )
                            : null;
                        if (slotIndex == 0) {
                          final desc = list.description;
                          final hasDesc = (desc ?? '').trim().isNotEmpty;
                          if (!hasDesc && followProof == null) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (hasDesc) ListDescription(description: desc),
                                if (followProof != null)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      top: hasDesc ? 10 : 0,
                                    ),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: followProof,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }
                        final item = state.items[slotIndex - 1];
                        // The below-pager note is owner-only. Non-owners already see
                        // the tip read-only inside the collage card
                        // (list_zine_item_page.dart), so the duplicate callout here
                        // is dropped for them. Sandbox is read-only too: no empty
                        // editable-note affordance (isOwner is true for the user's
                        // own hidden list).
                        final canEditNote = state.isOwner && !widget.sandbox;
                        final note = canEditNote
                            ? ListItemNote(
                                // Use the family key the page reads from (slug
                                // or UUID — whatever the route gave), NOT
                                // `list.id`. See class doc on [ListZineView].
                                listId: widget.listId,
                                listElementId: item.id,
                                tip: item.tip,
                                canEdit: canEditNote,
                                itemName: item.title,
                                authorAvatarUrl: item.addedByAvatarUrl,
                                authorName: item.addedByName,
                                authorId: item.addedById,
                              )
                            : null;
                        if (followProof == null && note == null) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _FollowNoteRow(proof: followProof, note: note),
                        );
                      },
                    ),
                  ),
                ),

                // ── Progress line ────────────────────────────────────────
                // Figma 7660:27961: sits BELOW the follow/note row. Rendered
                // unconditionally so the Column children list stays stable
                // across `state.items` loads — `ZineProgressLine` itself
                // returns `SizedBox.shrink()` when `totalSections <= 1`, so
                // the visual is unchanged on empty lists.
                SizedBox(height: pageCount > 1 ? 16 : 0),
                // PROD-1955: subscribe the progress line to per-frame
                // animation ticks so the fill / active-segment tracks the
                // page-turn animation at 60 FPS — no 300 ms poller lag, no
                // staircased advancement during a cascade. Only this
                // subtree rebuilds on ticks; the surrounding aux / pager
                // tree stays driven by `_currentIndex`.
                AnimatedBuilder(
                  animation: _turnController,
                  builder: (context, _) => ZineProgressLine(
                    totalSections: pageCount,
                    activeUpTo: _turnController.fractionalProgress + 1,
                    // `_animateToPage` handles the "tap on active = noop"
                    // and mid-cascade lockout rules — the progress line
                    // just emits the segment index.
                    onSegmentTap: _animateToPage,
                  ),
                ),

                // ── Auxiliary content (cross-fades on page change) ───────
                // PROD-1955: same source-anchored gating as the slot above —
                // aux content stays on the source page through the cascade
                // and flips once at the end.
                // Sandbox: the aux map/calendar render but stay non-interactive
                // (their pin/day taps navigate to in-list detail routes, which
                // would leave the onboarding gate). Mirrors the IgnorePointer
                // wrap around launcher content in Venue/EventDetailBody.
                IgnorePointer(
                  ignoring: widget.sandbox,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: KeyedSubtree(
                      key: ValueKey(
                        'zine-aux-${_cascadeSourceIndex ?? currentIndex}',
                      ),
                      child: Builder(
                        builder: (_) {
                          final auxIndex = _cascadeSourceIndex ?? currentIndex;
                          return auxIndex == 0
                              ? ListZineCoverAux(state: state)
                              : ListZineItemAux(
                                  item: state.items[auxIndex - 1],
                                  state: state,
                                );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Bottom safe-area cushion so the last section breathes above
          // the bottom nav.
          SizedBox(height: MediaQuery.of(context).padding.bottom + 20),
        ],
      ),
    );
  }
}

/// The justified follow-proof ←→ leave-note row below a zine item card (Figma
/// `7660:27950`). The follow-proof hugs the left, the note affordance the
/// right; when only one is present it takes the row, and when the note expands
/// to its editor / tip callout the two share the width (the empty-mockup
/// resting state — a compact "Deixar nota" pill — is the common owner case).
class _FollowNoteRow extends StatelessWidget {
  final Widget? proof;
  final Widget? note;

  const _FollowNoteRow({this.proof, this.note});

  @override
  Widget build(BuildContext context) {
    final proof = this.proof;
    final note = this.note;
    if (proof == null && note == null) return const SizedBox.shrink();
    // Note only → full width (its own states left-align themselves).
    if (proof == null) return note!;
    // Proof only → left-aligned social proof, no right-hand affordance.
    if (note == null) {
      return Align(alignment: Alignment.centerLeft, child: proof);
    }
    // Both → proof left, note right (Figma justified row). Bounded on both
    // sides so the note's expanded editor/callout can never overflow.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: proof),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Align(alignment: Alignment.centerRight, child: note),
        ),
      ],
    );
  }
}

/// The zine cover rendered on the FIRST (uncached) open, while
/// `unifiedListProvider` is still loading, from a [ZineCoverSeed] cached on the
/// Library tap — so the open paints a real cover instead of a blank frame.
///
/// Reproduces the real cover's rect EXACTLY — same `Padding(horizontal: 15)`,
/// same 4:5-with-floor sizing — as the hydrated cover in [ListZineView] above,
/// so when the list loads and the real pager replaces this, there is no jump.
/// Non-interactive (no add-photo / tease).
class ZineCoverLoading extends StatelessWidget {
  final String listId;
  final ZineCoverRecipe recipe;
  final String title;

  const ZineCoverLoading({
    super.key,
    required this.listId,
    required this.recipe,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 0.0;
          final cardHeight = math.max(
            cardWidth * 5 / 4,
            kListZinePageMinHeight,
          );
          return SizedBox(
            width: cardWidth,
            height: cardHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ListZineCoverCard(
                recipe: recipe,
                title: title,
                pageNumber: 1,
              ),
            ),
          );
        },
      ),
    );
  }
}
