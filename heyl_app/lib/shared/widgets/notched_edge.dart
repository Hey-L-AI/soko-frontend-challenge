import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Designed ratio of gap to circle: the reference frames use a 12 px circle
/// with a 10 px gap, and the bundle thumbnail holds the same 10/12 at a much
/// smaller size (3.428 px circle, 2.858 px gap). It is the *proportion* that
/// makes the pattern recognisable, not either number on its own.
const double kNotchGapRatio = 10 / 12;

/// Where the half-circle notches sit along an edge of [runWidth].
///
/// Pure geometry, no painting — so the thing that actually has to survive
/// arbitrary card widths can be tested directly.
///
/// ## How this scales, and why
///
/// **The diameter is an input, not a function of the width.** Two reference
/// frames pin the pattern: the event hero (386 px run, 12 px circles) and the
/// bundle thumbnail (60 px run, 3.428 px circles). Their circle-to-run ratios
/// are nothing alike — 0.031 against 0.057 — so the designer is choosing a
/// notch size per surface, the way you would choose a corner radius.
///
/// The two alternatives are both worse:
///
/// * **scale the diameter with the width** and a hero that grows from 400 to
///   800 px gets 24 px craters — a different design element, not the same one
///   bigger;
/// * **keep a fixed count** and the gaps stretch without bound, so the notches
///   drift apart into unrelated dots.
///
/// So the diameter holds, and the **count and gap absorb the width**: fit a
/// whole number of notches at as close to [gapRatio] as the run allows, with
/// the first and last circle flush to the ends. Both reference frames come out
/// exactly right, and every width in between degrades by a fraction of a pixel
/// in the gap rather than by anything you can see.
@immutable
class NotchedEdgeGeometry {
  const NotchedEdgeGeometry({
    required this.runWidth,
    required this.diameter,
    required this.count,
    required this.pitch,
  });

  /// Length of the edge the notches are distributed across.
  final double runWidth;

  /// Circle diameter. The notch itself is the lower half, so it bites
  /// [radius] deep into the surface.
  final double diameter;

  final int count;

  /// Centre-to-centre distance. Equal to [diameter] + the actual gap.
  final double pitch;

  double get radius => diameter / 2;

  /// The realised gap, which flexes around the designed one so the ends land
  /// flush.
  double get gap => count < 2 ? 0 : pitch - diameter;

  /// Centre of notch [i], measured from the start of the run.
  ///
  /// A lone notch is centred on the run rather than parked flush at its start
  /// — "flush at both ends" has no meaning for one circle, and pinning it left
  /// looks like a mistake rather than a decision.
  double centreOf(int i) => count == 1 ? runWidth / 2 : radius + i * pitch;

  List<double> get centres => [for (var i = 0; i < count; i++) centreOf(i)];

  /// Fit notches of [diameter] across [runWidth].
  factory NotchedEdgeGeometry.fit({
    required double runWidth,
    required double diameter,
    double gapRatio = kNotchGapRatio,
  }) {
    if (runWidth <= 0 || diameter <= 0) {
      return NotchedEdgeGeometry(
        runWidth: math.max(runWidth, 0),
        diameter: 0,
        count: 0,
        pitch: 0,
      );
    }

    // A notch can never be wider than the edge it is cut into.
    final d = math.min(diameter, runWidth);

    // Centres run from `radius` to `runWidth - radius`, so the span the gaps
    // have to fill is one diameter short of the run. Working in centres rather
    // than in edges is what keeps the first and last notch flush.
    final span = runWidth - d;
    if (span <= 0) {
      return NotchedEdgeGeometry(
        runWidth: runWidth,
        diameter: d,
        count: 1,
        pitch: 0,
      );
    }

    final nominalPitch = d * (1 + gapRatio);
    var count = math.max(2, (span / nominalPitch).round() + 1);
    // Rounding up on a short run can pack the circles closer than their own
    // diameter; back off until they at least touch rather than overlap.
    while (count > 2 && span / (count - 1) < d) {
      count--;
    }
    // Even two will overlap once the run is barely wider than one circle —
    // `count > 2` above cannot catch that, and the result was a run of circles
    // drawn on top of each other. One notch is the honest answer.
    if (count == 2 && span < d) {
      return NotchedEdgeGeometry(
        runWidth: runWidth,
        diameter: d,
        count: 1,
        pitch: 0,
      );
    }

    return NotchedEdgeGeometry(
      runWidth: runWidth,
      diameter: d,
      count: count,
      pitch: span / (count - 1),
    );
  }
}

