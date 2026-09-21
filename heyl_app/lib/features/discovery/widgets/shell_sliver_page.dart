import 'package:flutter/cupertino.dart'
    show CupertinoSliverRefreshControl, RefreshIndicatorMode;
import 'package:flutter/widgets.dart';

import '../../../core/theme/page_layout.dart';

/// Inherited scope exposed by `DiscoveryShell` to its routed `child` when
/// the active route is registered as sliver-aware (see
/// `_isShellSliverRoute` in `discovery_shell.dart`). Pages on a
/// sliver-aware route consume this via [ShellSliverScope.of] inside a
/// [ShellSliverHost] to build their own `CustomScrollView` with the
/// shell's chrome reservation, scroll controller, physics, and optional
/// pull-to-refresh handler.
///
/// **Why this exists.** The legacy shell wraps every page in
/// `SliverToBoxAdapter(child: PageContent(child: widget.child))`, which
/// makes the whole page one indivisible block from the viewport's
/// perspective — every row of a long list is built eagerly on first
/// paint (PROD-1967 trigger). To unlock real viewport culling for
/// long-list pages, the page itself owns the `CustomScrollView` and
/// emits its long list as a `SliverList.builder`. The shell still owns
/// the controller and the chrome metadata; both flow into the page via
/// this scope.
///
/// **Why an InheritedWidget instead of a marker mixin.** A marker mixin
/// would require the page widget's `build()` to return a sliver — but
/// the inner Navigator built by `ShellRoute` wraps every routed page in
/// `Semantics`/`Focus`/`RepaintBoundary` (all `RenderBox` widgets) before
/// mounting. A page's `build()` therefore MUST return a `RenderBox` to
/// satisfy that wrapping chain. [ShellSliverHost] is a `RenderBox`
/// widget that produces a `CustomScrollView` (also a `RenderBox`)
/// containing slivers as its children — the right shape for both
/// constraints.
class ShellSliverScope extends InheritedWidget {
  /// Top spacer height the page must prepend as a sliver so its content
  /// clears the floating `PinnedPageChrome`. Equal to the value the
  /// legacy shell uses, computed by `PinnedPageChrome.reservedHeight`.
  final double chromeReserved;

  /// The physics the shell would have applied to its own
  /// `CustomScrollView` — bouncing on feed-shaped routes (so
  /// `CupertinoSliverRefreshControl` can expand on overscroll), clamping
  /// elsewhere.
  final ScrollPhysics physics;

  /// Bound feed-refresh callback for the active route, or null on
  /// non-feed routes. Pages should add a `CupertinoSliverRefreshControl`
  /// between the chrome spacer and their content slivers when this is
  /// non-null — see `docs/learnings/cupertino-sliver-refresh-for-feeds.md`.
  /// [ShellSliverHost] handles this for you.
  final Future<void> Function()? onFeedRefresh;

  /// Cache window forwarded to the page's `CustomScrollView`. Larger
  /// than Flutter's framework default (250) so that long lists build
  /// enough rows for `SliverList.estimateMaxScrollOffset` to return a
  /// usable extent. ≈ one mobile viewport.
  final double cacheExtent;

  const ShellSliverScope({
    super.key,
    required this.chromeReserved,
    required this.physics,
    required this.onFeedRefresh,
    required this.cacheExtent,
    required super.child,
  });

  /// Returns the nearest [ShellSliverScope] in the ancestor chain, or
  /// null if none. `DiscoveryShell` provides the scope on every
  /// non-full-bleed route, so a missing scope means the widget is
  /// either (a) on the chat full-bleed branch, (b) mounted outside
  /// `DiscoveryShell` (preview / test), or (c) being rebuilt during a
  /// transition where the ancestor chain hasn't settled. Consumers
  /// handle null defensively rather than asserting — see
  /// [ShellSliverHost].
  static ShellSliverScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ShellSliverScope>();
  }

  @override
  bool updateShouldNotify(ShellSliverScope oldWidget) {
    return chromeReserved != oldWidget.chromeReserved ||
        physics != oldWidget.physics ||
        onFeedRefresh != oldWidget.onFeedRefresh ||
        cacheExtent != oldWidget.cacheExtent;
  }
}

