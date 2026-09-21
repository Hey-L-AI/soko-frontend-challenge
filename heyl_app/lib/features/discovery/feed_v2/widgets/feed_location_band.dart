// The feed's location band: "Estás em" against "◎ Avenidas Novas", closed off
// by the scallop rule (Figma `7304-23416`) — **and the same widget morphed into
// the pinned bar**, because the location is the one thing both headers show and
// it must not blink out between them (Zé, 2026-09-01).
//
// It renders in three places, which is what every decision here follows from:
//
//  1. inside [FeedTopHeader] at `t == 0`, scrolling away with the page;
//  2. inside the feed's pinned overlay at `t == 0`, pinned to the top edge from
//     the moment (1) has travelled up to meet it — the two have to be
//     pixel-identical, so they are the same widget with the same argument;
//  3. inside that same overlay with `t` animating to 1, where the prefix and
//     the scallop give way to the bar's filter chip and memories button, and
//     the location **slides** from hard right to just after the chip's "in".
//
// **The location is one widget across the whole of (3).** Cross-fading two
// headers that each own a location would read as one disappearing while another
// appears somewhere else — which is exactly what it replaced. Here there is a
// single [SokoLocationLine] at a single position in the tree, and only where it
// is laid out changes.
//
// Vertical rhythm at `t == 0` is the Figma frame, measured: location box
// `145.06 → 171.06` (26 tall) · **10** · scallop `181.06 → 190.06` (9 tall).
// The scallop is bottom-aligned to the frame, which is why the gap above it is
// 10 and not the 45 the child's reported `y` suggests.

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/scallop_divider.dart';
import '../../../../shared/widgets/soko_pinned_header.dart';

/// Height of the location row at rest, straight from Figma's 26 px text box
/// (`7304:23419`). Fixed rather than let the row size to its tallest child —
/// the 14 px pin icon and an 18 px line box disagree, and the gap below only
/// measures 10 px if the row above it is exactly the frame's 26.
///
/// It grows to [kSokoPinnedHeaderHeight] as the band becomes the bar.
const double kFeedTopHeaderLocationRowHeight = 26;

/// Figma: location box ends 171.06, scallop starts 181.06.
const double kFeedLocationBandRowGap = 10;

/// [FeedLocationBand]'s rendered height **at `t == 0`**.
///
/// **Stated in advance because a pinned overlay has to know how tall the band
/// is before it exists.** The feed reveals the pinned copy at the scroll offset
/// where the in-flow copy's top edge reaches the pinned position, and it finds
/// that offset by subtracting this from the top header's measured trailing
/// edge — the header ends at the scallop, so the band is its last
/// [kFeedLocationBandHeight] px.
///
/// ⚠️ **A second expression for something the widget also builds**, which is
/// the shape of bug PROD-4101 spent a ticket removing. It is summed from the
/// same three constants [build] lays out, and `feed_sticky_location_test.dart`
/// asserts it against the band's **measured** height so the two cannot drift.
/// If you add a row here, the parity test is what will tell you.
const double kFeedLocationBandHeight =
    kFeedTopHeaderLocationRowHeight +
    kFeedLocationBandRowGap +
    ScallopDivider.defaultTileHeight;

/// The band's height once it has fully become the bar — the scallop and its gap
/// have collapsed and the row has grown to the bar's height.
const double kFeedLocationBandBarHeight = kSokoPinnedHeaderHeight;

class FeedLocationBand extends StatelessWidget {
  /// 0 = the band as Figma draws it. 1 = the pinned bar. Everything between is
  /// the transition, and every geometry here is a straight lerp of the two
  /// ends, so both ends are exact rather than approximately right.
  final double t;

  /// The bar's leading half — the filter chip and the "in" — **without a
  /// location**, since this widget owns the one that slides.
  ///
  /// Null below `t == 0`, and the feed only supplies it once `t > 0` so an
  /// invisible button is never mounted over the page waiting to be tapped.
  ///
  /// Its **measured** width is where the location lands: see [_BandToBarLayout].
  final Widget? barLeading;

  /// The bar's trailing half — the memories button, or a zero-width box for the
  /// users who do not get one. Same null-until-`t > 0` rule as [barLeading].
  final Widget? barTrailing;

