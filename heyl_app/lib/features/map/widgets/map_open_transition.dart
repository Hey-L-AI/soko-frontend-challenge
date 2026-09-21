import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// PROD — opening the Map from the Discovery feed's floating `Mapa` pill is a
/// **container transform**: the pink button visibly expands into the full-screen
/// map instead of the map just popping in.
///
/// The morph is a shared-element [Hero]:
/// * the source is the `DiscoveryMapButton` (wrapped in a [Hero] with
///   [kMapOpenHeroTag] at its slot), so the flight is anchored to the button's
///   real on-screen rect — whichever state it's in (expanded 141-px pill or
///   collapsed 60-px circle);
/// * the destination is an invisible full-screen anchor in `MapScreen` (same
///   tag), so the flight lands filling the screen.
///
/// The live Mapbox platform view is **never** reparented into the Hero overlay
/// (that would flicker / re-init it). Instead the flight paints only a pink
/// rounded rect — [mapOpenFlightShuttleBuilder] — that grows from the pill to
/// full-bleed (corner radius 30 → 0) and fades its pink out over the final
/// stretch, while the real map page fades in beneath it via
/// [mapOpenPageTransitionsBuilder]. The hand-off reads as the button opening up
/// into the map.
///
/// Reverse (map → feed) plays automatically: Hero runs the flight backwards on
/// pop and the page fade reverses with it.
const String kMapOpenHeroTag = 'map-open-container';

/// The pill's resting corner radius (see `DiscoveryMapButton`), the start of the
/// radius interpolation.
const double _kPillRadius = 30;

/// Total open/close motion. Kept in one place so the route's
/// [transitionDuration] and any consumer stay in lock-step with the Hero flight
/// (Hero borrows the route's animation, so these ARE the flight timings).
const Duration kMapOpenDuration = Duration(milliseconds: 620);
const Duration kMapCloseDuration = Duration(milliseconds: 500);

/// Shuttle painted during the Hero flight: a [AppColors.sokoPink] rounded rect
/// that fills the interpolated flight box (Hero sizes/positions the box; this
/// widget only fills it), with the corner radius easing 30 → 0 and the folded-map
/// glyph fading out in the first slice so the very start still reads as the pill.
///
/// `animation` runs 0 → 1 on open and 1 → 0 on close, so the same builder gives a
/// symmetric expand / collapse.
Widget mapOpenFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = Curves.easeOutCubic.transform(animation.value.clamp(0.0, 1.0));
      final radius = lerpDouble(_kPillRadius, 0, t)!;
      // Pink is fully opaque while it grows, then clears over the last ~30% to
      // hand off to the map fading in beneath.
      final pinkOpacity = (1.0 - (t - 0.7) / 0.3).clamp(0.0, 1.0);
      // Glyph is only legible in the first sliver, before the box has stretched
      // enough to distort it.
      final glyphOpacity = (1.0 - t / 0.18).clamp(0.0, 1.0);
      return Opacity(
        opacity: pinkOpacity,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.sokoPink,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: glyphOpacity <= 0
              ? const SizedBox.shrink()
              : Opacity(
                  opacity: glyphOpacity,
                  child: SizedBox(
                    width: 31,
                    height: 24.47,
                    child: Image.asset(
                      'assets/images/icons/discovery/map_button_glyph.png',
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      color: AppColors.sokoInk,
                      colorBlendMode: BlendMode.srcIn,
                    ),
                  ),
                ),
        ),
      );
    },
  );
}

/// Page transition for the `/map` route: the map fades in over the back half of
/// the flight, so it materialises as the pink shuttle clears. Before that the
/// map page is ~transparent, leaving the feed visible around the growing pill.
Widget mapOpenPageTransitionsBuilder(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return FadeTransition(
    opacity: CurvedAnimation(
      parent: animation,
      curve: const Interval(0.45, 1, curve: Curves.easeOut),
      reverseCurve: const Interval(0.45, 1, curve: Curves.easeIn),
    ),
    child: child,
  );
}
