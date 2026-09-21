import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

import '../../core/theme/app_colors.dart';

/// Warms Flutter's image cache for a shared-element ("Hero") flight photo so
/// the **actual photo** — not the [SokoCardImage] brand-floor placeholder —
/// is what flies during the open transition.
///
/// Why this exists: opening an item from a zine page is a Flutter `Hero`
/// flight. The flying child is a
/// [CachedNetworkImage]; on a cold image cache it shows its placeholder for the
/// whole ~460ms flight, so the user sees a blank/pastel rectangle glide instead
/// of the poster — which reads as "the animation didn't work". Every open path
/// already holds the destination image URL, so kicking off the decode the
/// instant the user taps (before `context.push`) means the bytes are usually
/// ready by the time the flight starts and the real photo flies.
///
/// Still called on the open paths whose flight was reverted (feed → detail,
/// Library → detail, Library → zine). It is worth keeping there on its own
/// merits: the destination paints its real photo on frame 1 instead of the
/// brand floor, which is the bulk of what made those opens feel fast.
///
/// Uses the same [CachedNetworkImageProvider] the card widgets render with, so
/// the decoded bytes are shared (no double download).
///
/// **Fire-and-forget**: never awaited, so a slow network can never delay the
/// push. No-op for a null/blank URL. Decode/network failures are swallowed —
/// a failed warm-up must never throw or surface; the flight simply falls back
/// to the brand floor exactly as it does today.
void warmHeroImage(BuildContext context, String? url) {
  final trimmed = url?.trim();
  if (trimmed == null || trimmed.isEmpty) return;
  precacheImage(
    CachedNetworkImageProvider(trimmed),
    context,
    onError: (_, __) {},
  );
}

/// Linear rect interpolation for a [Hero] flight, replacing Flutter's default
/// `MaterialRectArcTween`.
///
/// The arc travels the rect along a curve and tweens position and size on
/// *different* curves, so it bulges past the destination mid-flight and then
/// settles back. On a big move that reads as "grows too much, then shrinks";
/// on a mostly-vertical move it reads as a direction change right at the
/// landing — the "it snaps into place near the end" report. Linear runs
/// monotonically to the destination with no overshoot and no corner.
///
/// Pass as `createRectTween` on **both** ends of the flight.
RectTween linearHeroRect(Rect? begin, Rect? end) =>
    RectTween(begin: begin, end: end);

/// Corner radius of the detail-page collage tile every source poster flies
/// into ([soko_photo_collage] `_radius`). Kept in sync so the flight shuttle's
/// rounding matches the destination exactly.
const double _kDetailPosterRadius = 6;

/// A [Hero.flightShuttleBuilder] for a source card whose poster flies into the
/// detail page's [SokoPhotoCollage] main tile.
///
/// **Why this exists:** the poster sources differ from the destination in ways
/// that make the default flight look broken — Library / feed-bundle rows fly a
/// tiny 64×80 thumb wrapped in a notched, bottom-radius-only, paper-grain clip,
/// and the destination is a [SokoCardImage] with a ~400ms brand-floor *hold*.
/// On a cold image cache the default flight (which renders the destination
/// subtree in the overlay) shows that transparent/pastel floor for the whole
/// flight and only "snaps" the real photo in at the end — the reported
/// "cut, then snaps" (PROD-4160-followup). The zine poster avoids it only
/// because its bytes are already hot and it flies as a coordinated pair with
/// the card's colour panel.
///
/// This shuttle sidesteps all of that: for the entire flight it paints a clean,
/// constant `ClipRRect(radius 6)` + `BoxFit.cover` poster straight off the
/// [CachedNetworkImageProvider] — the same provider [warmHeroImage] precaches
/// and [CachedImage] renders with — so the warmed photo is what flies, with no
/// floor-hold and no notch/shape swap. It lands seamlessly on the identical
/// destination collage tile.
///
/// **Set this on the SOURCE hero, not the collage.** Flutter resolves the
/// shuttle as `toHero.flightShuttleBuilder ?? fromHero.flightShuttleBuilder ??
/// default`, so a source-side builder governs both the open (push: source is
/// `fromHero`) and close (pop: source is `toHero`) of the row↔detail flight,
/// while leaving the detail↔fullscreen-gallery zoom (which reuses the same
/// Hero tag but defines no builder on either end) on the default.
HeroFlightShuttleBuilder detailPhotoHeroFlightShuttle(String? url) {
  final trimmed = url?.trim();
  return (
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final Widget content = (trimmed == null || trimmed.isEmpty)
        // No URL to fly (shouldn't happen for photo rows) — a neutral floor is
        // still cleaner than the default's notched thumb / held brand floor.
        ? const ColoredBox(color: AppColors.sokoShade5)
        : Image(
            image: CachedNetworkImageProvider(trimmed),
            fit: BoxFit.cover,
            // Keep the last frame while the (warmed) bytes resolve, so a
            // one-frame miss never flashes empty mid-flight.
            gaplessPlayback: true,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(_kDetailPosterRadius),
      child: SizedBox.expand(child: content),
    );
  };
}
