import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/widgets/cached_image.dart';
import '../../../shared/widgets/soko_card_image.dart';

/// Hero photo at the top of the venue detail page. Single landscape photo
/// at 16:9, full content width, **rounded corners (radius 6)**.
///
/// Uses `BoxFit.cover` (not `BoxFit.contain`) so we get an edge-to-edge
/// image with no letterbox bars on portrait or off-aspect sources. Yes
/// this crops, which is the trade-off Zé picked over the bars.
///
/// Tapping the photo opens it in a fullscreen viewer with pinch-zoom
/// (`InteractiveViewer`). A `Hero` transition links the inline image
/// to the fullscreen one; tag is derived from the image URL so multiple
/// photos on screen (e.g., card thumbnails) don't collide.
///
/// Texture overlays are intentionally stripped per design doc § 5.2.
class VenueHeroPhoto extends StatelessWidget {
  final String? imageUrl;

  /// Texture seed (entity id) + floor colour (venue blue / event green)
  /// for the fallback shown while the photo loads or if it fails — so a
  /// venue whose `image_url` 404s shows a brand hero, not a broken icon.
  final String seed;
  final SokoEntityKind kind;

  /// 16:9 keeps the hero a comfortable ~ 240 px tall on a 430 px Figma
  /// frame and ~ 270 px on the desktop content cap (480 px). Drops cleanly
  /// into the long scrolling page without dominating the viewport.
  static const double _aspectRatio = 16 / 9;
  static const double _radius = 6;

  const VenueHeroPhoto({
    super.key,
    this.imageUrl,
    required this.seed,
    required this.kind,
  });

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return const SizedBox.shrink();
    }
    final heroTag = 'detail-hero-photo:$url';
    return GestureDetector(
      onTap: () => _openFullscreen(context, url, heroTag),
      child: Hero(
        tag: heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_radius),
          child: AspectRatio(
            aspectRatio: _aspectRatio,
            child: SokoCardImage(
              imageUrl: url,
              seed: seed,
              kind: kind,
              fit: BoxFit.cover,
              // The hero is the first thing on the page; a long blank hold
              // reads as sluggish, so reveal the brand floor sooner.
              holdDuration: const Duration(milliseconds: 400),
            ),
          ),
        ),
      ),
    );
  }

  void _openFullscreen(BuildContext context, String url, String heroTag) {
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) =>
            _FullscreenPhotoViewer(imageUrl: url, heroTag: heroTag),
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }
}

class _FullscreenPhotoViewer extends StatelessWidget {
  final String imageUrl;
  final String heroTag;

  const _FullscreenPhotoViewer({required this.imageUrl, required this.heroTag});

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            SafeArea(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Hero(
                  tag: heroTag,
                  child: CachedImage(imageUrl: imageUrl, fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.4),
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonLabel,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
