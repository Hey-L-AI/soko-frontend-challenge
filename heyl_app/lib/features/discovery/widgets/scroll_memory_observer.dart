import 'package:flutter/widgets.dart';

/// Imperative scroll operations on the **Discovery feed**: the "Descobre a
/// cidade" search-overlay snapshot/restore, and the bottom-nav Home-retap
/// "scroll to top".
///
/// **History (PROD-1899).** This file used to host a `NavigatorObserver` that
/// kept a `Map<Route, double>` of per-route offsets and restored them via a
/// post-frame `jumpTo` on a single shell-wide `ScrollController` shared by every
/// route. That existed only because the shared controller had multiple
/// `ScrollPosition`s attached during transitions; it also caused a visible
/// "snap to top then jump" on iOS back-nav (the restore could only run after the
/// CupertinoPage slide settled). The shell now gives **each page its own
/// [ScrollController]** (see `ShellSliverHost`), so a page mounted offstage keeps
/// its offset natively and backing out reveals the feed already in place — no
/// cross-route observer needed.
///
/// What remains are a couple of imperative one-shot ops on the *live* feed.
/// `DiscoveryScreen` owns the feed controller and registers it here (set in
/// `initState`, cleared in `dispose`) so shell-level callers that are NOT
/// descendants of the feed — the bottom nav's [animateToTop] and the search
/// overlay's reset/restore — can act on it without threading it through the
/// tree. In-page descendants that need to *listen* to feed scroll (the map
/// button, the default-content pager) read the same controller reactively via
/// `FeedScrollControllerScope` instead.
class _DiscoveryFeedScroll {
  /// The live Discovery feed controller, registered by `DiscoveryScreen`.
  /// Per-page and single-position, so `controller.position` is unambiguous.
  /// Null when Discovery isn't mounted (cold start / after teardown).
  ScrollController? controller;

  /// Feed offset captured when the search overlay opens. Closing the overlay via
  /// the input's X (nothing left to clear) restores it so the user lands back
  /// where they were.
  double? _homeOffsetBeforeSearch;

  double? _pixels() {
    final c = controller;
    if (c == null || !c.hasClients) return null;
    return c.position.pixels;
  }

  void _jumpTo(double offset) {
    final c = controller;
    if (c == null || !c.hasClients) return;
    final pos = c.position;
    pos.jumpTo(offset.clamp(0.0, pos.maxScrollExtent));
  }

  /// Snapshot the current feed offset, then jump the feed to the top. Called
  /// when the search overlay opens.
  void resetForSearch() {
    _homeOffsetBeforeSearch = _pixels();
    _jumpTo(0);
  }

  /// Restore the offset captured by [resetForSearch] (no-op if none was saved).
  /// Deferred a frame so the feed has re-laid-out before we jump.
  void restoreAfterSearch() {
    final saved = _homeOffsetBeforeSearch;
    _homeOffsetBeforeSearch = null;
    if (saved == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(saved));
  }

  /// Smoothly scroll the feed back to the top. Used when the user re-taps the
  /// Home tab while already on Discovery (#1242). No-op with no live position or
  /// already at the top.
  void animateToTop() {
    final c = controller;
    if (c == null || !c.hasClients) return;
    final pos = c.position;
    if (pos.pixels <= 0) return;
    pos.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
}

/// Singleton feed-scroll helper for Discovery. `DiscoveryScreen` registers its
/// feed controller here; the bottom nav and search overlay drive it.
// ignore: library_private_types_in_public_api
final _DiscoveryFeedScroll discoveryFeedScroll = _DiscoveryFeedScroll();