/// Clips its [child] so half-circle notches are cut out of the top edge — the
/// treatment on the event hero's poster (`7304:23768`) and the bundle row's
/// thumbnail (`7304:23923`).
///
/// **It clips, it does not paint.** The frames draw filled `Soko/Paper`
/// circles over the image, which is quicker to author but bakes the page
/// colour into the card: on any other background those circles read as bumps
/// ON the card instead of bites out of it. Removing the pixels instead makes
/// the treatment background-independent, which is what lets it be reused —
/// Zé, 2026-08-28.
///
/// [borderRadius] is folded into the same path rather than left to an outer
/// `ClipRRect`, because two clips cannot produce one shape: the corner clip
/// would round a rectangle the notch clip has already bitten into, and the
/// seam shows wherever a notch lands near a corner.
class NotchedTopEdgeClip extends StatelessWidget {
  const NotchedTopEdgeClip({
    super.key,
    required this.child,
    this.diameter = 12,
    this.horizontalInset = 0,
    this.gapRatio = kNotchGapRatio,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;

  /// Circle diameter — see the scaling note on [NotchedEdgeGeometry]. 12 is
  /// the event hero's; the bundle thumbnail uses 3.428.
  final double diameter;

  /// Inset at each end before the run starts. The hero holds 7 px on a 400 px
  /// card, the bundle thumbnail 2 px on 64 px.
  final double horizontalInset;

  final double gapRatio;

  /// The surface's own corners, cut in the same pass as the notches.
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) => ClipPath(
    clipper: NotchedEdgeClipper(
      diameter: diameter,
      horizontalInset: horizontalInset,
      gapRatio: gapRatio,
      borderRadius: borderRadius,
    ),
    child: child,
  );
}

/// The path behind [NotchedTopEdgeClip]. Exposed so a caller that already has
/// its own `ClipPath` — or wants the shape for a border or a shadow — can
/// reuse it rather than re-deriving the geometry.
class NotchedEdgeClipper extends CustomClipper<Path> {
  const NotchedEdgeClipper({
    required this.diameter,
    this.horizontalInset = 0,
    this.gapRatio = kNotchGapRatio,
    this.borderRadius = BorderRadius.zero,
  });

  final double diameter;
  final double horizontalInset;
  final double gapRatio;
  final BorderRadius borderRadius;

  @override
  Path getClip(Size size) {
    final body = Path()..addRRect(borderRadius.toRRect(Offset.zero & size));

    final geometry = NotchedEdgeGeometry.fit(
      runWidth: size.width - horizontalInset * 2,
      diameter: diameter,
      gapRatio: gapRatio,
    );
    if (geometry.count == 0) return body;

    // WHOLE circles centred on y = 0. The upper half falls outside the body,
    // so the difference removes exactly the lower half — and the arc stays a
    // true circle rather than a half-disc whose chord could leave a flat.
    final notches = Path();
    for (final centre in geometry.centres) {
      notches.addOval(
        Rect.fromCircle(
          center: Offset(horizontalInset + centre, 0),
          radius: geometry.radius,
        ),
      );
    }
    return Path.combine(PathOperation.difference, body, notches);
  }

  @override
  bool shouldReclip(covariant NotchedEdgeClipper old) =>
      old.diameter != diameter ||
      old.horizontalInset != horizontalInset ||
      old.gapRatio != gapRatio ||
      old.borderRadius != borderRadius;
}