/// Drop-in widget for sliver-aware pages. Consumes [ShellSliverScope]
/// and builds a `CustomScrollView` with the shell's chrome spacer +
/// optional refresh control + the page's [slivers].
///
/// Use this from a page's `build()` when the active route is registered
/// as sliver-aware in the shell:
///
/// ```dart
/// @override
/// Widget build(BuildContext context) {
///   return ShellSliverHost(slivers: [
///     SliverToBoxAdapter(child: header),
///     SliverList.builder(itemCount: items.length, itemBuilder: ...),
///     SliverToBoxAdapter(child: footer),
///   ]);
/// }
/// ```
///
/// **Ordering invariant** (enforced by this widget — do not reproduce
/// in [slivers]):
/// 1. `CupertinoSliverRefreshControl` (when
///    [ShellSliverScope.onFeedRefresh] is non-null) — MUST be first so
///    its `SliverConstraints.overlap` receives the viewport's negative
///    overscroll signal directly. Any sliver above it clamps overlap to
///    0 via the viewport's `maxPaintOffset` upper-bound. PROD-2065.
/// 2. Chrome-reservation spacer (from [ShellSliverScope.chromeReserved])
/// 3. The page's own [slivers]
///
/// The spinner therefore renders at the very top of the viewport, behind
/// `PinnedPageChrome`. On Discovery / Yours / other feed routes the
/// chrome is empty (`_resolveSpec` returns null → `reservedHeight = 0`),
/// so the spinner is fully visible. On list-detail (chrome carries a
/// back arrow + title) the spinner sits behind the chrome — accepted
/// tradeoff vs not firing at all.
///
/// **Pull-to-refresh callback** is wired automatically when the scope's
/// `onFeedRefresh` is set; pages don't need to read or thread it.
///
/// **Scroll controller (PROD-1899).** Each host owns its own
/// [ScrollController] by default — a single [ScrollPosition] per page — so a
/// page mounted offstage keeps its scroll offset natively and backing out of a
/// detail reveals the feed already at its offset (no cross-route restore, no
/// visible jump). Pages that need their controller visible to page-level
/// siblings (the Discovery feed shares it with `DiscoveryMapButton` /
/// `DefaultContentSection` / the search overlay via `FeedScrollControllerScope`)
/// pass one in via [controller]; the host uses it instead of creating its own
/// and does NOT dispose a borrowed controller.
class ShellSliverHost extends StatefulWidget {
  /// The page's own slivers, appended after the shell's chrome spacer +
  /// optional refresh control. Each element must be a sliver
  /// (`SliverToBoxAdapter`, `SliverList`, `SliverGrid`, `SliverPadding`,
  /// `SliverFillRemaining`, `SliverMainAxisGroup`, ...).
  final List<Widget> slivers;

  /// Optional controller supplied by the page. When null, the host creates and
  /// owns one for its lifetime. When non-null, the host uses it and leaves its
  /// disposal to the owner (the page).
  final ScrollController? controller;

  /// Whether dragging the page should put an on-screen keyboard away.
  ///
  /// PROD-4179 — the feed passes `onDrag` because Procura puts a live text
  /// field in its header: typing and then scrolling used to leave the keyboard
  /// covering the results the reader was scrolling toward.
  ///
  /// **Defaults to `manual`, which is the framework's own default** — every
  /// other page that mounts this host keeps exactly the behaviour it had.
  ///
  /// Two properties of `onDrag` worth knowing before adopting it elsewhere,
  /// both from `scroll_view.dart`'s handler rather than from inference:
  ///
  ///  * it fires only when `notification.dragDetails != null`, so a **mouse
  ///    wheel or trackpad scroll does not dismiss anything** — desktop web can
  ///    scroll a page while a field keeps focus, and no `kIsWeb` gate is
  ///    needed to get that;
  ///  * the listener sits above the whole scrollable, so a notification from a
  ///    *nested* scrollable (the horizontal chip row inside the feed's chrome)
  ///    bubbles into it and also dismisses. Swiping the chips putting the
  ///    keyboard away is a reasonable reading of the gesture, so this is left
  ///    as-is rather than filtered by depth.
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  const ShellSliverHost({
    super.key,
    required this.slivers,
    this.controller,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  });

