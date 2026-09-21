import 'package:flutter/material.dart';

/// Snap-to-card physics that still lets a **fast fling carry through several
/// cards**.
///
/// A plain `PageView` (`PageScrollPhysics`) only ever advances one page per
/// fling, however hard you throw it. This instead lets the normal scroll
/// momentum run its course, then rounds the *resting* position to the nearest
/// card — so a small flick lands on the next card and a hard fling lands several
/// along, both settling cleanly on one.
///
/// [itemExtent] is the **pitch**: card width plus the gap between cards, i.e.
/// the distance between two consecutive card leading edges. Passing the card
/// width alone makes the rounding drift by one gap per card.
///
/// Introduced for the map results carousel (PROD-2993, D23) and extracted here
/// when the Discovery top slot needed the same behaviour. `MapResultsCarousel`
/// and `FeedTopCards` are the two callers; keep changes behaviour-neutral for
/// both — `test/features/map/map_results_carousel_geometry_test.dart` and
/// `map_results_carousel_widget_test.dart` pin the map's side.
class CarouselSnapPhysics extends ScrollPhysics {
  const CarouselSnapPhysics({required this.itemExtent, super.parent});

  final double itemExtent;

  @override
  CarouselSnapPhysics applyTo(ScrollPhysics? ancestor) => CarouselSnapPhysics(
    itemExtent: itemExtent,
    parent: buildParent(ancestor),
  );

  double _snapTarget(ScrollMetrics position, double velocity) {
    // Where the free (parent) simulation would come to rest, then round it to a
    // card boundary. Falls back to the current position for a below-threshold
    // release (no simulation), which rounds to the nearest card.
    final sim = super.createBallisticSimulation(position, velocity);
    final rest = sim?.x(double.infinity) ?? position.pixels;
    final page = (rest / itemExtent).roundToDouble();
    return (page * itemExtent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // Let the parent own genuine over-scroll (bounce) at the ends.
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    if (itemExtent <= 0) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = _snapTarget(position, velocity);
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tolerance,
    );
  }

  // A carousel card is not a focus-traversal scroll target; keep implicit
  // scrolling off so a11y focus changes don't fight the snap.
  @override
  bool get allowImplicitScrolling => false;
}
