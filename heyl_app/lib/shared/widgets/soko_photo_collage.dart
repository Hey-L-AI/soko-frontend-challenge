import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cached_image.dart';
import 'hero_image_warmup.dart';
import 'soko_card_image.dart';

/// PROD-4074 — the photo block at the top of the venue / event detail page.
///
/// Replaces the single [VenueHeroPhoto] on the two detail pages with the
/// Figma `6621:15626` collage: one large image plus a right column of up to
/// two stacked images. Layout scales with the count so the page degrades
/// cleanly on the (today: universal) single-image case:
///
///   - **1 image**  → the "big tile" at its natural 4:5 proportions (264×330),
///     **left-aligned** in the content column with the brand background to its
///     right — matching the big tile's left placement in the 2/3+ collages.
///     This is what ships today: the backend sends a single photo
///     (multi-image is PROD-1676), so production shows only this image.
///   - **2 images** → big tile (left) + one full-height tile (right).
///   - **3+ images** → big tile (left) + two stacked tiles (right). A 4th+
///     image is not shown inline; the bottom-right tile carries a "+N"
///     overlay and the whole set is browsable in the fullscreen gallery.
///
/// **Interaction (PROD-4074):**
///   - Tapping the **main** (large) tile opens the fullscreen, pinch-zoom
///     gallery at the current main photo.
///   - Tapping a **secondary** tile promotes that photo into the main slot
///     (swapping the previous main into the tapped slot). Lets the user
///     inspect any photo large without leaving the page.
///
/// Proportions are lifted straight from Figma `6621:15626`: total 400×330 at
/// content width, `gap 6` between columns, `gap 4` between the stacked tiles,
/// big tile 264 wide, stacked tiles 130 wide. Expressed as flex + fixed gaps
/// so it scales across the mobile width and the desktop content cap.
///
/// Texture overlays on the photos are intentionally stripped (design doc
/// § 5.2), matching [VenueHeroPhoto] — [SokoCardImage] still paints the brand
/// floor + fallback while a photo loads or 404s.
class SokoPhotoCollage extends StatefulWidget {
  /// The photo set, in display order. Blank entries should already be
  /// filtered by the model ([_parseDetailImages]); any that slip through are
  /// dropped here defensively. Empty → renders nothing.
  final List<String> imageUrls;

  /// Texture/floor seed (entity id) + floor colour (venue blue / event green)
  /// for the fallback shown while a photo loads or if it fails.
  final String seed;
  final SokoEntityKind kind;

  /// Optional sticker builder for the **main (big left) tile's** top-right
  /// corner — e.g. the rotated relative-date tag on the detail hero. Rides the
  /// actual photo, not the surrounding brand margin (the single-image big tile
  /// only fills ~2/3 of the content width), and sits outside the tile's Hero so
  /// it doesn't animate into the fullscreen viewer. Null → no sticker.
  ///
  /// The builder receives whether the **main photo has loaded**, so the badge
  /// (via `RotatedDateTag.active`) can defer its stamp-in until the poster
  /// paints rather than landing on a blank tile.
  final Widget Function(bool mainImageLoaded)? cornerBadgeBuilder;

  const SokoPhotoCollage({
    super.key,
    required this.imageUrls,
    required this.seed,
    required this.kind,
    this.cornerBadgeBuilder,
  });

  @override
  State<SokoPhotoCollage> createState() => _SokoPhotoCollageState();
}

class _SokoPhotoCollageState extends State<SokoPhotoCollage> {
  static const double _radius = 6;
  static const double _colGap = 6;
  static const double _stackGap = 4;

  /// Figma `6621:15626`: 400 wide × 330 tall content block. Drives the
  /// multi-image collage aspect.
  static const double _collageAspect = 400 / 330;

