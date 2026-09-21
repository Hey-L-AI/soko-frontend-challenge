import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../widgets/zine/list_zine_cover.dart';
import 'zine_cover_recipe.dart';

/// PROD-3217 — offscreen capture of a list's zine cover to a PNG that the
/// backend composites into the IG-Story share card. The Flutter app is the
/// single renderer of the cover, so the share card is pixel-faithful to the
/// app's hero cover instead of a drift-prone server re-implementation.
///
/// The backend composites the PNG full-bleed into a fixed `aspect-ratio: 4/5`
/// box (720px wide) and resizes so the longest edge is ≤1920px. We therefore
/// render at [kCoverCaptureLogicalSize] (4:5) × [kCoverCapturePixelRatio] →
/// 720×900 px, an exact match for the composite box width with no crop.

/// Logical size of the captured cover — 4:5, matching the hero
/// `ListZineCoverCard`.
const Size kCoverCaptureLogicalSize = Size(360, 450);

/// Device-pixel multiplier for the capture. 360×450 @ 2.0 → 720×900 px.
const double kCoverCapturePixelRatio = 2.0;

/// Renders [ListZineCover] (with `showTitle`/`showLogo` on, matching the
/// hero) offscreen and returns a 720×900 PNG.
///
/// Returns `null` on any failure — a cross-origin photo tainting the
/// CanvasKit surface on web, an image/asset load timeout, or a layout error.
/// Callers treat `null` as "skip the upload"; the backend then renders its
/// plain solid-colour fallback (never a blank frame), so a failed capture is
/// never user-visible.
///
/// [overlay] is the live [OverlayState] to mount into — pass the root
/// navigator's own overlay (`navigatorKey.currentState.overlay`), NOT
/// `Overlay.of(navigatorContext)`: the root navigator's context sits *above*
/// its Overlay, so an ancestor lookup from it finds nothing and the capture
/// silently no-ops. The cover is mounted in this overlay, off screen, so
/// `LayoutBuilder` + `AutoSizeText` get a real layout+paint pass.
Future<Uint8List?> captureZineCoverPng({
  required OverlayState overlay,
  required ZineCoverRecipe recipe,
  required String title,
}) async {
  // A context below the overlay — valid for precacheImage + MediaQuery.of.
  final BuildContext context = overlay.context;
  final GlobalKey boundaryKey = GlobalKey();
  OverlayEntry? entry;

  try {
    // 1. Warm the raster paint dependencies so the first painted frame is
    //    complete. The glyph SVG is virtually always already in flutter_svg's
    //    cache by now (the hero cover rendered it), and the settle loop below
    //    covers a cold parse; the photo + texture are what matter for the
    //    composite, so precache those explicitly.
    if (recipe.hasPhoto) {
      // The photo is the cover's PRIMARY content — it MUST be decoded before we
      // capture, else we'd upload a photoless render that the backend would then
      // composite as a stale/wrong cover (PROD-3217). Use a generous bound + one
      // retry so a cold GCS/proxy fetch doesn't false-skip; if it still fails,
      // let it throw → the outer catch returns null → caller skips the upload
      // → the backend stale-guard shows the plain fallback, never a wrong cover.
      final photoProvider = CachedNetworkImageProvider(recipe.photoUrl!);
      try {
        await precacheImage(
          photoProvider,
          context,
        ).timeout(const Duration(seconds: 8));
      } catch (_) {
        // Retry once. `context` is the session-lived root-navigator context
        // (see callers), valid across the await above; any teardown edge is
        // caught by the outer try and yields a null (skip-upload) result.
        await precacheImage(
          photoProvider,
          // ignore: use_build_context_synchronously
          context,
        ).timeout(const Duration(seconds: 8));
      }
    }
    await precacheImage(
      AssetImage(recipe.textureAssetPath),
      // `context` is a session-lived root-navigator context (see the
      // callers), so it stays valid across the precache await above; any
      // teardown edge is caught below and yields a null (skip-upload) result.
      // ignore: use_build_context_synchronously
      context,
    ).timeout(const Duration(seconds: 2), onTimeout: () {});

    // 2. Mount off-screen but painted. NOT Offstage (RenderOffstage skips
    //    paint → a blank/transparent capture); a far-negative Positioned is
    //    laid out and painted normally.
    entry = OverlayEntry(
      builder: (BuildContext _) {
        return Positioned(
          left: -10000,
          top: -10000,
          child: RepaintBoundary(
            key: boundaryKey,
            child: buildCaptureCoverSubtree(
              // Neutralise the user's text-scale so the captured cover is
              // deterministic across devices.
              mediaQuery: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.noScaling),
              recipe: recipe,
              title: title,
            ),
          ),
        );
      },
    );
    overlay.insert(entry);

    // 3. Let AutoSizeText's post-layout font resolution (SeasonMix), the SVG
    //    glyph, and the image layers composite. Bounded paint-ready settle:
    //    pump up to 8 frames, early-breaking once the boundary has painted.
    //    (`debugNeedsPaint` is assert-only — unsafe in release — so the
    //    early break runs in debug; release pumps the full cap ≈130 ms.) The
    //    raster deps are already precached above.
    final WidgetsBinding binding = WidgetsBinding.instance;
    for (int i = 0; i < 8; i++) {
      binding.scheduleFrame();
      await binding.endOfFrame;
      final RenderObject? ro = boundaryKey.currentContext?.findRenderObject();
      bool painted = false;
      assert(() {
        painted = ro is RenderRepaintBoundary && !ro.debugNeedsPaint;
        return true;
      }());
      if (painted) break;
    }

    // 4. Capture.
    final RenderObject? renderObject = boundaryKey.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return null;

    final ui.Image image = await renderObject.toImage(
      pixelRatio: kCoverCapturePixelRatio,
    );
    try {
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final Uint8List? bytes = byteData?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } finally {
      image.dispose();
    }
  } catch (e, st) {
    // Graceful: null → caller skips upload → backend plain fallback.
    debugPrint('[zine-cover-capture] capture failed: $e\n$st');
    return null;
  } finally {
    entry?.remove();
  }
}

/// The captured cover subtree: [ListZineCover] (title + logo on, matching the
/// hero) wrapped in the ambient context the offscreen overlay lacks.
///
/// The [Directionality] + transparent [Material] are load-bearing (PROD-3257):
/// mounted directly in the root Overlay, the cover has no Material /
/// DefaultTextStyle ancestor, so its title text falls back to Flutter's debug
/// placeholder style — yellow with a double underline — which then bakes into
/// the shared IG-Story cover. `MaterialType.transparency` supplies a real
/// DefaultTextStyle without painting a surface over the cover art.
///
/// Extracted (over inlining in the [OverlayEntry]) so the regression test
/// exercises the exact tree that ships.
@visibleForTesting
Widget buildCaptureCoverSubtree({
  required MediaQueryData mediaQuery,
  required ZineCoverRecipe recipe,
  required String title,
}) {
  return MediaQuery(
    data: mediaQuery,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: kCoverCaptureLogicalSize.width,
          height: kCoverCaptureLogicalSize.height,
          child: ListZineCover(
            recipe: recipe,
            title: title,
            showTitle: true,
            showLogo: true,
          ),
        ),
      ),
    ),
  );
}
