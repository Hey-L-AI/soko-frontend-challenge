import 'package:flutter/widgets.dart';

import '../providers/map_ui_state_provider.dart';

/// PROD-3043 — all of the results drawer's geometry, in one place.
///
/// The drawer is a [DraggableScrollableSheet], which speaks in **fractions of
/// its box**. Two traps live here, so every fraction is derived through
/// [MapDrawerMetrics.resolve] rather than computed at the call site:
///
/// 1. **The box is NOT the screen.** `/map` renders inside `DiscoveryShell`
///    with the **bottom nav visible** (`mapPageName` is deliberately not in
///    `_navHiddenOnRoute` — see `discovery_shell.dart`). So the sheet's box is
///    `screenH - bottomNav`, which is what the sheet's own `LayoutBuilder`
///    measures. Dividing by `MediaQuery.sizeOf(context).height` instead would
///    make peek ~80 px short and **clip the question buttons**.
/// 2. **The snap list must satisfy the SDK's asserts** — every stop within
///    `[min, max]` and strictly ascending. A short screen or a large text scale
///    can otherwise collapse `full` below `half`. [MapDrawerMetrics.resolve]
///    degrades instead: it drops `half`, and finally locks to a single stop.

/// The vertical extent of the Map page's **top chrome** — safe area + the back
/// button / search row + the shortcut-chips row beneath it (which collapses to
/// the single centred "Reset all filters" button once a non-default filter is
/// on; same height).
///
/// This is the map CAMERA's top padding (`viewportPaddingTop`): the search-area
/// framing keeps clear of the WHOLE chrome so pins aren't hidden behind it. The
/// drawer's [MapDrawerSnap.full] stop uses the shorter [mapDrawerFullTopInset]
/// instead — it deliberately covers the chips row (PROD-2993).
double mapTopChromeInset(BuildContext context) =>
    MediaQuery.paddingOf(context).top + 16 + 44 + 8 + 30;

/// The chrome ABOVE the drawer's [MapDrawerSnap.full] stop — safe area, the top
/// pad and the back/search **row only**, NOT the shortcut-chips row.
///
/// So the full drawer parks just below the search bar and its grid **covers**
/// the shortcut-chips row, reclaiming that height (PROD-2993). The camera still
/// reserves the chips via [mapTopChromeInset]; the two are deliberately distinct.
double mapDrawerFullTopInset(BuildContext context) =>
    MediaQuery.paddingOf(context).top + 16 + 44;

/// Breathing room between [mapDrawerFullTopInset] (the back/search row) and the
/// drawer's top edge at [MapDrawerSnap.full] — a small gap below the search bar.
/// Kept ≤ the 8 px that separates the search row from the chips, so the full
/// drawer clears the search bar yet still fully covers the chips row it now sits
/// over (PROD-2993).
const double kMapDrawerFullTopMargin = 8;

/// PROD-2993 — the drawer-width boundary between the two `half` layouts.
///
/// **Below** this width (phones), `half` is the one-card horizontal carousel with
/// pin highlighting. **At or above** it, `half` and `full` are both the
/// multi-column grid — no carousel, no highlight, no camera freeze — because a
/// wide `half` has room for a real grid and one-card-at-a-time reads as
/// unnatural there. Matches `PageLayout.desktopBreakpoint` (600).
const double kMapWideDrawerMinWidth = 600;

/// PROD-2993 — where `half` sits, as a fraction of the box, on **wide** viewports.
///
/// Wide `half` is a short SCROLLING grid, so — unlike the narrow one-card
/// carousel — it needn't be an integer number of card rows. A grid card is
/// ~343 px tall, so a row-derived `half` won't fit clear of `full` on a short
/// desktop window and the metric would degrade it away (you'd only get
/// peek↔full). A plain fraction always fits and the grid shows whatever lands
/// in it and scrolls. Tunable — a device-QA judgement.
const double kMapWideHalfFraction = 0.6;