  /// Single-image treatment (the only case shipping today — the backend sends
  /// one photo; see [_parseDetailImages]). Per PROD-4074 the lone photo is the
  /// Figma "big tile" shown at its natural proportions (264×330, 4:5 portrait)
  /// and **left-aligned** in the content column (#1455, matching the big tile's
  /// placement in the 2/3+ collages), with the page's brand colour showing to
  /// its right — not stretched full-width. [_bigWidthFactor] is the
  /// big tile's share of the 400 px content block (264/400), so it scales with
  /// the column instead of pinning to a fixed pixel width.
  static const double _bigTileAspect = 264 / 330;
  static const double _bigWidthFactor = 264 / 400;

  /// Column widths from Figma (big 264, stacked 130). Used as flex weights.
  static const int _bigFlex = 264;
  static const int _sideFlex = 130;

  /// The photos in current display order. `_order[0]` is the main tile; a tap
  /// on a secondary tile swaps it here to the front. Reset whenever the
  /// incoming [SokoPhotoCollage.imageUrls] change (e.g. a provider refetch).
  late List<String> _order;

  /// Whether the current main tile's photo has painted — gates the corner
  /// badge's stamp-in.
  bool _mainLoaded = false;
  Timer? _badgeFallback;

  @override
  void initState() {
    super.initState();
    _order = _clean(widget.imageUrls);
    _armBadgeFallback();
  }

  @override
  void didUpdateWidget(covariant SokoPhotoCollage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameList(oldWidget.imageUrls, widget.imageUrls)) {
      _order = _clean(widget.imageUrls);
      _mainLoaded = false;
      _armBadgeFallback();
    }
  }

  /// Reveal the corner badge even if the main photo 404s / times out, so a
  /// failed hero never permanently hides the timing chip.
  void _armBadgeFallback() {
    _badgeFallback?.cancel();
    if (widget.cornerBadgeBuilder == null) return;
    _badgeFallback = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && !_mainLoaded) setState(() => _mainLoaded = true);
    });
  }

  @override
  void dispose() {
    _badgeFallback?.cancel();
    super.dispose();
  }

  static List<String> _clean(List<String> urls) => urls
      .map((u) => u.trim())
      .where((u) => u.isNotEmpty)
      .toList(growable: false);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Promote the photo at display slot [slot] into the main tile, swapping the
  /// previous main into that slot. No-op for the main tile itself.
  void _promote(int slot) {
    if (slot == 0) return;
    setState(() {
      final next = List<String>.from(_order);
      final tmp = next[0];
      next[0] = next[slot];
      next[slot] = tmp;
      _order = next;
      // A new photo occupies the main slot — re-gate the badge on its load.
      _mainLoaded = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final urls = _order;
    if (urls.isEmpty) return const SizedBox.shrink();

    if (urls.length == 1) {
      // Single photo (production today): the big tile at its natural 4:5
      // proportions, left-aligned, brand background showing to its right —
      // matching the big tile's left placement in the 2/3+ collages.
      return Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: _bigWidthFactor,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: AspectRatio(
              aspectRatio: _bigTileAspect,
              child: _tile(urls, slot: 0),
            ),
          ),
        ),
      );
    }

    // 2 images: big + one full-height side tile. 3+: big + two stacked.
    final Widget rightColumn = urls.length == 2
        ? _tile(urls, slot: 1)
        : Column(
            children: [
              Expanded(child: _tile(urls, slot: 1)),
              const SizedBox(height: _stackGap),
              Expanded(
                child: _tile(
                  urls,
                  slot: 2,
                  // A 4th+ photo isn't shown inline — surface the remainder as
                  // a "+N" badge. The full set stays reachable in fullscreen.
                  overflowCount: urls.length > 3 ? urls.length - 3 : 0,
                ),
              ),
            ],
          );

    return AspectRatio(
      aspectRatio: _collageAspect,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: _bigFlex, child: _tile(urls, slot: 0)),
          const SizedBox(width: _colGap),
          Expanded(flex: _sideFlex, child: rightColumn),
        ],
      ),
    );
  }

  Widget _tile(List<String> urls, {required int slot, int overflowCount = 0}) {
    final url = urls[slot];
    final isMain = slot == 0;
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(_radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          SokoCardImage(
            imageUrl: url,
            seed: widget.seed,
            kind: widget.kind,
            fit: BoxFit.cover,
            showTexture: false,
            // The main tile is the Hero-flight destination: paint the warmed
            // bytes instantly so the flown poster lands seamlessly instead of
            // re-fading (the "snap at the finish"). Secondary tiles are not
            // flight targets, so they keep the normal cached-image fade.
            instant: isMain,
            // First thing on the page — reveal the brand floor sooner so a
            // slow photo doesn't read as a sluggish blank hold.
            holdDuration: const Duration(milliseconds: 400),
            // Gate the corner badge's stamp-in on the main photo painting.
            onLoaded: isMain
                ? () {
                    if (!_mainLoaded && mounted) {
                      setState(() => _mainLoaded = true);
                    }
                  }
                : null,
          ),
          if (overflowCount > 0)
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
              ),
              child: Center(
                child: Text(
                  '+$overflowCount',
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w600,
                    fontSize: 22,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // Only the main tile links to the fullscreen viewer via Hero.
    final Widget tile = isMain
        ? Hero(
            tag: 'detail-collage-photo:${widget.seed}:main',
            // Linear (not the default arc) so a big flight doesn't overshoot
            // the final size — see [linearHeroRect].
            createRectTween: linearHeroRect,
            child: image,
          )
        : image;
    // The corner sticker rides the main tile's top-right, layered OUTSIDE the
    // Hero (so it doesn't fly into the gallery) and outside the tile's ClipRRect
    // (so the rotated sticker can bleed past the rounded corner). clipBehavior
    // none keeps that bleed visible.
    final Widget content = (isMain && widget.cornerBadgeBuilder != null)
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              tile,
              Positioned(
                top: 8,
                right: 8,
                child: widget.cornerBadgeBuilder!(_mainLoaded),
              ),
            ],
          )
        : tile;

    return GestureDetector(
      // Main tile → fullscreen viewer; secondary tile → promote to main.
      onTap: isMain ? () => _openGallery(urls) : () => _promote(slot),
      child: content,
    );
  }

  void _openGallery(List<String> urls) {
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) =>
            _FullscreenGallery(imageUrls: urls, seed: widget.seed),
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }
}

