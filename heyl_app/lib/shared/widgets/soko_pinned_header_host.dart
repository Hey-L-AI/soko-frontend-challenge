// PROD-4080 — the three placement modes for [SokoPinnedHeader] (D119).
//
// The three surfaces that want a header genuinely differ in how it behaves on
// scroll, so this is a mode rather than a styling flag. `fixed` and
// `scrollAway` are **identical at rest** and diverge only once the user
// scrolls, which is why each needs a test that actually scrolls — a mistake
// between them is invisible in a screenshot.

import 'package:flutter/material.dart';

import 'soko_pinned_header.dart';

/// How a [SokoPinnedHeader] sits relative to the page's scrollable.
enum SokoHeaderPlacement {
  /// Overlays the content and stays at the top. Nothing is reserved for it —
  /// content scrolls *under* it. Used by the Discovery feed, where the bar
  /// appears only once the in-flow chrome above has been consumed
  /// (see [SokoPinnedHeaderHost.revealAfter]).
  ///
  /// ⚠️ **Your header owns its top safe-area inset** — see the note on
  /// [SokoHeaderPlacement.fixed]. This mode is the one where getting it wrong
  /// is worst: the content scrolling under an un-inset bar is visible through
  /// the status-bar band.
  pinnedOverlay,

  /// Fixed at the top, outside the scroll view. Always visible, occupies
  /// vertical space, never covers anything.
  ///
  /// The design doc calls this mode `static`; `static` is a Dart reserved word
  /// and cannot be an enum value, so it is `fixed` here.
  ///
  /// ⚠️ **Wrap your bar in a `SokoPinnedHeaderBlock`.** This mode and
  /// [SokoHeaderPlacement.pinnedOverlay] both put the header at the very top of
  /// the page, so it needs the paper, the top safe-area inset and the margin
  /// above and below — and a bare [SokoPinnedHeader] has none of them.
  ///
  /// ```dart
  /// header: SokoPinnedHeaderBlock(
  ///   child: SokoPinnedHeader(leading: ..., centre: ...),
  /// ),
  /// ```
  ///
  /// The host cannot do this for you: it would have to paint the band behind
  /// the inset, and only your header knows what colour that is.
  ///
  /// **This note used to show the `ColoredBox > SafeArea > bar` composition
  /// inline and stop there** — correct about the `SafeArea` ordering, silent
  /// about the 15 px above and below. PROD-4081 followed it to the letter and
  /// came out 30 px short of the feed (84 against 114 at a 44 px notch). The
  /// block exists so that cannot happen again; do not hand-roll the
  /// composition (PROD-4101).
  fixed,

  /// In the layout flow: occupies vertical space and scrolls out of view with
  /// the content.
  ///
  /// ⚠️ The caller must reserve [SokoPinnedHeaderHost.headerHeight] at the top
  /// of the scrollable's **content** (a leading `SizedBox`, a spacer sliver, or
  /// `padding`) — the same figure the host animates against, which is exactly
  /// the [SokoPinnedHeaderHost.headerHeight] you passed. **It has no default
  /// and the constructor requires it** — compute it with
  /// `myBlock.heightFor(context)`, never a literal (PROD-4101).
  ///
  /// A box-world overlay cannot hand its band back to the child when it leaves
  /// — the child's viewport is fixed — so the space has to come from inside the
  /// scroll content. This mirrors how
  /// `PinnedPageChrome` and `ShellSliverScope.chromeReserved` already split
  /// the job in this codebase.
  ///
  /// If you are already building slivers, prefer skipping this host and
  /// putting `SliverToBoxAdapter(child: SokoPinnedHeader(...))` first in your
  /// sliver list — that is exactly this behaviour, with no machinery.
  scrollAway,
}

/// Mounts a [SokoPinnedHeader] over a page's scrollable in one of the three
/// [SokoHeaderPlacement] modes.
///
/// One host rather than three widgets so adopting does not require knowing
/// whether your page is sliver-world or box-world: it works over a reversed
/// `ListView` (chat), a `NestedScrollView` (public profile) or a
/// `CustomScrollView` (the feed, the library) alike, given a [controller].
///
/// **One constructor per placement**, each taking only what its mode reads —
/// see [SokoPinnedHeaderHost.fixed], [SokoPinnedHeaderHost.pinnedOverlay] and
/// [SokoPinnedHeaderHost.scrollAway]. There is no generative constructor: a
/// `placement` parameter meant `scrollAway` could be built without the height
/// it dereferences, caught only by an assert that release strips (PROD-4101).
///
/// ```dart
/// SokoPinnedHeaderHost.fixed(
///   header: SokoPinnedHeaderBlock(
///     child: SokoPinnedHeader(centre: SokoHeaderSlot.location()),
///   ),
///   child: myScrollable,
/// )
/// ```
///
/// **Pick a placement and keep it.** `fixed` puts [child] in a `Column`, the
/// other two put it in a `Stack`, so changing placement at runtime reparents
/// the caller's scrollable — Flutter rebuilds its element and it comes back at
/// scroll offset 0. The host handles the change correctly (it re-reports once
/// the frame settles), but the lost scroll position is not something it can
/// give back.
class SokoPinnedHeaderHost extends StatefulWidget {
  /// The bar. Normally a [SokoPinnedHeader], but any widget of
  /// [headerHeight] works — the feed passes its own paper-and-filter-row block.
  final Widget header;