/// PROD-2993 — height of the drawer's **top grab strip**: an invisible drag
/// zone over the drag handle that resizes the sheet directly (see the sheet's
/// Stack). A touch above the [kMapDrawerOpenHeaderPx] handle so it's an easy
/// target, but short enough not to swallow the first card row's taps.
const double kMapDrawerTopGrabPx = 40;

/// Minimum separation between two snap stops. Below this they're
/// indistinguishable to a drag, and the SDK's strictly-ascending assert is at
/// risk — so the stop is dropped instead.
const double _kMinSnapGap = 0.06;

/// The drawer header's height for a given collapse fraction (PROD-3090) —
/// [kMapDrawerHeaderPx] at `0`, [kMapDrawerOpenHeaderPx] at `1`.
///
/// One function, two callers that MUST agree to the pixel: the sliver header's
/// delegate (which reserves the extent) and the header widget's own `Align`
/// (which fills it). If they ever disagreed, the count row would either be
/// clipped or leave a gap.
double mapDrawerHeaderHeight(double collapseT) =>
    kMapDrawerOpenHeaderPx +
    kMapDrawerCountRowPx * (1 - collapseT.clamp(0.0, 1.0));

/// The drawer's resolved snap geometry for one layout pass.
@immutable
class MapDrawerMetrics {
  const MapDrawerMetrics._({
    required this.peek,
    required this.half,
    required this.full,
    required this.snaps,
    required this.locked,
  });

  /// The floor. The drawer never goes below this — the question buttons stay
  /// reachable at all times (PROD-3043 decision #2).
  final double peek;

  /// The mid stop — exactly one row of result cards (PROD-3090). Falls back to
  /// [full] when it can't sit clear of both neighbours, and to [peek] when
  /// [locked].
  final double half;

  /// The ceiling — parked just below the top chrome, never over it.
  final double full;

  /// Ascending, de-duplicated, all within `[peek, full]` — safe to hand to
  /// `DraggableScrollableSheet.snapSizes`.
  final List<double> snaps;

  /// No results (or no room to move): the sheet is pinned at [peek] and the
  /// grid must not scroll. `min == max == initial == peek`, `snaps == [peek]`.
  final bool locked;

  /// Resolve the geometry.
  ///
  /// [boxHeight] MUST come from the sheet's own `LayoutBuilder` (see trap 1 in
  /// the file doc), [chromeHeight] is the measured peek chrome (grows when a
  /// filter's option row opens), [cardRowHeight] is the height of one row of
  /// result cards at the current width (`MapResultsGrid.cardRowHeightFor`, which
  /// caps it so it can't balloon), [topChromeInset] is [mapTopChromeInset].
  /// [halfFractionOverride], when non-null, places `half` at that fraction of
  /// the box directly instead of deriving it from [cardRowHeight] — used on wide
  /// viewports where `half` is a scrolling grid, not a one-card carousel (see
  /// [kMapWideHalfFraction]). It still passes the same fit check, so a viewport
  /// with no room degrades to peek↔full exactly as a row-derived `half` would.
  factory MapDrawerMetrics.resolve({
    required double boxHeight,
    required double chromeHeight,
    required double cardRowHeight,
    required double topChromeInset,
    required bool hasResults,
    double? halfFractionOverride,
  }) {
    // Pre-layout / degenerate box — hand back a valid single-stop sheet rather
    // than dividing by zero.
    if (boxHeight <= 0) {
      return const MapDrawerMetrics._(
        peek: 1,
        half: 1,
        full: 1,
        snaps: <double>[1],
        locked: true,
      );
    }

    final double peek = (chromeHeight / boxHeight).clamp(0.05, 1.0);
    // The ceiling: stop [kMapDrawerFullTopMargin] below the top chrome. Never
    // let it fall below peek (a very short screen with very tall chrome).
    final double full =
        ((boxHeight - topChromeInset - kMapDrawerFullTopMargin) / boxHeight)
            .clamp(peek, 1.0);

    // Nothing to show, or no room to travel → one stop, drag is inert.
    if (!hasResults || full - peek < _kMinSnapGap) {
      return MapDrawerMetrics._(
        peek: peek,
        half: peek,
        full: peek,
        snaps: <double>[peek],
        locked: true,
      );
    }

    // PROD-3090 — the mid stop shows exactly ONE row of cards and nothing more.
    //
    // Composed from the chrome the drawer actually renders when open, so the
    // card's bottom edge lands precisely on the footer's top edge:
    //
    //   half = open header + grid top pad + one card row + footer
    //
    // The footer isn't passed in separately — `chromeHeight` is `header +
    // footer`, and the header sheds its count row on opening, so subtracting
    // that shed height off `chromeHeight` leaves exactly `openHeader + footer`.
    //
    // This replaces a blunt `peek + 0.42` of the box, which bore no relation to
    // the card it existed to reveal (and so overshot it).
    final double halfPx =
        chromeHeight -
        kMapDrawerHeaderCollapsePx +
        kMapDrawerGridTopPadPx +
        cardRowHeight;
    final double candidate = halfFractionOverride ?? (halfPx / boxHeight);
    // Keep it only if it sits clear of BOTH neighbours; otherwise degrade to two
    // stops (peek ↔ full) and let MapDrawerSnap.half resolve to full. A short,
    // wide viewport — where a full card row simply doesn't fit between peek and
    // full — lands here, as does a degenerate (0 or absurd) card height.
    final bool halfFits =
        candidate > peek + _kMinSnapGap && candidate < full - _kMinSnapGap;

    return MapDrawerMetrics._(
      peek: peek,
      half: halfFits ? candidate : full,
      full: full,
      snaps: halfFits ? <double>[peek, candidate, full] : <double>[peek, full],
      locked: false,
    );
  }