  const FeedLocationBand({
    super.key,
    this.t = 0,
    this.barLeading,
    this.barTrailing,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Column(
      // Shrink-wraps: this goes inside a `SokoPinnedHeaderBlock`'s
      // `Column(mainAxisSize: min)` as well as inside the top header, and a
      // greedy column there would fight the block for the page's height.
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: lerpDouble(
            kFeedTopHeaderLocationRowHeight,
            kSokoPinnedHeaderHeight,
            t,
          ),
          child: CustomMultiChildLayout(
            delegate: _BandToBarLayout(t: t),
            children: [
              // Paint order is children order, so the location is last: the
              // bar's own paper would otherwise cover it as it fades in.
              LayoutId(
                id: _BandSlot.prefix,
                child: Opacity(
                  opacity: 1 - t,
                  child: Text(
                    l10n.feedTopHeaderLocationPrefix,
                    maxLines: 1,
                    style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
                  ),
                ),
              ),
              if (barLeading != null)
                LayoutId(
                  id: _BandSlot.barLeading,
                  child: Opacity(opacity: t, child: barLeading!),
                ),
              if (barTrailing != null)
                LayoutId(
                  id: _BandSlot.barTrailing,
                  child: Opacity(opacity: t, child: barTrailing!),
                ),
              LayoutId(
                id: _BandSlot.location,
                // **The pinned bar's type, in the top header too** (Zé,
                // 2026-09-01). The band used to draw this at icon 22 while
                // the bar drew it at 14, so sliding one into the other would
                // have had to lerp the icon and the face as well. Matching
                // them makes the slide a pure change of position — and it is
                // the same rendering either side, so nothing about the
                // transition depends on the animation being watched closely.
                //
                // No `Opacity` on it at all: it is on screen throughout, at
                // full strength, in both header states. The bar used to fade
                // it out when the chrome drew its own — that was the
                // two-locations cross-fade PROD-4299 removed.
                child: SokoHeaderSlot.location(),
              ),
            ],
          ),
        ),
        // The gap and the scallop, collapsing together as the band becomes the
        // bar. `heightFactor` shrinks the box while `ClipRect` keeps the rule
        // inside it, so the block's height ends at exactly the bar block's —
        // which is the figure `SokoPinnedHeaderBlock.heightFor` reports and the
        // feed's reveal threshold subtracts.
        ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: 1 - t,
            child: Opacity(
              opacity: 1 - t,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: kFeedLocationBandRowGap),
                  // The tile's flat edge is on TOP with the points hanging
                  // down — the asset draws it the other way up, so this one is
                  // flipped. See the note on [ScallopDivider.inverted].
                  //
                  // `fillWidth` so the rule ends exactly on the page margin.
                  // The default floors to whole tiles and centres the
                  // remainder, which would leave the wave up to 9 px further in
                  // on each side than the row directly above it.
                  ScallopDivider(inverted: true, fillWidth: true),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _BandSlot { prefix, barLeading, barTrailing, location }

/// Positions the location between the two places it lives, and gives it the
/// room each of them leaves.
///
/// **A layout delegate rather than an `Align` with a lerped `Alignment`**,
/// which is the tempting one-liner and does produce both end positions
/// correctly. What it cannot produce is the *width*: at `t == 0` the location
/// may use whatever the prefix leaves — and the prefix is a translated string,
/// "Você está em" being half again as wide as "Estás em" — while at `t == 1` it
/// may use what the bar's two side slots leave. Only a layout pass knows either
/// number.
///
/// **This is also the bar's own layout** (PROD-4299), not just the band's. The
/// bar used to be a `SokoPinnedHeader` handed in whole, which meant two
/// implementations of "where does the location sit in the bar" — this one and
/// `_SlotLayout` — with a parity test standing between them. Laying the bar's
/// two side slots out here instead makes the two ends of the slide the *same*
/// measurement, so they cannot drift, and the location's end position falls out
/// of the same pass that positions the chip.
class _BandToBarLayout extends MultiChildLayoutDelegate {
  _BandToBarLayout({required this.t});

  final double t;

  @override
  void performLayout(Size size) {
    // The prefix, at its natural width, hard left — where `Row`'s
    // `spaceBetween` put it.
    var prefixWidth = 0.0;
    if (hasChild(_BandSlot.prefix)) {
      final prefix = layoutChild(
        _BandSlot.prefix,
        BoxConstraints(maxWidth: size.width, maxHeight: size.height),
      );
      prefixWidth = prefix.width;
      positionChild(
        _BandSlot.prefix,
        Offset(0, (size.height - prefix.height) / 2),
      );
    }

    // The bar's two sides, each at its NATURAL width and at the bar's OWN
    // height rather than the row's. Below `t == 1` the row is shorter than the
    // bar, so they overflow by up to 7 px into the block's 15 px margin — same
    // paper, nothing visible, and the alternative is squashing the chip and the
    // circular button on the way in.
    //
    // ⚠️ **Measured, never assumed, and that is what makes the whole thing
    // work.** The leading group's width changes with the chip's label
    // (`Eventos` / `Sítios` / `Zines`), with the locale's `in` / `em` / `en`,
    // and — frame by frame — with the `AnimatedSize` that eases between two
    // labels. A layout pass is the only thing that knows any of those numbers,
    // and it re-runs whenever a child resizes, so the location follows the chip
    // through a filter change with no extra wiring. Hardcoding this the way the
    // old three-slot bar could (both its slots were 40) would freeze the
    // location at one label's width.
    var leadingWidth = 0.0;
    if (hasChild(_BandSlot.barLeading)) {
      final leading = layoutChild(
        _BandSlot.barLeading,
        BoxConstraints(
          maxWidth: size.width,
          maxHeight: kSokoPinnedHeaderHeight,
        ),
      );
      leadingWidth = leading.width;
      positionChild(
        _BandSlot.barLeading,
        Offset(0, (size.height - leading.height) / 2),
      );
    }

    var trailingWidth = 0.0;
    if (hasChild(_BandSlot.barTrailing)) {
      final trailing = layoutChild(
        _BandSlot.barTrailing,
        BoxConstraints(
          maxWidth: size.width,
          maxHeight: kSokoPinnedHeaderHeight,
        ),
      );
      trailingWidth = trailing.width;
      positionChild(
        _BandSlot.barTrailing,
        Offset(
          size.width - trailing.width,
          (size.height - trailing.height) / 2,
        ),
      );
    }

    // **Lerp the location's BOX, then place it inside — not its width and its
    // left edge independently.**
    //
    // The bar's rule is the sentence's: the location sits immediately after the
    // "in" and takes everything the memories button leaves. It is NOT centred —
    // the old three-slot bar reserved 40 a side precisely so its centre could
    // not move, and this one deliberately reads as `[chip] in <place>` instead.
    // A non-admin's trailing slot measures 0, so the location simply gets the
    // width back rather than the row re-balancing around a missing button.
    //
    // ⚠️ **Why the box and not the two numbers.** Lerping `width` and `left`
    // separately is the obvious shape and it is subtly wrong: `right` is then
    // `lerp(a) + lerp(b)`, which is not bounded by either end's right edge. On
    // a long place name the bar's room is NARROWER than the band's while the
    // left edge travels RIGHT, and halfway through the location overflowed the
    // content column by 12 px — measured, not hypothetical. Interpolating the
    // two edges keeps the child inside the box at every `t` by construction:
    // the width can never exceed the room, and the offset is pinned between the
    // box's own edges.
    final boxLeft = lerpDouble(prefixWidth, leadingWidth, t)!;
    final boxRight = lerpDouble(size.width, size.width - trailingWidth, t)!;
    final room = math.max(0.0, boxRight - boxLeft);

    final location = layoutChild(
      _BandSlot.location,
      BoxConstraints(maxWidth: room, maxHeight: size.height),
    );

    // Right-aligned in the band (hard right, where `spaceBetween` put it),
    // left-aligned in the bar (immediately after the "in"). Both ends exact.
    final x = lerpDouble(boxRight - location.width, boxLeft, t)!;
    positionChild(
      _BandSlot.location,
      Offset(x, (size.height - location.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_BandToBarLayout old) => old.t != t;
}
