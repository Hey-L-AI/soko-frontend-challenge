import 'package:flutter/material.dart';

/// Shared layout primitive for redesign pages.
///
/// Lifted out of the original `DiscoveryShell` per
/// `docs/designs/venue-event-details-redesign.md` § 5.1, so every redesign
/// page (Discovery, venue detail, event detail, future redesigns) reads the
/// same breakpoint + max-width from one place. Tuning happens here, not at
/// each call site.
///
/// Below [desktopBreakpoint] (phones) the content fills the viewport.
/// At or above the breakpoint, the content is centred inside a column
/// capped at [desktopContentMaxWidth] — the editorial card chrome was
/// authored against ~430-px Figma frames, so growing past ~480 stretches
/// imagery out of proportion to the fixed-size text blocks.
class PageLayout {
  PageLayout._();

  /// Viewport width at or above which the redesign centres its content
  /// inside a max-width column. Below this, content fills the viewport.
  /// Matches Material Design's compact -> medium boundary.
  static const double desktopBreakpoint = 600;

  /// Max width of the centred content column on desktop / large tablets.
  static const double desktopContentMaxWidth = 480;
}

/// The page's margin unit: the gap between content and the viewport edge, and
/// the vertical inset of a pinned header's block above and below its bar.
/// **One number because it is one margin.**
///
/// **Why 15.** Figma's frames (`7304-23416`, `7304-23430`, `7304-24495`) are
/// **400 px wide against a 430 px mobile viewport** — the 400 is the CONTENT
/// column and the missing 30 is this margin, 15 a side. Everything in those
/// frames is laid out against x0…x400, so once the page supplies the margin no
/// widget should add horizontal padding of its own. Before this existed it was
/// spelled `16` in four separate widgets and `0` in the scallop, so the rule
/// read as "16 px, except the wavy line, which is full-bleed".
///
/// On viewports at or above [PageLayout.desktopBreakpoint] the column is capped
/// and centred by [PageContent] and the viewport-edge gap is much larger; this
/// stays the inset *within* that column, so the composition inside the content
/// area is identical at every width.
///
/// Lives here rather than in the feed (where it started, as `kFeedPageMargin`)
/// because `SokoPinnedHeaderBlock` needs it and `shared/` cannot depend on a
/// feature — PROD-4101.
const double kSokoPageMargin = 15;

/// Centres [child] inside a max-width column on viewports
/// >= [PageLayout.desktopBreakpoint], full-bleed otherwise.
///
/// **Tree structure is constant across the breakpoint** — the
/// `Center > ConstrainedBox > child` chain always renders, and only
/// the [BoxConstraints.maxWidth] flips between `infinity` (mobile)
/// and [PageLayout.desktopContentMaxWidth] (desktop). Earlier this
/// widget returned `child` bare under the breakpoint and a wrapped
/// subtree above it, which forced Flutter to dispose + remount the
/// entire descendant tree every time the user dragged the viewport
/// across 600 px — that triggered framework assertions in
/// `framework.dart:2168` (`_elements.contains(element)`) and
/// `object.dart:2524` whenever any descendant held state Flutter
/// expected to persist across the rebuild.
class PageContent extends StatelessWidget {
  final Widget child;

  const PageContent({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final maxWidth = width < PageLayout.desktopBreakpoint
        ? double.infinity
        : PageLayout.desktopContentMaxWidth;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Full-bleed sibling of [PageContent] for surfaces that fill the whole
/// viewport height and lay out via [Positioned.fill] (maps, immersive
/// media). [PageContent]'s [Center] loosens the incoming height
/// constraint, which collapses a `Stack` whose only children are
/// positioned — so those surfaces need this variant, which caps the
/// **width** at [PageLayout.desktopContentMaxWidth] on desktop while
/// keeping the child stretched to the full available **height**.
///
/// Below [PageLayout.desktopBreakpoint] it is a no-op (full-bleed). On
/// desktop it centres a fixed-width, full-height column; the caller is
/// expected to paint the surrounding margin (e.g. a `ColoredBox` /
/// `Scaffold.backgroundColor` in `AppColors.sokoPaper`).
class FullHeightPageContent extends StatelessWidget {
  final Widget child;

  const FullHeightPageContent({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width < PageLayout.desktopBreakpoint) return child;
    return Center(
      child: SizedBox(
        width: PageLayout.desktopContentMaxWidth,
        height: double.infinity,
        child: child,
      ),
    );
  }
}