  /// The extent for a commanded snap.
  double fractionFor(MapDrawerSnap snap) => switch (snap) {
    MapDrawerSnap.peek => peek,
    MapDrawerSnap.half => half,
    MapDrawerSnap.full => full,
  };

  /// The snap a settled extent corresponds to — used to write the user's drag
  /// back to `mapDrawerSnapProvider` so consumers (the count row's chevron)
  /// reflect reality.
  MapDrawerSnap nearestSnap(double size) {
    if (locked) return MapDrawerSnap.peek;
    var best = MapDrawerSnap.peek;
    var bestDelta = (size - peek).abs();
    for (final (snap, extent) in <(MapDrawerSnap, double)>[
      (MapDrawerSnap.half, half),
      (MapDrawerSnap.full, full),
    ]) {
      final delta = (size - extent).abs();
      if (delta < bestDelta) {
        best = snap;
        bestDelta = delta;
      }
    }
    return best;
  }

  /// PROD-3090 — how far the header has shed its count row at [size]: `0` at
  /// [peek] (row fully shown), `1` from [half] upwards (row fully gone).
  ///
  /// Driven off the **live extent**, not the settled snap. Collapsing at settle
  /// would jump the grid by [kMapDrawerHeaderCollapsePx] in a single frame — the
  /// pop doesn't disappear, it just moves. Mapping the collapse onto the
  /// peek→half journey instead makes it continuous under the finger, and needs no
  /// magic constant: the row is exactly gone at the moment the drawer arrives at
  /// the stop where it's no longer wanted.
  double headerCollapseT(double size) {
    if (locked) return 0;
    final travel = half - peek;
    // Degenerate (half collapsed onto full/peek): fall back to a binary shed, so
    // an open drawer never keeps the row.
    if (travel <= 0) return size > peek ? 1 : 0;
    return ((size - peek) / travel).clamp(0.0, 1.0);
  }

  /// The header's height at [size] — the drag handle, plus however much of the
  /// count row survives [headerCollapseT].
  double headerHeight(double size) =>
      mapDrawerHeaderHeight(headerCollapseT(size));

  /// The stop immediately below [size], or null when already at the floor.
  /// Powers the desktop mouse-wheel collapse and the over-scroll handoff.
  MapDrawerSnap? snapBelow(double size) {
    if (locked) return null;
    const eps = 0.002;
    if (size > full - eps && half < full) return MapDrawerSnap.half;
    if (size > peek + eps) return MapDrawerSnap.peek;
    return null;
  }
}
