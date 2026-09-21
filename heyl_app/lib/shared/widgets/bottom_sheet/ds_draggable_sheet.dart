import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/theme/app_colors.dart';
import '../../utils/bottom_sheet_utils.dart';
import 'ds_sheet_shell.dart';

/// The design-system **draggable, snap-height** bottom sheet — the sibling of
/// [DSSheetShell] for content that should open at a partial height and let the
/// user drag/snap between stops.
///
/// Pairs the DS chrome (sokoPaper surface, soft top shadow, drag handle) with
/// a [DraggableScrollableSheet]: the content lives in a single scroll view
/// driven by the sheet's `scrollController`, so — at any stop below the max —
/// a swipe up **first grows the sheet to the next snap, then scrolls** the
/// content (standard `DraggableScrollableSheet` behaviour). Snap stops keep it
/// settling on the configured fractions only.
///
/// Use [showDsDraggableSheet] to present one with the bottom nav hidden; or
/// embed [DSDraggableSheet] directly inside a [DraggableScrollableSheet]
/// builder when you need custom presentation.
///
/// The drag handle scrolls with the content (it's the first item in the scroll
/// view) so a drag anywhere — including on the handle — drives the resize.
///
/// Web: the content is wrapped in a [PointerInterceptor] so the sheet captures
/// its own drag/scroll pointers instead of letting them bleed through to an
/// HTML platform view underneath (e.g. the Mapbox GL canvas on the Map page).
/// This is the same pattern the map results drawer uses; without it the sheet
/// can't be dragged/scrolled over the map. ([PointerInterceptor] is a no-op on
/// native, so this is cross-platform safe.)
class DSDraggableSheet extends StatelessWidget {
  const DSDraggableSheet({
    super.key,
    required this.scrollController,
    required this.child,
    this.showDragHandle = true,
    this.backgroundColor = AppColors.sokoPaper,
    this.backgroundColorListenable,
  });

  /// The controller handed to the builder by [DraggableScrollableSheet] — must
  /// be passed to the internal scroll view so drag-to-resize works.
  final ScrollController scrollController;

  /// Sheet content (e.g. a detail body). Rendered below the drag handle and
  /// scrolled by [scrollController].
  final Widget child;

  final bool showDragHandle;

  /// Sheet surface colour. Defaults to [AppColors.sokoPaper]; the venue / event
  /// pin-tap detail sheets override it with the entity surface colour
  /// (`sokoVenue` blue / `sokoEvent` green) so the drawer matches the
  /// full-screen detail page background.
  ///
  /// Ignored when [backgroundColorListenable] is provided.
  final Color backgroundColor;

  /// A reactive surface colour. When non-null it drives the sheet fill instead
  /// of [backgroundColor], so callers whose content changes identity in place
  /// (the sibling-swipe detail sheet, which crossfades venue-blue ↔ event-green
  /// as you swipe between results) can recolour the whole surface without
  /// rebuilding the scroll view. Only the [DecoratedBox] rebuilds on change.
  final ValueListenable<Color>? backgroundColorListenable;

  @override
  Widget build(BuildContext context) {
    // Enable MOUSE + trackpad drag-to-resize. Modal sheets render via the
    // root navigator, OUTSIDE DiscoveryShell's ScrollConfiguration, so they
    // fall back to Flutter's default touch-only `dragDevices` — that's why
    // the sheet dragged on web-mobile (touch) but not on desktop (mouse).
    // Match the shell's device set so mouse-drag resizes the sheet too.
    final scrollView = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      // MUST be a ListView (not SingleChildScrollView): DraggableScrollableSheet
      // drives the resize through the child ScrollPosition's applyUserOffset,
      // which only grows the sheet when the position reports pixels == 0. The
      // canonical ListView/CustomScrollView shape feeds that correctly; a
      // SingleChildScrollView leaves the sheet stuck at its initial extent
      // (content scrolls but the sheet never resizes). Matches map_results_sheet.
      child: ListView(
        controller: scrollController,
        padding: EdgeInsets.zero,
        children: [
          if (showDragHandle) const SheetDragHandle(),
          SafeArea(top: false, child: child),
          // Breathing room below the content above the home indicator.
          const SizedBox(height: 24),
        ],
      ),
    );

    Widget surface(Color color) => DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        boxShadow: [
          BoxShadow(
            color: AppColors.sokoInk.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: scrollView,
    );

    final listenable = backgroundColorListenable;
    return PointerInterceptor(
      child: listenable == null
          ? surface(backgroundColor)
          // Pass the scroll view as the pre-built `child` so a colour change
          // rebuilds only the DecoratedBox, never the content/scroll position.
          : ValueListenableBuilder<Color>(
              valueListenable: listenable,
              child: scrollView,
              builder: (context, color, child) => DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.sokoInk.withValues(alpha: 0.12),
                      blurRadius: 20,
                      offset: const Offset(0, -4),
                    ),
                  ],
                ),
                child: child,
              ),
            ),
    );
  }
}

/// Presents [content] in a [DSDraggableSheet] with the bottom nav hidden.
///
/// Opens at [initialSize] and snaps between [snapSizes] (defaults to
/// `[initialSize, maxSize]` — i.e. mid ↔ full). Dragging DOWN past mid shrinks
/// toward [minSize] and, on reaching it, dismisses the sheet
/// (`DraggableScrollableSheet.shouldCloseOnMinExtent`, default true) — so
/// [minSize] must stay BELOW [initialSize], otherwise mid == min and the sheet
/// closes the moment it settles at mid. Tap-outside also dismisses. All sizes
/// are viewport fractions.
Future<T?> showDsDraggableSheet<T>({
  required BuildContext context,
  required WidgetRef ref,
  required WidgetBuilder content,
  double initialSize = 0.6,
  double minSize = 0.25,
  double maxSize = 0.95,
  List<double>? snapSizes,
  bool snap = true,
  bool showDragHandle = true,
  Color backgroundColor = AppColors.sokoPaper,
  ValueListenable<Color>? backgroundColorListenable,
  DraggableScrollableController? controller,
}) {
  final min = minSize;
  return showDraggableSheetWithHiddenNav<T>(
    context: context,
    ref: ref,
    controller: controller,
    initialChildSize: initialSize,
    minChildSize: min,
    maxChildSize: maxSize,
    // A content-hugging sheet (see showItemDetailSheet) disables snap: its
    // resting extent is measured, not one of a fixed set, so snapping would
    // yank it back to a fixed stop on the first drag.
    snap: snap,
    snapSizes: snap ? (snapSizes ?? [initialSize, maxSize]) : null,
    // expand:false is the safer modal config — the modal route positions the
    // sheet by its current extent instead of mounting a full-height transparent
    // draggable area over the page. (Note: scroll-at-mid does NOT auto-grow the
    // sheet in the modal-hosted form regardless of this flag; resize is via drag.)
    expand: false,
    // The DraggableScrollableSheet owns ALL vertical dragging (resize). The
    // modal route's own drag-to-dismiss (enableDrag) would compete with it —
    // the classic symptom is content scrolling but the sheet never resizing.
    // Dismiss stays available via tap-outside (isDismissible).
    enableDrag: false,
    builder: (context, scrollController) => DSDraggableSheet(
      scrollController: scrollController,
      showDragHandle: showDragHandle,
      backgroundColor: backgroundColor,
      backgroundColorListenable: backgroundColorListenable,
      child: content(context),
    ),
  );
}