  final SokoHeaderPlacement placement;

  /// The page's scrollable.
  final Widget child;

  /// The scrollable's controller. Required by [SokoHeaderPlacement.pinnedOverlay]
  /// and [SokoHeaderPlacement.scrollAway]; unused by
  /// [SokoHeaderPlacement.fixed], which needs no scroll information.
  final ScrollController? controller;

  /// [SokoHeaderPlacement.pinnedOverlay] only — the scroll offset past which
  /// the header shows. Defaults to always-visible, which is what a page with
  /// nothing above the header wants.
  ///
  /// **A getter, not a value**, because the threshold is often measured during
  /// layout rather than known up front: the feed reads a zero-extent
  /// `SliverLayoutBuilder`'s `precedingScrollExtent`, so the trigger follows
  /// whatever slivers sit above it without being told. Re-read on every tick.
  final ValueGetter<double> revealAfter;

  /// Fires when a [SokoHeaderPlacement.pinnedOverlay] header appears or
  /// disappears. The feed uses it to close a filter row that would otherwise be
  /// left floating over the page with nothing above it.
  final ValueChanged<bool>? onVisibilityChanged;

  /// Height of [header]. **Required for [SokoHeaderPlacement.scrollAway]**,
  /// which is the only mode that reads it; ignored by the other two.
  ///
  /// **Do not write the number** — use
  /// `myBlock.heightFor(context)` — an instance method, so the block's own gap
  /// and margin cannot disagree with it. A header block carries
  /// `MediaQuery.padding.top`, so no literal is right on more than one device:
  /// `114` is correct on a 44 px notch and wrong everywhere else. A constructor
  /// argument *can* express it — it is evaluated in your `build()`, not at
  /// compile time — but nothing about the type tells you the `MediaQuery` term
  /// is there, which is exactly how a literal gets written.
  ///
  /// It defaulted to [kSokoPinnedHeaderHeight] until PROD-4101. That default
  /// was right for a bare bar and silently wrong for every composed block —
  /// the feed hands over a block of `inset + 70` and passed nothing.
  final double? headerHeight;

  /// Overlays the content, appearing once the scroll passes [revealAfter].
  ///
  /// Wrap your bar in a `SokoPinnedHeaderBlock` — this mode puts the header at
  /// the very top of the page, so it needs the paper, the safe-area inset and
  /// the margins that a bare [SokoPinnedHeader] does not have.
  const SokoPinnedHeaderHost.pinnedOverlay({
    super.key,
    required this.header,
    required this.child,
    required ScrollController this.controller,
    this.revealAfter = _alwaysVisible,
    this.onVisibilityChanged,
  }) : placement = SokoHeaderPlacement.pinnedOverlay,
       headerHeight = null;

  /// Fixed above the content, outside the scroll view.
  ///
  /// Takes no controller, no [revealAfter] and no [onVisibilityChanged]: this
  /// mode is always visible and never moves, so there is nothing to observe.
  /// Those parameters were accepted and silently ignored until PROD-4101.
  const SokoPinnedHeaderHost.fixed({
    super.key,
    required this.header,
    required this.child,
  }) : placement = SokoHeaderPlacement.fixed,
       controller = null,
       revealAfter = _alwaysVisible,
       onVisibilityChanged = null,
       headerHeight = null;

  /// In the layout flow: occupies space and scrolls out of view.
  ///
  /// [headerHeight] is **required and cannot be defaulted** — it is how far the
  /// header travels before it is gone, and how much your scroll content must
  /// reserve. Use `yourBlock.heightFor(context)`; never a literal, since it
  /// carries the safe-area inset.
  ///
  /// Required in the *constructor* rather than asserted: an assert is stripped
  /// in release, where the null-unwrap in `build` became a crash. (codex.)
  const SokoPinnedHeaderHost.scrollAway({
    super.key,
    required this.header,
    required this.child,
    required ScrollController this.controller,
    required double this.headerHeight,
  }) : placement = SokoHeaderPlacement.scrollAway,
       revealAfter = _alwaysVisible,
       onVisibilityChanged = null;

  @override
  State<SokoPinnedHeaderHost> createState() => _SokoPinnedHeaderHostState();
}

