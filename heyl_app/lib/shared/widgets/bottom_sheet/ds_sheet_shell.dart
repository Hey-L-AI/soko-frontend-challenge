import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Standard chrome for every bottom sheet in the app — extracted from the
/// PROD-1804 chat sheet template (`places_map_modal.dart`).
///
/// Wraps content with the design-system look (`AppColors.sokoPaper`
/// background, top-only 20 px radius, soft `sokoInk @ 12 %` shadow) and lays
/// out three optional slots: drag handle, header, body, footer. The footer
/// stays pinned to the viewport bottom while the body scrolls between it and
/// the header.
///
/// Example — sticky footer:
/// ```dart
/// DSSheetShell(
///   header: const _SheetTitle('Add to list'),
///   body: ListView(...),       // scrolls
///   footer: const _SaveButton(),
/// )
/// ```
///
/// Example — intrinsic height, no footer:
/// ```dart
/// DSSheetShell(
///   body: Column(mainAxisSize: MainAxisSize.min, children: [...]),
/// )
/// ```
class DSSheetShell extends StatelessWidget {
  const DSSheetShell({
    super.key,
    required this.body,
    this.header,
    this.footer,
    this.showDragHandle = true,
    this.maxHeightFraction = 0.92,
    this.bodyPadding = EdgeInsets.zero,
  });

  final Widget body;
  final Widget? header;
  final Widget? footer;
  final bool showDragHandle;

  /// Cap on sheet height as a fraction of the device viewport. Defaults to
  /// 0.92 so a fingertip can still drag the sheet down from the top edge.
  final double maxHeightFraction;

  /// Padding applied to the body slot only — does not affect header/footer
  /// so they can span the sheet edge-to-edge (e.g. pink header banner in
  /// PROD-1861 Add-to-list).
  final EdgeInsets bodyPadding;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context).height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: viewport * maxHeightFraction),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.sokoPaper,
          // Square top corners (was 20 px radius). The sheet reads as a
          // clean horizontal cut against the underlying page instead of
          // a soft pill that competes with the rounded surfaces inside
          // the sheet body.
          borderRadius: BorderRadius.zero,
          boxShadow: [
            BoxShadow(
              color: AppColors.sokoInk.withValues(alpha: 0.12),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showDragHandle) const SheetDragHandle(),
              if (header != null) header!,
              Flexible(
                child: Padding(padding: bodyPadding, child: body),
              ),
              if (footer != null) footer!,
            ],
          ),
        ),
      ),
    );
  }
}

/// 40 × 4 px drag handle in `AppColors.sokoShade4`, centered with 12/8 px
/// top/bottom padding. Matches the PROD-1804 chat sheet handle.
class SheetDragHandle extends StatelessWidget {
  const SheetDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.sokoShade4,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}