/// Fullscreen, swipeable gallery. Mirrors the old single-photo viewer
/// ([VenueHeroPhoto._FullscreenPhotoViewer]) — black scrim, pinch-zoom,
/// close button, Esc-to-close — but pages across the whole set, opening on the
/// current main photo (index 0 of the passed order). The first page carries
/// the main tile's Hero tag so the open/close transition animates.
class _FullscreenGallery extends StatefulWidget {
  final List<String> imageUrls;
  final String seed;

  const _FullscreenGallery({required this.imageUrls, required this.seed});

  @override
  State<_FullscreenGallery> createState() => _FullscreenGalleryState();
}

class _FullscreenGalleryState extends State<_FullscreenGallery> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.imageUrls;
    final showCounter = urls.length > 1;
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
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _index = i),
                itemCount: urls.length,
                itemBuilder: (context, i) {
                  final image = CachedImage(
                    imageUrl: urls[i],
                    fit: BoxFit.contain,
                  );
                  return InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    // Only page 0 matches the inline main tile's Hero tag.
                    child: i == 0
                        ? Hero(
                            tag: 'detail-collage-photo:${widget.seed}:main',
                            createRectTween: linearHeroRect,
                            child: image,
                          )
                        : image,
                  );
                },
              ),
            ),
            if (showCounter)
              Positioned(
                top: 0,
                left: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: Text(
                          '${_index + 1} / ${urls.length}',
                          style: const TextStyle(
                            fontFamily: 'ZalandoSans',
                            fontWeight: FontWeight.w500,
                            fontSize: 13,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
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