double _alwaysVisible() => 0;

class _SokoPinnedHeaderHostState extends State<SokoPinnedHeaderHost> {
  /// Current scroll offset, for [SokoHeaderPlacement.scrollAway].
  ///
  /// `ValueNotifier` rather than `setState` throughout: crossing a threshold or
  /// sliding a 40 px bar must repaint the bar, **not** rebuild the page's
  /// slivers underneath it. Every builder below takes `child` so the page
  /// subtree is passed through untouched.
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  /// Whether a [SokoHeaderPlacement.pinnedOverlay] header is showing.
  final ValueNotifier<bool> _visible = ValueNotifier<bool>(false);

  /// Whether [onVisibilityChanged] has reported at least once.
  ///
  /// **The mount must report even though it is not a transition.** `_visible`
  /// starts `false`, so a page that mounts hidden looks like "no change" and a
  /// pure transition check stays silent — leaving any state the callback is
  /// supposed to clean up still set. The feed hits exactly this: its filter-bar
  /// provider outlives the page, so returning to the feed at the top with the
  /// row still open left an invisible full-screen tap-catcher over the content
  /// until the user tapped it. The listener it replaced ran the cleanup on
  /// every tick, so it never had the gap.
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onScroll);
    // The listener covers every subsequent change; this covers the mount, so a
    // page restored at a non-zero offset does not come up in the wrong state
    // until the user scrolls.
    _scheduleSync();
  }

  /// Sync once the current frame is done, when a position is attached.
  ///
  /// [_sync] bails when the controller has no attached position — true at mount
  /// (before the first layout) and during the update pass that swaps a
  /// controller in. `_reported` stays false through a bail, so the deferred
  /// pass is what actually delivers the first report in those cases.
  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  /// Re-sync whenever the scrollable's METRICS change, whoever caused it.
  ///
  /// The build-time sync above only fires when this host's own parent rebuilds.
  /// A descendant that shrinks on its own — Procura's search results settling
  /// into a short error state, say — collapses the content under the viewport,
  /// `ScrollPosition` clamps the offset during layout **without notifying
  /// listeners** (`correctPixels` deliberately does not), and nothing tells
  /// this host that the comparison in [_sync] has moved. `_visible` stays
  /// latched and both chromes paint at once (PROD-4179, reported on device).
  ///
  /// `ScrollMetricsNotification` is the signal built for exactly this. Returns
  /// `false` so it keeps bubbling — other listeners up the tree are none of
  /// this host's business.
  Widget _metricsSync({required Widget child}) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _scheduleSync();
        return false;
      },
      child: child,
    );
  }

  @override
  void didUpdateWidget(SokoPinnedHeaderHost old) {
    super.didUpdateWidget(old);
    final controllerChanged = old.controller != widget.controller;
    // **Placement counts too.** `_sync` is a no-op under `fixed`, so `_offset`,
    // `_visible` and `_reported` go stale while a host sits in that mode. A
    // parent that later flips to `pinnedOverlay` or `scrollAway` on the SAME
    // controller would then render from that stale state until the user
    // happens to scroll — the overlay staying hidden and skipping its first
    // report, or `scrollAway` painting at offset 0 on an already-scrolled list.
    // (codex, round 6, on the round-5 `fixed` guard.)
    final placementChanged = old.placement != widget.placement;
    if (!controllerChanged && !placementChanged) return;

    if (controllerChanged) {
      old.controller?.removeListener(_onScroll);
      widget.controller?.addListener(_onScroll);
    }

    // A swapped controller is a fresh scrollable; a placement change makes a
    // previously-dormant branch live. Either way the caller has not been told
    // about the state that is now on screen, so the first report is owed again.
    // Without this reset a new controller that happens to match the old
    // visibility is never reported, and a caller relying on
    // `onVisibilityChanged(false)` to clean up keeps stale state until the next
    // scroll. (codex, round 2.)
    _reported = false;
    // **Deferred only — never an immediate `_sync()` here.** During this update
    // pass the tree still holds the OLD arrangement: a swapped controller has
    // no attached position yet (so an immediate call is a no-op — proved by
    // mutation: removing the deferred pass fails the swap test), and a changed
    // placement still has the PREVIOUS scrollable's position attached, so an
    // immediate call answers from layout that is about to be thrown away. That
    // emitted a spurious `true` before the deferred pass corrected it to
    // `false`. One report, after the frame settles.
    _scheduleSync();
  }

  @override
  void dispose() {
    // The controller belongs to the page, not to this host — detach from it,
    // never dispose it. Children unmount before their parent, so this runs
    // while the page's controller is still alive.
    widget.controller?.removeListener(_onScroll);
    _offset.dispose();
    _visible.dispose();
    super.dispose();
  }

  void _onScroll() => _sync();

  void _sync() {
    // `fixed` is outside the scroll view: always visible, never moves, so
    // there is no visibility to report and no offset to track.
    //
    // Since PROD-4101 `.fixed` cannot be given a controller or an
    // `onVisibilityChanged` at all, so this is unreachable from that
    // constructor. It stays because `didUpdateWidget` can put a host into
    // `fixed` at runtime (a parent swapping constructors), and because a guard
    // that costs one comparison is cheaper than reasoning about whether the
    // listener below is live.
    if (widget.placement == SokoHeaderPlacement.fixed) return;

    final controller = widget.controller;
    if (controller == null) return;
    // PROD-3058 — a shared controller can have more than one attached position
    // while a detail route sits above this page, and `controller.position` then
    // throws `StateError: Too many elements` in release, where the debug assert
    // that would catch it is stripped.
    if (controller.positions.length != 1) return;
    final position = controller.position;
    if (!position.hasPixels) return;

    _offset.value = position.pixels;

    final visible = position.pixels >= widget.revealAfter();
    if (!_reported || _visible.value != visible) {
      _reported = true;
      _visible.value = visible;
      widget.onVisibilityChanged?.call(visible);
    }
  }

  @override
  Widget build(BuildContext context) {
    // **A scroll listener alone cannot keep `_visible` true to the page.**
    // Both sides of the comparison in [_sync] move without a scroll gesture:
    //
    // - `position.pixels` changes SILENTLY when the content shrinks under the
    //   viewport. `ScrollPosition` clamps an out-of-range offset during layout
    //   rather than by scrolling, so no notification is delivered and the
    //   listener never runs.
    // - `revealAfter()` is measured during layout by the caller (the feed reads
    //   a sentinel's `precedingScrollExtent`), so it changes on relayout too.
    //
    // The Discovery feed hit exactly the first one. Switching the entity filter
    // empties the block list; the page collapses to shorter than the viewport,
    // `maxScrollExtent` goes to 0 and the offset is clamped from deep in the
    // feed back to the top — with `_visible` still latched `true`. The result
    // is BOTH headers painted at once: the in-flow one at the top of the page
    // and this overlay on top of it, which is not a state D32 allows and which
    // no amount of scrolling caused.
    //
    // ⚠️ **A build is not enough on its own, and PROD-4179 found where.** It
    // covers the case where the PAGE rebuilds — a filter change does, because
    // the page watches the feed. It does not cover a DESCENDANT shrinking on
    // its own: the Procura search results settle inside their own widget, the
    // page never rebuilds, the content collapses under the viewport, the offset
    // is clamped silently, and `_visible` stays latched with both chromes
    // painted. That is why [_metricsSync] wraps the tree below — a
    // `ScrollMetricsNotification` fires whenever the scrollable's metrics
    // change, whoever caused it.
    //
    // A build is one signal that covers both: `_sync` is a comparison and
    // two `ValueNotifier` writes, this widget's `build` deliberately does NOT
    // run on scroll (that is what the notifiers are for), and the callback runs
    // after the layout this build produces — so it reads the settled offset
    // rather than the pre-layout one.
    _scheduleSync();

    // The controller requirement is structural now: only `.fixed` omits it,
    // and only `.fixed` compiles without one (PROD-4101).
    switch (widget.placement) {
      case SokoHeaderPlacement.fixed:
        // Outside the scroll view entirely — no offset involved, so nothing
        // here listens to anything.
        return Column(
          children: [
            widget.header,
            Expanded(child: widget.child),
          ],
        );

      case SokoHeaderPlacement.pinnedOverlay:
        return _metricsSync(
          child: Stack(
            children: [
              Positioned.fill(child: widget.child),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _visible,
                  builder: (context, visible, child) =>
                      visible ? child! : const SizedBox.shrink(),
                  child: widget.header,
                ),
              ),
            ],
          ),
        );

      case SokoHeaderPlacement.scrollAway:
        // Slides up at exactly the scroll rate and stops once it is gone, so
        // it tracks the reserved band at the top of the child's content. Past
        // `headerHeight` it is off-screen and stays there.
        return Stack(
          children: [
            Positioned.fill(child: widget.child),
            ValueListenableBuilder<double>(
              valueListenable: _offset,
              builder: (context, offset, child) => Positioned(
                // `!` is safe structurally, not by assert: the only way to
                // reach this branch is `SokoPinnedHeaderHost.scrollAway`, whose
                // constructor takes a non-nullable `double headerHeight`
                // (PROD-4101). An assert here would have been stripped in
                // release, which is exactly the bug that motivated the split.
                top: -offset.clamp(0.0, widget.headerHeight!),
                left: 0,
                right: 0,
                child: child!,
              ),
              child: widget.header,
            ),
          ],
        );
    }
  }
}