  @override
  State<ShellSliverHost> createState() => _ShellSliverHostState();
}

class _ShellSliverHostState extends State<ShellSliverHost> {
  /// Non-null only when the host owns its controller (no [widget.controller]
  /// was supplied). Disposed in [dispose].
  ScrollController? _owned;

  ScrollController get _controller => widget.controller ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _owned = ScrollController();
  }

  @override
  void didUpdateWidget(ShellSliverHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reconcile if a page ever toggles between owning and borrowing a
    // controller (not expected in practice, but keep the invariant sound).
    if (widget.controller == null && _owned == null) {
      _owned = ScrollController();
    } else if (widget.controller != null && _owned != null) {
      _owned!.dispose();
      _owned = null;
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ShellSliverScope.maybeOf(context);
    if (scope == null) {
      // PROD-1977: `DiscoveryShell` provides [ShellSliverScope] on every
      // non-full-bleed route. A missing scope means the page is mounted
      // outside `DiscoveryShell` (preview / test / accidentally inside
      // the full-bleed chat branch). Render an inert placeholder rather
      // than asserting — the shell's tree shape is constant on the
      // standard navigation path, so this branch should not fire in
      // production.
      assert(() {
        debugPrint(
          'ShellSliverHost: no ShellSliverScope in ancestor chain. Mounted '
          'outside DiscoveryShell? Rendering SizedBox.shrink().',
        );
        return true;
      }());
      return const SizedBox.shrink();
    }
    // PROD-1977: apply the desktop max-width column at the host level
    // so EVERY page gets it for free, including pages whose slivers are
    // raw `SliverList`/`SliverPadding` etc. (which take the viewport's
    // full cross-axis by default). Pre-migration this was done by
    // `PageContent` at the shell level wrapping the routed `child`; now
    // each page's slivers are constrained via `SliverPadding` here. The
    // chrome spacer + refresh control are also wrapped so the
    // pull-to-refresh indicator centers with the content column on
    // desktop. Pages that wrap their own content in [PageContent] still
    // work — `PageContent`'s ConstrainedBox(maxWidth: 480) becomes a
    // no-op when the outer constraint is already 480.
    //
    // **Why we ALWAYS wrap in `SliverPadding`, even when the padding
    // is zero**: same reason `PageContent` (`page_layout.dart`) always
    // returns `Center > ConstrainedBox` regardless of viewport size —
    // keeping the widget-tree shape constant across the 600 px
    // breakpoint avoids the dispose-and-remount churn that resets
    // descendant State (e.g. `_ListZineViewState`'s `TurnPageController`
    // snapping back to page 0). Conditionally wrapping (`padding > 0 ?
    // SliverPadding(...) : sliver`) reintroduces that bug as soon as
    // the user drags the desktop viewport past 600 px in either
    // direction.
    final viewportWidth = MediaQuery.of(context).size.width;
    final horizontalPadding = viewportWidth < PageLayout.desktopBreakpoint
        ? 0.0
        : (viewportWidth - PageLayout.desktopContentMaxWidth) / 2;
    final pagePadding = EdgeInsets.symmetric(horizontal: horizontalPadding);

    SliverPadding constrain(Widget sliver) =>
        SliverPadding(padding: pagePadding, sliver: sliver);

    // PROD-2065: `CupertinoSliverRefreshControl` MUST be the first sliver.
    //
    // The render viewport propagates overscroll to slivers via
    // `SliverConstraints.overlap`, computed as `maxPaintOffset - layoutOffset`
    // where `maxPaintOffset` is initialized to `layoutOffset + overlap`
    // (overlap is negative during overscroll, e.g. -50). After each sliver
    // lays out, the viewport runs:
    //
    //   maxPaintOffset = math.max(
    //     effectiveLayoutOffset + childLayoutGeometry.paintExtent,
    //     maxPaintOffset,
    //   );
    //
    // `math.max` only goes up. So a single zero-extent sliver above the
    // refresh control clamps maxPaintOffset from -50 to 0, and the refresh
    // control then sees overlap = 0 and stays inactive (see
    // `_RenderCupertinoSliverRefresh.performLayout` at
    // `flutter/lib/src/cupertino/refresh.dart:133`, where
    // `active = constraints.overlap < 0.0 || layoutExtent > 0.0`).
    //
    // The pre-PROD-1977 shell shape `[chromeSpacer, refresh, body]` looked
    // like it worked but actually had the same bug — verified empirically
    // on this branch under PROD-2065 with `NotificationListener` +
    // `CupertinoSliverRefreshControl.builder` instrumentation: the
    // scrollable reaches `pixels = -253` during overscroll yet the refresh
    // sliver's `builder` is never invoked.
    //
    // Putting the refresh control first means its spinner renders at the
    // top of the viewport, behind `PinnedPageChrome`. On Discovery (`/`)
    // and Yours (`/yours`) chrome is empty (`_resolveSpec` returns null →
    // `reservedHeight = 0`), so the spinner is fully visible. On
    // list-detail (where chrome carries a back arrow + title) the spinner
    // sits behind the chrome — accepted tradeoff vs not firing at all;
    // revisit if that surface needs a better affordance.
    // PROD-2065 (follow-up): the refresh control's spinner is bottom-
    // aligned within the sliver's region, and the sliver starts at the
    // very top of the viewport (y=0). On devices with a top safe-area
    // inset (iOS notch / dynamic island) the spinner sat *behind* the
    // status bar / dynamic island and the user never saw it. Fix:
    //   1. Bump `refreshIndicatorExtent` by `topInset` so the sliver's
    //      at-rest region is tall enough to fully clear the unsafe area.
    //   2. Provide a `builder` that wraps the default indicator in a
    //      `Padding(top: topInset)` so the inner default-builder lays
    //      out in (region - topInset), pushing the visible indicator
    //      below the status bar. Pass `extent - topInset` to the inner
    //      builder so its internal `SizedBox(height: percent * (extent
    //      - 16))` sizes for the visible region, not the full sliver.
    final topInset = MediaQuery.of(context).padding.top;
    // PROD-1899: belt-and-suspenders pre-paint restore. The per-page controller
    // already preserves the offset while the page stays mounted; the
    // PageStorageKey additionally restores it (via `restoreScrollOffset` in the
    // position ctor, before first paint) if the page's scrollable is ever fully
    // recreated. Keyed by route name; each `ModalRoute` carries its own
    // PageStorage bucket, so this needs to be unique only within a single
    // route's subtree (one host per page) — a route-name key suffices.
    final routeName = ModalRoute.of(context)?.settings.name;
    return CustomScrollView(
      key: PageStorageKey<String>('shell-sliver-${routeName ?? 'unknown'}'),
      controller: _controller,
      physics: scope.physics,
      cacheExtent: scope.cacheExtent,
      keyboardDismissBehavior: widget.keyboardDismissBehavior,
      slivers: [
        if (scope.onFeedRefresh != null)
          CupertinoSliverRefreshControl(
            onRefresh: scope.onFeedRefresh!,
            // PROD-2065: Both extents grow by `topInset` so the assertion
            // `refreshTriggerPullDistance >= refreshIndicatorExtent`
            // (refresh.dart:309) still holds. Default ratio (trigger
            // 100 / indicator 60) is preserved.
            refreshTriggerPullDistance: 100 + topInset,
            refreshIndicatorExtent: 60 + topInset,
            builder:
                (
                  BuildContext context,
                  RefreshIndicatorMode mode,
                  double pulled,
                  double trigger,
                  double extent,
                ) {
                  return Padding(
                    padding: EdgeInsets.only(top: topInset),
                    child: CupertinoSliverRefreshControl.buildRefreshIndicator(
                      context,
                      mode,
                      pulled,
                      trigger - topInset,
                      extent - topInset,
                    ),
                  );
                },
          ),
        constrain(
          SliverToBoxAdapter(child: SizedBox(height: scope.chromeReserved)),
        ),
        ...widget.slivers.map(constrain),
      ],
    );
  }
}
