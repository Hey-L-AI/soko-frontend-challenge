import 'package:flutter/widgets.dart';

/// Exposes the Discovery feed's [ScrollController] to descendants **and** to
/// page-level siblings of the feed scrollable.
///
/// Post-per-page-controller refactor (PROD-1899): every page mounted under
/// `DiscoveryShell` now owns its OWN [ScrollController] (see `ShellSliverHost`)
/// instead of sharing one shell-level controller. The feed's controller is
/// therefore no longer reachable through the shared `ShellSliverScope`.
/// `DiscoveryScreen` provides this scope around its whole body so the in-page
/// widgets that need to *listen* to feed scroll can still find it:
///
/// - `DefaultContentSection` (infinite-scroll pager) — a descendant of the
///   feed's `CustomScrollView`.
/// - `DiscoveryMapButton` (collapse-on-scroll pill) — a `Positioned` **sibling**
///   of the `ShellSliverHost` in the page `Stack`, so it can't read the
///   controller from inside the scrollable's subtree.
///
/// Shell-level imperative callers (the bottom-nav Home-retap "scroll to top"
/// and the search-overlay reset/restore) are NOT descendants of the feed, so
/// they act on the same controller through `discoveryFeedScroll`
/// (`scroll_memory_observer.dart`), which `DiscoveryScreen` registers the
/// controller into — not through this scope.
class FeedScrollControllerScope extends InheritedWidget {
  /// The Discovery feed's controller, owned by `DiscoveryScreen`.
  final ScrollController controller;

  const FeedScrollControllerScope({
    super.key,
    required this.controller,
    required super.child,
  });

  /// The nearest feed controller, or null when there is none (e.g. a widget
  /// reused outside `DiscoveryScreen`, or mid-build before the scope settles).
  /// Consumers handle null defensively.
  static ScrollController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<FeedScrollControllerScope>()
        ?.controller;
  }

  @override
  bool updateShouldNotify(FeedScrollControllerScope oldWidget) {
    return controller != oldWidget.controller;
  }
}
