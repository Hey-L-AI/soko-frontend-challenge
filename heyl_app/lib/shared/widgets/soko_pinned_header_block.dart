// PROD-4101 — the paper block a pinned header sits in.
//
// `SokoPinnedHeader` owns the 40 px bar. What a user reads as "the header" is
// this block around it: the paper, the top safe-area inset, and the margin
// above and below. Until this file existed that composition lived inside the
// Discovery feed's own page (`discovery_feed_v2_screen.dart::_pinnedChrome`),
// so the only way to build a matching header was to read the feed's source and
// copy it.
//
// **That is not hypothetical.** PROD-4081 built its header from this
// component's documentation — the "Adopting it" snippet plus the
// `SokoHeaderPlacement.fixed` note — followed both to the letter, and landed
// 30 px short (84 px against the feed's 114 at a 44 px notch). The docs were
// correct about their subject, the `SafeArea` ordering, and silent about the
// margins. The first independent adopter, following them, got it wrong on the
// first try; hence this widget.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/page_layout.dart';
import 'soko_pinned_header.dart';

/// The paper block a [SokoPinnedHeader] sits in: `SafeArea(top) → margin → bar
/// → [gap → below] → margin`, on a full-bleed background.
///
/// ```dart
/// SokoPinnedHeaderBlock(
///   child: SokoPinnedHeader(
///     leading: SokoHeaderSlot.back(),
///     centre: SokoHeaderSlot.title(Lt.of(context).profileTitle),
///   ),
/// )
/// ```
///
/// Height is [heightFor] — `topInset + 2 * margin + 40`, plus `gap + below` if
/// a [below] row is present. It is **not** a constant: the notch is only known
/// from `MediaQuery`.
class SokoPinnedHeaderBlock extends StatelessWidget {
  /// The bar. Normally a [SokoPinnedHeader].
  final Widget child;

  /// An optional row hanging under the bar, inside the same paper — the
  /// Discovery feed's filter row — **paired with the gap above it**. Null
  /// renders nothing and costs no height.
  ///
  /// The two travel together as a record rather than as two nullable
  /// parameters so the illegal state cannot be expressed: a `below` without a
  /// `gap` used to be an assert, and an assert is stripped in release, where
  /// the null-unwrap became a crash on first build. (codex.)
  final ({Widget widget, double gap})? below;

  /// Block fill. Defaults to [AppColors.sokoPaper].
  final Color background;

  /// Inset above the bar and below the last row. Defaults to
  /// [kSokoPageMargin], which is the same unit the page keeps to its side
  /// edges — the header's gap to the top edge is the gap content keeps to the
  /// sides, deliberately.
  final double margin;

  const SokoPinnedHeaderBlock({
    super.key,
    required this.child,
    this.below,
    this.background = AppColors.sokoPaper,
    this.margin = kSokoPageMargin,
  });

  /// This block's rendered height, for callers that must reserve it —
  /// [SokoHeaderPlacement.scrollAway]'s `headerHeight`.
  ///
  /// **An instance method, deliberately.** It was a static taking `margin` and
  /// the row's `gap` as arguments, which let a caller build the block with
  /// `gap: 30` and ask the helper for `gap: 24` — two expressions for one
  /// number, disagreeing, compiling. Reading them off `this` instead means the
  /// only thing the caller still supplies is [belowHeight], which is
  /// irreducible: a widget's height is not knowable without laying it out.
  /// (codex, round 2.)
  ///
  /// ```dart
  /// final header = SokoPinnedHeaderBlock(child: SokoPinnedHeader(...));
  /// SokoPinnedHeaderHost.scrollAway(
  ///   controller: _controller,
  ///   headerHeight: header.heightFor(context),
  ///   header: header,
  ///   child: myScrollable,
  /// )
  /// ```
  ///
  /// **Never write the number instead.** It carries `MediaQuery.padding.top`,
  /// so no literal is right on more than one device: `114` is correct on a
  /// 44 px notch and wrong everywhere else.
  ///
  /// ⚠️ Assumes [child] is [kSokoPinnedHeaderHeight] tall — the bar this block
  /// exists for. A taller [child] is not measurable from here, and the result
  /// will be short by the difference. The parity group in this widget's test
  /// pins the canonical composition against the block's **measured** height.
  double heightFor(BuildContext context, {double belowHeight = 0}) {
    final topInset = MediaQuery.of(context).padding.top;
    // Mirrors `build` exactly: the PRESENCE of `below` adds the gap, not its
    // height. An earlier version skipped the gap when the height was 0, so a
    // collapsed row made this under-report by the whole gap while `build`
    // still rendered it. (codex, round 1.)
    final belowExtent = below == null ? 0.0 : below!.gap + belowHeight;
    return topInset + 2 * margin + kSokoPinnedHeaderHeight + belowExtent;
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: background,
      // **The `SafeArea` goes INSIDE the `ColoredBox`, never around it**
      // (PROD-4085, moved here so no adopter can invert it again). A pinned
      // block usually overlays a scrollable, so the paper has to reach y=0
      // while the content starts below the notch. Insetting the whole block
      // clears the notch and leaves a transparent band with page content
      // visibly sliding through the status bar; colouring outside and padding
      // inside gives both.
      //
      // Top only. Horizontal insets are a page-wide decision this widget must
      // not make on the page's behalf, and the bottom belongs to the nav.
      child: SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: margin),
            child,
            if (below != null) ...[SizedBox(height: below!.gap), below!.widget],
            SizedBox(height: margin),
          ],
        ),
      ),
    );
  }
}
